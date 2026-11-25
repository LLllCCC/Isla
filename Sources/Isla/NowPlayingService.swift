import Foundation
import AppKit
import Darwin

/// 系统级「正在播放」。
///
/// macOS 15.4 起，`MRMediaRemoteGetNowPlayingInfo` 只对带 Apple 平台签名的进程返回数据：
/// 同一段代码用 `swift` 解释执行能读到，编译成 app bundle / 独立二进制一律返回 nil。
/// 私有 entitlement 会被 AMFI 直接杀掉（"adhoc signed but contains restricted entitlements"）。
///
/// 解法：把读取逻辑放进 JXA 脚本，交给 `/usr/bin/osascript`（平台二进制）执行，
/// 借用它的签名穿透门禁。每次调用约 40–50ms，2 秒轮询一次，无任何 TCC 权限。
final class NowPlayingService {
    static let shared = NowPlayingService()

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        /// MediaRemote 算出来的位置（锚点 + 流逝时间 × rate），采样时刻的值
        var elapsed: Double
        /// 播放器最后一次上报的原始位置，以及距离那次上报过了多久
        var anchorElapsed: Double
        var anchorAge: Double
        /// 播放器自称的播放状态。不可全信：QQ 音乐暂停后仍报 true。
        var isPlaying: Bool
        var artwork: Data?
        var appName: String
        /// 上报本身没有标题、用 app 名顶替的会话（抖音等视频 App 常见）。
        /// 这种「标题」拿去搜歌词会误匹配（网易云搜「抖音」有同名歌），
        /// 歌词模式要据此跳过歌词搜索。
        var titleIsFallback: Bool
        /// 播放器进程（用来做「进程还活着吗 / 还在出声吗」两道校验）
        var pid: Int32
        var bundle: String
        var sampledAt: Date
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.yopo.isla.nowplaying", qos: .utility)
    private var inFlight = false
    private let scriptPath: String?
    private let commandPath: String?

    private(set) var baseElapsed: Double = 0
    private(set) var baseDate = Date()
    private(set) var latest: Track?
    private(set) var lastError: String?

    var onUpdate: ((Track?) -> Void)?
    var isAvailable: Bool { scriptPath != nil }

    private init() {
        scriptPath = Bundle.main.url(forResource: "nowplaying", withExtension: "js")?.path
        commandPath = Bundle.main.url(forResource: "command", withExtension: "js")?.path
        if scriptPath == nil {
            NSLog("Isla: nowplaying.js 缺失，播放模块降级")
        }
    }

    /// 轮询间隔。每次轮询都要 spawn 一个 osascript（约 30–40ms CPU），
    /// 所以不能无脑高频：面板展开 1.0s，收起 1.5s（旧版收起时是 6s，点播放最慢要等 6 秒才变宽）。
    /// 「刚开始播」这一刻还有更快的通路：音频进程数变化会立刻触发 `refreshBurst`，不用等这一拍。
    private var isActive = false
    private var lastPollAt = Date.distantPast

    private var currentInterval: TimeInterval { isActive ? 1.0 : 1.5 }

    func start() {
        guard isAvailable else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    /// 立刻拉一次（音频刚开始/结束时用，不等常规节拍）
    func refreshNow() {
        guard isAvailable else { return }
        lastPollAt = .distantPast
        poll()
    }

    /// 连拉几次：系统的「正在播放」会话刚建立时可能还没就绪，
    /// 单次 refreshNow 拿到 nil 后就退回慢节拍，用户就会看到「点了播放好几秒没反应」。
    private var burstToken = 0
    func refreshBurst(times: Int = 4, spacing: TimeInterval = 0.4) {
        guard isAvailable else { return }
        refreshNow()
        burstToken += 1
        let token = burstToken
        for i in 1...max(1, times) {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(i)) { [weak self] in
                guard let self, self.burstToken == token else { return }
                self.refreshNow()
            }
        }
    }

    /// 面板显隐时切换采样频率（展开恢复 1.2s）
    func setActive(_ active: Bool) {
        isActive = active
        if active { poll() }
    }

    private func tick() {
        guard Date().timeIntervalSince(lastPollAt) >= currentInterval - 0.05 else { return }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        latest = nil
        onUpdate?(nil)
    }

    // MARK: - 读取

    private func poll() {
        guard !inFlight else { return }
        guard let path = scriptPath else { return }
        inFlight = true
        lastPollAt = Date()

        queue.async { [weak self] in
            guard let self else { return }
            let json = self.readFixture() ?? self.runScript(path, args: [])
            let parsed = self.parse(json)
            DispatchQueue.main.async {
                self.inFlight = false
                self.latest = parsed
                if let t = parsed {
                    self.baseElapsed = t.elapsed
                    self.baseDate = t.sampledAt
                }
                self.onUpdate?(parsed)
            }
        }
    }

    /// 测试夹具：`defaults write com.yopo.isla nowPlayingFixture -string /tmp/x.json`
    /// 让同一整套轮询/判定/渲染链路跑在可控输入上（没有播放器也能复现「播放器撒谎」的情形）。
    private func readFixture() -> [String: Any]? {
        guard let path = UserDefaults.standard.string(forKey: "nowPlayingFixture"),
              !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func runScript(_ path: String, args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        // 看门狗：osascript 卡住时不留悬空进程
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: killer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let d = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func parse(_ j: [String: Any]?) -> Track? {
        guard let j, j["none"] == nil, j["error"] == nil else { return nil }
        let app = (j["app"] as? String) ?? ""
        let rawTitle = (j["title"] as? String) ?? ""
        let artist = (j["artist"] as? String) ?? ""
        let duration = (j["duration"] as? Double) ?? 0
        let elapsed = (j["elapsed"] as? Double) ?? 0
        let anchorElapsed = (j["anchorElapsed"] as? Double) ?? elapsed
        let anchorAge = (j["anchorAge"] as? Double) ?? 0
        let rate = (j["rate"] as? Double) ?? 0

        if rawTitle.isEmpty && artist.isEmpty && duration == 0 && app.isEmpty { return nil }

        var track = Track(title: rawTitle.isEmpty ? (app.isEmpty ? L("未命名媒体") : app) : rawTitle,
                          artist: artist.isEmpty ? (rawTitle.isEmpty ? (rate > 0.01 ? "正在播放" : L("已暂停")) : app) : artist,
                          album: (j["album"] as? String) ?? "",
                          duration: duration,
                          elapsed: elapsed,
                          anchorElapsed: anchorElapsed,
                          anchorAge: anchorAge,
                          isPlaying: rate > 0.01,
                          artwork: nil,
                          appName: app,
                          titleIsFallback: rawTitle.isEmpty,
                          pid: Int32((j["pid"] as? Double) ?? 0),
                          bundle: (j["bundle"] as? String) ?? "",
                          sampledAt: Date())

        // 播放器会给出越界位置（实测 QQ 音乐 elapsed 25545 / duration 199）。
        // 这种脏数据只会让进度条满格、歌词跑到最后一句，直接按「停在开头」处理。
        if track.duration > 0, track.elapsed > track.duration + 2 {
            track.elapsed = 0
            track.anchorElapsed = 0
            track.isPlaying = false
        }
        return track
    }

    // MARK: - 传输控制
    // kMRPlay 0 / kMRPause 1 / kMRTogglePlayPause 2 / kMRNextTrack 4 / kMRPreviousTrack 5

    /// 用显式的 play/pause 而不是 toggle：
    /// 实测连续两次 toggle 之间只隔 0.8s 时，第二次会被播放器忽略（状态不翻转）。
    func togglePlay() { send((latest?.isPlaying ?? false) ? 1 : 0) }
    func next() { send(4) }
    func previous() { send(5) }

    private func send(_ command: Int) {
        guard let path = commandPath else { return }
        queue.async { [weak self] in
            _ = self?.runScript(path, args: [String(command)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshBurst(times: 3, spacing: 0.5) }
        }
    }
}

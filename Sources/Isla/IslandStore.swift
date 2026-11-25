import Foundation
import Combine
import Darwin

/// 全局状态：所有视图只读这里，不直接碰系统 API。
///
/// 播放状态是这里最麻烦的一块。MediaRemote 给的两个字段都不可靠：
/// - `rate`：QQ 音乐暂停后仍报 1（实测，且 30 秒内不变）
/// - `elapsed`：MediaRemote 用「锚点 + 流逝时间」算出来的，只要 rate 还是 1 就一直在走
/// 所以播放/暂停不能看播放器自称，要三道校验叠起来：
///   1. 播放器进程还活着吗（杀掉/退出后会话会变僵尸）
///   2. 播放器进程还在向输出设备送音频吗（CoreAudio 进程对象）
///   3. 播放器明确报 rate=0 吗
/// 判停时把时钟**回拨到「最后一次确认有声音」的时刻**，这样歌词停在这一句上，
/// 而不是停在我们发现得晚、已经多跑出去的那几句上。
final class IslandStore: ObservableObject {
    static let shared = IslandStore()

    @Published var track: NowPlayingService.Track?
    /// 当前播放位置（暂停时就是冻结值）
    @Published var elapsed: Double = 0
    @Published var progress: Double = 0
    @Published var volume: Float = 0
    @Published var cpu: Double = 0
    @Published var memGB: Double = 0
    /// 实时网速（B/s，已平滑）
    @Published var netDown: Double = 0
    @Published var netUp: Double = 0
    @Published var panelVisible = false
    @Published var pomodoroRemaining: Double = PomodoroService.shared.remaining
    @Published var pomodoroRunning = false
    @Published var pomodoroPhase = "专注"
    @Published var focusMinutes: Int = PomodoroService.shared.todayMinutes
    @Published var focusCount: Int = PomodoroService.shared.todayCount
    /// 最近 7 天专注分钟数（旧 → 新），仅供迷你柱图
    @Published var weekMinutes: [Int] = PomodoroService.shared.last7DaysMinutes()
    /// 面板当前页（概览 / 剪贴板）。持久化，下次打开还在同一页。
    @Published var page: PanelPage = .overview {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "panelPage") }
    }
    /// 最近一次翻页方向（+1 向后 / -1 向前），仅用于转场动画
    @Published var pageDirection: Int = 1

    // MARK: - 播放时钟

    /// 时钟锚点：running 时表示 clockDate 这一瞬间的位置
    private var clockAnchor: Double = 0
    private var clockDate = Date()
    /// 我们判断的「现在真的在播」
    private(set) var isAdvancing = false
    /// 这一首歌期间是否见过这个进程真的出声；没见过就不能用「没声」判停（AirPlay/虚拟声卡）
    private var audioSeen = false
    private var lastAudioAt: Date?
    /// 这一首歌第一次被看到的时间：启动时如果播放器刚好是暂停的，
    /// 我们从没见它出过声，不能因此把「rate=1 的谎言」当真。
    private var trackFirstSeenAt = Date()
    /// 最近一次采样（用于 4Hz 复评）
    private var sample: NowPlayingService.Track?
    /// 会话空窗开始时刻：NowPlaying 采样返回 nil 时先记时刻并保留旧显示，
    /// 2.5s 后才真正 dropSession（短视频 App 切换内容的正常空窗，不该闪时钟）。
    private var sessionGapSince: Date?
    /// 最近一次确认「真的在播」的时刻。波形动画用它做滞回：
    /// 抖音等短视频 App 切换间隙 advancing 会短暂翻 false，竖杠不该立刻停。
    private(set) var lastAdvancingAt: Date?
    /// 3s 内确认过在播（供波形动画滞回）
    var recentlyAdvancing: Bool {
        lastAdvancingAt.map { Date().timeIntervalSince($0) < 3 } ?? false
    }
    private var evaluator: Timer?
    private var lastTrackKey = ""
    /// 已判定「播放器进程没了」的会话（key = pid|title）。
    /// MediaRemote 的僵尸会话会一直重复推同一首歌，如果只是清空 track，
    /// 下一次轮询又会把它当成新歌拉回来 —— 胶囊就会「缩回去又弹出来」反复抽动。
    private var deadSessions: [String: Date] = [:]
    private func sessionKey(_ t: NowPlayingService.Track) -> String { "\(t.pid)|\(t.title)" }

    /// 外推上限：采样间隔是 2s，正常不会超过；osascript 卡住时靠它兜底，
    /// 避免歌词在「没有任何新数据」的情况下无限往前跑。
    private let extrapolationCap: Double = 2.5

    var liveElapsed: Double {
        guard isAdvancing else { return clockAnchor }
        let extra = min(extrapolationCap, max(0, Date().timeIntervalSince(clockDate)))
        let value = clockAnchor + extra
        if let d = sample?.duration, d > 0 { return min(d, max(0, value)) }
        return max(0, value)
    }

    // MARK: - 翻页

    /// 滚轮翻页：到头会回弹（返回 false）
    @discardableResult
    func turnPage(_ delta: Int) -> Bool {
        let all = PanelPage.tabOrder
        guard let i = all.firstIndex(of: page) else { return false }
        let next = i + delta
        guard all.indices.contains(next) else { return false }
        pageDirection = delta
        page = all[next]
        return true
    }

    /// 直接跳到某页（点圆点）。插件页被卸载后注册表里就没有它了，直接忽略。
    func go(to target: PanelPage) {
        guard target != page, PageRegistry.descriptor(for: target) != nil,
              let from = PanelPage.tabOrder.firstIndex(of: page),
              let to = PanelPage.tabOrder.firstIndex(of: target) else { return }
        pageDirection = to > from ? 1 : -1
        page = target
    }

    /// 插件被禁用/卸载后，当前页可能已不在注册表里：回到概览。
    func ensureValidPage() {
        if !PanelPage.tabOrder.contains(page) {
            page = .overview
        }
    }

    private var tick: Timer?
    private var counter = 0

    private init() {
        let saved = PanelPage(rawValue: UserDefaults.standard.string(forKey: "panelPage") ?? "")
        // 上次停留的插件页可能已被卸载：注册表里没有就回概览。
        page = PageRegistry.descriptor(for: saved) != nil ? saved : .overview
    }

    func start() {
        ClipboardService.shared.start()
        NowPlayingService.shared.onUpdate = { [weak self] t in
            self?.apply(t)
        }
        if SettingsStore.shared.mediaEnabled { NowPlayingService.shared.start() }

        // 4Hz 复评：音频进程状态与进程存活都要独立于 NowPlaying 采样来盯，
        // 否则「暂停」只能等播放器下次上报（QQ 音乐要 30 秒以上）。
        let e = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick4() }
        RunLoop.main.add(e, forMode: .common)
        evaluator = e

        PomodoroService.shared.onTick = { [weak self] in
            guard let self else { return }
            let svc = PomodoroService.shared
            self.pomodoroRemaining = svc.remaining
            self.pomodoroRunning = svc.running
            self.pomodoroPhase = svc.phase.title
            self.focusMinutes = svc.todayMinutes
            self.focusCount = svc.todayCount
        }

        volume = AudioService.shared.volume
        // 第一次 sample 只建立 CPU 基线（内存当场就有值），0.6s 后再采一次，
        // 否则首次展开面板会显示「CPU 0% / 内存 0.0G」，看起来像坏了。
        StatsService.shared.sample()
        memGB = StatsService.shared.memGB
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            StatsService.shared.sample()
            self?.cpu = StatsService.shared.cpuPercent
            self?.memGB = StatsService.shared.memGB
        }

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.once() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    // MARK: - 采样

    private func trackKey(_ t: NowPlayingService.Track) -> String {
        "\(t.title)|\(t.duration)|\(t.pid)"
    }

    private func apply(_ t: NowPlayingService.Track?) {
        let now = Date()
        guard let t else {
            // 短视频 App（抖音等）切换内容时会主动清空并重建「正在播放」会话，
            // 空窗只有一两秒。立刻 dropSession 会让歌词模式的胶囊闪回时钟
            // （2026-11-20 用户反馈「显示时间几秒后恢复」）；宽限期内保持上一首
            // 的显示与状态不动，超过 2.5s 才真正作废。
            if let since = sessionGapSince {
                if now.timeIntervalSince(since) >= 2.5 {
                    sessionGapSince = nil
                    dropSession()
                }
                return
            }
            sessionGapSince = now
            return
        }
        sessionGapSince = nil

        // 僵尸会话：同一个 pid + 同一首歌已经判定死亡，就不要再复活它
        if let diedAt = deadSessions[sessionKey(t)], Date().timeIntervalSince(diedAt) < 600 {
            return
        }
        sample = t
        let key = trackKey(t)
        if key != lastTrackKey {
            // 换歌：一切都重新开始，位置用播放器给的现值
            lastTrackKey = key
            audioSeen = false
            lastAudioAt = nil
            trackFirstSeenAt = now
            clockAnchor = max(0, t.elapsed)
            clockDate = now
            isAdvancing = t.isPlaying
            if t.isPlaying {
                lastAudioAt = now
                lastAdvancingAt = now
            }
            track = t
            publishPosition()
            return
        }

        track = t
        if isAdvancing, t.isPlaying {
            // 播放中：以播放器算出来的位置为准（它比自己按秒累加更准，能吃掉 seek）
            clockAnchor = max(0, t.elapsed)
            clockDate = now
        }
        reevaluate()
    }

    /// 4Hz：先看「有没有新的 App 开始/停止出声」，再复评播放状态。
    /// 音频客户端数量变化是最快能拿到的「播放器动了」信号（CoreAudio 进程对象变化），
    /// 比等 2s 的 NowPlaying 轮询快，是点播放后立刻变宽的关键。
    private var lastAudioClients = -1
    private var lastBurstAt = Date.distantPast
    private func tick4() {
        let clients = AudioService.shared.activeProcessCount
        if clients != lastAudioClients {
            lastAudioClients = clients
            // 通知音、系统音效也会改变数量：1s 内只补拉一次
            if Date().timeIntervalSince(lastBurstAt) > 1.0 {
                lastBurstAt = Date()
                NowPlayingService.shared.refreshBurst(times: 4, spacing: 0.4)
            }
        }
        reevaluate()
    }

    /// 4Hz 复评播放状态。判定顺序：进程活着 → 播放器说停 → 进程没声 → 播放器说在播。
    private func reevaluate() {
        guard let t = sample else { return }
        let now = Date()

        // 1) 播放器进程没了：会话是僵尸（App 被强杀后 MediaRemote 仍会保留很久，
        //    实测 QQ 音乐退出两分钟后 still reporting rate=1，胶囊会一直挂在播放态）
        let alive = DebugFixture.alive ?? !(t.pid > 0 && kill(t.pid, 0) != 0)
        if !alive {
            markDead(t)
            dropSession()
            return
        }

        let audio = DebugFixture.audioOn ?? AudioService.shared.isRendering(pid: t.pid)
        if audio {
            audioSeen = true
            lastAudioAt = now
        }

        // 2) 播放器按钮的实时状态（QQ 音乐）：0.25s 级，比 rate 和 CoreAudio 都快
        if let axPlaying = PlayerProbe.shared.isPlaying(bundle: t.bundle, pid: t.pid) {
            if !axPlaying {
                freeze(at: liveElapsed)
                return
            }
            if t.isPlaying {
                resume()
                return
            }
        }

        // 3) 播放器自己说停了 —— 最干脆，位置也是它给的，直接用
        if !t.isPlaying {
            freeze(at: max(0, t.elapsed))
            return
        }

        // 4) 进程没在出声
        if audioSeen, let last = lastAudioAt, now.timeIntervalSince(last) > 0.9 {
            // 回拨到「最后一次确认有声音」的时刻：CoreAudio 回收进程对象有延迟
            // （QQ 音乐实测约 7 秒），不回拨的话歌词会多跑两三句才停。
            let rewind = max(0, position(at: last.addingTimeInterval(0.35)))
            freeze(at: min(rewind, liveElapsed))
            return
        }

        // 5) 从没见过这个进程出声：可能是 AirPlay/虚拟声卡（只能信播放器），
        //    也可能是「App 启动时播放器本来就是暂停的」——后者更常见，
        //    给 3 秒宽限（播放器开始放声音需要一点时间），之后仍没声就按暂停处理。
        //    真在播的话，下次它一出声音 audioSeen 就会翻真，自动恢复。
        if !audioSeen, now.timeIntervalSince(trackFirstSeenAt) > 3.0 {
            freeze(at: clockAnchor)
            return
        }

        // 6) 兜底：信播放器
        resume()
    }

    /// 记下这个会话已死，避免下一次采样又把它拉起来
    private func markDead(_ t: NowPlayingService.Track) {
        // pid 未知时不做持久标记：不同曲目可能都拿不到 pid，会把后面的正常会话一起拉黑
        guard t.pid > 0 else { return }
        deadSessions[sessionKey(t)] = Date()
        if deadSessions.count > 12 {
            let cutoff = Date().addingTimeInterval(-600)
            deadSessions = deadSessions.filter { $0.value > cutoff }
        }
    }

    /// 会话作废（播放器进程已退出）
    private func dropSession() {
        sample = nil
        track = nil
        isAdvancing = false
        audioSeen = false
        lastAudioAt = nil
        clockAnchor = 0
        elapsed = 0
        progress = 0
        lastTrackKey = ""
        sessionGapSince = nil
    }

    /// 冻结在某个位置（不前进）
    private func freeze(at position: Double) {
        let p = max(0, position)
        // 已经冻在同一个位置就不要每 250ms 再 publish 一次（会无谓触发整条刷新链）
        if !isAdvancing, abs(p - clockAnchor) < 0.01 { return }
        clockAnchor = p
        clockDate = Date()
        isAdvancing = false
        publishPosition()
    }

    private func resume() {
        guard !isAdvancing else { publishPosition(); return }
        // 从冻结位置继续，不用播放器的外推值：暂停期间它一直按 rate=1 往前跑，
        // 直接采用会「一恢复就跳到几分钟后」。
        clockDate = Date()
        isAdvancing = true
        lastAdvancingAt = Date()
        publishPosition()
        // isAdvancing 不是 @Published：位置恰好没变时也要通知一次，
        // 否则控制器不知道「又开始播了」，胶囊要多等 1s 才变宽。
        objectWillChange.send()
    }

    /// 时钟在某个时刻的位置
    private func position(at date: Date) -> Double {
        guard isAdvancing else { return clockAnchor }
        let extra = min(extrapolationCap, max(0, date.timeIntervalSince(clockDate)))
        return clockAnchor + extra
    }

    private func publishPosition() {
        let e = liveElapsed
        if abs(e - elapsed) > 0.01 { elapsed = e }
        let p: Double
        if let d = sample?.duration, d > 0 {
            p = min(1, max(0, e / d))
        } else {
            p = 0
        }
        if abs(p - progress) > 0.001 { progress = p }
    }

    private func once() {
        counter += 1
        publishPosition()

        if counter % 3 == 0 {
            volume = AudioService.shared.volume
            StatsService.shared.sample()
            cpu = StatsService.shared.cpuPercent
            memGB = StatsService.shared.memGB
        }
        // 网速每秒都采（1Hz 差分，滑均 3s）
        NetworkSpeedService.shared.sample()
        netDown = NetworkSpeedService.shared.downBPS
        netUp = NetworkSpeedService.shared.upBPS
        focusMinutes = PomodoroService.shared.todayMinutes
        focusCount = PomodoroService.shared.todayCount
        if counter % 30 == 0 {
            weekMinutes = PomodoroService.shared.last7DaysMinutes()
        }
    }

    func reloadMedia() {
        if SettingsStore.shared.mediaEnabled {
            NowPlayingService.shared.start()
        } else {
            NowPlayingService.shared.stop()
            track = nil
            sample = nil
            isAdvancing = false
            elapsed = 0
            progress = 0
            lastTrackKey = ""
        }
    }

    func refreshVolume() {
        volume = AudioService.shared.volume
    }
}

/// 测试夹具的「外部真相」开关。
///
/// 播放链路的三个输入（会员信息 / 进程存活 / 进程是否出声）里，后两个在真机上无法按剧本编排：
/// QQ 音乐暂停后要 30 秒才改口、CoreAudio 回收进程对象要 7 秒。为了能稳定复现和回归，
/// 这里允许用 `nowPlayingFixtureAudio = on|off`、`nowPlayingFixtureAlive = on|off`
/// 覆盖掉硬件查询。**只在写了这两个 default 时生效**，正常使用完全不受影响。
enum DebugFixture {
    private static var audioRaw: String? { UserDefaults.standard.string(forKey: "nowPlayingFixtureAudio") }
    private static var aliveRaw: String? { UserDefaults.standard.string(forKey: "nowPlayingFixtureAlive") }

    static var audioOn: Bool? {
        switch audioRaw {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    static var alive: Bool? {
        switch aliveRaw {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }
}

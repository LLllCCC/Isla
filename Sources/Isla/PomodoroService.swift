import Foundation
import AppKit

/// 番茄钟：默认 25 分钟专注 / 5 分钟休息（时长可在设置里改）。纯本地计时，零权限。
/// 到点响一声并把「专注完成 / 休息结束」交给上层闪现；可选自动接续下一阶段。
/// 同时按天累计「今日专注时长 / 番茄个数」，落盘到 UserDefaults，跨天自动归零。
final class PomodoroService {
    static let shared = PomodoroService()

    enum Phase {
        case work, rest
        var title: String { self == .work ? "专注" : "休息" }
    }

    private(set) var phase: Phase = .work
    private(set) var remaining: Double = 25 * 60
    private(set) var running = false

    /// 今日统计（持久化）
    private(set) var todaySeconds: Double = 0
    private(set) var todayCount: Int = 0

    var onTick: (() -> Void)?
    /// 某个阶段结束（参数是刚结束的那个阶段）
    var onPhaseComplete: ((Phase) -> Void)?

    private var timer: Timer?
    private let d = UserDefaults.standard
    private static let statsKey = "focusStats"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private var loadedDay = ""
    private var lastPersist = Date.distantPast
    /// 上次已知的时长，用来判断「用户真的改了时长」
    private var cachedWork: Double = 25
    private var cachedRest: Double = 5

    private init() {
        rollIfNeeded()
        cachedWork = SettingsStore.shared.workMinutes
        cachedRest = SettingsStore.shared.restMinutes
        remaining = duration(for: .work)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .islandSettingsChanged, object: nil)
    }

    var progress: Double {
        min(1, max(0, 1 - remaining / duration(for: phase)))
    }

    var todayMinutes: Int { Int(todaySeconds / 60) }

    func duration(for p: Phase) -> TimeInterval {
        let minutes = p == .work ? SettingsStore.shared.workMinutes : SettingsStore.shared.restMinutes
        return max(1, minutes * 60)
    }

    /// 最近 7 天专注分钟数，从旧到新（最后一个是今天）
    func last7DaysMinutes() -> [Int] {
        let cal = Calendar.current
        let all = d.dictionary(forKey: Self.statsKey) ?? [:]
        return (0..<7).reversed().map { offset -> Int in
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { return 0 }
            let key = Self.dayFormatter.string(from: day)
            let secs = (all[key] as? [String: Double])?["seconds"] ?? 0
            return Int(secs / 60)
        }
    }

    func toggle() {
        running ? pause() : start()
    }

    func start() {
        guard !running else { return }
        rollIfNeeded()
        if remaining <= 0 { remaining = duration(for: phase) }
        running = true
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        onTick?()
    }

    func pause() {
        running = false
        timer?.invalidate()
        timer = nil
        persist(force: true)
        onTick?()
    }

    func reset() {
        pause()
        phase = .work
        remaining = duration(for: .work)
        onTick?()
    }

    /// 退出前强制落盘（AppDelegate 调用）
    func flush() { persist(force: true) }

    // MARK: - 计时

    private func tick() {
        rollIfNeeded()
        remaining = max(0, remaining - 0.5)
        if running, phase == .work {
            todaySeconds += 0.5
            persist()
        }
        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
            running = false

            let finished = phase
            if finished == .work {
                todayCount += 1
                persist(force: true)
            }
            phase = finished == .work ? .rest : .work
            remaining = duration(for: phase)

            if SettingsStore.shared.completionSound { chime(for: finished) }
            onPhaseComplete?(finished)

            if SettingsStore.shared.autoStartNext {
                start()
                return
            }
        }
        onTick?()
    }

    private func chime(for finished: Phase) {
        let name = finished == .work ? "Glass" : "Ping"
        NSSound(named: NSSound.Name(name))?.play()
    }

    @objc private func settingsChanged() {
        let w = SettingsStore.shared.workMinutes
        let r = SettingsStore.shared.restMinutes
        guard abs(w - cachedWork) > 0.001 || abs(r - cachedRest) > 0.001 else { return }
        let oldDuration = (phase == .work ? cachedWork : cachedRest) * 60
        cachedWork = w
        cachedRest = r
        // 只在「没在跑」且剩余时间还停在旧满值时，才跟着新时长重置
        if !running, remaining >= oldDuration - 0.5 {
            remaining = duration(for: phase)
        }
        onTick?()
    }

    // MARK: - 今日统计持久化

    private func rollIfNeeded() {
        let key = Self.dayFormatter.string(from: Date())
        guard key != loadedDay else { return }
        loadedDay = key
        todaySeconds = 0
        todayCount = 0
        let all = d.dictionary(forKey: Self.statsKey) ?? [:]
        if let e = all[key] as? [String: Double] {
            todaySeconds = e["seconds"] ?? 0
            todayCount = Int(e["count"] ?? 0)
        }
    }

    private func persist(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPersist) < 10 { return }
        lastPersist = now
        rollIfNeeded()
        var all = d.dictionary(forKey: Self.statsKey) ?? [:]
        all[loadedDay] = ["seconds": todaySeconds, "count": Double(todayCount)]
        if all.count > 90 {
            for k in all.keys.sorted().prefix(all.count - 90) { all.removeValue(forKey: k) }
        }
        d.set(all, forKey: Self.statsKey)
    }
}

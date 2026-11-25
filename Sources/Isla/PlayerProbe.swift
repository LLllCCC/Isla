import AppKit
import ApplicationServices

/// 播放器「播放/暂停」按钮探测。
///
/// 为什么需要它：MediaRemote 的 `rate` 会撒谎（QQ 音乐暂停后 30 秒内仍报 1），
/// CoreAudio 回收「进程正在出声」的进程对象又要 7 秒左右。
/// 但播放器自己的辅助功能树里那颗按钮是**实时**的：
///   QQ 音乐：desc 在「播放」与「暂停」之间切换（在播放时显示「暂停」按钮）
/// 读不到就返回 nil，完全退回原有判定，不影响其他播放器。
///
/// 只在 Isla 已有辅助功能权限时工作（菜单栏避让本来就要这个权限）。
final class PlayerProbe {
    static let shared = PlayerProbe()
    private init() {}

    /// 暂停态按钮的描述词。命中「暂停」说明正在播放，命中这些说明已暂停。
    private let pausedWords: Set<String> = ["播放", "继续播放", "play", "resume"]

    /// AXIsProcessTrusted() 每次都问 tccd，4Hz 调会白白抬高空闲 CPU；20 秒缓存一次。
    private var trustCache: (value: Bool, at: Date)?
    private var cachedElement: AXUIElement?
    private var cachedOwner: String = ""
    private var lastScanAt = Date.distantPast
    private var lastResult: Bool?

    /// true = 在播，false = 暂停，nil = 这个播放器读不出来
    func isPlaying(bundle: String, pid: Int32) -> Bool? {
        guard pid > 0 else { return nil }
        guard isTrusted() else {
            debugLog("not trusted (pid=\(pid) bundle=\(bundle))")
            return nil
        }
        let owner = "\(bundle)#\(pid)"
        if owner != cachedOwner {
            cachedElement = nil
            cachedOwner = owner
            lastResult = nil
            lastScanAt = .distantPast
        }

        if let el = cachedElement, let desc = description(of: el) {
            if let v = interpret(desc) { lastResult = v; return v }
            cachedElement = nil
        } else if cachedElement != nil {
            cachedElement = nil
        }

        // 扫描很贵（整棵窗口树），失败后 15 秒内不重试，避免 4Hz 空转
        guard Date().timeIntervalSince(lastScanAt) > 15 else { return nil }
        lastScanAt = Date()
        guard let el = findToggle(pid: pid) else {
            debugLog("scan \(owner) -> not found")
            return nil
        }
        cachedElement = el
        guard let desc = description(of: el), let v = interpret(desc) else {
            debugLog("scan \(owner) -> desc=\(description(of: el) ?? "nil")")
            return nil
        }
        debugLog("scan \(owner) -> desc=\(desc) playing=\(v)")
        lastResult = v
        return v
    }

    private func isTrusted() -> Bool {
        if let c = trustCache, Date().timeIntervalSince(c.at) < 20 { return c.value }
        let v = AXIsProcessTrusted()
        trustCache = (v, Date())
        return v
    }

    private func debugLog(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "playbackDebug") else { return }
        let text = String(format: "%.3f %@\n", Date().timeIntervalSince1970, line)
        let path = "/tmp/macisland-probe.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func interpret(_ desc: String) -> Bool? {
        let d = desc.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 播放器按钮描述不一定是单个词：QQ 音乐播放中显示「暂停播放」，
        // 只做精确匹配会漏掉，退回 3-8 秒的慢判定。
        if d.hasPrefix("暂停") || d.hasPrefix("pause") { return true }
        if pausedWords.contains(d) { return false }
        return nil
    }

    private func description(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// 在窗口树里找「播放/暂停」那颗按钮。
    /// 只从 kAXWindowsAttribute 往里走：菜单栏里的「播放/暂停」菜单项也有同样的描述，
    /// 但那是「点一下会执行什么」，不是当前状态，必须排除。
    private func findToggle(pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        var budget = 900
        var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
        while !queue.isEmpty, budget > 0 {
            let (el, depth) = queue.removeFirst()
            budget -= 1
            if let desc = description(of: el), interpret(desc) != nil { return el }
            guard depth < 10 else { continue }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                for k in kids.prefix(60) { queue.append((k, depth + 1)) }
            }
        }
        return nil
    }
}

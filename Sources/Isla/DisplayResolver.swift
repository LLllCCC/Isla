import AppKit
import Combine

extension Notification.Name {
    /// 岛所在的显示器发生切换（指针跨屏 / 指定屏被拔掉）。控制器收到后重排窗口。
    static let islandActiveScreenChanged = Notification.Name("islandActiveScreenChanged")
}

/// 设置页用的显示器清单。屏幕增减时自动刷新，SwiftUI 不用自己监听系统通知。
final class DisplayCatalog: ObservableObject {
    static let shared = DisplayCatalog()

    @Published private(set) var screens: [DisplaySnapshot] = []
    @Published private(set) var activeID: CGDirectDisplayID = 0

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    func reload() {
        screens = NSScreen.screens.map(DisplayResolver.snapshot(of:))
        activeID = DisplayResolver.shared.activeID
    }

    var activeName: String {
        screens.first(where: { $0.id == activeID })?.name ?? "主显示器"
    }
}

/// 「岛在哪块屏」的唯一决策点。
///
/// 优先级：强制屏（如有）> 用户设置（主屏 / 跟随鼠标 / 指定屏）。
/// 指针跨屏要停 0.45s 才搬家，且面板展开 / 拖动 / 缩回时不搬——避免工作到一半界面跳屏。
final class DisplayResolver {
    static let shared = DisplayResolver()

    private(set) var activeScreen: NSScreen
    private(set) var activeID: CGDirectDisplayID

    /// 强制屏：居中垂帘可用来锁定状态项所在屏（槽位不可读时不锁，按用户设置选屏）。
    private var forcedID: CGDirectDisplayID?
    /// 指针跨屏的延后切换（可取消）
    private var pendingSwitch: DispatchWorkItem?
    private var menuBarCache: [CGDirectDisplayID: CGFloat] = [:]

    private var debugEnabled: Bool { UserDefaults.standard.bool(forKey: "displayDebug") }

    private init() {
        let s = NSScreen.main ?? NSScreen.screens.first!
        activeScreen = s
        activeID = Self.id(of: s)
        // 预热每块屏的菜单栏高度，避免第一次读到时系统还在「自动隐藏」状态
        for scr in NSScreen.screens { _ = menuBarHeight(of: scr) }
    }

    // MARK: - 屏幕信息

    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func snapshot(of screen: NSScreen) -> DisplaySnapshot {
        let all = NSScreen.screens
        let displayID = id(of: screen)
        let primaryID = all.first.map(id(of:))
        let index = all.firstIndex(where: { id(of: $0) == displayID }) ?? 0
        // 本机实测 localizedName 可能为空串（macOS 27），设置页的下拉不能显示空白行
        let raw = screen.localizedName
        let name = raw.isEmpty ? (displayID == primaryID ? "主显示器" : String(format: L("显示器 %d"), index + 1)) : raw
        return DisplaySnapshot(
            id: displayID,
            name: name,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            isPrimary: displayID == primaryID
        )
    }

    /// 当前屏的菜单栏高度（自动隐藏时沿用该屏上一次已知值）
    var menuBarHeight: CGFloat { menuBarHeight(of: activeScreen) }

    func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let snap = Self.snapshot(of: screen)
        // 副屏可能压根没有菜单栏（关闭「显示器各自拥有独立空间」时）：
        // 没有缓存就按 0 处理，别凭空留 30pt 缝；主屏仍按 30 兜底。
        return DisplaySelection.menuBarHeight(for: snap, cache: &menuBarCache,
                                              fallback: snap.isPrimary ? 30 : 0)
    }

    // MARK: - 决策

    /// 重新解析目标屏。返回是否发生了「换屏」。
    @discardableResult
    func refresh(forceLayout: Bool = false, notify: Bool = true) -> Bool {
        guard let target = resolveScreen() else { return false }
        let newID = Self.id(of: target)
        let changed = newID != activeID
        activeScreen = target
        activeID = newID
        if changed || forceLayout {
            DisplayCatalog.shared.reload()
        }
        if changed {
            log("active screen → \(target.localizedName) id=\(newID) target=\(SettingsStore.shared.screenTarget.rawValue)")
            if notify {
                NotificationCenter.default.post(name: .islandActiveScreenChanged, object: nil)
            }
        }
        return changed
    }

    /// 居中垂帘槽位可读时传入状态项所在屏；菜单栏胶囊等形态传 nil 解除强制。
    /// 不发通知：调用方（applyForm）本来就处在重排流程里，再发会自我递归。
    func setForcedScreen(_ screen: NSScreen?) {
        forcedID = screen.map(Self.id(of:))
        _ = refresh(notify: false)
    }

    /// 指针移动时调用。只有「跟随鼠标」模式才可能触发搬家。
    /// busy = 面板展开 / 拖动组件 / 缩回顶边：这些状态下先不搬，等下一次指针移动再判断。
    func pointerMoved(to point: CGPoint, busy: Bool) {
        guard forcedID == nil, SettingsStore.shared.screenTarget == .pointer else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let id = Self.id(of: screen)
        guard id != activeID else {
            pendingSwitch?.cancel()
            pendingSwitch = nil
            return
        }
        guard !busy else { return }
        // 已经为同一块屏排过队就不再重置计时，否则指针持续移动会永远切不过去。
        if pendingSwitch != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSwitch = nil
            guard SettingsStore.shared.screenTarget == .pointer, self.forcedID == nil else { return }
            // 延迟期间指针可能已经移回原屏
            guard let now = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
                  Self.id(of: now) == id else { return }
            _ = self.refresh()
        }
        pendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// 系统屏幕参数变化（插拔 / 改分辨率 / 排列）后重算。
    func screenParametersChanged() {
        pendingSwitch?.cancel()
        pendingSwitch = nil
        menuBarCache = menuBarCache.filter { pair in
            NSScreen.screens.contains(where: { Self.id(of: $0) == pair.key })
        }
        _ = refresh(forceLayout: true)
    }

    private func resolveScreen() -> NSScreen? {
        let all = NSScreen.screens
        guard !all.isEmpty else { return nil }

        if let fid = forcedID, let hit = all.first(where: { Self.id(of: $0) == fid }) {
            return hit
        }
        let target = SettingsStore.shared.screenTarget
        let snaps = all.map(Self.snapshot(of:))
        guard let chosen = DisplaySelection.resolve(
            target: target,
            fixedID: target == .fixed ? CGDirectDisplayID(SettingsStore.shared.screenID) : nil,
            pointer: NSEvent.mouseLocation,
            screens: snaps,
            current: activeID
        ) else { return nil }
        return all.first(where: { Self.id(of: $0) == chosen.id })
    }

    private func log(_ line: String) {
        guard debugEnabled else { return }
        let path = "/tmp/isla-display.log"
        let stamped = "\(Date()) \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(stamped.data(using: .utf8)!); h.closeFile()
        } else {
            try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

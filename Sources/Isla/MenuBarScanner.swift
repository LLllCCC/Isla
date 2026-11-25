import AppKit
import ApplicationServices
import Combine

extension Notification.Name {
    static let islandMenuBarScanUpdated = Notification.Name("islandMenuBarScanUpdated")
}

/// 读取菜单栏状态项的位置，算出「离屏幕中线最近的合法空位」。
/// 只读 AX 位置/尺寸，不移动、不点击任何其它 App 的图标。
/// 没有辅助功能权限时返回 nil，调用方回退屏幕正中。
struct MenuBarSnapshot {
    let items: [CGRect]          // AX 坐标（原点在主屏左上，y 向下）
    let screenFrame: CGRect     // AppKit 坐标（原点左下）
    let displayID: CGDirectDisplayID
    let menuBarHeight: CGFloat
    let searchMinX: CGFloat
    let searchMaxX: CGFloat
    let timestamp: Date

    func bestCenter(forWidth width: CGFloat, margin: CGFloat = 4) -> CGFloat? {
        guard width > 0, searchMaxX > searchMinX else { return nil }
        var blocks: [(CGFloat, CGFloat)] = []
        for r in items.sorted(by: { $0.minX < $1.minX }) {
            let lo = r.minX - margin
            let hi = r.maxX + margin
            guard hi > searchMinX, lo < searchMaxX else { continue }
            if let last = blocks.last, lo <= last.1 {
                blocks[blocks.count - 1].1 = max(last.1, hi)
            } else {
                blocks.append((lo, hi))
            }
        }

        var free: [(CGFloat, CGFloat)] = []
        var cursor = searchMinX
        for b in blocks {
            if b.1 <= cursor { continue }
            if b.0 > cursor { free.append((cursor, min(b.0, searchMaxX))) }
            cursor = max(cursor, b.1)
            if cursor >= searchMaxX { break }
        }
        if cursor < searchMaxX { free.append((cursor, searchMaxX)) }

        let need = width + margin * 2
        let mid = screenFrame.midX
        var best: (center: CGFloat, gap: CGFloat, distance: CGFloat)?
        for f in free where f.1 - f.0 >= need {
            let minC = f.0 + width / 2 + margin
            let maxC = f.1 - width / 2 - margin
            guard minC <= maxC else { continue }
            let candidate = min(max(mid, minC), maxC)
            let d = abs(candidate - mid)
            if best == nil || d < best!.distance || (d == best!.distance && (f.1 - f.0) > best!.gap) {
                best = (candidate, f.1 - f.0, d)
            }
        }
        return best?.center
    }
}

extension MenuBarScanner {
    /// 以 center 为轴，左右最近的状态项之间还能用多宽（已扣 margin）。
    /// 用于给「歌词加宽」封顶：宁可少宽一点，也不要把邻居图标压在下面。
    func symmetricFreeWidth(around center: CGFloat, margin: CGFloat = 6) -> CGFloat? {
        guard let snap = snapshot,
              snap.displayID == DisplayResolver.shared.activeID else { return nil }
        var leftLimit = snap.searchMinX
        var rightLimit = snap.searchMaxX
        for r in snap.items {
            if r.maxX + margin <= center {
                leftLimit = max(leftLimit, r.maxX + margin)
            } else if r.minX - margin >= center {
                rightLimit = min(rightLimit, r.minX - margin)
            }
        }
        let half = min(center - leftLimit, rightLimit - center)
        return half > 60 ? half * 2 : nil
    }
}

/// 设置页用的轻量授权状态。AX 授权弹窗是异步的，用户点完后需要主动刷新。
final class AXPermissionStatus: ObservableObject {
    static let shared = AXPermissionStatus()
    @Published private(set) var trusted = MenuBarScanner.isTrusted

    private init() {}

    func refresh() {
        let now = MenuBarScanner.isTrusted
        if now != trusted { trusted = now }
    }

    /// 系统弹窗出现后轮询几次，用户授权完自动点亮。
    func refreshAfterPrompt() {
        for delay in stride(from: 0.8, through: 8.0, by: 1.0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }
}

final class MenuBarScanner {
    static let shared = MenuBarScanner()
    private let queue = DispatchQueue(label: "com.yopo.isla.menubar.scan", qos: .utility)
    private(set) var snapshot: MenuBarSnapshot?
    private var scanning = false

    private init() {}

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func bestCenter(forWidth width: CGFloat) -> CGFloat? {
        guard let snapshot,
              snapshot.displayID == DisplayResolver.shared.activeID,
              Date().timeIntervalSince(snapshot.timestamp) < 30 else { return nil }
        return snapshot.bestCenter(forWidth: width)
    }

    /// 被系统隐藏/未落位的状态项无法读窗口坐标时，用「状态区最左边界」反推槽位：
    /// 返回岛应该贴住的**右缘**（最左状态项 - margin）。用右缘而不是中心，
    /// 是为了歌词加宽时胶囊只向左长，不会因为宽度变化而整体跳位。
    func reservedSlotRightEdge(forWidth width: CGFloat, margin: CGFloat = 6) -> CGFloat? {
        guard let snapshot, snapshot.displayID == DisplayResolver.shared.activeID,
              Date().timeIntervalSince(snapshot.timestamp) < 15,
              width > 0, let leftmost = snapshot.items.map(\.minX).min() else { return nil }
        let edge = leftmost - margin
        // 至少给 App 菜单留 24pt，别把岛放到「文件 / 编辑」上面
        guard edge - width >= snapshot.searchMinX else { return nil }
        return edge
    }

    /// 上一次成功避让的落点。下次启动/切换形态时先用它，避免先落中线再跳到空位；
    /// 只对同一块屏、同一屏宽、同一胶囊宽度有效，扫描完成后仍会校正。
    func cachedCenter(forWidth width: CGFloat) -> CGFloat? {
        let d = UserDefaults.standard
        let savedWidth = d.double(forKey: "macisland.lastAvoidWidth")
        let savedScreen = d.double(forKey: "macisland.lastAvoidScreenWidth")
        let savedCenter = d.double(forKey: "macisland.lastAvoidCenterX")
        let savedDisplay = d.object(forKey: "macisland.lastAvoidDisplayID") as? Int
        guard savedDisplay == Int(DisplayResolver.shared.activeID),
              abs(savedWidth - width) < 0.5,
              abs(savedScreen - IslandMetrics.screen.frame.width) < 0.5,
              savedCenter >= IslandMetrics.screen.frame.minX + width / 2,
              savedCenter <= IslandMetrics.screen.frame.maxX - width / 2 else { return nil }
        return savedCenter
    }

    func rememberCenter(_ center: CGFloat, forWidth width: CGFloat) {
        let d = UserDefaults.standard
        d.set(center, forKey: "macisland.lastAvoidCenterX")
        d.set(width, forKey: "macisland.lastAvoidWidth")
        d.set(IslandMetrics.screen.frame.width, forKey: "macisland.lastAvoidScreenWidth")
        d.set(Int(DisplayResolver.shared.activeID), forKey: "macisland.lastAvoidDisplayID")
    }

    /// 弹系统授权提示。只在用户主动点「授予权限」时调用，不在启动时骚扰。
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func scan() {
        guard Self.isTrusted, !scanning else { return }
        scanning = true
        let screen = IslandMetrics.screen
        let ownPID = NSRunningApplication.current.processIdentifier
        let screenFrame = screen.frame
        let displayID = DisplayResolver.id(of: screen)
        let menuBarHeight = IslandMetrics.menuBarHeight

        queue.async { [weak self] in
            let snapshot = Self.collect(screenFrame: screenFrame,
                                        displayID: displayID,
                                        menuBarHeight: menuBarHeight,
                                        ownPID: ownPID)
            DispatchQueue.main.async {
                guard let self else { return }
                // 扫描期间换了屏：这份快照作废，别把 A 屏的空位用到 B 屏上
                guard DisplayResolver.shared.activeID == displayID else {
                    self.scanning = false
                    return
                }
                self.snapshot = snapshot
                self.scanning = false
                if snapshot != nil {
                    NotificationCenter.default.post(name: .islandMenuBarScanUpdated, object: nil)
                }
            }
        }
    }

    private static func collect(screenFrame: CGRect, displayID: CGDirectDisplayID,
                                menuBarHeight: CGFloat,
                                ownPID: pid_t) -> MenuBarSnapshot? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        let axTop = primaryTop - screenFrame.maxY
        let stripMinY = axTop
        let stripMaxY = axTop + menuBarHeight

        var rects: [CGRect] = []
        var menuRight = screenFrame.minX + 40

        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated, app.processIdentifier != ownPID else { continue }
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // 不响应的 App 不要把整轮扫描拖住；0.2s 足够正常进程返回属性。
            AXUIElementSetMessagingTimeout(axApp, 0.2)

            if let extrasValue = copyAttr(axApp, "AXExtrasMenuBar") {
                let extras = extrasValue as! AXUIElement
                let children = copyAttr(extras, kAXChildrenAttribute) as? [AXUIElement] ?? []
                for child in children {
                    guard let p = pointAttr(child, kAXPositionAttribute),
                          let s = sizeAttr(child, kAXSizeAttribute),
                          s.width > 0, s.height > 0, s.width < 500,
                          p.y >= stripMinY - 2, p.y < stripMaxY + 2,
                          p.x >= screenFrame.minX - 2, p.x < screenFrame.maxX else { continue }
                    rects.append(CGRect(x: p.x, y: p.y, width: s.width, height: s.height))
                }
            }

            // 当前前台 App 的左侧菜单标题也算边界：岛不要跑到 App 菜单里。
            if app.isActive, let barValue = copyAttr(axApp, kAXMenuBarAttribute) {
                let bar = barValue as! AXUIElement
                let children = copyAttr(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
                for child in children {
                    if let p = pointAttr(child, kAXPositionAttribute),
                       let s = sizeAttr(child, kAXSizeAttribute), s.width > 0 {
                        menuRight = max(menuRight, p.x + s.width)
                    }
                }
            }
        }

        let lo = max(screenFrame.minX + 24, menuRight + 10)
        let hi = screenFrame.maxX - 8
        guard hi > lo else { return nil }
        return MenuBarSnapshot(items: rects, screenFrame: screenFrame,
                               displayID: displayID,
                               menuBarHeight: menuBarHeight,
                               searchMinX: lo, searchMaxX: hi, timestamp: Date())
    }

    private static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        return result == .success ? value : nil
    }

    private static func pointAttr(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = copyAttr(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func sizeAttr(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let value = copyAttr(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
    }
}

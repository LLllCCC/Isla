import AppKit

/// 一台显示器的几何快照。与 NSScreen 解耦，纯结构体，
/// 这样「选哪块屏 / 菜单栏多高 / 放不放得下」都能在命令行里注入假数据做断言。
struct DisplaySnapshot: Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// AppKit 坐标（原点左下，可为负；副屏在主屏下方时 minY < 0）
    let frame: NSRect
    let visibleFrame: NSRect
    /// 刘海屏的顶部安全区；无刘海为 0
    let safeAreaTop: CGFloat
    let isPrimary: Bool

    /// 菜单栏高度 = 屏幕顶到可视区顶。自动隐藏时两者相等 → 0。
    var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// 是否带刘海（MacBook Pro 14/16 等）
    var hasNotch: Bool { safeAreaTop > 0 }
}

/// 岛落在哪块屏。
enum ScreenTarget: String, CaseIterable, Identifiable {
    case main, pointer, fixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main:    return "主显示器"
        case .pointer: return "跟随鼠标"
        case .fixed:   return "指定显示器"
        }
    }

    var detail: String {
        switch self {
        case .main:    return "固定留在主显示器（系统菜单栏所在的那块）"
        case .pointer: return "鼠标停在另一块屏时，岛自动搬过去"
        case .fixed:   return "手动选一块屏，插拔后找不到就回退主屏"
        }
    }
}

enum DisplaySelection {

    /// 选出目标显示器。
    /// 任何失效配置（指定屏被拔掉、指针落在屏幕缝隙、screens 为空）都保证返回一个结果：
    /// 先回退当前屏，再回退主屏——绝不让调用方拿到 nil 去布局。
    static func resolve(target: ScreenTarget,
                        fixedID: CGDirectDisplayID?,
                        pointer: CGPoint,
                        screens: [DisplaySnapshot],
                        current: CGDirectDisplayID? = nil) -> DisplaySnapshot? {
        guard !screens.isEmpty else { return nil }
        let primary = screens.first(where: { $0.isPrimary }) ?? screens[0]
        let fallback = screens.first(where: { $0.id == current }) ?? primary

        switch target {
        case .main:
            return primary
        case .pointer:
            return screens.first(where: { $0.frame.contains(pointer) }) ?? fallback
        case .fixed:
            guard let fixedID, let hit = screens.first(where: { $0.id == fixedID }) else {
                return fallback
            }
            return hit
        }
    }

    /// 菜单栏高度记忆：系统「自动隐藏菜单栏」时 visibleFrame == frame，
    /// 不能把 0 当成真实高度，否则面板会贴到屏幕最顶端被菜单栏压住。
    /// 每块屏各记一份——副屏的菜单栏高度可能和主屏不同。
    static func menuBarHeight(for screen: DisplaySnapshot,
                              cache: inout [CGDirectDisplayID: CGFloat],
                              fallback: CGFloat = 30) -> CGFloat {
        let h = screen.menuBarHeight
        if h > 1, h < 64 {
            cache[screen.id] = h
            return h
        }
        return cache[screen.id] ?? fallback
    }

    /// 这块屏能不能装下给定尺寸（留 40pt 给菜单栏与底部呼吸空间）。
    /// 用于切屏前的合理性判断：宁可留在原地，也不要把岛放到一块塞不下的副屏上。
    static func fits(size: CGSize, in screen: DisplaySnapshot) -> Bool {
        size.width <= screen.frame.width && size.height <= screen.frame.height - 40
    }
}

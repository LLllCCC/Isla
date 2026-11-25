import AppKit

/// 所有几何量的唯一来源。任何模块都不许自己算菜单栏高度。
enum IslandMetrics {

    /// 岛当前所在的屏。多显示器下由 DisplayResolver 决策（主屏 / 跟随鼠标 / 指定屏），
    /// 其它任何模块都不许直接读 NSScreen.main——否则面板和胶囊会落在不同的屏上。
    static var screen: NSScreen {
        DisplayResolver.shared.activeScreen
    }

    /// 菜单栏高度。visibleFrame 推算比写死 24/30 可靠，且能跟随「菜单栏自动隐藏」变化。
    /// 实测本机 macOS 27 / 1080p：30pt。
    /// 自动隐藏时 visibleFrame 会等于 frame，此时沿用**该屏**上一次已知高度——
    /// 否则面板会贴到屏幕顶端，菜单栏一滑下来就被压住。副屏高度与主屏不同，必须分屏缓存。
    static var menuBarHeight: CGFloat {
        DisplayResolver.shared.menuBarHeight
    }

    /// 菜单栏是否被系统自动隐藏
    static var menuBarHidden: Bool {
        screen.frame.maxY - screen.visibleFrame.maxY <= 1
    }

    /// 菜单栏下沿（AppKit 坐标，原点左下）。所有自绘内容的「天花板」。
    static var ceilingY: CGFloat {
        screen.frame.maxY - menuBarHeight
    }

    /// 形态 C 的细线手柄
    static let railSize = NSSize(width: 96, height: 6)

    static func railFrame() -> NSRect {
        let s = screen
        return NSRect(x: s.frame.midX - railSize.width / 2,
                      y: ceilingY - railSize.height - 4,
                      width: railSize.width,
                      height: railSize.height)
    }

    /// 状态栏胶囊
    static let capsuleWidth: CGFloat = 92
    static let capsuleHeight: CGFloat = 22
    static let capsuleRadius: CGFloat = 11

    /// 下挂面板。高度不再写死：由内容实测高度决定，只钳制在上下限内。
    static let panelWidth: CGFloat = 380
    static let panelMinHeight: CGFloat = 168
    /// 画布可扩展，上限放到 620（超过就贴到屏幕底部了）
    static let panelMaxHeight: CGFloat = 620
    static let panelRadius: CGFloat = 24
    /// 面板顶边与菜单栏下沿之间的呼吸间隙：不做贴合，避免任何像素越界
    static let panelGap: CGFloat = 8
    static let screenInset: CGFloat = 8

    /// 面板顶部以下留给页签行 / 圆点 / 内边距的高度；画布上限与面板尺寸共用同一份。
    static let panelChromeWidth: CGFloat = 28
    /// 面板 chrome：上下内边距（各 14）+ 页签行（约 26）+ 行间距（10）。
    /// 不能把已删掉的底部圆点高度继续算进来，否则画布/卡片会离外框下沿多出空白，
    /// 贴角圆角的圆心就对不上外框了。
    static let panelChromeHeight: CGFloat = 64

    /// 画布可扩展到的物理上限：再大就会被面板裁掉。
    static let canvasMinWidth: CGFloat = 352
    /// 允许收缩到一行卡片的裸高度（150）；首次启动仍用 244 的完整布局。
    static let canvasMinHeight: CGFloat = 150
    static let canvasDefaultHeight: CGFloat = 244
    static var canvasMaxWidth: CGFloat {
        max(canvasMinWidth, screen.frame.width - panelChromeWidth - screenInset * 2)
    }
    static var canvasMaxHeight: CGFloat {
        max(canvasMinHeight, panelMaxHeight - panelChromeHeight)
    }

    /// 面板的最终 frame。
    /// 只要给了锚点（状态栏胶囊 / 居中浮胶囊 / 边缘手柄），面板就跟着锚点中点走；
    /// 没有锚点时才回退屏幕正中。面板锚点始终跟胶囊中心线——否则菜单栏胶囊
    /// 被拖到一边时，面板仍会自顾自地停在中线。
    static func panelFrame(anchorMidX: CGFloat?, width: CGFloat = panelWidth,
                           height: CGFloat, gap: CGFloat = panelGap) -> NSRect {
        let s = screen
        let w = min(width, s.frame.width - screenInset * 2)
        let h = min(max(height, panelMinHeight), min(panelMaxHeight, s.frame.height - 120))
        let anchor = anchorMidX ?? s.frame.midX
        var x = anchor - w / 2
        x = min(max(x, s.frame.minX + screenInset), s.frame.maxX - w - screenInset)
        let top = ceilingY - gap
        return NSRect(x: x, y: top - h, width: w, height: h)
    }

    /// 浮层胶囊的 frame：高度与垂直位置完全由设置决定。
    /// yOffset 是「距屏幕物理上沿」的偏移，0 就是贴住屏幕最上沿（不是菜单栏下沿）。
    static func capsuleFrame(width: CGFloat, centerX: CGFloat? = nil,
                             height: CGFloat, yOffset: CGFloat = 0) -> NSRect {
        let s = screen.frame
        // 上限要覆盖「设置里的最大宽度 + 两侧肩弧」，还要给歌词「加宽」留空间
        // （160 + 32 再 ×2.4 ≈ 460）。这里放到屏幕宽度的 60%，别让胶囊横穿整个菜单栏。
        let cap = min(520, s.width * 0.6)
        let w = min(max(width, 20), cap)
        let h = min(max(height, 16), s.height)
        let maxOffset = max(0, s.height - h)
        var off = min(max(yOffset, 0), maxOffset)
        let mid = centerX ?? s.midX
        // 刘海屏（MacBook Pro 14/16 等）：屏幕顶部正中是摄像头黑块，系统不会在上面画东西。
        // 浮胶囊若落在刘海横向范围内，按 yOffset 贴顶会被刘海整块遮住，这里自动下移到刘海下沿。
        // 两个形态都会走这段：居中垂帘默认就在正中，菜单栏胶囊也可能被拖进刘海范围。
        let notchInset = screen.safeAreaInsets.top
        if notchInset > 0 {
            let notchHalfWidth: CGFloat = 110
            let overlapsNotch = mid + w / 2 > s.midX - notchHalfWidth
                && mid - w / 2 < s.midX + notchHalfWidth
            if overlapsNotch {
                off = max(off, notchInset + 2)
            }
        }
        return NSRect(x: mid - w / 2, y: s.maxY - off - h, width: w, height: h)
    }
}

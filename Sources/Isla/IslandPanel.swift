import AppKit
import SwiftUI

/// 面板本体：无边框、非激活、层级 .statusBar。
/// 关键约束：它的 frame 顶部永远 ≤ 菜单栏下沿，因此不会盖住任何菜单栏像素。
final class IslandPanel: NSPanel {

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.panelWidth, height: IslandMetrics.panelMinHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // 27：比胶囊浮层（statusBar+1 = 26）高一级。
        // 胶囊悬停「Q 弹」的窗口带 8pt 垂直余量（窗口高 38 > 菜单栏 30），
        // 悬停拉伸的尖端会落到 30–38pt 区间——面板在 30pt 开始，
        // 层级低于胶囊时这段尖端会盖住面板页签、还会拦截该条带的点击。
        // 面板在胶囊之上：尖端滑到面板背后，交界处零重叠、零点击死区，
        // 胶囊本体（0–30pt）仍露在面板外，视觉上「伸进面板里」。
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // nonactivating 面板默认不抢 key：第一次点 WKWebView 只会让窗口变成 key，
        // 网页里的按钮看起来"点一下没反应"。鼠标按下时先自己变 key，再把事件送进去。
        // 只有用户真的点在面板上才会走到这里，不会抢走其它 App 正在输入的键盘焦点。
        if !isKeyWindow, event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// 圆角遮罩 + 材质背景 + 近黑压暗层 + 顶部微光。
///
/// 上一版用 white 0.56 的中性灰压暗，桌面一有亮内容就整片发灰、层次糊在一起。
/// 现在改为「近黑底 + 顶亮底暗的渐变」，让面板像一块沉下去的玻璃，而不是一层灰膜。
final class PanelBackgroundView: NSView {

    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let sheen = NSView()

    /// 面板内的滚轮事件（SwiftUI 列表若自己消费了，就不会走到这里）
    var onScroll: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = IslandMetrics.panelRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.09).cgColor

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)

        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tint.frame = bounds
        addSubview(tint)

        // 顶部 1 像素级微光 + 底部轻微下沉，制造「面朝光源」的厚度感
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(calibratedWhite: 1, alpha: 0.075).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.018).cgColor,
            NSColor(calibratedWhite: 0, alpha: 0.0).cgColor,
            NSColor(calibratedWhite: 0, alpha: 0.16).cgColor
        ]
        gradient.locations = [0, 0.10, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.wantsLayer = true
        sheen.layer = gradient
        sheen.autoresizingMask = [.width, .height]
        sheen.frame = bounds
        addSubview(sheen)

        apply(theme: SettingsStore.shared.panelTheme)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        if let onScroll, abs(event.scrollingDeltaY) > 0.01 {
            onScroll(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        tint.frame = bounds
        sheen.frame = bounds
    }

    /// 玻璃 / 实色。系统开启「降低透明度」时强制实色——这是无障碍偏好，不该被 App 覆盖。
    /// 深色主题 = 近黑底；浅色主题 = 纸白底。窗口外观由 IslandController.applyTheme 统一设置，
    /// 玻璃材质会跟着窗口外观翻转。
    func apply(theme: PanelTheme) {
        let solid = theme == .solid || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let dark = Theme.isDarkUI
        blur.isHidden = solid
        if solid {
            tint.layer?.backgroundColor = dark
                ? NSColor(srgbRed: 0.039, green: 0.043, blue: 0.051, alpha: 1).cgColor
                : NSColor(srgbRed: 0.965, green: 0.968, blue: 0.974, alpha: 1).cgColor
        } else {
            // 近黑/近白而非中性灰：灰会和背后的窗口内容混成一片雾
            tint.layer?.backgroundColor = dark
                ? NSColor(srgbRed: 0.024, green: 0.027, blue: 0.033, alpha: 0.88).cgColor
                : NSColor(srgbRed: 0.985, green: 0.987, blue: 0.991, alpha: 0.86).cgColor
        }
        layer?.borderColor = dark
            ? NSColor(calibratedWhite: 1, alpha: solid ? 0.11 : 0.09).cgColor
            : NSColor(calibratedWhite: 0, alpha: solid ? 0.14 : 0.12).cgColor
    }
}

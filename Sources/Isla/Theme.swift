import SwiftUI
import AppKit

/// 全局设计令牌。
///
/// 方向：**深夜仪表盘**——近黑底、单一强调色、发丝描边代替投影、4/6/10/14 的紧凑间距。
/// 参考了 `design-taste-frontend`（先定调、反模板化）与 `apple-design`（层级靠明度差，不靠装饰）的取向，
/// 但数值是按 380×280 的菜单栏浮层手工调出来的，不是照搬 web 的 scale。
///
/// 主题（2026-11-19）：「应用图标」风格里的 深色/浅色/跟随设备 同时决定**整套界面主题**——
/// 深色 = 原版深夜仪表盘；浅色 = 纸白底 + 墨色文字。所有颜色都是计算属性，
/// 读 `Theme.isDarkUI` 翻转，调用点不需要感知主题。
enum Theme {

    // 主题事实源：图标风格的 深色/浅色/跟随设备 即整体主题
    static var isDarkUI: Bool {
        switch SettingsStore.shared.appIcon {
        case .dark: return true
        case .light: return false
        case .auto: return AppDelegate.isDarkAppearance
        }
    }

    // 强调色只用于「状态」与「关键数字」，不用于装饰
    static var accent: Color { SettingsStore.shared.accentTheme.color }
    static var nsAccent: NSColor { SettingsStore.shared.accentTheme.nsColor }
    static let amber  = Color(red: 1.00, green: 0.71, blue: 0.40)
    static let blue   = Color(red: 0.44, green: 0.68, blue: 1.00)
    static let violet = Color(red: 0.72, green: 0.62, blue: 1.00)

    // 两种底：玻璃（带一点背后环境色）/ 实色
    static var canvasGlass: Color { isDarkUI ? Color(red: 0.027, green: 0.031, blue: 0.037)
                                             : Color(red: 0.955, green: 0.958, blue: 0.965) }
    static var canvasSolid: Color { isDarkUI ? Color(red: 0.039, green: 0.043, blue: 0.051)
                                             : Color(red: 0.937, green: 0.941, blue: 0.949) }

    // 表面与描边：用明度差分层，不用阴影堆叠
    static var surface:   Color { isDarkUI ? Color.white.opacity(0.045) : Color.black.opacity(0.055) }
    static var surfaceHi: Color { isDarkUI ? Color.white.opacity(0.085) : Color.black.opacity(0.10) }
    static var stroke:    Color { isDarkUI ? Color.white.opacity(0.065) : Color.black.opacity(0.10) }
    static var strokeHi:  Color { isDarkUI ? Color.white.opacity(0.13)  : Color.black.opacity(0.16) }

    // 文本三级
    static var textPrimary:   Color { isDarkUI ? Color.white.opacity(0.94) : Color.black.opacity(0.86) }
    static var textSecondary: Color { isDarkUI ? Color.white.opacity(0.56) : Color.black.opacity(0.55) }
    static var textTertiary:  Color { isDarkUI ? Color.white.opacity(0.30) : Color.black.opacity(0.38) }

    /// 关键数字/强调文本（dark=纯白 / light=近黑）：倒计时天数、百分比、进度条
    static var textStrong:    Color { isDarkUI ? Color.white.opacity(0.96) : Color.black.opacity(0.88) }
    /// 进度条已走过的部分
    static var progressFill:  Color { isDarkUI ? Color.white.opacity(0.88) : Color.black.opacity(0.72) }
    /// 进度条轨道
    static var progressTrack: Color { isDarkUI ? Color.white.opacity(0.16) : Color.black.opacity(0.16) }
    /// 装饰性图形（周柱空档、空态图标）：dark=白系 / light=黑系
    static var deco:          Color { isDarkUI ? Color.white.opacity(0.28) : Color.black.opacity(0.30) }
    static var decoFaint:     Color { isDarkUI ? Color.white.opacity(0.22) : Color.black.opacity(0.24) }
    static var decoStrong:    Color { isDarkUI ? Color.white.opacity(0.45) : Color.black.opacity(0.46) }
    /// 未选中页签文字
    static var textTab:       Color { isDarkUI ? Color.white.opacity(0.48) : Color.black.opacity(0.45) }
    /// 压在强调色实底上的图标/文字色：强调色都是亮色系，用近黑对比最稳
    static let iconOnAccent = Color(red: 0.02, green: 0.05, blue: 0.04)

    // 几何
    static let rCard: CGFloat = 14
    static let rChip: CGFloat = 9
    /// 贴到面板外角时，与外框半径 24、内边距 14 同心：24 - 14 = 10
    static let rNested: CGFloat = 10
    static let gap: CGFloat = 10

    // 设置窗口
    static let settingsSidebar: CGFloat = 188
}

extension Theme {
    /// 当前全局字号比例。控件宽度也要跟着放大，否则 150% 时
    /// 分段控件 / 输入框里的文字会被固定宽度裁掉。
    static var uiScale: CGFloat { CGFloat(SettingsStore.shared.uiFontScale) }
    static func ui(_ v: CGFloat) -> CGFloat { v * uiScale }
}

extension View {
    /// 统一的卡片底：填充 + 0.6pt 发丝描边
    func miCard(radius: CGFloat = Theme.rCard, fill: Color = Theme.surface) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.6))
    }

    /// 所有界面字号都走这里；只改 `SettingsStore.uiFontScale`，保持层级一致。
    func miFont(size: CGFloat,
                weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        modifier(Theme.MiFontModifier(size: size, weight: weight, design: design))
    }
}

extension Theme {
    struct MiFontModifier: ViewModifier {
        @ObservedObject private var settings = SettingsStore.shared
        let size: CGFloat
        let weight: Font.Weight
        let design: Font.Design

        func body(content: Content) -> some View {
            content.font(.system(size: size * CGFloat(settings.uiFontScale),
                                 weight: weight,
                                 design: design))
        }
    }
}

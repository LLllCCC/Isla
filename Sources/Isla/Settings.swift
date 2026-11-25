import SwiftUI
import AppKit
import ServiceManagement

/// 面板页。Phase 0 起改为字符串 id + 注册表驱动，内置三页只是预置值；
/// 插件页不再需要改 enum，只要在 `PageRegistry` 注册即可。
struct PanelPage: RawRepresentable, Hashable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let overview  = PanelPage("overview")
    static let clipboard = PanelPage("clipboard")
    static let shelf     = PanelPage("shelf")

    var id: String { rawValue }

    var descriptor: PageDescriptor? { PageRegistry.descriptor(for: self) }
    var title: String { descriptor?.title ?? "插件页" }
    var kind: PageDescriptor.Kind { descriptor?.kind ?? .plugin }

    /// 概览永远在正中间；其余页面按注册顺序左右交替放置：
    /// 第 1 个在左、第 2 个在右、第 3 个再向左外侧、第 4 个再向右外侧。
    static var tabOrder: [PanelPage] {
        PageRegistry.ordered.map(\.page)
    }
}

/// 面板里可排序的模块。顺序存在 UserDefaults["moduleOrder"]。
enum ModuleID: String, CaseIterable, Identifiable {
    case countdown, focus, media, pomodoro, cpu, memory, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: return "计划"
        case .focus:     return "今日专注"
        case .media:     return "正在播放"
        case .pomodoro:  return "番茄钟"
        case .cpu:       return "处理器"
        case .memory:    return "内存"
        case .network:   return "实时网速"
        }
    }
}

/// 一条计划：名称 + 日期。多计划列表存在 UserDefaults["plans"]（JSON）。
struct PlanItem: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var date: Date

    init(id: UUID = UUID(), title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }
}

/// 主题色：只换强调色，不改变信息层级。
enum AccentTheme: String, CaseIterable, Identifiable {
    case mint, blue, violet, coral

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mint:   return "薄荷"
        case .blue:   return "海蓝"
        case .violet: return "紫罗兰"
        case .coral:  return "珊瑚"
        }
    }
    var color: Color {
        switch self {
        case .mint:   return Color(red: 0.42, green: 0.92, blue: 0.72)
        case .blue:   return Color(red: 0.44, green: 0.68, blue: 1.00)
        case .violet: return Color(red: 0.72, green: 0.62, blue: 1.00)
        case .coral:  return Color(red: 1.00, green: 0.56, blue: 0.46)
        }
    }
    var nsColor: NSColor {
        switch self {
        case .mint:   return NSColor(calibratedRed: 0.42, green: 0.92, blue: 0.72, alpha: 1)
        case .blue:   return NSColor(calibratedRed: 0.44, green: 0.68, blue: 1.00, alpha: 1)
        case .violet: return NSColor(calibratedRed: 0.72, green: 0.62, blue: 1.00, alpha: 1)
        case .coral:  return NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.46, alpha: 1)
        }
    }
}

/// 概览画布的拖动模式：自由移动 / 受限排列（网格磁吸 + 防重叠）
enum DragMode: String, CaseIterable, Identifiable {
    case free, grid
    var id: String { rawValue }
    var title: String { self == .free ? "自由移动" : "受限排列" }
    var detail: String {
        self == .free
            ? "长按后随意拖动，拖出边界面板跟着变大"
            : "只吸其它组件的真实边；拖动中可临时重叠，松手仍重叠会弹回原位"
    }
}

/// 应用图标风格：深色（近黑底 + 白霓虹胶囊 P5）/ 浅色（纸白底 + 黑线稿 P4）/ 跟随设备。
/// 跟随设备 = 按系统深浅色外观实时切换，浅色外观必须用浅色图标。
/// 界面语言。切换写入 App 自己的 AppleLanguages，下次启动生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .zh:     return "简体中文"
        case .en:     return "English"
        }
    }

    /// 写入 UserDefaults["AppleLanguages"] 的值；nil = 跟随系统（清除覆盖）
    var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .zh:     return ["zh-Hans"]
        case .en:     return ["en"]
        }
    }
}

enum AppIconStyle: String, CaseIterable, Identifiable {
    case dark, light, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        case .auto: return "跟随设备"
        }
    }
    var detail: String {
        switch self {
        case .dark:  return "黑底白胶囊，适合深色桌面"
        case .light: return "白底黑线稿，适合浅色桌面"
        case .auto:  return "随系统深浅色自动切换"
        }
    }
    /// icns 资源名。auto 没有固定资源——运行时按当前外观解析成 dark/light。
    var resource: String {
        switch self {
        case .dark:  return "AppIcon"
        case .light: return "AppIconLight"
        case .auto:  return ""
        }
    }
    /// 当前外观对应的实际风格（auto → 按系统解析；其余原样返回）
    var resolved: AppIconStyle {
        if self == .auto { return AppDelegate.isDarkAppearance ? .dark : .light }
        return self
    }
}

/// 贴边时的肩弧档位：G 无肩（真刘海形态）/ B 短肩 / C 长肩。
/// 数值与设计稿的对比图一一对应：extend = 顶边每侧多伸出多少，depth = 往下滑多少才回到侧边。
enum AttachedShoulder: String, CaseIterable, Identifiable {
    case notch, short, long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "无肩"
        case .short: return "短肩"
        case .long:  return "长肩"
        }
    }

    var detail: String {
        switch self {
        case .notch: return "MacBook 刘海形态：顶边直角，只有下沿圆角"
        case .short: return "肩宽 12 · 落差 18：克制的过渡，最接近系统工具"
        case .long:  return "肩宽 16 · 落差 22：抛物线式长弧，最像「从屏幕长出来」"
        }
    }

    /// 顶边每侧多伸出的宽度
    var extend: CGFloat {
        switch self {
        case .notch: return 0
        case .short: return 12
        case .long:  return 16
        }
    }

    /// 从顶边往下滑多少才回到胶囊侧边
    var depth: CGFloat {
        switch self {
        case .notch: return 0
        case .short: return 18
        case .long:  return 22
        }
    }
}

/// 胶囊形态：悬浮（四角圆、离菜单栏上下留白）/ 贴边（顶到屏幕上沿，四角与悬浮同一套圆角）
enum IslandStyle: String, CaseIterable, Identifiable {
    case floating, attached
    var id: String { rawValue }
    var title: String { self == .floating ? "悬浮" : "贴边" }
    var detail: String {
        self == .floating
            ? "四角全圆，上下各留一点空隙，像浮在菜单栏里"
            : "顶边贴住屏幕上沿，只圆下面两角，展开面板无间隙"
    }
}

enum PanelTheme: String, CaseIterable, Identifiable {
    case glass, solid

    var id: String { rawValue }
    var title: String { self == .glass ? "玻璃" : "实色" }
}

/// 胶囊形态。
/// 注意：rawValue 沿用旧版命名（`capsule` / `centered`），只对调了显示名与行为，
/// 这样用户升级后仍停在原来选中的那一项上，不需要迁移。
enum IslandForm: String, CaseIterable, Identifiable {
    /// 居中垂帘：占用真实状态项槽位，固定不能拖动（旧名为「菜单栏胶囊」）。
    case centered = "capsule"
    /// 菜单栏胶囊：可在菜单栏左右拖动（旧名为「居中垂帘」）。
    case menuBar = "centered"
    case rail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .centered: return "居中垂帘"
        case .menuBar:  return "菜单栏胶囊"
        case .rail:     return "边缘细线"
        }
    }

    var detail: String {
        switch self {
        case .centered: return "胶囊占用菜单栏里的一个位置，固定不能拖动；面板像垂帘一样从它下面展开"
        case .menuBar:  return "胶囊浮在菜单栏上，可左右拖动；面板跟着它展开"
        case .rail:     return "隐藏胶囊，只在菜单栏下沿留一条细线"
        }
    }
}

/// 「胶囊」显示什么内容。
/// 歌词在胶囊里的三种排版（A 单行滚动 / B 自动加宽 / C 逐字推进）
enum LyricsLayout: String, CaseIterable, Identifiable {
    case single, widen, typewriter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single:     return "单行"
        case .widen:      return "加宽"
        case .typewriter: return "逐字"
        }
    }
    var detail: String {
        switch self {
        case .single:     return "胶囊保持原宽，长句按这句的时长横向滚过去"
        case .widen:      return "歌词模式下胶囊按「加宽倍数」自动变宽，一眼读完一整句"
        case .typewriter: return "胶囊保持原宽，按这句的时长逐字显示"
        }
    }
    /// 默认加宽倍数（可在歌词页调节）：120 × 3.4 = 408，接近 520 的窗口上限。
    static let defaultWidenFactor: Double = 3.4
}

/// 胶囊加宽时往哪边长。
enum WidenDirection: String, CaseIterable, Identifiable {
    case left, right, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left:  return "向左加宽"
        case .right: return "向右加宽"
        case .both:  return "向两边展开"
        }
    }
    var detail: String {
        switch self {
        case .left:  return "歌词变长时胶囊向右对齐，向左生长，不挤右边的菜单栏图标"
        case .right: return "歌词变长时胶囊向左对齐，向右生长"
        case .both:  return "胶囊保持居中，两边同时生长"
        }
    }
}

enum CapsuleContent: String, CaseIterable, Identifiable {
    case auto, time, network, pomodoro, media, lyrics, plugin

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto:     return "智能"
        case .time:     return "时间"
        case .network:  return "网速"
        case .pomodoro: return "番茄"
        case .media:    return "媒体"
        case .lyrics:   return "歌词"
        case .plugin:   return "插件"
        }
    }
    var detail: String {
        switch self {
        case .auto:     return "专注/播放时显示对应信息，空闲时显示时间"
        case .time:     return "始终显示 HH:mm"
        case .network:  return "显示当前下行速度（B / K / M）"
        case .pomodoro: return "显示专注或休息的剩余时间"
        case .media:    return "显示正在播放的剩余时间；未播放显示 --:--"
        case .lyrics:   return "显示当前播放歌曲的歌词（按「排版」设置决定单行 / 加宽 / 逐字）"
        case .plugin:   return "显示插件提供的胶囊内容（如剪贴板条数）"
        }
    }
}

/// 「居中」形态的落点策略。
enum CenteredPlacement: String, CaseIterable, Identifiable {
    case exact, avoid

    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact: return "屏幕正中"
        case .avoid: return "就近空位"
        }
    }
    var detail: String {
        switch self {
        case .exact: return "严格落在屏幕中线；中间有图标时会被岛盖住"
        case .avoid: return "用辅助功能读取状态项位置，落在离中线最近的空位"
        }
    }
}

extension Notification.Name {
    static let islandSettingsChanged = Notification.Name("islandSettingsChanged")
}

enum AppInfo {
    /// 版本号只留在 Info.plist 一处，避免 UI 里写死后跟构建脱节
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
    }
    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }
    static var buildInt: Int { Int(build) ?? 0 }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let d = UserDefaults.standard

    @Published var form: IslandForm {
        didSet { d.set(form.rawValue, forKey: "form"); post() }
    }
    /// 居中形态落点：严格正中 / 用 AX 找最近空位
    @Published var centeredPlacement: CenteredPlacement {
        didSet { d.set(centeredPlacement.rawValue, forKey: "centeredPlacement"); post() }
    }
    /// 岛落在哪块显示器：主屏 / 跟随鼠标 / 指定屏
    @Published var screenTarget: ScreenTarget {
        didSet { d.set(screenTarget.rawValue, forKey: "screenTarget"); post() }
    }
    /// 指定屏的 CGDirectDisplayID（0 = 未选，回退当前/主屏）
    @Published var screenID: Int {
        didSet { d.set(screenID, forKey: "screenID"); post() }
    }
    /// 胶囊显示内容（智能 / 时间 / 网速 / 番茄 / 媒体）
    @Published var capsuleContent: CapsuleContent {
        didSet { d.set(capsuleContent.rawValue, forKey: "capsuleContent"); post() }
    }
    /// 选「插件」胶囊时使用的模式 id（plugin.<插件id>.<模式id>）。
    @Published var capsulePluginMode: String {
        didSet { d.set(capsulePluginMode, forKey: "capsulePluginMode"); post() }
    }
    @Published var capsuleWidth: Double {
        didSet { d.set(capsuleWidth, forKey: "capsuleWidth"); post() }
    }
    /// 在 Dock 中显示（切换 activationPolicy）
    @Published var showInDock: Bool {
        didSet { d.set(showInDock, forKey: "showInDock"); post() }
    }
    @Published var islandStyle: IslandStyle {
        didSet {
            d.set(islandStyle.rawValue, forKey: "islandStyle")
            // 贴边就是「物理上沿」，不再让上一次的垂直偏移把胶囊拉下来。
            if islandStyle == .attached, capsuleYOffset != 0 { capsuleYOffset = 0 }
            post()
        }
    }
    /// 悬停驻留：悬停即展开、离开自动缩回；关掉则退回「点击固定」的老行为
    @Published var hoverDwell: Bool {
        didSet { d.set(hoverDwell, forKey: "hoverDwell"); post() }
    }
    /// 自动检查更新（启动后 + 每 24h；安装仍需用户确认）
    @Published var autoCheckUpdates: Bool {
        didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }
    /// 上次检查更新的时间戳（秒）；只落盘，不触发界面重排
    @Published var lastUpdateCheck: Double {
        didSet { d.set(lastUpdateCheck, forKey: "lastUpdateCheck") }
    }
    /// 上次自动提示过的 build，避免同一版本反复弹窗
    @Published var lastPromptedBuild: Int {
        didSet { d.set(lastPromptedBuild, forKey: "lastPromptedBuild") }
    }
    /// 用户拖动面板后记住的偏移（相对「胶囊下方」的默认位置）
    @Published var panelOffsetX: Double {
        didSet { d.set(panelOffsetX, forKey: "panelOffsetX"); post() }
    }
    @Published var panelOffsetY: Double {
        didSet { d.set(panelOffsetY, forKey: "panelOffsetY"); post() }
    }
    /// 胶囊高度（浮层胶囊可自由设置，不再受状态栏 22pt 高度限制）
    @Published var capsuleHeight: Double {
        didSet {
            d.set(capsuleHeight, forKey: "capsuleHeight")
            let maxY = max(0, IslandMetrics.menuBarHeight - CGFloat(capsuleHeight))
            if capsuleYOffset > Double(maxY) { capsuleYOffset = Double(maxY) }
            post()
        }
    }
    /// 胶囊垂直位置：距屏幕物理上沿的偏移（0 = 贴住屏幕顶边）
    @Published var capsuleYOffset: Double {
        didSet { d.set(capsuleYOffset, forKey: "capsuleYOffset"); post() }
    }
    /// 自动缩回顶边：空闲时把胶囊推到屏幕上方，只露 capsulePeek 高度
    @Published var capsuleAutoRetract: Bool {
        didSet { d.set(capsuleAutoRetract, forKey: "capsuleAutoRetract"); post() }
    }
    /// 缩回后保留的可见高度（pt，0 = 完全隐藏）
    @Published var capsulePeek: Double {
        didSet { d.set(capsulePeek, forKey: "capsulePeek"); post() }
    }
    /// 歌词相对播放器的偏移（秒）：>0 = 显示更早的歌词
    @Published var lyricOffset: Double {
        didSet { d.set(lyricOffset, forKey: "lyricOffset"); post() }
    }
    /// 歌词在胶囊里的排版
    @Published var lyricsLayout: LyricsLayout {
        didSet { d.set(lyricsLayout.rawValue, forKey: "lyricsLayout"); post() }
    }
    /// 应用图标风格
    @Published var appIcon: AppIconStyle {
        didSet { d.set(appIcon.rawValue, forKey: "appIcon"); post() }
    }
    /// 贴边肩弧档位（只在 islandStyle == .attached 时有意义）
    @Published var attachedShoulder: AttachedShoulder {
        didSet { d.set(attachedShoulder.rawValue, forKey: "attachedShoulder"); post() }
    }
    /// 强调色主题
    @Published var accentTheme: AccentTheme {
        didSet { d.set(accentTheme.rawValue, forKey: "accentTheme"); post() }
    }
    /// 全局界面字号比例：1.0 = 当前设计；面板、组件、设置、胶囊一起变。
    @Published var uiFontScale: Double {
        didSet { d.set(uiFontScale, forKey: "uiFontScale"); post() }
    }
    /// 歌词加宽时胶囊往哪边长
    @Published var widenDirection: WidenDirection {
        didSet { d.set(widenDirection.rawValue, forKey: "widenDirection"); post() }
    }

    /// 菜单栏胶囊形态的水平偏移（直接拖动后记住；0 = 屏幕中央）
    @Published var capsuleXOffset: Double {
        didSet { d.set(capsuleXOffset, forKey: "capsuleXOffset"); post() }
    }

    /// 标题/歌词滚动的刷新帧率（30/60/90/120）
    static let scrollFPSOptions = [30, 60, 90, 120]

    @Published var scrollFPS: Int {
        didSet { d.set(scrollFPS, forKey: "scrollFPS"); post() }
    }

    /// 界面语言：跟随系统 / 简体中文 / English（重启生效）
    @Published var uiLanguage: AppLanguage {
        didSet {
            d.set(uiLanguage.rawValue, forKey: "uiLanguage")
            if let langs = uiLanguage.appleLanguages {
                d.set(langs, forKey: "AppleLanguages")
            } else {
                d.removeObject(forKey: "AppleLanguages")
            }
            post()
        }
    }
    @Published var panelTheme: PanelTheme {
        didSet { d.set(panelTheme.rawValue, forKey: "panelTheme"); post() }
    }
    /// 组件顺序（字符串 id，内置与插件共用），缺失项自动补到末尾。
    /// Phase 0 起不再按 ModuleID 存，插件注册的卡片也能持久化顺序。
    @Published var widgetOrder: [String] {
        didSet { d.set(widgetOrder, forKey: "widgetOrder"); post() }
    }
    /// 组件开关（字符串 id）。关掉的组件不渲染，也就不占面板高度。
    @Published var widgetEnabled: [String: Bool] {
        didSet { d.set(widgetEnabled, forKey: "widgetEnabled"); post() }
    }
    @Published var hoverDelay: Double {
        didSet { d.set(hoverDelay, forKey: "hoverDelay"); post() }
    }
    @Published var autoHideDelay: Double {
        didSet { d.set(autoHideDelay, forKey: "autoHideDelay"); post() }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLogin(); post() }
    }
    /// 多计划列表。首次从旧版单条「考试倒数」自动迁移。
    @Published var plans: [PlanItem] {
        didSet {
            if let data = try? JSONEncoder().encode(plans) {
                d.set(data, forKey: "plans")
            }
            post()
        }
    }
    /// 胶囊里歌词的字号（pt，不含全局字号缩放）。
    @Published var lyricFontSize: Double {
        didSet { d.set(lyricFontSize, forKey: "lyricFontSize"); post() }
    }
    /// 歌词「加宽」的倍数（1.5–4.5，默认 3.4）。
    @Published var lyricWidenFactor: Double {
        didSet { d.set(lyricWidenFactor, forKey: "lyricWidenFactor"); post() }
    }
    /// 加宽是否只认「音乐类」App 的媒体会话（默认开）。
    /// 抖音/B 站/浏览器播视频也会占据系统「正在播放」：没有这层过滤，
    /// 刷视频时胶囊会反复加宽几秒再缩回（2026-11-20 用户反馈）。
    @Published var lyricsWidenMusicOnly: Bool {
        didSet { d.set(lyricsWidenMusicOnly, forKey: "lyricsWidenMusicOnly"); post() }
    }

    /// 只读的内置组件顺序：布局/整理等旧代码继续按 ModuleID 使用。
    var moduleOrder: [ModuleID] {
        widgetOrder.compactMap(ModuleID.init(rawValue:))
    }

    // 兼容旧调用点的只读开关（设置页与菜单统一走字符串 id）。
    var countdownEnabled: Bool { isEnabled("countdown") }
    var focusCard: Bool { isEnabled("focus") }
    var mediaEnabled: Bool { isEnabled("media") }
    var tilePomodoro: Bool { isEnabled("pomodoro") }
    var tileCPU: Bool { isEnabled("cpu") }
    var tileMemory: Bool { isEnabled("memory") }
    var networkEnabled: Bool { isEnabled("network") }

    /// 组件当前是否显示。画布整理 / 设置页共用一份判断，避免两处口径漂移。
    func isEnabled(_ m: ModuleID) -> Bool { isEnabled(m.rawValue) }
    func isEnabled(_ id: String) -> Bool { widgetEnabled[id] ?? true }

    /// 菜单栏「显示模块」开关
    func setEnabled(_ m: ModuleID, _ on: Bool) { setEnabled(m.rawValue, on) }
    func setEnabled(_ id: String, _ on: Bool) {
        guard widgetEnabled[id] != on else { return }
        var copy = widgetEnabled
        copy[id] = on
        widgetEnabled = copy
    }
    /// 概览画布拖动模式（自由 / 受限网格）
    @Published var dragMode: DragMode {
        didSet { d.set(dragMode.rawValue, forKey: "dragMode"); post() }
    }
    // 番茄钟
    @Published var workMinutes: Double {
        didSet { d.set(workMinutes, forKey: "workMinutes"); post() }
    }
    @Published var restMinutes: Double {
        didSet { d.set(restMinutes, forKey: "restMinutes"); post() }
    }
    @Published var autoStartNext: Bool {
        didSet { d.set(autoStartNext, forKey: "autoStartNext"); post() }
    }
    @Published var completionSound: Bool {
        didSet { d.set(completionSound, forKey: "completionSound"); post() }
    }

    private init() {
        let raw = d.string(forKey: "form") ?? IslandForm.centered.rawValue
        let loadedForm = IslandForm(rawValue: raw) ?? .centered
        form = loadedForm
        centeredPlacement = CenteredPlacement(rawValue: d.string(forKey: "centeredPlacement") ?? "") ?? .exact
        screenTarget = ScreenTarget(rawValue: d.string(forKey: "screenTarget") ?? "") ?? .main
        screenID = (d.object(forKey: "screenID") as? Int) ?? 0
        capsuleContent = CapsuleContent(rawValue: d.string(forKey: "capsuleContent") ?? "") ?? .auto
        capsulePluginMode = d.string(forKey: "capsulePluginMode") ?? ""
        capsuleWidth = (d.object(forKey: "capsuleWidth") as? Double) ?? 92
        panelTheme = PanelTheme(rawValue: d.string(forKey: "panelTheme") ?? "") ?? .glass
        let loadedStyle = IslandStyle(rawValue: d.string(forKey: "islandStyle") ?? "") ?? .floating
        islandStyle = loadedStyle
        capsuleHeight = (d.object(forKey: "capsuleHeight") as? Double) ?? 26
        capsuleYOffset = (d.object(forKey: "capsuleYOffset") as? Double) ?? 0
        capsuleAutoRetract = (d.object(forKey: "capsuleAutoRetract") as? Bool) ?? false
        capsulePeek = min(12, max(0, (d.object(forKey: "capsulePeek") as? Double) ?? 3))
        if loadedStyle == .attached {
            capsuleYOffset = 0
            d.set(0, forKey: "capsuleYOffset")
        }
        accentTheme = AccentTheme(rawValue: d.string(forKey: "accentTheme") ?? "") ?? .mint
        uiFontScale = min(1.5, max(0.85, (d.object(forKey: "uiFontScale") as? Double) ?? 1.0))
        uiLanguage = AppLanguage(rawValue: d.string(forKey: "uiLanguage") ?? "") ?? .system
        widenDirection = WidenDirection(rawValue: d.string(forKey: "widenDirection") ?? "") ?? .left
        capsuleXOffset = d.object(forKey: "capsuleXOffset") as? Double ?? 0
        scrollFPS = (d.object(forKey: "scrollFPS") as? Int).flatMap { Self.scrollFPSOptions.contains($0) ? $0 : nil } ?? 60
        hoverDwell = (d.object(forKey: "hoverDwell") as? Bool) ?? true
        autoCheckUpdates = (d.object(forKey: "autoCheckUpdates") as? Bool) ?? true
        lastUpdateCheck = d.double(forKey: "lastUpdateCheck")
        lastPromptedBuild = d.integer(forKey: "lastPromptedBuild")
        panelOffsetX = (d.object(forKey: "panelOffsetX") as? Double) ?? 0
        if loadedForm == .centered {
            // 居中垂帘的面板横向锚死中心线，旧的水平偏移不应继续生效。
            panelOffsetX = 0
            d.set(0, forKey: "panelOffsetX")
        }
        panelOffsetY = (d.object(forKey: "panelOffsetY") as? Double) ?? 0
        showInDock = (d.object(forKey: "showInDock") as? Bool) ?? true
        let knownIDs = WidgetRegistry.orderedIDs
        let savedOrder = d.stringArray(forKey: "widgetOrder")
            ?? d.stringArray(forKey: "moduleOrder")
            ?? []
        var order = savedOrder.filter { knownIDs.contains($0) }
        for id in knownIDs where !order.contains(id) { order.append(id) }
        widgetOrder = order
        let enabled: [String: Bool]
        if let saved = d.dictionary(forKey: "widgetEnabled") as? [String: Bool] {
            var map = saved
            for id in knownIDs where map[id] == nil { map[id] = true }
            enabled = map
        } else {
            // 从旧的 7 个 Bool key 迁移一次；以后插件组件直接写 widgetEnabled。
            enabled = [
                "countdown": (d.object(forKey: "countdownEnabled") as? Bool) ?? true,
                "focus":     (d.object(forKey: "showFocusCard") as? Bool) ?? true,
                "media":     (d.object(forKey: "mediaEnabled") as? Bool) ?? true,
                "pomodoro":  (d.object(forKey: "tilePomodoro") as? Bool) ?? true,
                "cpu":       (d.object(forKey: "tileCPU") as? Bool) ?? true,
                "memory":    (d.object(forKey: "tileMemory") as? Bool) ?? true,
                "network":   (d.object(forKey: "networkEnabled") as? Bool) ?? true
            ]
        }
        widgetEnabled = enabled
        d.set(order, forKey: "widgetOrder")
        d.set(enabled, forKey: "widgetEnabled")
        hoverDelay = (d.object(forKey: "hoverDelay") as? Double) ?? 0.12
        autoHideDelay = (d.object(forKey: "autoHideDelay") as? Double) ?? 0.28
        launchAtLogin = SMAppService.mainApp.status == .enabled
        dragMode = DragMode(rawValue: d.string(forKey: "dragMode") ?? "") ?? .free
        attachedShoulder = AttachedShoulder(rawValue: d.string(forKey: "attachedShoulder") ?? "") ?? .long
        appIcon = AppIconStyle(rawValue: d.string(forKey: "appIcon") ?? "") ?? .dark
        lyricsLayout = LyricsLayout(rawValue: d.string(forKey: "lyricsLayout") ?? "") ?? .widen
        lyricOffset = min(3, max(0, (d.object(forKey: "lyricOffset") as? Double) ?? 0))
        workMinutes = (d.object(forKey: "workMinutes") as? Double) ?? 25
        restMinutes = (d.object(forKey: "restMinutes") as? Double) ?? 5
        autoStartNext = (d.object(forKey: "autoStartNext") as? Bool) ?? false
        completionSound = (d.object(forKey: "completionSound") as? Bool) ?? true
        lyricFontSize = min(18, max(8, (d.object(forKey: "lyricFontSize") as? Double) ?? 10.5))
        lyricWidenFactor = min(4.5, max(1.5, (d.object(forKey: "lyricWidenFactor") as? Double)
            ?? LyricsLayout.defaultWidenFactor))
        lyricsWidenMusicOnly = (d.object(forKey: "lyricsWidenMusicOnly") as? Bool) ?? true
        if let data = d.data(forKey: "plans"),
           let list = try? JSONDecoder().decode([PlanItem].self, from: data), !list.isEmpty {
            plans = list
        } else {
            // 旧版只有一条「考试倒数」：迁进多计划列表，默认 2026-12-19（2027 考研初试）
            let title = d.string(forKey: "countdownTitle") ?? "考研初试"
            let date: Date
            if let t = d.object(forKey: "countdownDate") as? Double, t > 0 {
                date = Date(timeIntervalSince1970: t)
            } else {
                var c = DateComponents()
                c.year = 2026; c.month = 12; c.day = 19
                date = Calendar.current.date(from: c) ?? Date()
            }
            plans = [PlanItem(title: title, date: date)]
        }
    }

    /// 距某天还有几天（按自然日算，今天 = 0）
    func days(to date: Date) -> Int {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 未来的计划按日期从近到远；全都过期时退回过期计划里最近的一条。
    var upcomingPlans: [PlanItem] {
        let sorted = plans.sorted { $0.date < $1.date }
        let future = sorted.filter { days(to: $0.date) >= 0 }
        return future.isEmpty ? Array(sorted.suffix(1)) : future
    }

    private func post() {
        NotificationCenter.default.post(name: .islandSettingsChanged, object: nil)
    }

    private func applyLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Isla login item failed: \(error.localizedDescription)")
        }
    }
}

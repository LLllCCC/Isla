import SwiftUI
import AppKit
import Combine

// MARK: - 页签

/// 侧栏页签。旧版「外观与形态」一页塞了 16 个设置项，拆成
/// 通用 / 胶囊 / 歌词 / 主题 四页，参考 LaunchNext 的分组密度：
/// 每页 2–4 张分组卡，一屏能看完。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, capsule, lyrics, theme, modules, plugins, pomodoro, study, behavior, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "通用"
        case .capsule:  return "胶囊"
        case .lyrics:   return "歌词"
        case .theme:    return "主题"
        case .modules:  return "模块"
        case .plugins:  return "插件"
        case .pomodoro: return "番茄钟"
        case .study:    return "计划"
        case .behavior: return "行为"
        case .about:    return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general:  return "启动、显示与全局字号"
        case .capsule:  return "形态、尺寸与显示内容"
        case .lyrics:   return "歌词排版与时间校正"
        case .theme:    return "主题色与应用图标"
        case .modules:  return "面板上有哪些卡片，按什么顺序排"
        case .plugins:  return "安装、启用与查看权限"
        case .pomodoro: return "专注时长、到点反馈与自动接续"
        case .study:    return "计划与今日专注统计"
        case .behavior: return "悬停手感、播放信息读取"
        case .about:    return "版本信息与设计说明"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape.2"
        case .capsule:  return "capsule"
        case .lyrics:   return "music.note.list"
        case .theme:    return "paintpalette"
        case .modules:  return "square.grid.2x2"
        case .plugins:  return "puzzlepiece.extension"
        case .pomodoro: return "timer"
        case .study:    return "checklist"
        case .behavior: return "cursorarrow.motionlines"
        case .about:    return "info.circle"
        }
    }

    var group: String {
        switch self {
        case .general, .capsule, .lyrics, .theme, .modules: return "界面"
        case .plugins, .pomodoro, .study:                    return "组件"
        case .behavior, .about:                              return "系统"
        }
    }
}

// MARK: - 主视图

/// 设置窗口的导航状态。
/// 不用 @State：macOS 26 SDK 的 @State 是宏，本机只有 CLT、没有 SwiftUIMacros 插件，编译会失败。
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()

    /// 记住上次停留的页签
    @Published var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
    }
    @Published var hovered: SettingsTab?
    /// 侧栏折叠：只显示图标，给内容区让出宽度
    @Published var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "settingsSidebarCollapsed") }
    }

    private init() {
        // 旧版存的 "appearance" 在新枚举里不存在，自然回落到 .general
        tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general
        sidebarCollapsed = UserDefaults.standard.bool(forKey: "settingsSidebarCollapsed")
    }
}

/// 搜索框状态。单独放 ObservableObject：本机只有 CLT，@State 宏不可用。
final class SettingsSearch: ObservableObject {
    static let shared = SettingsSearch()
    @Published var text = ""
    private init() {}
}

struct SettingsView: View {
    @EnvironmentObject var s: SettingsStore
    @ObservedObject private var nav = SettingsNav.shared
    @ObservedObject private var axStatus = AXPermissionStatus.shared
    @ObservedObject private var search = SettingsSearch.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var store = PluginStore.shared
    @ObservedObject private var update = UpdateService.shared
    /// 屏幕增减时自动刷新，指定屏下拉不会停在旧列表上
    @ObservedObject private var displays = DisplayCatalog.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 0.6)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Theme.ui(700), idealWidth: Theme.ui(780), maxWidth: .infinity,
               minHeight: Theme.ui(500), idealHeight: Theme.ui(600), maxHeight: .infinity)
        .background(Theme.canvasSolid)
        .tint(Theme.accent)                     // 控件也走品牌色，避免系统蓝与品牌色打架
        .environment(\.colorScheme, Theme.isDarkUI ? ColorScheme.dark : ColorScheme.light)
        .onAppear { axStatus.refresh() }
    }

    /// 折叠后只留图标槽位；宽度变化做 0.18s 过渡，内容区跟着长出来
    private var sidebarWidth: CGFloat {
        nav.sidebarCollapsed ? Theme.ui(58) : Theme.ui(Theme.settingsSidebar)
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, nav.sidebarCollapsed ? 0 : 16)
                .padding(.top, 30)      // 让出窗口红绿灯
                .padding(.bottom, 16)

            if nav.sidebarCollapsed {
                collapseButton
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { nav.sidebarCollapsed = false }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .miFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("搜索设置"))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            } else {
                searchField
            }

            if search.text.isEmpty || nav.sidebarCollapsed {
                ForEach(Array(["界面", "组件", "系统"].enumerated()), id: \.offset) { idx, group in
                    if nav.sidebarCollapsed {
                        if idx > 0 {
                            Rectangle()
                                .fill(Theme.stroke)
                                .frame(height: 0.6)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    } else {
                        Text(LocalizedStringKey(group))
                            .miFont(size: 9.5, weight: .semibold)
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                            .padding(.bottom, 4)
                    }

                    ForEach(SettingsTab.allCases.filter { $0.group == group }) { t in
                        navItem(t)
                    }
                }
            } else {
                searchResults
            }

            Spacer(minLength: 8)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power").miFont(size: 10, weight: .medium)
                    if !nav.sidebarCollapsed {
                        Text("退出 Isla").miFont(size: 11.5)
                        Spacer()
                    }
                }
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: nav.sidebarCollapsed ? .center : .leading)
                .padding(.horizontal, nav.sidebarCollapsed ? 0 : 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("退出 Isla"))
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .background(Color.black.opacity(0.22))
        .animation(.easeInOut(duration: 0.18), value: nav.sidebarCollapsed)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { nav.sidebarCollapsed.toggle() }
        } label: {
            Image(systemName: "sidebar.leading")
                .miFont(size: 11, weight: .medium)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(nav.sidebarCollapsed ? "展开侧栏" : "折叠侧栏"))
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .miFont(size: 9.5, weight: .medium)
                .foregroundStyle(Theme.textTertiary)
            TextField("搜索设置", text: $search.text)
                .textFieldStyle(.plain)
                .miFont(size: 11)
                .foregroundStyle(Theme.textPrimary)
            if !search.text.isEmpty {
                Button { search.text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .miFont(size: 9)
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var searchResults: some View {
        let q = search.text.trimmingCharacters(in: .whitespaces)
        let hits = Self.searchIndex.filter {
            ($0.title + " " + $0.keywords).localizedCaseInsensitiveContains(q)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if hits.isEmpty {
                    Text(String(format: L("没有找到「%@」"), q))
                        .miFont(size: 10.5)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                } else {
                    ForEach(hits.prefix(16)) { hit in
                        Button {
                            nav.tab = hit.tab
                            search.text = ""
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: hit.tab.icon)
                                    .miFont(size: 9, weight: .medium)
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(LocalizedStringKey(hit.title))
                                        .miFont(size: 11.5)
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(LocalizedStringKey(hit.tab.title))
                                        .miFont(size: 8.5)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// 搜索索引：页面名 + 每个可设置项，命中的词都跳转到对应页面
    private static let searchIndex: [SettingsSearchHit] = [
        .init(.general, "通用", "启动 显示 外观"),
        .init(.general, "在 Dock 中显示", "dock 图标"),
        .init(.general, "登录时启动", "开机 自启"),
        .init(.general, "全局字号", "字体 大小 缩放"),
        .init(.general, "面板材质", "玻璃 实色 模糊"),
        .init(.general, "显示器", "屏幕 多屏 多显示器 主屏 跟随鼠标 指定屏"),
        .init(.capsule, "胶囊", "形状 位置 尺寸"),
        .init(.capsule, "形态", "贴边 悬浮 居中"),
        .init(.capsule, "宽度", "尺寸"),
        .init(.capsule, "高度", "尺寸"),
        .init(.capsule, "侧边距", "位置"),
        .init(.capsule, "圆角", "形状"),
        .init(.capsule, "水平位置", "位置"),
        .init(.capsule, "垂直位置", "位置"),
        .init(.capsule, "肩弧", "贴边"),
        .init(.capsule, "胶囊显示", "时间 歌曲 媒体 歌词"),
        .init(.lyrics, "歌词", "排版 时间 来源"),
        .init(.lyrics, "歌词排版", "单行 加宽 逐字"),
        .init(.lyrics, "歌词字号", "字体 大小"),
        .init(.lyrics, "仅音乐加宽", "加宽 抖音 视频 音乐 来源 过滤"),
        .init(.lyrics, "加宽倍数", "宽度 倍数"),
        .init(.lyrics, "滚动帧率", "帧率 FPS 流畅"),
        .init(.lyrics, "歌词提前", "时间校正 延迟"),
        .init(.lyrics, "歌词来源", "匹配 网易云 QQ"),
        .init(.theme, "主题", "颜色 图标"),
        .init(.theme, "主题色", "薄荷 海蓝 紫罗兰 珊瑚 强调色"),
        .init(.theme, "图标风格", "深色 浅色 跟随设备"),
        .init(.modules, "模块", "卡片 顺序 显示"),
        .init(.modules, "拖动模式", "自由移动 受限排列"),
        .init(.modules, "模块显示与层级", "计划 专注 播放 番茄钟 处理器 内存 网速"),
        .init(.modules, "画布布局", "整理 恢复默认"),
        .init(.plugins, "插件", "安装 启用 权限 日志"),
        .init(.plugins, "插件目录", "安装 扫描 示例"),
        .init(.plugins, "插件商店", "商店 远端 源 index 安装 更新"),
        .init(.pomodoro, "番茄钟", "计时"),
        .init(.pomodoro, "专注时长", "计时"),
        .init(.pomodoro, "休息时长", "计时"),
        .init(.pomodoro, "长休息", "计时"),
        .init(.pomodoro, "自动开始", "计时"),
        .init(.study, "计划", "倒数 日期"),
        .init(.study, "添加计划", "新建 倒数"),
        .init(.study, "在面板中显示", "计划卡片"),
        .init(.behavior, "行为", "悬停 拖动 快捷键"),
        .init(.behavior, "悬停驻留", "展开 收起"),
        .init(.behavior, "面板拖动", "位置"),
        .init(.behavior, "滚轮翻页", "手势"),
        .init(.behavior, "快捷键", "键盘"),
        .init(.about, "关于", "版本")
    ]

    /// 与 Dock 栏完全一致的 App 图标（深/浅按当前设置解析）
    private var appMarkImage: NSImage {
        let name = s.appIcon.resolved.resource
        if let url = Bundle.main.url(forResource: name, withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: appMarkImage)
                .interpolation(.high)
                .resizable()
                .frame(width: nav.sidebarCollapsed ? 28 : 36,
                       height: nav.sidebarCollapsed ? 28 : 36)
            if !nav.sidebarCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Isla")
                        .miFont(size: 14.5, weight: .semibold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("v\(AppInfo.version)")
                        .miFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                collapseButton
            }
        }
        .frame(maxWidth: .infinity, alignment: nav.sidebarCollapsed ? .center : .leading)
    }

    private func navItem(_ t: SettingsTab) -> some View {
        let selected = nav.tab == t
        let hot = nav.hovered == t
        return Button {
            nav.tab = t
        } label: {
            HStack(spacing: 8) {
                // 图标底座：选中 = 强调色实底 + 深色图标（LaunchNext 式），未选中 = 灰底
                Image(systemName: t.icon)
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(selected ? Theme.iconOnAccent : Theme.textTertiary)
                    .frame(width: Theme.ui(20), height: Theme.ui(20))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Theme.accent : Theme.surface)
                    )
                if !nav.sidebarCollapsed {
                    Text(LocalizedStringKey(t.title))
                        .miFont(size: 12, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Theme.textPrimary : (hot ? Theme.textSecondary : Theme.textSecondary.opacity(0.85)))
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: nav.sidebarCollapsed ? .center : .leading)
            .padding(.horizontal, nav.sidebarCollapsed ? 0 : 8)
            .frame(height: Theme.ui(30))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.14) : (hot ? Theme.surface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(t.title))
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .onHover { inside in
            if inside { nav.hovered = t } else if nav.hovered == t { nav.hovered = nil }
        }
    }

    // MARK: 详情

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(nav.tab.title))
                    .miFont(size: 18, weight: .semibold)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Rectangle().fill(Theme.stroke).frame(height: 0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch nav.tab {
                    case .general:  generalPane
                    case .capsule:  capsulePane
                    case .lyrics:   lyricsPane
                    case .theme:    themePane
                    case .modules:  modulesPane
                    case .plugins:  pluginsPane
                    case .pomodoro: pomodoroPane
                    case .study:    studyPane
                    case .behavior: behaviorPane
                    case .about:    aboutPane
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }

    // MARK: 通用

    private var generalPane: some View {
        VStack(spacing: 14) {
            card("启动与显示") {
                row("在 Dock 中显示", "关闭后只在菜单栏显示，可从 Dock 或 Cmd-Tab 打开") {
                    Toggle("", isOn: $s.showInDock).toggleStyle(.switch).labelsHidden()
                }
                hairline
                row("登录时启动", "开机自动启动（App 需放在「应用程序」文件夹）") {
                    Toggle("", isOn: $s.launchAtLogin).toggleStyle(.switch).labelsHidden()
                }
            }
            card("显示") {
                sliderRow("全局字号", value: "\(Int(s.uiFontScale * 100))%",
                          binding: $s.uiFontScale, range: 0.85...1.5, step: 0.01)
                Text("同时调整面板、组件、设置窗口和胶囊的字号。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                hairline
                row("界面语言", "切换后需要重启 App 生效") {
                    Picker("", selection: Binding(
                        get: { s.uiLanguage },
                        set: { newValue in
                            let old = s.uiLanguage
                            s.uiLanguage = newValue
                            if newValue != old { promptRestartForLanguage() }
                        }
                    )) {
                        ForEach(AppLanguage.allCases) { l in
                            Text(LocalizedStringKey(l.title)).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Theme.ui(150))
                }
                hairline
                row("面板材质", "玻璃带背景模糊，实色更清晰") {
                    Picker("", selection: $s.panelTheme) {
                        ForEach(PanelTheme.allCases) { t in Text(LocalizedStringKey(t.title)).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Theme.ui(180))
                }
            }
            card("显示器") {
                row("岛所在的屏幕", s.screenTarget.detail) {
                    Picker("", selection: Binding(
                        get: { s.screenTarget },
                        set: { newValue in
                            s.screenTarget = newValue
                            // 第一次切到「指定」时默认选当前屏，别让下拉空着
                            if newValue == .fixed,
                               !displays.screens.contains(where: { $0.id == CGDirectDisplayID(s.screenID) }) {
                                s.screenID = Int(displays.activeID)
                            }
                        }
                    )) {
                        ForEach(ScreenTarget.allCases) { t in Text(LocalizedStringKey(t.title)).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Theme.ui(300))
                }
                if s.screenTarget == .fixed {
                    hairline
                    row("指定屏幕", "插拔后这块屏不在了，会自动回退到当前屏") {
                        Picker("", selection: $s.screenID) {
                            Text("自动（当前屏）").tag(0)
                            ForEach(displays.screens, id: \.id) { d in
                                Text(d.name).tag(Int(d.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: Theme.ui(180))
                    }
                }
                Text("居中垂帘贴着系统状态项所在屏；菜单栏胶囊按这里的设置选屏。跟随鼠标时，指针停到另一块屏约 0.45 秒后岛才搬过去（面板展开或拖动组件期间不搬）。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if s.form == .menuBar {
                    hairline
                    row(L("胶囊水平位置"), capsuleOffsetText) {
                        Button(L("复位")) { s.capsuleXOffset = 0 }
                            .buttonStyle(.borderless)
                            .miFont(size: 10.5)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            card("权限") {
                row("辅助功能权限",
                    axStatus.trusted ? "已授权：菜单栏自动避让 + 播放/暂停即时判定"
                                     : "未授权：居中避让回退屏幕正中，暂停判定最慢 8 秒") {
                    if axStatus.trusted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    } else {
                        Button("授予权限") {
                            MenuBarScanner.requestPermission()
                            AXPermissionStatus.shared.refreshAfterPrompt()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                    }
                }
                Text("只读取状态项位置和播放器按钮状态，不会操作其它 App。系统更新或重新安装后可能需要重新授权。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 胶囊

    private var capsulePane: some View {
        VStack(spacing: 14) {
            card("形态") {
                row("菜单栏形态", formDetail(s.form)) {
                    Picker("", selection: $s.form) {
                        ForEach(IslandForm.allCases) { f in Text(LocalizedStringKey(f.title)).tag(f) }
                    }
                    // 三段英文标签比中文长很多，segmented 会撑出卡片；改用菜单。
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Theme.ui(190))
                    // 菜单栏胶囊是浮层：默认从屏幕正中开始；「就近空位」开着时
                    // 先切回正中，避免看起来和「居中垂帘」抢位置。
                    .onChange(of: s.form) { _, newValue in
                        if newValue == .menuBar && s.centeredPlacement == .avoid {
                            s.centeredPlacement = .exact
                        }
                    }
                }
                if s.form == .menuBar {
                    hairline
                    row("居中位置", s.centeredPlacement.detail) {
                        Picker("", selection: $s.centeredPlacement) {
                            ForEach(CenteredPlacement.allCases) { p in
                                Text(LocalizedStringKey(p.title)).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: Theme.ui(170))
                    }
                }
            }

            card("贴边样式") {
                row("胶囊样式", s.islandStyle.detail) {
                    Picker("", selection: $s.islandStyle) {
                        ForEach(IslandStyle.allCases) { st in Text(LocalizedStringKey(st.title)).tag(st) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Theme.ui(150))
                }
                if s.islandStyle == .attached {
                    hairline
                    row("肩弧", s.attachedShoulder.detail) {
                        Picker("", selection: $s.attachedShoulder) {
                            ForEach(AttachedShoulder.allCases) { sh in Text(LocalizedStringKey(sh.title)).tag(sh) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: Theme.ui(210))
                    }
                    Text("无肩：顶边为直角，像 MacBook 刘海；短肩 / 长肩：顶边向两侧延伸后滑回侧边。")
                        .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card("尺寸与位置") {
                sliderRow("胶囊宽度", value: "\(Int(s.capsuleWidth)) pt",
                          binding: $s.capsuleWidth, range: 28...160, step: 4)
                hairline
                sliderRow("胶囊高度", value: "\(Int(s.capsuleHeight)) pt",
                          binding: $s.capsuleHeight, range: 18...30, step: 1)
                hairline
                capsuleVerticalRow
                hairline
                row("缩回屏幕顶边", "空闲时缩到屏幕上沿，指针移到该处自动滑出") {
                    Toggle("", isOn: $s.capsuleAutoRetract)
                        .toggleStyle(.switch).labelsHidden()
                }
                hairline
                row(L("加宽方向"), s.widenDirection.detail) {
                    Picker("", selection: $s.widenDirection) {
                        ForEach(WidenDirection.allCases) { d in Text(LocalizedStringKey(d.title)).tag(d) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Theme.ui(150))
                }
                if s.capsuleAutoRetract {
                    sliderRow("缩回后露出", value: "\(Int(s.capsulePeek)) pt",
                              binding: $s.capsulePeek, range: 0...12, step: 1)
                    Text("0 = 完全隐藏（仍可在屏幕顶边胶囊位置滑出）；建议 3–5pt。面板展开或钉住时不缩回，仅「居中垂帘」形态生效。")
                        .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("胶囊是独立浮层，高度可自由调整；选择「贴边」后会自动贴住屏幕上沿。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
            }

            card("显示内容") {
                row("胶囊显示", s.capsuleContent.detail) {
                    Picker("", selection: $s.capsuleContent) {
                        ForEach(CapsuleContent.allCases) { c in Text(LocalizedStringKey(c.title)).tag(c) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Theme.ui(170))
                }
                if s.capsuleContent == .lyrics {
                    hairline
                    Text("选「歌词」后可到侧栏「歌词」页调排版与时间校正。")
                        .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                }
                if s.capsuleContent == .plugin {
                    hairline
                    if pluginManager.capsuleModes.isEmpty {
                        Text("还没有插件提供胶囊模式。安装并启用带 capsuleModes 的插件后会出现在这里。")
                            .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        row("插件模式", "插件每次渲染返回一段文本，直接显示在胶囊里") {
                            Picker("", selection: $s.capsulePluginMode) {
                                ForEach(pluginManager.capsuleModes) { m in
                                    Text(LocalizedStringKey(m.title)).tag(m.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: Theme.ui(180))
                        }
                    }
                }
            }
        }
    }

    // MARK: 歌词

    private var lyricsPane: some View {
        VStack(spacing: 14) {
            if s.capsuleContent != .lyrics {
                card {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .miFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.amber)
                        Text("当前胶囊显示的不是歌词。先到「胶囊 › 显示内容」里切换到歌词，这里的设置才会生效。")
                            .miFont(size: 11).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            card("排版") {
                row("歌词排版", s.lyricsLayout.detail) {
                    Picker("", selection: $s.lyricsLayout) {
                        ForEach(LyricsLayout.allCases) { l in Text(LocalizedStringKey(l.title)).tag(l) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Theme.ui(255))
                }
                hairline
                sliderRow("歌词字号", value: String(format: "%.1f pt", s.lyricFontSize),
                          binding: $s.lyricFontSize, range: 8...18, step: 0.5)
                hairline
                sliderRow("加宽倍数", value: String(format: "%.1f×", s.lyricWidenFactor),
                          binding: $s.lyricWidenFactor, range: 1.5...4.5, step: 0.1)
                hairline
                row("滚动帧率", "标题与歌词滚动的每秒刷新次数；高刷新屏可上调") {
                    Picker("", selection: $s.scrollFPS) {
                        ForEach(SettingsStore.scrollFPSOptions, id: \.self) { f in
                            Text("\(f) FPS").tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Theme.ui(110))
                }
                hairline
                row("仅音乐 App 加宽", "抖音、浏览器等视频来源不再触发加宽，只显示标题") {
                    Toggle("", isOn: $s.lyricsWidenMusicOnly)
                        .toggleStyle(.switch).labelsHidden()
                }
                Text("加宽：整句尽量铺满；单行：长句按播放进度滚动；逐字：随播放逐字出现。暂停后自动恢复原宽。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card("时间校正") {
                sliderRow("歌词提前", value: String(format: "%.1f s", s.lyricOffset),
                          binding: $s.lyricOffset, range: 0...3, step: 0.1)
                Text("歌词比声音慢时，向右调，让歌词提前出现。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card("来源") {
                Text("根据歌名和歌手自动匹配歌词。浏览器等其他应用占用「正在播放」时不会显示。")
                    .miFont(size: 10.5).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: 主题

    private var themePane: some View {
        VStack(spacing: 14) {
            card("主题色") {
                HStack(spacing: 8) {
                    ForEach(AccentTheme.allCases) { t in
                        Button {
                            s.accentTheme = t
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(t.color).frame(width: 9, height: 9)
                                Text(LocalizedStringKey(t.title)).miFont(size: 11, weight: .medium)
                            }
                            .foregroundStyle(s.accentTheme == t ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(
                                Capsule().fill(s.accentTheme == t ? Theme.surfaceHi : Theme.surface)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    s.accentTheme == t ? t.color.opacity(0.55) : Theme.stroke,
                                    lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                Text("用于胶囊、页签、进度条和关键数字的高亮色。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
            }

            card("应用图标") {
                row("图标风格", s.appIcon.detail) {
                    Picker("", selection: $s.appIcon) {
                        ForEach(AppIconStyle.allCases) { st in Text(LocalizedStringKey(st.title)).tag(st) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Theme.ui(240))
                }
                Text("图标会同步到 Dock 和设置页左上角。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 模块

    /// 形态说明：说清楚这个形态下胶囊到底会出现在哪、能不能拖
    private func formDetail(_ form: IslandForm) -> String {
        switch form {
        case .centered:
            return L("胶囊占用菜单栏里的一个位置，像其它图标一样不会盖住别人；固定不能拖动，面板从它下面展开")
        case .menuBar:
            return s.centeredPlacement == .avoid
                ? L("胶囊浮在菜单栏的空位上，可左右拖动（不用按 ⌘）")
                : L("胶囊浮在屏幕正中，可左右拖动（不用按 ⌘）")
        case .rail:
            return L("隐藏胶囊，只在菜单栏下沿留一条细线")
        }
    }

    /// 胶囊水平偏移的显示文案（在「菜单栏胶囊」形态直接拖动可改）
    private var capsuleOffsetText: String {
        let v = s.capsuleXOffset
        if abs(v) < 0.5 { return L("默认位置（屏幕中央）") }
        return String(format: L("偏移 %+.0f pt"), v)
    }

    private var modulesPane: some View {
        VStack(spacing: 14) {
            card("拖动模式") {
                Picker("", selection: $s.dragMode) {
                    ForEach(DragMode.allCases) { m in
                        Text(LocalizedStringKey(m.title)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(LocalizedStringKey(s.dragMode.detail))
                    .miFont(size: 10.5).foregroundStyle(Theme.textTertiary)
            }
            card("模块显示与层级") {
                Text("卡片位置可在概览页长按拖动；右下角手柄可缩放，右键组件可放大 / 缩小 / 恢复尺寸。")
                    .miFont(size: 10.5).foregroundStyle(Theme.textTertiary)
                VStack(spacing: 2) {
                    ForEach(s.widgetOrder.compactMap(WidgetRegistry.descriptor)) { d in
                        moduleRow(d)
                    }
                }
                .padding(.top, 2)
                Divider().opacity(0.3).padding(.vertical, 4)
                HStack {
                    Text("画布布局").miFont(size: 12.5, weight: .medium)
                    Spacer()
                    Button("网格整理") { CanvasLayout.shared.arrangeGrid() }
                        .buttonStyle(.borderless)
                        .miFont(size: 11.5)
                    Button("恢复默认摆放") { CanvasLayout.shared.reset() }
                        .buttonStyle(.borderless)
                        .miFont(size: 11.5)
                }
            }
        }
    }

    private func moduleRow(_ d: WidgetDescriptor) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal")
                .miFont(size: 10, weight: .medium)
                .foregroundStyle(Theme.textTertiary)
            Toggle(isOn: toggleBinding(d.id)) {
                Text(LocalizedStringKey(d.title)).miFont(size: 12)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface.opacity(0.5)))
        .contentShape(Rectangle())
        .onDrag {
            ModuleDrag.current = d.id
            return NSItemProvider(object: d.id as NSString)
        }
        .onDrop(of: [.text], delegate: ModuleDropDelegate(item: d, store: s))
    }

    /// 组件开关统一按字符串 id 绑定：内置与插件组件共用一份存储。
    private func toggleBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { s.isEnabled(id) }, set: { s.setEnabled(id, $0) })
    }

    // MARK: 插件

    private var pluginsPane: some View {
        VStack(spacing: 14) {
            storeCard
            card("插件目录") {
                Text(pluginManager.pluginsDirectory.path)
                    .miFont(size: 10, design: .monospaced)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("打开文件夹") { pluginManager.openPluginsFolder() }
                    Button("重新扫描") { pluginManager.scan() }
                    Button("安装插件…") { installPlugin() }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .miFont(size: 11.5)
                Text("插件是包含 manifest.json 的文件夹或 .zip。安装后在下面启用；禁用的插件不会出现页面。")
                    .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                hairline
                row("自动重载（开发模式）", "改完 main.js / manifest.json 后 1~2 秒内自动生效，不用重启 App") {
                    Toggle("", isOn: $pluginManager.hotReloadEnabled)
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            if pluginManager.plugins.isEmpty {
                card("还没有插件") {
                    Text("从下面的官方示例装一个：剪贴板看板（声明式 JS 页）或数据面板（Web 自定义页）。")
                        .miFont(size: 11).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                card("已安装") {
                    VStack(spacing: 8) {
                        ForEach(pluginManager.plugins) { p in
                            pluginRow(p)
                        }
                    }
                }
            }

            let usages = pluginManager.permissionUsage()
            if !usages.isEmpty {
                card("权限总览") {
                    VStack(spacing: 6) {
                        ForEach(usages) { u in
                            permissionRow(u)
                        }
                    }
                    Text("安装时逐项确认；未声明的能力一律拒绝。敏感权限会单独标注。")
                        .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let catalog = pluginManager.catalogPlugins()
            if !catalog.isEmpty {
                card("官方示例（本地目录）") {
                    VStack(spacing: 8) {
                        ForEach(catalog) { entry in
                            catalogRow(entry)
                        }
                    }
                    Text("本地目录随 App 分发，不需要联网；安装时仍会逐项确认权限。")
                        .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
    }

    private var storeCard: some View {
        card("插件商店（远端）") {
            row("商店源",
                store.hasSource
                    ? (store.storeName.isEmpty ? store.activeHost : store.storeName)
                    : "还没有添加商店源") {
                if store.sources.count > 1 {
                    Picker("", selection: Binding(
                        get: { store.activeSource },
                        set: { store.activate($0) }
                    )) {
                        ForEach(store.sources) { s in
                            Text(s.host).tag(s.url)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Theme.ui(150))
                }
                Button("刷新") { store.refresh() }
                    .disabled(!store.hasSource || store.isRefreshing)
                Button("添加…") { addStoreSource() }
            }
            Text(store.statusLine)
                .miFont(size: 10)
                .foregroundStyle(store.lastError == nil ? Theme.textTertiary : Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
            if !store.signatureLine.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: store.signature.isVerified ? "checkmark.seal.fill"
                          : (store.signature.publisher != nil ? "exclamationmark.shield" : "lock.open"))
                        .miFont(size: 10, weight: .medium)
                        .foregroundStyle(store.signature.isVerified ? Theme.accent : Theme.amber)
                    Text(store.signatureLine)
                        .miFont(size: 10)
                        .foregroundStyle(store.signature.isVerified ? Theme.textSecondary : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.canTrustCurrentPublisher {
                        Button("信任并校验") { trustStorePublisher() }
                            .buttonStyle(.borderless)
                            .miFont(size: 10.5)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            if store.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在读取商店…").miFont(size: 10).foregroundStyle(Theme.textTertiary)
                }
            }
            if !store.plugins.isEmpty {
                VStack(spacing: 8) {
                    ForEach(store.plugins) { p in
                        storeRow(p)
                    }
                }
            }
            if store.hasSource {
                hairline
                HStack(spacing: 8) {
                    Text(store.activeSource)
                        .miFont(size: 9.5, design: .monospaced)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 6)
                    Button("移除这个源") { confirmRemoveStoreSource() }
                        .buttonStyle(.borderless)
                        .miFont(size: 10.5)
                }
            }
            Text("索引支持 Ed25519 签名：首次使用需确认发布者公钥指纹；未签名或未信任的商店，安装前会再确认一次。安装包校验 SHA-256，安装时仍会逐项确认权限。签名不代表代码审计。")
                .miFont(size: 10).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.ensureLoaded() }
    }

    // MARK: 商店

    private func storeRow(_ p: StorePlugin) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).miFont(size: 12, weight: .medium)
                    Text("v\(p.version)")
                        .miFont(size: 9.5, design: .monospaced)
                        .foregroundStyle(Theme.textTertiary)
                    if !p.compatible {
                        Text(String(format: L("需要 Isla ≥ %@"), p.minAppVersion ?? "?"))
                            .miFont(size: 9)
                            .foregroundStyle(Theme.amber)
                    }
                }
                if !p.summary.isEmpty {
                    Text(p.summary)
                        .miFont(size: 10).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if !p.author.isEmpty {
                        Text(p.author).miFont(size: 9).foregroundStyle(Theme.textTertiary)
                    }
                    if !p.sizeText.isEmpty {
                        Text(p.sizeText).miFont(size: 9, design: .monospaced)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !p.permissions.isEmpty {
                        Text(String(format: L("%d 项权限"), p.permissions.count))
                            .miFont(size: 9)
                            .foregroundStyle(p.permissions.contains { PluginManager.permissionInfo($0)?.risk == .sensitive }
                                             ? Theme.amber : Theme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            if store.installing.contains(p.id) {
                ProgressView().controlSize(.small)
            } else if p.installed && p.hasUpdate {
                HStack(spacing: 6) {
                    Text(String(format: L("已装 v%@"), p.installedVersion ?? "?"))
                        .miFont(size: 9.5, design: .monospaced)
                        .foregroundStyle(Theme.textTertiary)
                    Button("更新") { confirmStoreInstall(p) }
                        .buttonStyle(.borderless)
                        .miFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.accent)
                }
            } else if p.installed {
                Text("已安装")
                    .miFont(size: 10)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Button("安装") { confirmStoreInstall(p) }
                    .buttonStyle(.borderless)
                    .miFont(size: 11, weight: .medium)
                    .foregroundStyle(Theme.accent)
                    .disabled(!p.compatible)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface.opacity(0.5)))
    }

    private func trustStorePublisher() {
        guard let p = store.signature.publisher else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("信任发布者 %@？"), p.name)
        alert.informativeText = String(format: L("公钥指纹：%@"), p.keyID) + "\n\n"
            + L("信任后，这个源的索引必须继续由同一把钥匙签名；换钥匙会直接拒绝加载。只有在你确认这个指纹来自发布者本人时才继续。")
        alert.addButton(withTitle: L("信任"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.trustCurrentPublisher()
    }

    /// 安装前的最终闸门：已签名且钥匙已信任 → 直接装；否则把风险说清楚再让用户决定。
    private func confirmStoreInstall(_ p: StorePlugin) {
        switch store.signature {
        case .verified:
            store.install(p)
        case .untrusted(let publisher):
            let alert = NSAlert()
            alert.messageText = L("发布者尚未信任")
            alert.informativeText = String(format: L("商店发布者：%@"), publisher.name) + "\n"
                + String(format: L("公钥指纹：%@"), publisher.keyID) + "\n\n"
                + L("信任后，这个源的索引必须继续由这把钥匙签名；换钥匙会拒绝加载。只在你能确认这个指纹来源时继续。")
            alert.addButton(withTitle: L("信任并安装"))
            alert.addButton(withTitle: L("取消"))
            if alert.runModal() == .alertFirstButtonReturn {
                store.trustCurrentPublisher()
                store.install(p, allowUntrusted: true)
            }
        case .unsigned:
            let alert = NSAlert()
            alert.messageText = L("这个商店没有签名")
            alert.informativeText = L("无法确认索引是谁发布的。安装包仍会校验 SHA-256，但索引本身可能被替换。")
                + "\n\n" + L("只在你知道这个商店地址可信时继续。")
            alert.addButton(withTitle: L("仍然安装"))
            alert.addButton(withTitle: L("取消"))
            if alert.runModal() == .alertFirstButtonReturn {
                store.install(p, allowUntrusted: true)
            }
        case .none:
            break
        }
    }

    private func promptRestartForLanguage() {
        let alert = NSAlert()
        alert.messageText = L("界面语言已更改")
        alert.informativeText = L("需要重启 Isla 后生效。现在就重启吗？")
        alert.addButton(withTitle: L("立即重启"))
        alert.addButton(withTitle: L("稍后"))
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .islaRestartRequested, object: nil)
        }
    }

    private func addStoreSource() {
        let alert = NSAlert()
        alert.messageText = L("添加商店源")
        alert.informativeText = L("输入商店 index.json 的地址（https）。商店源地址就是信任根，只添加你信任的商店。")
        alert.addButton(withTitle: L("添加"))
        alert.addButton(withTitle: L("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://example.com/isla/store/index.json"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.addSource(field.stringValue)
        } catch {
            let a = NSAlert()
            a.messageText = L("添加失败")
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: L("知道了"))
            a.runModal()
        }
    }

    private func confirmRemoveStoreSource() {
        let alert = NSAlert()
        alert.messageText = L("移除这个商店源？")
        alert.informativeText = store.activeSource + L("\n\n已安装的插件不会受影响，只是不再从它更新。")
        alert.addButton(withTitle: L("移除"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeSource(store.activeSource)
    }

    private func permissionRow(_ u: PluginPermissionUsage) -> some View {
        HStack(spacing: 7) {
            Image(systemName: u.info.risk == .sensitive ? "exclamationmark.shield" : "lock.shield")
                .miFont(size: 10, weight: .medium)
                .foregroundStyle(u.info.risk == .sensitive ? Theme.amber : Theme.textTertiary)
                .frame(width: 16)
            Text(LocalizedStringKey(u.info.title))
                .miFont(size: 11.5, weight: .medium)
                .lineLimit(1)
                .layoutPriority(1)
            if u.info.risk == .sensitive {
                Text("敏感")
                    .miFont(size: 8.5)
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.amber.opacity(0.12)))
                    .fixedSize()
            }
            Text(String(format: L("%d 个插件"), u.pluginNames.count))
                .miFont(size: 9.5)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            Button("详情") { showPermissionDetail(u) }
                .buttonStyle(.borderless)
                .miFont(size: 10.5)
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
    }

    private func showPermissionDetail(_ u: PluginPermissionUsage) {
        let alert = NSAlert()
        alert.messageText = "\(u.info.title)\(u.info.risk == .sensitive ? "（敏感权限）" : "")"
        alert.informativeText = u.info.detail + L("\n\n使用插件：\n")
            + u.pluginNames.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: L("知道了"))
        alert.runModal()
    }

    private func catalogRow(_ entry: PluginManager.CatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).miFont(size: 12, weight: .medium)
                    Text("v\(entry.version)")
                        .miFont(size: 9.5, design: .monospaced)
                        .foregroundStyle(Theme.textTertiary)
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .miFont(size: 10).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if entry.installed {
                if entry.hasUpdate {
                    HStack(spacing: 6) {
                        Text(String(format: L("已装 v%@"), entry.installedVersion ?? "?"))
                            .miFont(size: 9.5, design: .monospaced)
                            .foregroundStyle(Theme.textTertiary)
                        Button("更新") { updateCatalog(entry) }
                            .buttonStyle(.borderless)
                            .miFont(size: 11, weight: .medium)
                            .foregroundStyle(Theme.accent)
                    }
                } else {
                    Text("已安装")
                        .miFont(size: 10)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                Button("安装") { installCatalog(entry) }
                    .buttonStyle(.borderless)
                    .miFont(size: 11, weight: .medium)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface.opacity(0.5)))
    }

    private func pluginRow(_ p: PluginRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: p.manifest?.icon ?? "puzzlepiece.extension")
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                Text(p.name).miFont(size: 12.5, weight: .medium)
                Text("v\(p.version)")
                    .miFont(size: 10, design: .monospaced)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                if p.isUsable {
                    Toggle("", isOn: pluginBinding(p.id))
                        .toggleStyle(.switch).labelsHidden()
                } else {
                    Text("不可用").miFont(size: 10).foregroundStyle(.red)
                }
            }
            Text(p.id)
                .miFont(size: 9.5, design: .monospaced)
                .foregroundStyle(Theme.textTertiary)
            if let error = p.error {
                Text(error)
                    .miFont(size: 10)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !p.permissions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(p.permissions, id: \.self) { perm in
                        let info = PluginManager.permissionInfo(perm)
                        Text(LocalizedStringKey(info?.title ?? perm))
                            .miFont(size: 9)
                            .foregroundStyle(info?.risk == .sensitive ? Theme.amber : Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.surface))
                    }
                }
            }
            integrityRow(p)
            HStack(spacing: 10) {
                Button("查看日志") { pluginManager.openLog(for: p.id) }
                Button("打开目录") { NSWorkspace.shared.open(p.directory) }
                if p.integrity != .ok, p.manifest != nil {
                    Button("信任当前文件") { pluginManager.trustCurrentFiles(id: p.id) }
                        .foregroundStyle(Theme.accent)
                }
                if p.manifest != nil {
                    Button("卸载") { confirmUninstall(p) }
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.38))
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .miFont(size: 10.5)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface.opacity(0.5)))
    }

    private func pluginBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { pluginManager.plugins.first(where: { $0.id == id })?.enabled ?? false },
            set: { pluginManager.setEnabled(id: id, $0) }
        )
    }

    private func integrityRow(_ p: PluginRecord) -> some View {
        let color: Color = p.integrity == .changed ? Theme.amber : Theme.textTertiary
        let icon: String
        let text: String
        switch p.integrity {
        case .ok:
            icon = "checkmark.shield"
            text = "完整性校验通过"
        case .changed:
            icon = "exclamationmark.triangle"
            text = pluginManager.hotReloadEnabled ? "文件已改动（开发模式）" : "文件在安装后被改动"
        case .unrecorded:
            icon = "questionmark.circle"
            text = "未记录校验值（旧安装）"
        }
        return HStack(spacing: 5) {
            Image(systemName: icon).miFont(size: 9, weight: .medium)
            Text(LocalizedStringKey(text)).miFont(size: 9.5)
            if let hash = p.hash, p.integrity == .ok {
                Text("SHA-256 \(hash.prefix(8))…")
                    .miFont(size: 9, design: .monospaced)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
    }

    private func installPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择插件文件夹或 .zip"
        if panel.runModal() == .OK, let url = panel.url {
            do { try pluginManager.install(from: url) }
            catch { showPluginError(error) }
        }
    }

    private func installSample() {
        do { try pluginManager.installSample() }
        catch { showPluginError(error) }
    }

    private func installCatalog(_ entry: PluginManager.CatalogEntry) {
        do { try pluginManager.installCatalog(id: entry.id) }
        catch { showPluginError(error) }
    }

    private func updateCatalog(_ entry: PluginManager.CatalogEntry) {
        do { try pluginManager.updateCatalog(id: entry.id) }
        catch { showPluginError(error) }
    }

    private func confirmUninstall(_ p: PluginRecord) {
        let a = NSAlert()
        a.messageText = String(format: L("卸载 %@？"), p.name)
        a.informativeText = L("会删除插件目录和它保存的数据，不能撤销。")
        a.addButton(withTitle: L("卸载"))
        a.addButton(withTitle: L("取消"))
        if a.runModal() == .alertFirstButtonReturn {
            pluginManager.uninstall(id: p.id)
        }
    }

    private func showPluginError(_ error: Error) {
        let a = NSAlert()
        a.messageText = L("插件操作失败")
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    // MARK: 番茄钟

    private var pomodoroPane: some View {
        VStack(spacing: 14) {
            card("时长") {
                sliderRow("专注", value: String(format: L("%d 分钟"), Int(s.workMinutes)),
                          binding: $s.workMinutes, range: 5...60, step: 5)
                hairline
                sliderRow("休息", value: String(format: L("%d 分钟"), Int(s.restMinutes)),
                          binding: $s.restMinutes, range: 3...20, step: 1)
            }
            card("到点") {
                row("自动开始下一阶段", "专注结束进休息，休息结束回专注") {
                    Toggle("", isOn: $s.autoStartNext).toggleStyle(.switch).labelsHidden()
                }
                hairline
                row("完成时播放提示音", "专注结束 Glass、休息结束 Ping") {
                    Toggle("", isOn: $s.completionSound).toggleStyle(.switch).labelsHidden()
                }
                hairline
                row("今日专注", "番茄钟每完成一个 + 专注时长；跨天归零") {
                    Text(focusSummary)
                        .miFont(size: 11, design: .monospaced)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var focusSummary: String {
        let svc = PomodoroService.shared
        return String(format: L("%d 分 · %d 个"), svc.todayMinutes, svc.todayCount)
    }

    // MARK: 计划

    private var studyPane: some View {
        card("我的计划") {
            row("在面板中显示", "面板里显示最近的计划和剩余天数") {
                Toggle("", isOn: toggleBinding("countdown")).toggleStyle(.switch).labelsHidden()
            }
            hairline
            VStack(spacing: 8) {
                ForEach($s.plans) { $plan in
                    planRow($plan)
                }
                Button {
                    let date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                    s.plans.append(PlanItem(title: "新计划", date: date))
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill").miFont(size: 11)
                        Text("添加计划").miFont(size: 11.5, weight: .medium)
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func planRow(_ plan: Binding<PlanItem>) -> some View {
        HStack(spacing: 8) {
            TextField("计划名称", text: planTitleBinding(plan))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            DatePicker("", selection: plan.date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
            Text(planDaysText(plan.wrappedValue.date))
                .miFont(size: 10.5, design: .monospaced)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: Theme.ui(58), alignment: .trailing)
            Button {
                let id = plan.wrappedValue.id
                s.plans.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("删除这个计划"))
        }
    }

    /// 默认计划名「计划」在英文界面显示为 Plan（只影响显示，用户改过就按原样存）。
    private func planTitleBinding(_ plan: Binding<PlanItem>) -> Binding<String> {
        Binding(
            get: {
                let raw = plan.wrappedValue.title
                return (isEnglishUIEnabled && raw == "计划") ? "Plan" : raw
            },
            set: { plan.wrappedValue.title = $0 }
        )
    }

    private func planDaysText(_ date: Date) -> String {
        let d = s.days(to: date)
        if d > 0 { return String(format: L("%d 天"), d) }
        if d == 0 { return L("今天") }
        return String(format: L("已过 %d 天"), -d)
    }

    // MARK: 行为

    private var behaviorPane: some View {
        VStack(spacing: 14) {
            card("悬停") {
                row("悬停驻留", "开启：悬停胶囊即展开，离开自动缩回；关闭：点一下才展开") {
                    Toggle("", isOn: $s.hoverDwell).toggleStyle(.switch).labelsHidden()
                }
                hairline
                sliderRow("展开延迟", value: String(format: "%.2f s", s.hoverDelay),
                          binding: $s.hoverDelay, range: 0.02...0.45, step: 0.01)
                hairline
                sliderRow("收起延迟", value: String(format: "%.2f s", s.autoHideDelay),
                          binding: $s.autoHideDelay, range: 0.10...0.80, step: 0.01)
            }
            card("面板") {
                row("拖动面板", "按住面板任意空白处拖动，位置会被记住") {
                    Button("回到默认位置") {
                        s.panelOffsetX = 0
                        s.panelOffsetY = 0
                    }
                    .buttonStyle(.borderless)
                    .miFont(size: 11.5)
                }
                hairline
                row("滚轮翻页", "指针在面板内时上下滚动，可在概览 / 剪贴板 / 暂存之间翻页") {
                    Text("⇅").miFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            card("读取") {
                row("正在播放（系统级）", "读取系统正在播放的信息，不需要额外授权") {
                    Toggle("", isOn: toggleBinding("media")).toggleStyle(.switch).labelsHidden()
                }
                hairline
                row("快捷键", "唤出 / 收起面板") {
                    Text("⌥ ⌘ Space")
                        .miFont(size: 11, design: .monospaced)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                }
            }
        }
    }

    // MARK: 关于

    private var aboutPane: some View {
        VStack(spacing: 14) {
            card {
                HStack(spacing: 14) {
                    Image(nsImage: appMarkImage)
                        .interpolation(.high)
                        .resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Isla").miFont(size: 14, weight: .semibold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("v\(AppInfo.version) (build \(AppInfo.build)) · macOS 14+")
                            .miFont(size: 10, design: .monospaced).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
            }
            card("更新") {
                row("当前版本", "v\(AppInfo.version) (build \(AppInfo.build))") {
                    Button("检查更新…") { UpdateService.shared.present() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                }
                hairline
                row("自动检查更新", "启动后每 24 小时检查一次；安装前仍会确认") {
                    Toggle("", isOn: $s.autoCheckUpdates)
                        .toggleStyle(.switch).labelsHidden()
                }
                if case .available = update.phase, let release = update.release {
                    hairline
                    row("发现新版本", "v\(release.version) (build \(release.build))") {
                        Button("查看更新") { UpdateService.shared.present() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    // MARK: 组件

    @ViewBuilder
    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if let title {
                Text(LocalizedStringKey(title))
                    .miFont(size: 10, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .miCard(radius: 12)
    }

    @ViewBuilder
    private func row<Control: View>(_ title: String, _ subtitle: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .miFont(size: 12.5, weight: .medium)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .miFont(size: 10.5)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private var capsuleVerticalRow: some View {
        Group {
            if s.islandStyle == .attached {
                HStack {
                    Text("胶囊垂直位置")
                        .miFont(size: 12.5, weight: .medium)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("贴边时自动贴住屏幕上沿")
                        .miFont(size: 11)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 2)
            } else {
                let maxY = max(1, IslandMetrics.menuBarHeight - CGFloat(s.capsuleHeight))
                sliderRow("胶囊垂直位置", value: String(format: L("距上沿 %d pt"), Int(s.capsuleYOffset)),
                          binding: $s.capsuleYOffset, range: 0...Double(maxY), step: 1)
            }
        }
    }

    private func sliderRow(_ title: String, value: String, binding: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(LocalizedStringKey(title))
                    .miFont(size: 12.5, weight: .medium)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(value)
                    .miFont(size: 11, design: .monospaced)
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: binding, in: range, step: step)
                .controlSize(.small)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.6)
    }
}

// MARK: - 拖拽

/// 拖拽中的组件 id（SwiftUI 的 onDrag 不带数据给 onDrop，用静态变量传递）
enum ModuleDrag { static var current: String? }

struct ModuleDropDelegate: DropDelegate {
    let item: WidgetDescriptor
    let store: SettingsStore

    func dropEntered(info: DropInfo) {
        guard let dragged = ModuleDrag.current, dragged != item.id,
              let from = store.widgetOrder.firstIndex(of: dragged),
              let to = store.widgetOrder.firstIndex(of: item.id) else { return }
        guard store.widgetOrder[to] != dragged else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            var order = store.widgetOrder
            order.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
            store.widgetOrder = order
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        ModuleDrag.current = nil
        return true
    }
}

// MARK: - 窗口

final class SettingsWindowController: NSWindowController {

    private var cancellables = Set<AnyCancellable>()

    init() {
        let store = SettingsStore.shared
        let scale = CGFloat(store.uiFontScale)
        let host = NSHostingView(rootView: SettingsView().environmentObject(store))
        // 第一次打开就按屏幕可视区域夹紧：1366×768 / 1280×720 这类小屏
        // 默认 780×600（再乘字号倍率）会超出屏幕底部，窗口下半截够不着。
        let initFrame = Self.clampedFrame(scale: scale, screen: NSScreen.main)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: initFrame.width, height: initFrame.height),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = L("Isla 设置")
        // 窗口外观跟随主题（深色/浅色/跟随设备）；IslandController.applyTheme 会在切换时更新
        w.appearance = NSAppearance(named: Theme.isDarkUI ? .darkAqua : .aqua)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.minSize = initFrame.minSize
        w.backgroundColor = Theme.isDarkUI
            ? NSColor(srgbRed: 0.039, green: 0.043, blue: 0.051, alpha: 1)
            : NSColor(srgbRed: 0.937, green: 0.941, blue: 0.949, alpha: 1)
        w.center()
        w.contentView = host
        super.init(window: w)

        // 字号滑块一动，窗口跟着放大/缩小，顶边保持不动：
        // 固定 780×600 的窗口在 150% 时会把右侧控件裁掉。
        store.$uiFontScale
            .removeDuplicates()
            .sink { [weak self] value in self?.fit(to: CGFloat(value)) }
            .store(in: &cancellables)

        // 外接屏拔掉 / 分辨率变化后，设置窗口可能落在已经不存在的坐标上。
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.clampToVisibleScreen() }
            .store(in: &cancellables)
    }

    /// 屏幕参数变化后把窗口拉回当前屏幕的可视区域。
    private func clampToVisibleScreen() {
        guard let w = window else { return }
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = w.frame
        f.size.width = min(f.width, max(560, visible.width - 40))
        f.size.height = min(f.height, max(420, visible.height - 40))
        f.origin.x = min(max(f.minX, visible.minX + 20), visible.maxX - f.width - 20)
        f.origin.y = min(max(f.minY, visible.minY + 20), visible.maxY - f.height - 20)
        w.setFrame(f, display: true, animate: false)
    }

    /// 目标尺寸 + 最小尺寸都夹在屏幕可视区域内（四周各留 20pt）。
    private static func clampedFrame(scale: CGFloat, screen: NSScreen?) -> (width: CGFloat, height: CGFloat, minSize: NSSize) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = max(560, visible.width - 40)
        let maxH = max(420, visible.height - 40)
        return (min(780 * scale, maxW),
                min(600 * scale, maxH),
                NSSize(width: min(700 * scale, maxW), height: min(500 * scale, maxH)))
    }

    /// 按比例调整窗口尺寸，并夹在屏幕可视区域内。
    private func fit(to scale: CGFloat) {
        guard let w = window else { return }
        let screen = NSScreen.main
        let size = Self.clampedFrame(scale: scale, screen: screen)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = w.frame
        let dy = size.height - f.height
        f.size = NSSize(width: size.width, height: size.height)
        f.origin.y -= dy
        // 右下角都别越界（顶边不变的前提下可能顶到屏幕外）
        f.origin.x = min(max(f.minX, visible.minX + 20), visible.maxX - size.width - 20)
        f.origin.y = min(max(f.minY, visible.minY + 20), visible.maxY - size.height - 20)
        w.minSize = size.minSize
        w.setFrame(f, display: true, animate: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 搜索索引

private struct SettingsSearchHit: Identifiable {
    let tab: SettingsTab
    let title: String
    let keywords: String
    var id: String { "\(tab.rawValue)-\(title)" }

    init(_ tab: SettingsTab, _ title: String, _ keywords: String = "") {
        self.tab = tab
        self.title = title
        self.keywords = keywords
    }
}


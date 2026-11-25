import Foundation
import CoreGraphics

// MARK: - 页面注册表
//
// 插件体系 Phase 0：面板页不再由 `PanelPage` 固定 enum + switch 决定，
// 而是由注册表提供 descriptor。内置三页也注册进来，顺序和左右交替规则保持不变；
// 后续插件管理器只需要往 `PageRegistry.descriptors` 追加一条即可多一页。

struct PageDescriptor: Identifiable, Equatable {
    enum Kind: Equatable {
        case overview
        case clipboard
        case shelf
        /// 插件页：Phase 1 由插件页宿主渲染，Phase 0 不会出现。
        case plugin
    }

    let id: String
    let title: String
    let icon: String
    let kind: Kind
    /// 插件页可声明首选高度；内置页继续走现有的动态量高。
    let preferredHeight: CGFloat?
    let sortKey: Int
    /// 非 nil = kind=web 的自定义页，值为相对插件目录的入口 HTML。
    var webEntry: String? = nil

    var page: PanelPage { PanelPage(rawValue: id) }
}

enum PageRegistry {
    static let builtins: [PageDescriptor] = [
        PageDescriptor(id: "overview", title: "概览", icon: "square.grid.2x2",
                       kind: .overview, preferredHeight: nil, sortKey: 0),
        PageDescriptor(id: "clipboard", title: "剪贴板", icon: "doc.on.clipboard",
                       kind: .clipboard, preferredHeight: nil, sortKey: 1),
        PageDescriptor(id: "shelf", title: "暂存", icon: "tray.full",
                       kind: .shelf, preferredHeight: nil, sortKey: 2)
    ]

    /// 插件管理器后续会往这里追加；Phase 0 只有内置页。
    static var descriptors: [PageDescriptor] = builtins

    static func descriptor(for page: PanelPage) -> PageDescriptor? {
        descriptors.first { $0.id == page.rawValue }
    }

    /// 概览永远居中；其余按 sortKey 左右交替：第 1 个在左、第 2 个在右。
    static var ordered: [PageDescriptor] {
        let extras = descriptors
            .filter { $0.kind != .overview }
            .sorted { $0.sortKey < $1.sortKey }
        var left: [PageDescriptor] = []
        var right: [PageDescriptor] = []
        for (index, d) in extras.enumerated() {
            if index % 2 == 0 {
                left.insert(d, at: 0)
            } else {
                right.append(d)
            }
        }
        let center = descriptors.first { $0.kind == .overview }
        return left + (center.map { [$0] } ?? []) + right
    }
}

// MARK: - 组件注册表
//
// 概览卡片同样改为注册表：内置 7 个模块是 builtin renderer；
// 插件卡片后续以 .plugin(id) 注册，CanvasLayout 按字符串 id 布置。

struct WidgetDescriptor: Identifiable, Equatable {
    enum Renderer: Equatable {
        case builtin(ModuleID)
        case plugin(pluginID: String, cardID: String)
    }

    let id: String
    let title: String
    let renderer: Renderer
    let sortKey: Int
    /// 插件卡片首次加入画布时的尺寸；内置模块走 CanvasLayout.defaultBoxes。
    let defaultSize: CGSize?
}

enum WidgetRegistry {
    static let builtins: [WidgetDescriptor] = ModuleID.allCases.enumerated().map { index, m in
        WidgetDescriptor(id: m.rawValue, title: m.title, renderer: .builtin(m),
                         sortKey: index, defaultSize: nil)
    }

    /// 插件系统后续会追加；Phase 0 只有内置组件。
    static var descriptors: [WidgetDescriptor] = builtins

    static func descriptor(for id: String) -> WidgetDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// 默认顺序：注册顺序。SettingsStore 的 widgetOrder 才是用户实际顺序。
    static var orderedIDs: [String] { descriptors.map(\.id) }
}

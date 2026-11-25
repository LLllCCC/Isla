import SwiftUI

/// 插件声明的渲染树节点。只支持受控组件，插件不能写任意 SwiftUI/HTML。
struct PluginNode: Decodable, Equatable {
    var type: String
    var id: String?
    var title: String?
    var text: String?
    var value: String?
    var subtitle: String?
    var icon: String?
    var style: String?
    var tone: String?
    var action: PluginAction?
    var children: [PluginNode]?
    var items: [PluginNode]?
    var checked: Bool?
    var progress: Double?
    var placeholder: String?
    var options: [PluginOption]?
    var min: Double?
    var max: Double?
    var step: Double?
    /// 紧凑按钮：放在 row 里时不要撑满整行。
    var compact: Bool?
}

struct PluginOption: Decodable, Equatable {
    var title: String
    var value: String
}

/// 交互组件的本地状态。插件页每次重绘都会用渲染树里的值重新 seed，
/// 用户操作先写本地再 invoke 宿主，避免开关/输入框在重绘前跳回去。
final class PluginFormState: ObservableObject {
    static let shared = PluginFormState()

    @Published private var values: [String: Any] = [:]

    func bool(_ key: String, fallback: Bool) -> Bool {
        values[key] as? Bool ?? fallback
    }

    func string(_ key: String, fallback: String) -> String {
        values[key] as? String ?? fallback
    }

    func double(_ key: String, fallback: Double) -> Double {
        (values[key] as? NSNumber)?.doubleValue ?? fallback
    }

    func set(_ key: String, _ value: Any) {
        var copy = values
        copy[key] = value
        values = copy
    }

    func seed(_ key: String, _ value: Any) {
        // 只在没有本地值时播种；用户操作过的控件不被下一次重绘覆盖。
        guard values[key] == nil else { return }
        set(key, value)
    }
}

struct PluginAction: Decodable, Equatable {
    var command: String?
    var page: String?
    var url: String?
    /// 按钮携带的静态值（例如剪贴板条目的文本），invoke 时原样传给命令。
    var value: String?
}

// MARK: - 页面壳

struct PluginPageView: View {
    let pluginID: String
    let pageID: String
    /// manifest.preferredHeight；ScrollView 必须固定高度，否则会撑破面板把页签顶出去。
    var contentHeight: CGFloat = 300
    @ObservedObject private var runtime = PluginRuntime.shared

    var body: some View {
        let _ = runtime.treeRevision
        Group {
            if let node = runtime.tree(pluginID: pluginID, pageID: pageID) {
                ScrollView(.vertical, showsIndicators: false) {
                    PluginNodeView(node: node, pluginID: pluginID, stateKey: "\(pluginID)/\(pageID)")
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let error = runtime.error(pluginID: pluginID, pageID: pageID) {
                errorView(error)
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: contentHeight, alignment: .topLeading)
        .onAppear { runtime.render(pluginID: pluginID, pageID: pageID) }
        .onChange(of: runtime.invalidation) { _ in
            runtime.render(pluginID: pluginID, pageID: pageID)
        }
        .onChange(of: runtime.loadRevision) { _ in
            runtime.render(pluginID: pluginID, pageID: pageID)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("插件渲染中…")
                .miFont(size: 11)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 12)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .miFont(size: 11, weight: .medium)
                    .foregroundStyle(Theme.amber)
                Text("插件渲染失败")
                    .miFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(message)
                .miFont(size: 10.5)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") { runtime.render(pluginID: pluginID, pageID: pageID) }
                .buttonStyle(.borderless)
                .miFont(size: 11)
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .miCard(radius: Theme.rCard)
    }
}

// MARK: - 概览卡片

/// 插件注册到概览画布上的卡片。卡片自己画背景会与画布卡片的圆角/边距打架，
/// 所以 card / stat 根节点在这里展开成「标题 + 大数值」，外层统一用 miCard。
struct PluginWidgetView: View {
    let pluginID: String
    let cardID: String
    var title: String
    @ObservedObject private var runtime = PluginRuntime.shared

    var body: some View {
        let _ = runtime.treeRevision
        Group {
            if let node = runtime.card(pluginID: pluginID, cardID: cardID) {
                root(node)
            } else if let error = runtime.cardError(pluginID: pluginID, cardID: cardID) {
                VStack(alignment: .leading, spacing: 3) {
                    label
                    Text(error)
                        .miFont(size: 9)
                        .foregroundStyle(Theme.amber)
                        .lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    label
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 7).padding(.vertical, 7)
        .miCard(radius: Theme.rCard)
        .onAppear { runtime.renderCard(pluginID: pluginID, cardID: cardID) }
        .onChange(of: runtime.invalidation) { _ in
            runtime.renderCard(pluginID: pluginID, cardID: cardID)
        }
        .onChange(of: runtime.loadRevision) { _ in
            runtime.renderCard(pluginID: pluginID, cardID: cardID)
        }
    }

    private var label: some View {
        Text(title)
            .miFont(size: 10, weight: .medium)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func root(_ node: PluginNode) -> some View {
        if node.type == "card" || node.type == "stat" {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title ?? title)
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let value = node.value {
                    Text(value)
                        .miFont(size: 20, weight: .semibold, design: .rounded)
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .miFont(size: 9.5)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if let kids = node.children, !kids.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(kids.enumerated()), id: \.offset) { item in
                            PluginNodeView(node: item.element, pluginID: pluginID,
                                           stateKey: "\(pluginID)/card/\(cardID)")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            PluginNodeView(node: node, pluginID: pluginID,
                           stateKey: "\(pluginID)/card/\(cardID)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }
}

// MARK: - 声明式组件

struct PluginNodeView: View {
    let node: PluginNode
    let pluginID: String
    var stateKey: String = "root"
    @ObservedObject private var runtime = PluginRuntime.shared
    @ObservedObject private var form = PluginFormState.shared

    var body: some View {
        let _ = runtime.treeRevision
        switch node.type {
        case "page":
            VStack(alignment: .leading, spacing: 10) { childViews }
        case "section":
            VStack(alignment: .leading, spacing: 6) {
                if let title = node.title {
                    Text(title)
                        .miFont(size: 10, weight: .semibold)
                        .tracking(0.5)
                        .foregroundStyle(Theme.textTertiary)
                }
                childViews
            }
        case "text":
            Text(node.text ?? "")
                .miFont(size: textSize, weight: textWeight)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case "card":
            VStack(alignment: .leading, spacing: 4) {
                if let title = node.title {
                    Text(title)
                        .miFont(size: 10, weight: .medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let value = node.value {
                    Text(value)
                        .miFont(size: 20, weight: .semibold, design: .rounded)
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                childViews
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .miCard(radius: Theme.rCard)
        case "stat":
            VStack(alignment: .leading, spacing: 3) {
                if let title = node.title {
                    Text(title)
                        .miFont(size: 10, weight: .medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let value = node.value {
                    Text(value)
                        .miFont(size: 18, weight: .semibold, design: .rounded)
                        .foregroundStyle(Theme.textStrong)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .miCard(radius: Theme.rCard)
        case "list":
            VStack(alignment: .leading, spacing: 4) {
                if (node.items ?? node.children ?? []).isEmpty {
                    Text("暂无内容")
                        .miFont(size: 10.5)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    childViews
                }
            }
        case "row":
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = node.title {
                        Text(title)
                            .miFont(size: 11.5, weight: .medium)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let subtitle = node.subtitle {
                        Text(subtitle)
                            .miFont(size: 10)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 4)
                if let value = node.value {
                    Text(value)
                        .miFont(size: 11, design: .monospaced)
                        .foregroundStyle(Theme.textSecondary)
                }
                childViews
            }
            .padding(.vertical, 2)
        case "button":
            Button {
                if let command = node.action?.command {
                    runtime.invoke(pluginID: pluginID, command: command, value: node.action?.value)
                }
            } label: {
                HStack(spacing: 5) {
                    if let icon = node.icon {
                        Image(systemName: icon).miFont(size: 10, weight: .medium)
                    }
                    if let title = node.title, !title.isEmpty {
                        Text(title)
                            .miFont(size: 11.5, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // 紧凑按钮里不要放 Spacer：否则三个按钮会平分整行，
                    // 把条目名称挤成省略号。整行按钮才需要撑满。
                    if node.compact != true {
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: node.compact == true ? nil : .infinity, alignment: .leading)
                .background(Capsule().fill(Theme.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case "toggle":
            HStack(spacing: 10) {
                if let title = node.title {
                    Text(title)
                        .miFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { form.bool(stateKey, fallback: node.checked ?? false) },
                    set: { value in
                        form.set(stateKey, value)
                        if let command = node.action?.command {
                            runtime.invoke(pluginID: pluginID, command: command, value: value)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .onAppear { form.seed(stateKey, node.checked ?? false) }
        case "textField":
            VStack(alignment: .leading, spacing: 4) {
                if let title = node.title {
                    Text(title)
                        .miFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                TextField(node.placeholder ?? "", text: Binding(
                    get: { form.string(stateKey, fallback: node.value ?? "") },
                    set: { form.set(stateKey, $0) }
                ))
                .textFieldStyle(.plain)
                .miFont(size: 11.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.6))
                .onSubmit {
                    if let command = node.action?.command {
                        runtime.invoke(pluginID: pluginID, command: command,
                                       value: form.string(stateKey, fallback: node.value ?? ""))
                    }
                }
            }
            .onAppear { form.seed(stateKey, node.value ?? "") }
        case "picker":
            HStack(spacing: 10) {
                if let title = node.title {
                    Text(title)
                        .miFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { form.string(stateKey, fallback: node.value ?? node.options?.first?.value ?? "") },
                    set: { value in
                        form.set(stateKey, value)
                        if let command = node.action?.command {
                            runtime.invoke(pluginID: pluginID, command: command, value: value)
                        }
                    }
                )) {
                    ForEach(node.options ?? [], id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            .onAppear { form.seed(stateKey, node.value ?? node.options?.first?.value ?? "") }
        case "slider":
            let current = form.double(stateKey, fallback: node.value.flatMap(Double.init) ?? node.min ?? 0)
            VStack(spacing: 5) {
                HStack {
                    if let title = node.title {
                        Text(title)
                            .miFont(size: 11, weight: .medium)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f", current))
                        .miFont(size: 10, design: .monospaced)
                        .foregroundStyle(Theme.textTertiary)
                }
                Slider(value: Binding(
                    get: { form.double(stateKey, fallback: node.value.flatMap(Double.init) ?? node.min ?? 0) },
                    set: { value in
                        form.set(stateKey, value)
                        if let command = node.action?.command {
                            runtime.invoke(pluginID: pluginID, command: command, value: value)
                        }
                    }
                ), in: (node.min ?? 0)...(node.max ?? 1), step: node.step ?? 0.1)
                .controlSize(.small)
            }
            .onAppear { form.seed(stateKey, current) }
        case "divider":
            Rectangle().fill(Theme.stroke).frame(height: 0.6)
        case "spacer":
            Spacer(minLength: 4)
        case "image":
            Image(systemName: node.icon ?? "questionmark")
                .miFont(size: 14, weight: .medium)
                .foregroundStyle(textColor)
        case "progress":
            ProgressView(value: min(max(node.progress ?? 0, 0), 1))
                .tint(Theme.accent)
                .controlSize(.small)
        default:
            Text(String(format: L("[未知组件：%@]"), node.type))
                .miFont(size: 10)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var nodes: [PluginNode] { node.children ?? node.items ?? [] }

    @ViewBuilder
    private var childViews: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { index, child in
            PluginNodeView(node: child, pluginID: pluginID, stateKey: "\(stateKey)/\(index)")
        }
    }

    private var textSize: CGFloat {
        switch node.style {
        case "title":    return 15
        case "subtitle": return 11
        case "caption":  return 9.5
        default:         return 11.5
        }
    }

    private var textWeight: Font.Weight {
        node.style == "title" ? .semibold : .regular
    }

    private var textColor: Color {
        switch node.tone {
        case "accent":    return Theme.accent
        case "red":       return Color(red: 1.0, green: 0.42, blue: 0.38)
        case "secondary": return Theme.textSecondary
        case "tertiary":  return Theme.textTertiary
        default:          return Theme.textPrimary
        }
    }
}

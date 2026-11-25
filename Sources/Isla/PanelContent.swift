import SwiftUI
import AppKit

struct PanelContent: View {
    @ObservedObject var store = IslandStore.shared
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var clip = ClipboardService.shared
    @ObservedObject var shelf = ShelfService.shared
    @ObservedObject var canvas = CanvasLayout.shared
    @ObservedObject var pluginManager = PluginManager.shared
    @Namespace private var pageNamespace
    /// 量高时强制按某一页渲染（用于「三页统一以概览为准」）
    var pageOverride: PanelPage? = nil

    private var page: PanelPage { pageOverride ?? store.page }

    /// 拖动中实时跟随 preview 尺寸（虚线框不再悬在面板外），松手后用落盘值
    private var liveW: Double { (canvas.dragging != nil || canvas.resizing != nil) ? canvas.previewW : canvas.canvasW }
    private var liveH: Double { (canvas.dragging != nil || canvas.resizing != nil) ? canvas.previewH : canvas.canvasH }

    /// 概览页宽度跟随画布；其它页统一用同一个宽度，切页不横向跳
    private var viewWidth: CGFloat {
        CGFloat(liveW) + IslandMetrics.panelChromeWidth
    }

    private let amber = Theme.amber

    var body: some View {
        let _ = pluginManager.revision
        VStack(alignment: .leading, spacing: 10) {
            pageBar
            Group {
                switch page.kind {
                case .overview:  overviewCanvas
                case .clipboard: clipboardPage
                case .shelf:     shelfPage
                case .plugin:
                    if let ref = PluginManager.shared.pageRef(for: page.rawValue),
                       let desc = page.descriptor,
                       let entry = desc.webEntry,
                       let dir = PluginManager.shared.directory(forPlugin: ref.pluginID) {
                        // Phase 3：kind=web 的插件页由 WKWebView 渲染。
                        PluginWebPageView(
                            pluginID: ref.pluginID,
                            pageID: ref.pageID,
                            entry: entry,
                            directory: dir,
                            permissions: PluginManager.shared.permissions(forPlugin: ref.pluginID),
                            height: CGFloat(desc.preferredHeight ?? 360),
                            revision: pluginManager.revision
                        )
                    } else if let ref = PluginManager.shared.pageRef(for: page.rawValue) {
                        PluginPageView(pluginID: ref.pluginID, pageID: ref.pageID,
                                       contentHeight: CGFloat(page.descriptor?.preferredHeight ?? 300))
                    } else {
                        pluginPagePlaceholder
                    }
                }
            }
            .id(page)
            .transition(pageTransition)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(width: viewWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.page)
        .environment(\.colorScheme, Theme.isDarkUI ? ColorScheme.dark : ColorScheme.light)
    }

    /// 插件页宿主占位：Phase 1 接入 JS 运行时后由插件渲染树替换。
    private var pluginPagePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .miFont(size: 22, weight: .medium)
                .foregroundStyle(Theme.textTertiary)
            Text("插件页")
                .miFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.textSecondary)
            Text("插件运行时将在下一阶段接入")
                .miFont(size: 10)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private enum PanelBlock: String, Hashable { case study, media, tiles }

    /// 学习卡里被启用的模块，按用户顺序
    private var studyModules: [ModuleID] {
        settings.moduleOrder.filter {
            ($0 == .countdown && settings.countdownEnabled) || ($0 == .focus && settings.focusCard)
        }
    }

    private var tileModules: [ModuleID] {
        settings.moduleOrder.filter {
            ($0 == .pomodoro && settings.tilePomodoro)
            || ($0 == .cpu && settings.tileCPU)
            || ($0 == .memory && settings.tileMemory)
        }
    }

    /// 三大块按各自「最靠前的模块」排序；块内顺序沿用同一份 moduleOrder
    private var orderedBlocks: [PanelBlock] {
        var candidates: [(PanelBlock, Int)] = []
        if let i = settings.moduleOrder.firstIndex(where: { studyModules.contains($0) }) {
            candidates.append((.study, i))
        }
        if settings.mediaEnabled, let i = settings.moduleOrder.firstIndex(of: .media) {
            candidates.append((.media, i))
        }
        if let i = settings.moduleOrder.firstIndex(where: { tileModules.contains($0) }) {
            candidates.append((.tiles, i))
        }
        return candidates.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: - 分页

    private var pageBar: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(PanelPage.tabOrder) { p in
                            Button { store.go(to: p) } label: {
                                HStack(spacing: 5) {
                                    Text(LocalizedStringKey(p.title))
                                        .miFont(size: 10, weight: page == p ? .semibold : .medium)
                                        .foregroundStyle(page == p ? Theme.textPrimary : Theme.textTab)
                                    Circle()
                                        .fill(page == p ? Theme.accent : Theme.decoFaint)
                                        .frame(width: page == p ? 4.5 : 3.5,
                                               height: page == p ? 4.5 : 3.5)
                                        .shadow(color: page == p ? Theme.accent.opacity(0.7) : .clear,
                                                radius: page == p ? 4 : 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    if page == p {
                                        Capsule()
                                            .fill(Theme.surfaceHi)
                                            .matchedGeometryEffect(id: "pagePill", in: pageNamespace)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(p)
                        }
                    }
                    .padding(3)
                    .background(Capsule().fill(Theme.surface.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.6))
                    // 页签放得下时铺满可视宽度并居中；放不下时保持自身宽度，横向滚动。
                    .frame(minWidth: geo.size.width, alignment: .center)
                }
                .onChange(of: page) { newPage in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(newPage, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(page, anchor: .center)
                }
            }
        }
        .frame(height: 28)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: page)
    }

    // MARK: - 计划

    // MARK: - 积木画布

    private var canvasModules: [WidgetDescriptor] {
        settings.widgetOrder
            .compactMap(WidgetRegistry.descriptor)
            .filter { settings.isEnabled($0.id) }
    }

    private var overviewCanvas: some View {
        ZStack(alignment: .topLeading) {
            // 拖动中「将要长到/缩到」的边界：虚线预览框（只提示，不挡操作）；
            // 尺寸与画布实时 frame 一致，扩展/缩回都看得见
            if (canvas.dragging != nil || canvas.resizing != nil),
               canvas.previewW > canvas.canvasW || canvas.previewH > canvas.canvasH,
               canvas.previewW > 0, canvas.previewH > 0 {
                RoundedRectangle(cornerRadius: Theme.rNested, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: CGFloat(canvas.previewW), height: CGFloat(canvas.previewH))
                    .allowsHitTesting(false)
            }
            // 受限排列的吸附参考线：只在真正吸住邻居边/中心线时出现。
            // 局部线段（拖动卡自身范围 ±12pt），不再画整条贯穿画布的长线——
            // 长线会被读成「虚线框在吸卡片」，局部段只表达「这两条边对齐了」。
            if let activeID = canvas.dragging ?? canvas.resizing,
               let db = canvas.boxes[activeID] {
                if let gx = canvas.guideX {
                    Rectangle()
                        .fill(Theme.accent.opacity(0.45))
                        .frame(width: 1, height: CGFloat(db.h) + 24)
                        .offset(x: CGFloat(gx - canvas.originX) - 0.5, y: CGFloat(db.y) - 12)
                        .allowsHitTesting(false)
                }
                if let gy = canvas.guideY {
                    Rectangle()
                        .fill(Theme.accent.opacity(0.45))
                        .frame(width: CGFloat(db.w) + 24, height: 1)
                        .offset(x: CGFloat(db.x - canvas.originX) - 12, y: CGFloat(gy) - 0.5)
                        .allowsHitTesting(false)
                }
            }
            ForEach(canvasModules) { d in
                let box = canvas.boxes[d.id]
                    ?? CanvasLayout.defaultBoxes[d.id]
                    ?? CanvasLayout.Box(x: 0, y: 0, w: 172, h: 84)
                let isDragged = canvas.dragging == d.id
                let conflicted = canvas.inConflict(d.id)
                let radius = moduleRadius(d.id)
                moduleBody(d)
                    .contextMenu {
                        Button("放大 20%") { canvas.scale(d.id, by: 1.2) }
                        Button("缩小 20%") { canvas.scale(d.id, by: 1 / 1.2) }
                        Button("恢复默认尺寸") { canvas.resetSize(d.id) }
                        Divider()
                        Button("网格整理") { canvas.arrangeGrid() }
                    }
                    .frame(width: box.w, height: box.h)
                    .overlay(alignment: .bottomTrailing) {
                        resizeHandle(d.id)
                    }
                    .onHover { inside in
                        canvas.setHovered(inside ? d.id : nil)
                    }
                    // 拖动重叠的冲突提示：被压到的卡和压人的卡都描一圈警示红、压暗；
                    // 松手回弹后提示自动消失
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color(red: 1.0, green: 0.42, blue: 0.38),
                                          lineWidth: conflicted ? 1.3 : 0)
                            .allowsHitTesting(false)
                    )
                    .opacity(conflicted ? (isDragged ? 0.88 : 0.45) : 1)
                    .offset(x: box.x - canvas.originX, y: box.y)
                    .zIndex(isDragged ? 20 : 0)
                    // 拖动中不做 scaleEffect：卡片放大 2% 会让可见边比布局边外扩 3~4pt，
                    // 吸附参考线画在布局边上，看起来就永远「差一点点对不齐」。
                    // 抬起来的观感靠下面的阴影，不靠放大。
                    .shadow(color: .black.opacity(isDragged ? 0.45 : 0),
                            radius: 14, y: 7)
                    // 松手回弹：只有「这一张卡正在弹回原位」时才给弹簧动画；
                    // 拖动中的逐帧跟随必须保持无动画（nil = 显式关闭），否则会飘。
                    .animation(canvas.snapBack == d.id
                               ? .spring(response: 0.36, dampingFraction: 0.62)
                               : nil,
                               value: box)
                    .simultaneousGesture(dragGesture(d.id))
            }
        }
        .frame(width: liveW, height: liveH, alignment: .topLeading)
    }

    @ViewBuilder
    private func moduleBody(_ d: WidgetDescriptor) -> some View {
        switch d.renderer {
        case .builtin(let m):
            moduleBody(m)
        case .plugin(let pluginID, let cardID):
            PluginWidgetView(pluginID: pluginID, cardID: cardID, title: d.title)
        }
    }

    @ViewBuilder
    private func moduleBody(_ m: ModuleID) -> some View {
        let r = moduleRadius(m.rawValue)
        switch m {
        case .countdown: countdownCard(radius: r)
        case .focus:     focusCard(radius: r)
        case .media:     nowPlaying(radius: r)
        case .pomodoro:
            Button { PomodoroService.shared.toggle() } label: {
                // 82pt 窄 tile 放不下「番茄 · 专注」：阶段改由图标表达（休息 = 咖啡杯），
                // 文字只留「番茄」，避免出现「番茄 …」这种省略号
                tile(icon: store.pomodoroPhase == "休息" ? "cup.and.saucer.fill" : "timer",
                     title: "番茄",
                     value: timeString(store.pomodoroRemaining),
                     tint: store.pomodoroRunning ? Theme.accent : Theme.textSecondary,
                     radius: r)
            }
            .buttonStyle(.plain)
        case .cpu:
            tile(icon: "cpu", title: "处理器", value: "\(Int(store.cpu))%", tint: Theme.blue, radius: r)
        case .memory:
            tile(icon: "memorychip", title: "内存", value: String(format: "%.1fG", store.memGB), tint: Theme.violet, radius: r)
        case .network:
            networkTile(radius: r)
        }
    }

    /// 贴到画布外角的卡片要和外框/虚线共用同一个圆心：
    /// 外框半径 24、内边距 14，因此贴角卡片用 10；其它卡片维持 14。
    private func moduleRadius(_ id: String) -> CGFloat {
        guard let box = canvas.boxes[id] else { return Theme.rCard }
        let x = box.x - canvas.originX
        let y = box.y
        let right = x + box.w
        let bottom = y + box.h
        let atHorizontalEdge = x <= 0.5 || right >= liveW - 0.5
        // 面板顶部留给页签，真正的同心外角只有左下/右下；
        // 顶部卡片不要误用 10pt，否则它会比页签看起来更「尖」。
        let atBottomEdge = bottom >= liveH - 0.5
        return atHorizontalEdge && atBottomEdge ? Theme.rNested : Theme.rCard
    }

    /// 实时网速：两行（↓ 下行 / ↑ 上行），82pt 窄 tile 里也能放下
    private var networkTile: some View { networkTile(radius: Theme.rCard) }

    private func networkTile(radius: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            speedRow(icon: "arrow.down", label: L("下行"),
                     value: NetworkSpeedService.format(store.netDown), tint: Theme.accent)
            speedRow(icon: "arrow.up", label: L("上行"),
                     value: NetworkSpeedService.format(store.netUp), tint: Theme.amber)
        }
        // 撑满 box frame：miCard 填充必须铺满 82×58，否则可见边缘与吸附边不一致
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 7).padding(.vertical, 7)
        .miCard(radius: radius)
    }

    /// 一行网速：箭头 + 数值。
    /// 82pt 的 tile 里「箭头 + 下行 + 102KB/s」放不下（实测差 10pt 以上），
    /// 用 ViewThatFits 按内容切换又会在网速跳动时来回抖，所以固定成箭头 + 数值：
    /// 方向由箭头和颜色表达，中文名放到无障碍标签里。
    /// 字体分档：几百 KB/s / MB/s 时数值变长，按字符数降字号，
    /// 保证 tile 尺寸与内存/处理器 tile 完全一致；几或几十 KB/s 用正常字号。
    private func speedRow(icon: String, label: String, value: String, tint: Color) -> some View {
        let size: CGFloat
        switch value.count {
        case ..<7:  size = 11      // 2KB/s、683B/s、86KB/s
        case 7:     size = 9.5     // 868KB/s、1.4MB/s
        default:    size = 8.5     // 12.5MB/s 及更长
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .miFont(size: 8, weight: .bold)
                .foregroundStyle(tint)
                .frame(width: 8)
            Spacer(minLength: 2)
            Text(value)
                .miFont(size: size, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(Theme.textStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    /// 右下角缩放手柄：只在悬停或缩放时显示，避免挡住卡片右下角按钮。
    private func resizeHandle(_ id: String) -> some View {
        let visible = canvas.hovered == id || canvas.resizing == id
        return ZStack(alignment: .bottomTrailing) {
            Color.clear.frame(width: 18, height: 18)
            Image(systemName: "arrow.down.right")
                .miFont(size: 7.5, weight: .bold)
                .foregroundStyle(Theme.decoFaint)
                .padding(3)
        }
        .contentShape(Rectangle())
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { inside in
            canvas.setHandleHovered(inside ? id : nil)
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in canvas.updateResize(id) }
                .onEnded { _ in canvas.endResize(id) }
        )
        .help("拖动缩放组件")
    }

    /// 长按 0.32s 后才进入拖动（类似手机桌面图标）
    private func dragGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.32)
            .sequenced(before: DragGesture(minimumDistance: 1, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    // 指针停在缩放手柄上时长按只应该缩放，不能把卡片拖走。
                    if canvas.hoveredHandle == nil { canvas.begin(id) }
                case .second(true, let drag?):
                    canvas.update(id, translation: drag.translation)
                default:
                    break
                }
            }
            .onEnded { _ in
                canvas.end(id)
            }
    }

    /// 翻页转场：向后翻时新页从右侧滑入，向前翻时从左侧滑入
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: store.pageDirection > 0 ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: store.pageDirection > 0 ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func clearButton(empty: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "trash").miFont(size: 8, weight: .medium)
                Text("清空").miFont(size: 9.5, weight: .medium)
            }
            .foregroundStyle(empty ? Theme.textTertiary.opacity(0.5) : Theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .help(hint)
    }

    private var studyRow: some View {
        HStack(spacing: 8) {
            ForEach(studyModules) { m in
                Group {
                    if m == .countdown { countdownCard } else { focusCard }
                }
                // 两张卡必须等宽：只靠 maxWidth 会按各自理想宽度分配，出现一宽一窄
                .frame(width: studyCardWidth)
            }
        }
    }

    private var studyCardWidth: CGFloat {
        let content = IslandMetrics.panelWidth - 28   // 左右各 14 的内边距
        return studyModules.count > 1 ? (content - 8) / 2 : content
    }

    private var countdownCard: some View { countdownCard(radius: Theme.rCard) }

    private func countdownCard(radius: CGFloat) -> some View {
        let list = settings.upcomingPlans
        let focus = list.first
        let extra = Array(list.dropFirst().prefix(2))
        let value = focus.map { countdownValue($0) } ?? ("—", "")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .miFont(size: 9, weight: .bold)
                    .foregroundStyle(Theme.accent)
                Text(LocalizedStringKey(focus?.title ?? L("计划")))
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.0)
                    .miFont(size: 20, weight: .semibold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textStrong)
                Text(value.1)
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 2)
                if let f = focus {
                    Text(shortDate(f.date))
                        .miFont(size: 9)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if !extra.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(extra) { p in
                        HStack(spacing: 3) {
                            Text(LocalizedStringKey(p.title))
                                .miFont(size: 8.5)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(dayLabel(p.date))
                                .miFont(size: 8.5)
                                .foregroundStyle(Theme.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        // 同 statCard：撑满 box frame，可见边缘=吸附边缘
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .miCard(radius: radius)
    }

    /// 今日专注：左侧数字，右侧 7 天迷你柱（最后一根是今天）
    private var focusCard: some View { focusCard(radius: Theme.rCard) }

    private func focusCard(radius: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .miFont(size: 9, weight: .bold)
                    .foregroundStyle(amber)
                Text("今日专注")
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(String(format: L("%d 个番茄"), store.focusCount))
                    .miFont(size: 9)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            HStack(alignment: .bottom, spacing: 2) {
                Text("\(store.focusMinutes)")
                    .miFont(size: 20, weight: .semibold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textStrong)
                Text("分")
                    .miFont(size: 10, weight: .medium)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 2)
                weekBars
            }
        }
        // 同 statCard：撑满 box frame，可见边缘=吸附边缘
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .miCard(radius: radius)
    }

    private var weekBars: some View {
        let data = store.weekMinutes
        let maxV = max(data.max() ?? 0, 1)
        // 全为 0 时不画（否则 7 个 2pt 圆点连成一条虚线，像渲染故障）
        let allZero = data.allSatisfy { $0 == 0 }
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(data.enumerated()), id: \.offset) { idx, v in
                Capsule()
                    .fill(allZero
                          ? Color.clear
                          : (idx == data.count - 1
                             ? Theme.accent.opacity(0.95)
                             : Theme.accent.opacity(v > 0 ? 0.42 : 0.14)))
                    .frame(width: 3, height: max(2, CGFloat(v) / CGFloat(maxV) * 15))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .help(L("最近 7 天专注分钟数"))
    }

    private func countdownValue(_ plan: PlanItem) -> (String, String) {
        let d = settings.days(to: plan.date)
        if d > 0 { return ("\(d)", L("天")) }
        if d == 0 { return ("今天", "") }
        return ("已过", String(format: L("%d 天"), -d))
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    private func dayLabel(_ date: Date) -> String {
        let d = settings.days(to: date)
        if d > 0 { return String(format: L("%d 天"), d) }
        if d == 0 { return "今天" }
        return String(format: L("已过 %d 天"), -d)
    }

    private var nowPlaying: some View { nowPlaying(radius: 16) }

    private func nowPlaying(radius: CGFloat) -> some View {
        HStack(spacing: 10) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(store.track?.title ?? "未在播放")
                    .miFont(size: 13, weight: .semibold)
                    .foregroundStyle(store.track == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(LocalizedStringKey(subtitle))
                    .miFont(size: 11)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                progressBar
                    .padding(.top, 2)
            }

            Spacer(minLength: 2)

            HStack(spacing: 9) {
                Button { NowPlayingService.shared.previous() } label: {
                    Image(systemName: "backward.fill").miFont(size: 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.track == nil ? Theme.textTertiary : Theme.textSecondary)

                Button { NowPlayingService.shared.togglePlay() } label: {
                    Image(systemName: (store.track?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                        .miFont(size: 15)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.track == nil ? Theme.textTertiary : Theme.textPrimary)

                Button { NowPlayingService.shared.next() } label: {
                    Image(systemName: "forward.fill").miFont(size: 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.track == nil ? Theme.textTertiary : Theme.textSecondary)
            }
            .disabled(store.track == nil)
        }
        // 撑满 box frame：空闲态内容变矮时填充不再居中漂移（同 statCard）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(10)
        .miCard(radius: radius)
    }

    private var subtitle: String {
        guard let t = store.track else { return "在任意播放器里开始播放" }
        let parts = [t.artist, t.album].filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var artwork: some View {
        Group {
            if let data = store.track?.artwork, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceHi)
                    Image(systemName: "music.note")
                        .miFont(size: 15, weight: .medium)
                        .foregroundStyle(Theme.accent.opacity(0.75))
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var progressBar: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.progressTrack).frame(width: 176, height: 3)
                Capsule().fill(Theme.progressFill)
                    .frame(width: max(0, 176 * CGFloat(store.progress)), height: 3)
            }
            HStack {
                Text(timeString(store.elapsed))
                Spacer()
                Text(timeString(store.track?.duration ?? 0))
            }
            .miFont(size: 9, design: .monospaced)
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 176)
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            ForEach(tileModules) { m in
                switch m {
                case .pomodoro:
                    Button { PomodoroService.shared.toggle() } label: {
                        tile(icon: "timer",
                             title: String(format: L("番茄 · %@"), store.pomodoroPhase),
                             value: timeString(store.pomodoroRemaining),
                             tint: store.pomodoroRunning ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                case .cpu:
                    tile(icon: "cpu", title: "处理器", value: "\(Int(store.cpu))%", tint: Theme.blue)
                default:
                    tile(icon: "memorychip", title: "内存", value: String(format: "%.1fG", store.memGB), tint: Theme.violet)
                }
            }
        }
    }

    private func tile(icon: String, title: String, value: String, tint: Color,
                      radius: CGFloat = Theme.rCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).miFont(size: 9, weight: .bold).foregroundStyle(tint)
                Text(LocalizedStringKey(title)).miFont(size: 10, weight: .medium).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(value).miFont(size: 15, weight: .semibold, design: .rounded)
                .monospacedDigit().foregroundStyle(Theme.textStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .miCard(radius: radius)
    }

    // MARK: - 剪贴板页

    private var clipboardPage: some View {
        VStack(spacing: 7) {
            listBlock
            privacyHint
        }
    }

    private var listBlock: some View {
        Group {
            if clip.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .miFont(size: 22, weight: .light)
                        .foregroundStyle(Theme.decoFaint)
                    Text("复制点什么，这里会出现")
                        .miFont(size: 11)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(clip.items) { item in
                            clipboardRow(item)
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
    }

    /// 列表高度跟着条目数长，最多 4 行；再多多滚
    private var listHeight: CGFloat {
        let rows = min(max(clip.items.count, 1), 4)
        return CGFloat(rows) * 36 - 6
    }

    private var privacyHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
                .miFont(size: 9, weight: .medium)
            Text("文本 / 图片 / 文件都记；隐私内容不记")
                .miFont(size: 9)
                .lineLimit(1)
            Spacer(minLength: 6)
            // 「清空」从页签栏移到这里：插件页变多后，覆盖在页签上会互相压字。
            clearButton(empty: clip.items.isEmpty, hint: "剪贴板只在内存里，退出即清") { clip.clear() }
        }
        .foregroundStyle(Theme.deco)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clipboardRow(_ item: ClipboardService.Item) -> some View {
        Button { clip.copy(item) } label: {
            HStack(spacing: 8) {
                if item.kind == .image, let img = item.image {
                    // 图片条目直接显示内容缩略图（数据本来就在内存历史里，零额外开销）；
                    // 旧实现只有 photo 图标 + 尺寸文字，用户无法「看到复制过的图片」。
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 30, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.6))
                } else {
                    Image(systemName: iconName(item.kind))
                        .miFont(size: 10, weight: .medium)
                        .foregroundStyle(Theme.decoStrong)
                        .frame(width: 14)
                }
                Text(item.preview)
                    .miFont(size: 11)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if clip.isPinned(item.id) {
                    Image(systemName: "pin.fill")
                        .miFont(size: 8, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                }
                Text(clip.justCopied == item.id ? "已复制" : clip.ageText(item.date))
                    .miFont(size: 9, weight: .medium)
                    .foregroundStyle(clip.justCopied == item.id ? Theme.accent : Theme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(clip.justCopied == item.id ? Theme.surfaceHi : Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private func iconName(_ kind: ClipboardService.Kind) -> String {
        switch kind {
        case .text:  return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    // MARK: - 暂存页

    private var shelfPage: some View {
        VStack(spacing: 7) {
            shelfListBlock
            HStack(spacing: 5) {
                Image(systemName: "hand.draw")
                    .miFont(size: 9, weight: .medium)
                Text("拖到胶囊上收进来，拖出面板即可取出")
                    .miFont(size: 9)
                    .lineLimit(1)
                Spacer(minLength: 6)
                clearButton(empty: shelf.items.isEmpty, hint: "暂存架只存路径，不复制文件") { shelf.clear() }
            }
            .foregroundStyle(Theme.deco)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shelfListBlock: some View {
        Group {
            if shelf.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .miFont(size: 22, weight: .light)
                        .foregroundStyle(Theme.decoFaint)
                    Text("把文件拖到菜单栏胶囊上")
                        .miFont(size: 11)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            shelfRow(item)
                        }
                    }
                }
                .frame(height: shelfHeight)
            }
        }
    }

    private var shelfHeight: CGFloat {
        CGFloat(min(max(shelf.items.count, 1), 4)) * 36 - 6
    }

    private func shelfRow(_ item: ShelfService.Item) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: shelf.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
            Text(item.name)
                .miFont(size: 11)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url.path)
            Spacer(minLength: 4)
            Text(shelf.ageText(item.added))
                .miFont(size: 9)
                .foregroundStyle(Theme.textTertiary)
            Button { shelf.remove(item) } label: {
                Image(systemName: "xmark")
                    .miFont(size: 8, weight: .bold)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .miCard(radius: Theme.rChip)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    }

}

import SwiftUI
import AppKit
import Combine

/// 概览的「积木画布」：每个模块有自己的 x/y/w/h，长按可自由拖动。
///
/// 画布宽度不是简单跟随最右卡片，而是以设计中心线为轴**对称扩展**：
/// 组件往左拖 d，面板左右各长 d；组件往右拖 d，面板也左右各长 d。
/// 这样胶囊中心线、面板中心线始终重合，拖动卡片仍 1:1 跟手，
/// 其它卡片在屏幕上保持原位；空白只会出现在相反方向。
final class CanvasLayout: ObservableObject {
    static let shared = CanvasLayout()

    struct Box: Codable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    /// 画布最小尺寸（也是首次启动的样式）
    static let minW: Double = Double(IslandMetrics.canvasMinWidth)
    static let minH: Double = Double(IslandMetrics.canvasMinHeight)
    /// 首次启动的完整布局高度（全模块一行行摆满时的包围盒）
    static let defaultH: Double = Double(IslandMetrics.canvasDefaultHeight)
    /// 画布上限：超过面板就会被裁掉（高 = 面板上限 − 页签/内边距）。
    private static var maxW: Double { Double(IslandMetrics.canvasMaxWidth) }
    private static var maxH: Double { Double(IslandMetrics.canvasMaxHeight) }
    /// 默认布局水平中心：所有对称扩展都围绕它发生。
    private static let baseCenter: Double = minW / 2

    @Published private(set) var boxes: [String: Box]
    /// 面板内画布的宽度（已经包含左右对称空白），不是卡片内容的包围盒宽度。
    @Published private(set) var canvasW: Double
    @Published private(set) var canvasH: Double
    /// 画布原点偏移（<=0）：渲染时用 `box.x - originX`。
    /// 它同时让面板左边缘左移，因此面板中心线不会跟着画布跑。
    @Published private(set) var originX: Double = 0
    @Published private(set) var dragging: String?
    /// 正在拖右下角缩放的组件。
    @Published private(set) var resizing: String?
    /// 当前指针悬停的组件（缩放手柄只在悬停/缩放时显示，避免挡住卡片右下角按钮）。
    @Published private(set) var hovered: String?
    /// 当前指针是否停在缩放手柄上：此时禁止长按拖动，保证拖手柄只缩放。
    @Published private(set) var hoveredHandle: String?
    /// 拖动中「将要长到/缩到」的尺寸 = 全部组件包围盒 + 10pt 呼吸边距；
    /// 面板尺寸拖动中实时跟随这个值，松手后落盘为 canvasW/H。
    @Published private(set) var previewW: Double = 0
    @Published private(set) var previewH: Double = 0
    /// 受限排列时，当前吸附到的参考线（画布坐标）。用于显示对齐提示。
    @Published private(set) var guideX: Double?
    @Published private(set) var guideY: Double?
    /// 松手时因重叠被弹回原位的组件 id（0.45s 后清除，SwiftUI 据此播回弹动画）
    @Published private(set) var snapBack: String?

    /// 拖动中的几何变化回调：由控制器同步改面板 frame。
    /// 不能只靠 objectWillChange + DispatchQueue.main.async——那条链路会晚一拍，
    /// 卡片已经跟手了、边框还在追，剧烈拖动时卡片会被旧窗口边界裁掉。
    var onDragGeometryChanged: (() -> Void)?

    private var dragStart: Box?
    /// 手势开始时的全局鼠标位置：SwiftUI 的 translation 在面板自身移动时会失真，
    /// 直接用鼠标位移换算，保证卡片始终 1:1 跟手。
    private var dragPointerStart: NSPoint?
    private var resizeStart: Box?
    private var resizePointerStart: NSPoint?
    private var snapBackWork: DispatchWorkItem?
    private let d = UserDefaults.standard

    /// 四个 tile 一行（82pt × 4 + 8pt 间距 × 3 = 352，画布宽度不变）
    static let defaultBoxes: [String: Box] = [
        "countdown": Box(x: 0,   y: 0,   w: 172, h: 84),
        "focus":     Box(x: 180, y: 0,   w: 172, h: 84),
        "media":     Box(x: 0,   y: 92,  w: 352, h: 84),
        "pomodoro":  Box(x: 0,   y: 184, w: 82,  h: 58),
        "cpu":       Box(x: 90,  y: 184, w: 82,  h: 58),
        "memory":    Box(x: 180, y: 184, w: 82,  h: 58),
        "network":   Box(x: 270, y: 184, w: 82,  h: 58)
    ]

    private init() {
        var loaded = Self.defaultBoxes
        if let data = d.data(forKey: "canvasBoxes"),
           let saved = try? JSONDecoder().decode([String: Box].self, from: data) {
            // 不再只认内置 id：插件卡片的位置也要能跨启动保留。
            // 已卸载插件的盒子由 syncWidgets() 清理。
            for (k, v) in saved { loaded[k] = v }
        }
        // 老数据可能落在新上限之外（换屏/旧版本拖太远）：加载时就收回可显示区域。
        loaded = loaded.mapValues { Self.clampBox($0) }
        boxes = loaded
        let metrics = Self.centeredMetrics(for: loaded)
        originX = metrics.originX
        canvasW = metrics.width
        let maxB = loaded.values.map { $0.y + $0.h }.max() ?? Self.minH
        canvasH = min(max(Self.minH, maxB), Self.maxH)
        previewW = canvasW
        previewH = canvasH
    }

    // MARK: 拖动

    func begin(_ id: String) {
        guard boxes[id] != nil, resizing == nil else { return }
        dragging = id
        dragStart = boxes[id]
        dragPointerStart = NSEvent.mouseLocation
        guideX = nil
        guideY = nil
        previewW = canvasW
        previewH = canvasH
        snapBackWork?.cancel()
        snapBackWork = nil
        snapBack = nil
    }

    func update(_ id: String, translation: CGSize) {
        guard dragging == id, let start = dragStart else { return }

        let dx: Double
        let dy: Double
        if let p0 = dragPointerStart {
            let now = NSEvent.mouseLocation
            dx = Double(now.x - p0.x)
            dy = Double(p0.y - now.y)   // AppKit y 向上，画布 y 向下
        } else {
            dx = Double(translation.width)
            dy = Double(translation.height)
        }
        var nx = start.x + dx
        var ny = max(0, start.y + dy)
        // 到画布物理边界就停住，别让卡片被面板裁掉。
        // 左边界允许为负：负坐标会把画布向左扩展，面板与其它组件按原点偏移跟随。
        nx = min(nx, max(0, Self.maxW - start.w))
        nx = max(nx, -max(0, Self.maxW - start.w))
        ny = min(ny, max(0, Self.maxH - start.h))

        var nextGuideX: Double?
        var nextGuideY: Double?
        if SettingsStore.shared.dragMode == .grid {
            let result = magneticBox(for: start, desiredX: nx, desiredY: ny, id: id)
            boxes[id] = result.box
            nx = result.box.x
            ny = result.box.y
            nextGuideX = result.guideX
            nextGuideY = result.guideY
        } else {
            boxes[id] = Box(x: nx, y: ny, w: start.w, h: start.h)
        }
        guideX = nextGuideX
        guideY = nextGuideY

        let metrics = Self.centeredMetrics(for: boxes)
        originX = metrics.originX
        let maxB = boxes.values.map { $0.y + $0.h }.max() ?? canvasH
        // 水平宽度由 centeredMetrics 决定；高度仍按卡片包围盒长。
        previewW = min(Self.maxW, max(Self.minW, metrics.width))
        previewH = min(Self.maxH, max(Self.minH, maxB > canvasH ? maxB + 10 : maxB))
        onDragGeometryChanged?()
    }

    func end(_ id: String) {
        guard dragging == id, let start = dragStart else { return }
        let finalBox = boxes[id]
        dragging = nil
        dragStart = nil
        dragPointerStart = nil
        guideX = nil
        guideY = nil

        // 松手时如果还压在别的组件上：不允许保留重叠，
        // 整张卡弹回拖动前的原位置（SwiftUI 端用 snapBack 播弹簧动画）。
        if let f = finalBox, overlaps(f, excluding: id, padding: 0) {
            boxes[id] = start
            snapBack = id
            snapBackWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.snapBack = nil }
            snapBackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        let metrics = Self.centeredMetrics(for: boxes)
        originX = metrics.originX
        let maxB = boxes.values.map { $0.y + $0.h }.max() ?? Self.minH
        canvasW = min(Self.maxW, max(Self.minW, metrics.width))
        canvasH = min(Self.maxH, max(Self.minH, maxB))
        previewW = canvasW
        previewH = canvasH
        save()
        onDragGeometryChanged?()
    }

    /// 尺寸吸附：按 step 取整，避免面板抖动
    static func snap(_ v: Double, to step: Double) -> Double { (v / step).rounded() * step }

    // MARK: 缩放

    func beginResize(_ id: String) {
        guard boxes[id] != nil, dragging == nil else { return }
        resizing = id
        resizeStart = boxes[id]
        resizePointerStart = NSEvent.mouseLocation
        guideX = nil
        guideY = nil
        snapBackWork?.cancel()
        snapBackWork = nil
        snapBack = nil
    }

    func setHovered(_ id: String?) {
        guard hovered != id else { return }
        hovered = id
    }

    func setHandleHovered(_ id: String?) {
        guard hoveredHandle != id else { return }
        hoveredHandle = id
    }

    /// 从右下角拖拽缩放；第一次调用自动开始。
    func updateResize(_ id: String) {
        if resizing != id { beginResize(id) }
        guard resizing == id, let start = resizeStart, let p0 = resizePointerStart else { return }
        let now = NSEvent.mouseLocation
        var w = start.w + Double(now.x - p0.x)
        var h = start.h + Double(p0.y - now.y)   // AppKit y 向上，画布 y 向下
        if SettingsStore.shared.dragMode == .grid {
            w = Self.snap(w, to: 8)
            h = Self.snap(h, to: 8)
        }

        // 右边 / 底边吸附到其它组件的真实边（与拖动共用参考线）。
        let others = boxes.filter { $0.key != id }.map(\.value)
        let threshold: Double = 14
        var guideXValue: Double?
        var guideYValue: Double?

        let rightEdge = start.x + w
        var bestX: (distance: Double, edge: Double)?
        for b in others {
            for edge in [b.x, b.x + b.w] {
                let distance = abs(edge - rightEdge)
                guard distance <= threshold else { continue }
                if bestX == nil || distance < bestX!.distance { bestX = (distance, edge) }
            }
        }
        if let best = bestX {
            let candidate = best.edge - start.x
            if candidate >= 60, best.edge <= Self.maxW {
                w = candidate
                guideXValue = best.edge
            }
        }

        let bottomEdge = start.y + h
        var bestY: (distance: Double, edge: Double)?
        for b in others {
            for edge in [b.y, b.y + b.h] {
                let distance = abs(edge - bottomEdge)
                guard distance <= threshold else { continue }
                if bestY == nil || distance < bestY!.distance { bestY = (distance, edge) }
            }
        }
        if let best = bestY {
            let candidate = best.edge - start.y
            if candidate >= 44, best.edge <= Self.maxH {
                h = candidate
                guideYValue = best.edge
            }
        }

        let rightLimit = max(60, Self.maxW - max(0, start.x))
        let bottomLimit = max(44, Self.maxH - start.y)
        w = min(max(60, w), rightLimit)
        h = min(max(44, h), bottomLimit)
        // 吸附后又被边界钳制掉的情况：参考线不再成立。
        if let gx = guideXValue, abs(start.x + w - gx) > 0.5 { guideXValue = nil }
        if let gy = guideYValue, abs(start.y + h - gy) > 0.5 { guideYValue = nil }
        guideX = guideXValue
        guideY = guideYValue

        boxes[id] = Box(x: start.x, y: start.y, w: w, h: h)
        updatePreview()
        onDragGeometryChanged?()
    }

    func endResize(_ id: String) {
        guard resizing == id, let start = resizeStart else { return }
        let final = boxes[id]
        resizing = nil
        resizeStart = nil
        resizePointerStart = nil
        guideX = nil
        guideY = nil
        if let f = final, overlaps(f, excluding: id, padding: 0) {
            boxes[id] = start
            snapBack = id
            snapBackWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.snapBack = nil }
            snapBackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        applyLayoutChange()
    }

    /// 右键菜单的缩放档位。放大后压到邻居时保持原尺寸。
    func scale(_ id: String, by factor: Double) {
        guard var b = boxes[id] else { return }
        var w = min(max(60, b.w * factor), max(60, Self.maxW - max(0, b.x)))
        var h = min(max(44, b.h * factor), max(44, Self.maxH - b.y))
        if SettingsStore.shared.dragMode == .grid {
            w = max(60, Self.snap(w, to: 8))
            h = max(44, Self.snap(h, to: 8))
        }
        b.w = w
        b.h = h
        guard !overlaps(b, excluding: id, padding: 0) else { return }
        boxes[id] = b
        applyLayoutChange()
    }

    /// 恢复组件出厂尺寸（位置不动）。
    func resetSize(_ id: String) {
        guard var b = boxes[id] else { return }
        let fallback = Self.defaultBoxes[id] ?? Box(x: b.x, y: b.y, w: 172, h: 84)
        let size = WidgetRegistry.descriptor(for: id)?.defaultSize
        b.w = Double(size?.width ?? CGFloat(fallback.w))
        b.h = Double(size?.height ?? CGFloat(fallback.h))
        b.w = min(max(60, b.w), max(60, Self.maxW - max(0, b.x)))
        b.h = min(max(44, b.h), max(44, Self.maxH - b.y))
        guard !overlaps(b, excluding: id, padding: 0) else { return }
        boxes[id] = b
        applyLayoutChange()
    }

    private func updatePreview() {
        let metrics = Self.centeredMetrics(for: boxes)
        originX = metrics.originX
        let maxB = boxes.values.map { $0.y + $0.h }.max() ?? canvasH
        previewW = min(Self.maxW, max(Self.minW, metrics.width))
        previewH = min(Self.maxH, max(Self.minH, maxB > canvasH ? maxB + 10 : maxB))
    }

    private func applyLayoutChange() {
        let metrics = Self.centeredMetrics(for: boxes)
        originX = metrics.originX
        let maxB = boxes.values.map { $0.y + $0.h }.max() ?? Self.minH
        canvasW = min(Self.maxW, max(Self.minW, metrics.width))
        canvasH = min(Self.maxH, max(Self.minH, maxB))
        previewW = canvasW
        previewH = canvasH
        save()
        onDragGeometryChanged?()
    }

    /// 按 4 列网格（82pt 列宽 + 8pt 间距）一键整理：组件宽度吸到 1/2/3/4 列，逐行排布。
    func arrangeGrid() {
        let settings = SettingsStore.shared
        let visible = settings.widgetOrder.filter { settings.isEnabled($0) }
        let unit: Double = 82
        let gap: Double = 8
        let columns = 4
        let rowWidth = Double(columns) * unit + Double(columns - 1) * gap

        var layout = boxes
        var col = 0
        var y: Double = 0
        var rowH: Double = 0
        var maxB: Double = 0

        func flushRow() {
            guard rowH > 0 else { return }
            y += rowH + gap
            rowH = 0
            col = 0
        }

        for id in visible {
            guard var b = layout[id] else { continue }
            var span = Int(((b.w + gap) / (unit + gap)).rounded())
            span = min(max(span, 1), columns)
            if span == columns || col + span > columns { flushRow() }
            b.w = min(rowWidth, Double(span) * unit + Double(span - 1) * gap)
            b.x = Double(col) * (unit + gap)
            b.y = y
            layout[id] = b
            maxB = max(maxB, b.y + b.h)
            rowH = max(rowH, b.h)
            col += span
            if col >= columns { flushRow() }
        }

        layout = layout.mapValues { b in
            var b = b
            b.x = max(0, b.x)
            return b
        }
        boxes = layout
        applyLayoutChange()
    }

    /// 把组件收回画布可显示区域（老数据/换屏时用）
    private static func clampBox(_ b: Box) -> Box {
        var b = b
        b.x = max(-max(0, maxW - b.w), min(b.x, max(0, maxW - b.w)))
        b.y = max(0, min(b.y, max(0, maxH - b.h)))
        return b
    }

    /// 以默认中心线为轴，计算画布需要的对称宽度与原點偏移。
    /// 组件最左/最右离中心线多远，左右就各留多远。
    private static func centeredMetrics(for boxes: [String: Box]) -> (originX: Double, width: Double) {
        let minX = boxes.values.map(\.x).min() ?? 0
        let maxR = boxes.values.map { $0.x + $0.w }.max() ?? minW
        let half = max(minW / 2, abs(minX - baseCenter), abs(maxR - baseCenter))
        let width = min(maxW, max(minW, half * 2))
        return (-(half - baseCenter), width)
    }

    private struct MagnetResult {
        var box: Box
        var guideX: Double?
        var guideY: Double?
    }

    /// 候选框是否与其它组件重叠（受限模式的碰撞检测）
    private func overlaps(_ candidate: Box, excluding id: String, padding: Double = 0) -> Bool {
        for (k, b) in boxes where k != id {
            let hit = candidate.x < b.x + b.w + padding && b.x < candidate.x + candidate.w + padding
                   && candidate.y < b.y + b.h + padding && b.y < candidate.y + candidate.h + padding
            if hit { return true }
        }
        return false
    }

    private enum SnapAxis { case horizontal, vertical }

    /// 吸附规则：**只吸其它组件的真实边**——左对左、右对右、中线对中线。
    /// 画布边界（y=0 / x=0）不再作为候选：空白区域和「没放组件的上下边界」没有参照物，
    /// 吸上去只会让卡片飞到用户没想放的地方。要对齐顶行，顶行组件自己的 y=0 就是候选。
    /// 中线仍保留，但加 10pt 罚分。
    private func snapAxis(pos: Double, size: Double, others: [Box], axis: SnapAxis,
                          threshold: Double = 22) -> (delta: Double, line: Double?) {
        let starts: [Double]
        let ends: [Double]
        let mids: [Double]
        switch axis {
        case .horizontal:
            starts = others.map(\.x)
            ends = others.map { $0.x + $0.w }
            mids = others.map { $0.x + $0.w / 2 }
        case .vertical:
            starts = others.map(\.y)
            ends = others.map { $0.y + $0.h }
            mids = others.map { $0.y + $0.h / 2 }
        }

        var best: (score: Double, delta: Double, line: Double)?
        func consider(_ edge: Double, _ candidates: [Double], penalty: Double) {
            for c in candidates {
                let d = abs(c - edge)
                guard d <= threshold else { continue }
                let score = d + penalty
                if best == nil || score < best!.score {
                    best = (score, c - edge, c)
                }
            }
        }
        consider(pos, starts, penalty: 0)
        consider(pos + size, ends, penalty: 0)
        // 中线对齐保留为候选，但重罚：用户明确要的是「边缘对边缘」，
        // 罚分太小会让中线在边缘差 1~2pt 时抢先赢（实测 desired bottom 距 242 只差 12pt
        // 时被 213 中线抢走）。罚 18 = 边缘必须明显更远时中线才接管。
        consider(pos + size / 2, mids, penalty: 18)

        guard let b = best else { return (0, nil) }
        return (b.delta, b.line)
    }

    /// 邻近吸附：不要求边/中心线完全对齐，只要拖到邻居边缘 26pt 内，
    /// 就直接吸到「贴着邻居 + 8pt 间隙」的位置（8pt 是默认布局的行列间距）。
    /// 比单纯对齐线更有磁吸感。
    private func nearestAdjacent(_ start: Box, desiredX: Double, desiredY: Double,
                                 others: [Box], id: String,
                                 minX: Double, maxX: Double, maxY: Double)
        -> (box: Box, guideX: Double?, guideY: Double?)? {
        let range: Double = 26
        var best: Box?
        var bestGuideX: Double?
        var bestGuideY: Double?
        var bestDistance = Double.infinity
        for b in others {
            let candidates: [(Box, Double?, Double?)] = [
                (Box(x: b.x - start.w - 8, y: desiredY, w: start.w, h: start.h), b.x, nil),
                (Box(x: b.x + b.w + 8, y: desiredY, w: start.w, h: start.h), b.x + b.w, nil),
                (Box(x: desiredX, y: b.y - start.h - 8, w: start.w, h: start.h), nil, b.y),
                (Box(x: desiredX, y: b.y + b.h + 8, w: start.w, h: start.h), nil, b.y + b.h)
            ]
            for (box, gx, gy) in candidates {
                var a = box
                a.x = min(max(a.x, minX), maxX)
                a.y = min(max(a.y, 0), maxY)
                guard !overlaps(a, excluding: id, padding: 4) else { continue }
                let dx = a.x - desiredX
                let dy = a.y - desiredY
                let distance = dx * dx + dy * dy
                guard distance <= range * range, distance < bestDistance else { continue }
                bestDistance = distance
                best = a
                bestGuideX = gx
                bestGuideY = gy
            }
        }
        guard let box = best else { return nil }
        return (box, bestGuideX, bestGuideY)
    }

    /// 受限排列：以其它组件的真实边/中心线为磁吸候选。
    /// 核心原则：**拖动中允许临时重叠** —— 磁吸只发生在「吸附结果不压到任何组件」时；
    /// 一旦吸住的位置会重叠，就放弃吸附、让卡片 1:1 跟着指针走（穿过组件群是合法路径），
    /// 松手时若仍重叠，end() 会把卡片弹回拖动前的原位。
    /// 旧实现的「碰撞时搜索替代落位」会让卡片在拖动途中瞬移到别的空位——已删除。
    private func magneticBox(for start: Box, desiredX: Double, desiredY: Double,
                             id: String) -> MagnetResult {
        let maxX = max(0, Self.maxW - start.w)
        let minX = -maxX
        let maxY = max(0, Self.maxH - start.h)
        let others = boxes.filter { $0.key != id }.map(\.value)

        let sx = snapAxis(pos: desiredX, size: start.w, others: others, axis: .horizontal)
        let sy = snapAxis(pos: desiredY, size: start.h, others: others, axis: .vertical)

        let snappedX = min(max(desiredX + sx.delta, minX), maxX)
        let snappedY = min(max(desiredY + sy.delta, 0), maxY)
        let snapped = Box(x: snappedX, y: snappedY, w: start.w, h: start.h)

        if UserDefaults.standard.bool(forKey: "dragDebug") {
            let msg = "drag id=\(id) desired=(\(desiredX),\(desiredY)) snapX=\(sx.delta)/\(String(describing: sx.line)) snapY=\(sy.delta)/\(String(describing: sy.line)) snapped=\(snappedX),\(snappedY) overlap=\(overlaps(snapped, excluding: id, padding: 0))\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/macisland-drag.log") { h.seekToEndOfFile(); h.write(msg.data(using: .utf8)!); h.closeFile() }
            else { try? msg.write(toFile: "/tmp/macisland-drag.log", atomically: true, encoding: .utf8) }
        }

        // 吸附位置不重叠：落位。没吸到任何边时再试「贴着邻居 8pt」的邻近吸附，
        // 它的候选同样不允许重叠（贴邻的空位被占着就不吸，继续跟手）。
        if !overlaps(snapped, excluding: id, padding: 0) {
            if sx.line == nil, sy.line == nil,
               let adjacent = nearestAdjacent(start, desiredX: desiredX, desiredY: desiredY,
                                              others: others, id: id,
                                              minX: minX, maxX: maxX, maxY: maxY) {
                return MagnetResult(box: adjacent.box, guideX: adjacent.guideX, guideY: adjacent.guideY)
            }
            return MagnetResult(box: snapped, guideX: sx.line, guideY: sy.line)
        }

        // 吸附位置会重叠：拖动中允许临时重叠 —— 直接跟指针（不吸附、不跳位）。
        // 参考线不画：对齐提示只在真正能落位时出现。
        let raw = Box(x: min(max(desiredX, minX), maxX),
                      y: min(max(desiredY, 0), maxY),
                      w: start.w, h: start.h)
        return MagnetResult(box: raw, guideX: nil, guideY: nil)
    }

    /// 组件 `id` 当前是否与其它启用组件重叠（拖动中的冲突提示）。
    /// 对被拖的卡返回「压到别人了」，对别的卡返回「被压到了」。
    func inConflict(_ id: String) -> Bool {
        guard dragging != nil, let a = boxes[id] else { return false }
        for (k, b) in boxes where k != id {
            let hit = a.x < b.x + b.w && b.x < a.x + a.w
                   && a.y < b.y + b.h && b.y < a.y + a.h
            if hit { return true }
        }
        return false
    }

    /// 注册表变化后同步画布：移除已卸载插件的盒子，为新增插件卡片分配默认位置。
    /// 由 PluginManager.refreshRegistries() 在启用/禁用/安装/卸载后调用。
    func syncWidgets() {
        let descriptors = WidgetRegistry.descriptors
        let ids = Set(descriptors.map(\.id))
        var next = boxes.filter { ids.contains($0.key) }
        var maxBottom = next.values.map { $0.y + $0.h }.max() ?? 0
        var changed = next.count != boxes.count

        for d in descriptors where next[d.id] == nil {
            let size = d.defaultSize ?? CGSize(width: 172, height: 84)
            let b = Self.clampBox(Box(x: 0, y: maxBottom > 0 ? maxBottom + 8 : 0,
                                      w: Double(size.width), h: Double(size.height)))
            next[d.id] = b
            maxBottom = max(maxBottom, b.y + b.h)
            changed = true
        }
        guard changed else { return }

        boxes = next
        let metrics = Self.centeredMetrics(for: next)
        originX = metrics.originX
        canvasW = min(Self.maxW, max(Self.minW, metrics.width))
        let maxB = next.values.map { $0.y + $0.h }.max() ?? Self.minH
        canvasH = min(Self.maxH, max(Self.minH, maxB))
        previewW = canvasW
        previewH = canvasH
        save()
    }

    /// 按当前模块顺序把「已启用」的卡片紧凑地排成若干行，并把画布收到包围盒。
    /// 只在用户主动点「整理布局」或模块开关翻转时调用，不偷偷动自由摆位。
    func arrange() {
        let settings = SettingsStore.shared
        let visible = settings.widgetOrder.filter { settings.isEnabled($0) }
        var layout = boxes
        var x: Double = 0
        var y: Double = 0
        var rowH: Double = 0
        var maxB: Double = 0

        for id in visible {
            guard var b = layout[id] else { continue }
            if x > 0, x + b.w > Self.minW {
                x = 0
                y += rowH + 8
                rowH = 0
            }
            b.x = x
            b.y = y
            layout[id] = b
            maxB = max(maxB, b.y + b.h)
            x += b.w + 8
            rowH = max(rowH, b.h)
        }
        layout = layout.mapValues { b in
            var b = b
            b.x = max(0, b.x)
            return b
        }

        boxes = layout
        let metrics = Self.centeredMetrics(for: layout)
        originX = metrics.originX
        canvasW = metrics.width
        canvasH = min(max(Self.minH, maxB), Self.maxH)
        previewW = canvasW
        previewH = canvasH
        guideX = nil
        guideY = nil
        save()
    }

    func reset() {
        boxes = Self.defaultBoxes
        let metrics = Self.centeredMetrics(for: Self.defaultBoxes)
        originX = metrics.originX
        canvasW = metrics.width
        canvasH = Self.minH
        previewW = canvasW
        previewH = canvasH
        guideX = nil
        guideY = nil
        save()
        // 插件卡片没有出厂位置：恢复默认后按注册表顺序重新追加。
        syncWidgets()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(boxes) {
            d.set(data, forKey: "canvasBoxes")
        }
        d.set(canvasW, forKey: "canvasW")
        d.set(canvasH, forKey: "canvasH")
        d.set(originX, forKey: "canvasOriginX")
    }
}

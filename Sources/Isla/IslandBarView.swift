import AppKit

/// 状态栏里的「胶囊」。它由系统布局，物理上不可能覆盖其它菜单栏图标。
final class IslandBarView: NSView {

    struct CapsuleState: Equatable {
        var isPlaying = false
        var progress: Double = 0
        var text = ""
        var overlay: String? = nil
        /// 歌词模式：当前句 + 这句内的进度（0…1），用于滚动 / 逐字
        var lyric = ""
        var lyricProgress: Double = 0
        var lyricActive = false
        /// 当前曲目标识：字号只按「一首歌」降一次，不同句之间不再忽大忽小
        var lyricKey = ""
        /// 波形竖杠是否律动：抖音等短视频切换间隙 advancing 短暂翻 false，
        /// 控制器用「最近 3s 确认过在播」保持律动，避免竖杠频繁停住。
        var waveAnimated = false
        /// 当前文字是歌曲标题（歌词模式无歌词时的回退）：
        /// 用歌词字体字号显示、超宽跑马灯滚动，与「加宽」态观感一致。
        var titleMode = false
    }

    var onHoverChange: ((Bool) -> Void)?
    /// 左键点击胶囊：展开/收起面板（不再顺带钉住，钉住只由菜单触发）
    var onClick: (() -> Void)?
    var onVolumeScroll: ((Float) -> Void)?
    /// 文件拖到胶囊上
    var onFilesDropped: (([URL]) -> Void)?

    private var dropHighlighted = false { didSet { applyVisualHover() } }

    var state = CapsuleState() { didSet { needsDisplay = true } }

    private var tracking: NSTrackingArea?
    /// 指针真实悬停状态（pulse 期间可能与视觉状态不一致，分开记）
    private var pointerHovering = false
    /// 面板展开时的联动「跳一下」
    private var pulsing = false
    /// 视觉驱动值：指针悬停 ∪ pulse ∪ 文件拖入高亮
    private var hovered = false { didSet { animateHover() } }
    private func applyVisualHover() {
        let visual = pointerHovering || pulsing || dropHighlighted
        guard hovered != visual else { return }
        hovered = visual
    }
    /// 0...1 的悬停进度：胶囊拉伸/收窄，用欠阻尼弹簧过渡（Q 弹）。
    private var hoverProgress: CGFloat = 0
    private var hoverTimer: Timer?
    /// 当前歌曲的歌词字号（只降不升，避免换句时字号跳动；基准值来自设置）
    private var fittedLyricSize: CGFloat = 10.5
    private var lyricFontKey = ""
    private var lyricBaseSize: CGFloat = 0

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        titleScrollTimer?.invalidate()
        titleScrollTimer = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 外部正在拖动胶囊：忽略悬停进出。
    /// 拖动时窗口从指针底下滑过，会连续触发 mouseEntered/Exited，
    /// 胶囊一边移动一边做悬停动画 —— 屏幕上就会留下两个半透明的「鬼影」。
    var isDraggingExternal = false

    override func mouseEntered(with event: NSEvent) {
        guard !isDraggingExternal else { return }
        pointerHovering = true
        applyVisualHover()
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDraggingExternal else { return }
        pointerHovering = false
        applyVisualHover()
        onHoverChange?(false)
    }

    /// 面板从胶囊里长出来的瞬间，胶囊自己也「跳一下」—— 两个界面之间的联动。
    /// 只改视觉状态，不碰 pointerHovering；0.26s 后按真实指针状态归位。
    func pulse() {
        pulsing = true
        applyVisualHover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self else { return }
            self.pulsing = false
            self.applyVisualHover()
        }
    }

    /// 欠阻尼弹簧（ζ=0.55, ω=11）：展开会冲过目标约 13% 再弹回，
    /// 收起会先缩过头再回来 —— 比 easeOutBack 的单次 overshoot 更「Q 弹」。
    private func springEase(_ p: CGFloat) -> CGFloat {
        let zeta: CGFloat = 0.55
        let omega: CGFloat = 11.0
        let a = zeta * omega
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-a * p) * (cos(wd * p) + (a / wd) * sin(wd * p))
    }

    /// 悬停进度按 1/60s 缓动；弹簧 0.5s 内收敛，之后不占计时器。
    private func animateHover() {
        hoverTimer?.invalidate()
        let target: CGFloat = hovered ? 1 : 0
        let start = hoverProgress
        guard abs(target - start) > 0.001 else { needsDisplay = true; return }
        let startedAt = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            let elapsed = CGFloat(Date().timeIntervalSince(startedAt))
            let p = min(1, elapsed / 0.5)
            let eased = self.springEase(p)
            var v = start + (target - start) * eased
            // 弹簧的欠冲/过冲允许小幅越界，但不许失控
            v = max(-0.2, min(1.2, v))
            self.hoverProgress = p >= 1 ? target : v
            self.needsDisplay = true
            if p >= 1 {
                t.invalidate()
                self.hoverTimer = nil
            }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 拖动请求交给控制器决定怎么处理：
    /// 菜单栏胶囊形态 → 直接左右拖；居中垂帘形态贴状态项槽位、不响应拖动。
    /// 返回 true 表示这次按下已被处理。
    var onDragRequest: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let isCommand = event.modifierFlags.contains(.command)
        if let handler = onDragRequest, handler(event) { return }
        // 状态项自己的视图（透明占位）：⌘ 按下交给 AppKit，保留系统原生行为。
        // 普通点击才是展开面板。
        if isCommand {
            super.mouseDown(with: event)
            return
        }
        onClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let delta = Float(event.scrollingDeltaY) * 0.018
        AudioService.shared.adjust(by: delta)
        onVolumeScroll?(AudioService.shared.volume)
    }

    // MARK: - 接收文件拖放

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        dropHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        dropHighlighted = false
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let st = SettingsStore.shared
        let attached = st.islandStyle == .attached
        // 悬停反馈：胶囊在窗口余量内向下拉伸（attached），或上下对称膨胀（悬浮样式）。
        // 弹簧的过冲/欠冲会短暂越过 0…1，钳在 [-0.2, 1.2]。
        let baseH = min(CGFloat(st.capsuleHeight), bounds.height)
        let v = max(-0.2, min(1.2, hoverProgress))
        let h = max(16, min(baseH + (bounds.height - baseH) * v, bounds.height))
        let insetX = 2.5 * (1 - max(0, v))
        // 歌词「加宽」模式：窗口本身就是加宽后的宽度，主体要铺满窗口
        // （贴边只留两侧肩弧的余量，悬浮留一点 hover 的 2.5pt 呼吸）。
        // 这里不能只看 attached：悬浮样式下窗口变宽了、画出来的胶囊却还是原宽，
        // 视觉上就只剩「胶囊往左挪了一下」，这正是用户看到的「只移动、不加宽」。
        let widenLyrics = st.capsuleContent == .lyrics && st.lyricsLayout == .widen
        let bodyW = widenLyrics
            ? max(40, bounds.width - (attached ? CGFloat(st.attachedShoulder.extend) * 2 : insetX))
            : min(max(CGFloat(st.capsuleWidth) - insetX, 20), bounds.width)
        let bodyRect = attached
            ? NSRect(x: (bounds.width - bodyW) / 2, y: bounds.height - h, width: bodyW, height: h)
            : NSRect(x: (bounds.width - bodyW) / 2, y: (bounds.height - h) / 2, width: bodyW, height: h)

        let shoulder = attached ? min(CGFloat(st.attachedShoulder.extend),
                                      max(0, (bounds.width - bodyW) / 2)) : 0
        let path = attached
            ? Self.attachedPath(body: bodyRect, extend: shoulder,
                                depth: CGFloat(st.attachedShoulder.depth), in: bounds)
            : NSBezierPath(roundedRect: bodyRect,
                           xRadius: min(h / 2, bodyW / 2), yRadius: min(h / 2, bodyW / 2))
        if UserDefaults.standard.bool(forKey: "drawDebug") {
            let msg = "draw bounds=\(bounds.width)x\(bounds.height) bodyW=\(bodyW) content=\(st.capsuleContent.rawValue) layout=\(st.lyricsLayout.rawValue) attached=\(attached)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/macisland-draw.log") { h.seekToEndOfFile(); h.write(msg.data(using: .utf8)!); h.closeFile() }
            else { try? msg.write(toFile: "/tmp/macisland-draw.log", atomically: true, encoding: .utf8) }
        }
        // 深色主题：近黑填充；浅色主题：纸白填充。悬停时各自向「更亮/更暗」微调。
        // 必须不透明：半透明底会让上一帧的歌词透出来（残影闪一下）。
        let darkUI = Theme.isDarkUI
        let fillColor = darkUI
            ? NSColor(calibratedWhite: 0.015 + 0.03 * max(0, v), alpha: 1)
            : NSColor(calibratedWhite: 0.975 - 0.03 * max(0, v), alpha: 1)
        fillColor.setFill()
        path.fill()
        if attached {
            // 贴边形态的保底：路径顶边与窗口顶边重合，但窗口落位若有半像素取整差，
            // 顶行就会露出菜单栏底色（用户看到的就是「顶部 1~2px 缝」）。
            // 直接把顶行整行刷成填充色，保证与屏幕顶边完全贴合。
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
        // 描边：贴边形态只描「看得见的边」（侧边 + 下沿圆角 + 肩弧）。
        // 之前的整圈描边会在顶边压一条 0.5pt 的白线，加上顶部内侧高光，
        // 第一行像素被洗成 0.23 亮度（填充只有 0.02）——看起来就像胶囊和屏幕顶边之间有缝。
        let strokePath = attached
            ? Self.attachedOutlinePath(body: bodyRect, extend: shoulder,
                                       depth: CGFloat(st.attachedShoulder.depth), in: bounds)
            : path
        if dropHighlighted {
            SettingsStore.shared.accentTheme.nsColor.withAlphaComponent(0.95).setStroke()
            strokePath.lineWidth = 1.4
        } else {
            darkUI
                ? NSColor(calibratedWhite: 1, alpha: 0.26 + 0.12 * max(0, v)).setStroke()
                : NSColor(calibratedWhite: 0, alpha: 0.30 + 0.10 * max(0, v)).setStroke()
            strokePath.lineWidth = 1.0
        }
        strokePath.stroke()

        // 顶部内侧高光：一条 1pt 的淡白线，给胶囊一点「玻璃厚度」。
        // 贴边形态跳过——高光贴着屏幕顶边画，正是「顶缝」观感的另一半来源。
        if !attached {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor(calibratedWhite: 1, alpha: 0.10 + 0.06 * max(0, v)).setFill()
            NSRect(x: bodyRect.minX, y: bodyRect.maxY - 1.2, width: bodyRect.width, height: 1.2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        probeTick()
        if state.lyricActive, bodyW >= 44 {
            drawLyric(in: bodyRect, wide: SettingsStore.shared.lyricsLayout == .widen)
        } else {
            drawBars(in: bodyRect)
            if bodyW >= 52 {
                drawText(in: bodyRect)
            }
            if state.isPlaying, state.progress > 0, bodyW >= 52 {
                drawProgress(in: bodyRect)
            }
        }
    }

    /// 贴边形态：胶囊顶住屏幕上沿，两侧按档位做肩弧。
    /// 圆弧用二次贝塞尔（= 抛物线的一段），控制点落在「胶囊侧边 × 屏幕顶边」的角点上，
    /// 所以上端与顶边水平相切、下端与侧边垂直相切。
    /// extend = 0 时退化为 MacBook 刘海那种直角顶边（只圆下沿）。
    private static func attachedPath(body r: NSRect, extend: CGFloat, depth: CGFloat,
                                     in bounds: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let top = bounds.maxY
        let bottomRadius = min(r.height / 2, r.width / 2)
        // 肩弧不能把侧边吃光：至少留 3pt 直线
        let depth = max(0, min(depth, r.height - bottomRadius - 3))
        let straight = extend <= 0.5 || depth <= 0.5

        p.move(to: NSPoint(x: bounds.minX, y: top))
        p.line(to: NSPoint(x: bounds.maxX, y: top))
        if straight {
            p.line(to: NSPoint(x: r.maxX, y: r.minY + bottomRadius))
        } else {
            p.curve(to: NSPoint(x: r.maxX, y: top - depth),
                    controlPoint1: NSPoint(x: r.maxX, y: top),
                    controlPoint2: NSPoint(x: r.maxX, y: top))
        }
        p.line(to: NSPoint(x: r.maxX, y: r.minY + bottomRadius))
        p.appendArc(withCenter: NSPoint(x: r.maxX - bottomRadius, y: r.minY + bottomRadius),
                    radius: bottomRadius, startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: r.minX + bottomRadius, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.minX + bottomRadius, y: r.minY + bottomRadius),
                    radius: bottomRadius, startAngle: 270, endAngle: 180, clockwise: true)
        if straight {
            p.line(to: NSPoint(x: r.minX, y: top))
        } else {
            p.line(to: NSPoint(x: r.minX, y: top - depth))
            p.curve(to: NSPoint(x: bounds.minX, y: top),
                    controlPoint1: NSPoint(x: r.minX, y: top),
                    controlPoint2: NSPoint(x: r.minX, y: top))
        }
        p.close()
        return p
    }

    /// 贴边形态的**描边**路径：与 attachedPath 同几何，但不画顶边、不闭合。
    /// 顶边就是屏幕物理上沿，那里描一条白线只会被读成「胶囊和顶边之间有条缝」。
    private static func attachedOutlinePath(body r: NSRect, extend: CGFloat, depth: CGFloat,
                                            in bounds: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let top = bounds.maxY
        let bottomRadius = min(r.height / 2, r.width / 2)
        let depth = max(0, min(depth, r.height - bottomRadius - 3))
        let straight = extend <= 0.5 || depth <= 0.5

        if straight {
            p.move(to: NSPoint(x: r.maxX, y: top))
        } else {
            p.move(to: NSPoint(x: bounds.maxX, y: top))
            p.curve(to: NSPoint(x: r.maxX, y: top - depth),
                    controlPoint1: NSPoint(x: r.maxX, y: top),
                    controlPoint2: NSPoint(x: r.maxX, y: top))
        }
        p.line(to: NSPoint(x: r.maxX, y: r.minY + bottomRadius))
        p.appendArc(withCenter: NSPoint(x: r.maxX - bottomRadius, y: r.minY + bottomRadius),
                    radius: bottomRadius, startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: r.minX + bottomRadius, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.minX + bottomRadius, y: r.minY + bottomRadius),
                    radius: bottomRadius, startAngle: 270, endAngle: 180, clockwise: true)
        if straight {
            p.line(to: NSPoint(x: r.minX, y: top))
        } else {
            p.line(to: NSPoint(x: r.minX, y: top - depth))
            p.curve(to: NSPoint(x: bounds.minX, y: top),
                    controlPoint1: NSPoint(x: r.minX, y: top),
                    controlPoint2: NSPoint(x: r.minX, y: top))
        }
        return p
    }

    /// 歌词：单行（超宽沿进度滚）/ 逐字（按进度揭示）。
    /// 加宽模式只是窗口更宽，绘制逻辑复用单行。
    private func drawLyric(in rect: NSRect, wide: Bool) {
        if Self.fpsProbe { probeLyricFrames += 1 }
        let layout = SettingsStore.shared.lyricsLayout
        var text = state.lyric
        if layout == .typewriter {
            let n = max(1, Int((Double(text.count) * min(1, max(0, state.lyricProgress))).rounded()))
            text = String(text.prefix(n))
        }
        guard !text.isEmpty else { return }

        let scale = CGFloat(SettingsStore.shared.uiFontScale)
        let inset: CGFloat = 9
        let avail = rect.width - inset * 2
        guard avail > 8 else { return }
        let color = Theme.isDarkUI
            ? NSColor(srgbRed: 0.55, green: 0.93, blue: 0.78, alpha: 0.96)          // 薄荷（黑底）
            : NSColor(srgbRed: 0.02, green: 0.42, blue: 0.28, alpha: 0.96)          // 深苔绿（白底）
        func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: size * scale, weight: .semibold), .foregroundColor: color]
        }
        // 字号按「一首歌」收敛：新歌从设置里的基准字号起步，遇到放不下的长句就降一档，
        // 之后整首歌都用这一档。用户在设置里改字号时立即按新基准重排。
        let base = CGFloat(SettingsStore.shared.lyricFontSize)
        if state.lyricKey != lyricFontKey || abs(base - lyricBaseSize) > 0.01 {
            lyricFontKey = state.lyricKey
            lyricBaseSize = base
            fittedLyricSize = base
        }
        var fontSize = min(base, fittedLyricSize)
        var a = attrs(fontSize)
        var size = measuredSize(text, fontSize: fontSize, font: a[.font] as! NSFont,
                                cache: &lyricMeasureCache)
        // 只有「当前矩形确实是加宽后的宽度」才允许收缩字号。
        // 恢复播放瞬间 applyForm 异步滞后一拍，首帧仍按 120pt 窄窗口绘制：
        // 旧判定只看 lyricsLayout 设置值，会在窄矩形里把长句缩到 65% 下限并整首沿用，
        // 用户看到的就是「暂停后恢复播放，歌词变小；切歌才恢复」。
        // 判据 rect.width ≥ 基准宽 × 加宽倍数 − 8：窄矩形（≈基准宽）恒为假，
        // 贴边/悬浮两种形态加宽后的矩形（≈基准宽 × 倍数 ± 肩弧）恒为真。
        let widenRectTarget = CGFloat(SettingsStore.shared.capsuleWidth)
            * CGFloat(SettingsStore.shared.lyricWidenFactor)
        let widenedNow = rect.width >= widenRectTarget - 8
        if layout == .widen, widenedNow, size.width > avail {
            let floorSize = max(6.5, base * 0.65)
            while size.width > avail, fontSize > floorSize {
                fontSize -= 0.5
                a = attrs(fontSize)
                size = measuredSize(text, fontSize: fontSize, font: a[.font] as! NSFont,
                                    cache: &lyricMeasureCache)
            }
            fittedLyricSize = fontSize
        }
        let str = text as NSString

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        clip.addClip()

        // 加宽模式：整句居中（胶囊宽度在一首歌里是固定的，不会左右跳）；
        // 单行/逐字模式：左对齐，超长按进度横向滚动 —— 窄胶囊里居中会让短句乱飘。
        var x = rect.minX + inset
        if wide, size.width <= avail {
            x = rect.midX - size.width / 2
        } else if layout == .typewriter, size.width > avail {
            // 长句逐字：揭示前沿贴右缘、整句向左推进（字幕机式），
            // 全部揭示完停在结尾——旧实现不滚动，长句后半段永远看不到
            x = rect.minX + inset - (size.width - avail)
        } else if layout != .typewriter, size.width > avail {
            let overflow = size.width - avail
            x = rect.minX + inset - overflow * CGFloat(min(1, max(0, state.lyricProgress)))
        }
        str.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2), withAttributes: a)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBars(in rect: NSRect) {
        let midY = rect.midY
        let barW: CGFloat = 2.2
        var bx = rect.minX + 8
        let t = Date().timeIntervalSinceReferenceDate

        for i in 0..<3 {
            var bh: CGFloat
            if state.isPlaying || state.waveAnimated {
                // 用时间做相位，控制器以 ~10Hz 触发重绘
                let phase = t * 7.0 + Double(i) * 2.1
                bh = 4 + CGFloat((sin(phase) + 1) / 2) * 9
            } else {
                bh = [4.0, 7.0, 5.0][i]
            }
            let alpha: CGFloat = state.isPlaying ? 0.95 : 0.32
            let barColor = SettingsStore.shared.accentTheme.nsColor
            (Theme.isDarkUI ? barColor : barColor.blended(withFraction: 0.35, of: .black)?.withAlphaComponent(1) ?? barColor)
                .withAlphaComponent(alpha).setFill()
            let r = NSRect(x: bx, y: midY - bh / 2, width: barW, height: bh)
            NSBezierPath(roundedRect: r, xRadius: 1.1, yRadius: 1.1).fill()
            bx += barW + 2.2
        }
    }

    private func drawText(in rect: NSRect) {
        let text = (state.overlay ?? state.text) as NSString
        guard text.length > 0 else { return }
        let isTitle = state.overlay == nil && state.titleMode
        // 波形条实际占 8 + 3×4.4 ≈ 21pt；之前按 26 预留，标题被多挤掉几 pt，
        // 明明放得下却开始滚动。
        let maxW = rect.width - 8 - 21.5
        guard maxW > 8 else { return }
        func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: isTitle
                ? NSFont.systemFont(ofSize: size, weight: .semibold)          // 与歌词同字体
                : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
             .foregroundColor: Theme.isDarkUI
                 ? NSColor(calibratedWhite: 0.96, alpha: state.overlay == nil ? 0.95 : 1.0)
                 : NSColor(calibratedWhite: 0.08, alpha: state.overlay == nil ? 0.90 : 1.0)]
        }
        // 标题字号取「加宽」歌词的基准字号（lyricFontSize × 全局缩放），
        // 用户反馈暂停态歌名偏小（2026-11-20）；时钟/overlay 维持等宽数字字体。
        let base: CGFloat = isTitle
            ? CGFloat(SettingsStore.shared.lyricFontSize) * CGFloat(SettingsStore.shared.uiFontScale)
            : 11 * CGFloat(SettingsStore.shared.uiFontScale)
        var fontSize = base
        var size = measuredSize(text as String, fontSize: fontSize,
                                font: attrs(fontSize)[.font] as! NSFont,
                                cache: &titleMeasureCache)
        var scroll = false
        var drawText = text
        if isTitle {
            // 超宽歌名跑马灯往返滚动，完整可读；不缩字号、不截断
            scroll = size.width > maxW
        } else {
            // 时钟/overlay：缩字号兜底，仍超宽才截断（几乎不触发）
            while size.width > maxW, fontSize > 8.5 {
                fontSize -= 0.5
                size = measuredSize(text as String, fontSize: fontSize,
                                    font: attrs(fontSize)[.font] as! NSFont,
                                    cache: &titleMeasureCache)
            }
            var s = text as String
            while size.width > maxW, s.count > 1 {
                s.removeLast()
                drawText = (s + "…") as NSString
                size = drawText.size(withAttributes: attrs(fontSize))
                if size.width <= maxW { break }
            }
        }
        // 「看起来放得下」就先缩字号，而不是直接开始滚动：
        // 静态可读的标题比来回滚动舒服。缩到下限还放不下才滚动。
        if isTitle, size.width > maxW {
            let floor = max(10, base * 0.75)
            while size.width > maxW, fontSize > floor {
                fontSize -= 0.5
                size = measuredSize(text as String, fontSize: fontSize,
                                    font: attrs(fontSize)[.font] as! NSFont,
                                    cache: &titleMeasureCache)
            }
        }
        var x = rect.maxX - 8 - min(size.width, maxW)
        // 文字没变就不重置滚动位置：胶囊在悬停 / 缩回时宽度会变，
        // 旧实现用「绝对时间 % 周期」，周期一变相位就乱跳（表现为反复从开头滚）。
        let textKey = text as String
        if scrollTextKey != textKey {
            scrollTextKey = textKey
            let now = ProcessInfo.processInfo.systemUptime
            // 面板开合 / 视图重建会让同一个标题重新走一次绘制：
            // 2 分钟内同一段文字从上次位置继续，不要从开头重来。
            if let mem = Self.scrollMemory[textKey], now - mem.at < 120 {
                scrollOffset = mem.offset
                scrollForward = mem.forward
            } else {
                scrollOffset = 0
                scrollForward = true
            }
            scrollHoldUntil = 0
            scrollLastTick = nil
        }
        if scroll {
            let overflow = max(0, size.width - maxW)
            let now = ProcessInfo.processInfo.systemUptime
            if let last = scrollLastTick {
                let dt = min(0.2, max(0, now - last))
                if now >= scrollHoldUntil {
                    var next = scrollOffset + CGFloat(dt) * Self.titleScrollSpeed * (scrollForward ? 1 : -1)
                    if next >= overflow {
                        next = overflow
                        scrollForward = false
                        scrollHoldUntil = now + Self.titleScrollPause
                    } else if next <= 0 {
                        next = 0
                        scrollForward = true
                        scrollHoldUntil = now + Self.titleScrollPause
                    }
                    scrollOffset = min(max(0, next), overflow)
                }
            }
            scrollLastTick = now
            Self.rememberScroll(key: textKey, offset: scrollOffset, forward: scrollForward, at: now)
            x = rect.minX + 8 - min(scrollOffset, overflow)
        } else {
            // 暂停计时但不重置：加宽后文字合拢、再缩回时从原位继续
            scrollLastTick = nil
        }
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        drawText.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attrs(fontSize))
        NSGraphicsContext.restoreGraphicsState()
        syncTitleScroll(active: scroll && window?.isVisible == true)
    }

    /// 文本测量缓存：同一段文字 + 同一字号的结果复用。
    /// 60fps 下每帧重排一次长歌词是纯浪费（字号/文字不变时结果也不变）。
    private var titleMeasureCache: (text: String, fontSize: CGFloat, size: NSSize)?
    private var lyricMeasureCache: (text: String, fontSize: CGFloat, size: NSSize)?

    /// 字号也会变（长句自动降档），所以 key 必须带上字号。
    private func measuredSize(_ text: String, fontSize: CGFloat, font: NSFont,
                              cache: inout (text: String, fontSize: CGFloat, size: NSSize)?) -> NSSize {
        if let c = cache, c.text == text, abs(c.fontSize - fontSize) < 0.01 { return c.size }
        let s = (text as NSString).size(withAttributes: [.font: font])
        cache = (text, fontSize, s)
        return s
    }

    /// 帧率探针：`Isla --fps-probe` 时每秒打印一次实际重绘/歌词重绘次数。
    private static let fpsProbe = CommandLine.arguments.contains("--fps-probe")
    private var probeFrames = 0
    private var probeLyricFrames = 0
    private var probeStart = Date()
    private var probeStarted = false

    private func probeTick() {
        guard Self.fpsProbe else { return }
        if !probeStarted {
            probeStarted = true
            let msg = "fps-probe enabled\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/isla-fps.log") {
                h.seekToEndOfFile(); h.write(Data(msg.utf8)); h.closeFile()
            } else {
                try? msg.write(toFile: "/tmp/isla-fps.log", atomically: true, encoding: .utf8)
            }
        }
        if probeFrames == 0, probeStart.timeIntervalSinceNow < -1 {
            FileHandle.standardError.write(Data("fps-probe first-draw\n".utf8))
        }
        probeFrames += 1
        let now = Date()
        if now.timeIntervalSince(probeStart) >= 1 {
            // 写文件：stdout 被 launchd 吞掉、stderr 也进不了日志，落到文件最省事
            let line = "fps-probe total=\(probeFrames) lyric=\(probeLyricFrames)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/isla-fps.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            } else {
                try? line.write(toFile: "/tmp/isla-fps.log", atomically: true, encoding: .utf8)
            }
            probeFrames = 0
            probeLyricFrames = 0
            probeStart = now
        }
    }

    /// 超宽标题的滚动位置（pt，而不是时间相位）：宽度变化时只 clamp，不重头开始。
    private static let titleScrollSpeed: CGFloat = 30   // pt/s
    private static let titleScrollPause: TimeInterval = 0.8
    private var scrollOffset: CGFloat = 0
    private var scrollForward = true
    private var scrollHoldUntil: TimeInterval = 0
    private var scrollTextKey: String?
    private var scrollLastTick: TimeInterval?

    private struct ScrollMemory { var offset: CGFloat; var forward: Bool; var at: TimeInterval }
    private static var scrollMemory: [String: ScrollMemory] = [:]

    private static func rememberScroll(key: String, offset: CGFloat, forward: Bool, at: TimeInterval) {
        if scrollMemory.count > 24 { scrollMemory.removeAll() }
        scrollMemory[key] = ScrollMemory(offset: offset, forward: forward, at: at)
    }

    /// 超宽标题滚动用的重绘驱动：只在滚动激活时存在，view 释放即停。
    private var titleScrollTimer: Timer?
    private var titleScrollInterval: TimeInterval?
    private func syncTitleScroll(active: Bool) {
        let interval = 1.0 / Double(max(1, SettingsStore.shared.scrollFPS))
        if active {
            if titleScrollTimer == nil || abs((titleScrollInterval ?? 0) - interval) > 0.0001 {
                titleScrollTimer?.invalidate()
                let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    self?.needsDisplay = true
                }
                RunLoop.main.add(t, forMode: .common)
                titleScrollTimer = t
                titleScrollInterval = interval
            }
        } else if titleScrollTimer != nil {
            titleScrollTimer?.invalidate()
            titleScrollTimer = nil
            titleScrollInterval = nil
        }
    }

    private func drawProgress(in rect: NSRect) {
        let inset: CGFloat = 8
        let track = NSRect(x: rect.minX + inset, y: rect.minY + 3.5,
                           width: rect.width - inset * 2, height: 1.5)
        Theme.isDarkUI
            ? NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
            : NSColor(calibratedWhite: 0, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 0.75, yRadius: 0.75).fill()

        let done = NSRect(x: track.minX, y: track.minY,
                          width: track.width * CGFloat(min(1, max(0, state.progress))),
                          height: track.height)
        SettingsStore.shared.accentTheme.nsColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: done, xRadius: 0.75, yRadius: 0.75).fill()
    }
}

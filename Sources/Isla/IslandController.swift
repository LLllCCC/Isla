import AppKit
import SwiftUI
import Combine

/// 面板不是 key window 时，第一次点击只负责激活窗口，SwiftUI 控件会吞掉这次点击。
/// 让 hosting view 接受 first mouse，用户从别的 App 移过来就能一次点中页签/拖动卡片。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandController: NSObject {

    private let settings = SettingsStore.shared
    private let store = IslandStore.shared
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 92)
    private let barView = IslandBarView(frame: NSRect(x: 0, y: 0, width: 92, height: 24))
    private let panel = IslandPanel()
    private let background = PanelBackgroundView(frame: .zero)
    private let panelHost = FirstMouseHostingView(rootView: PanelContent())
    /// 由 SwiftUI 内容实测得到的理想高度；面板高度跟着内容走，不留死白。
    private var contentHeight: CGFloat = IslandMetrics.panelMinHeight
    private var contentWidth: CGFloat = IslandMetrics.panelWidth
    private var canvasSink: AnyCancellable?
    /// 两个形态共用的浮层胶囊：居中垂帘盖在透明状态项槽位上，菜单栏胶囊浮在任意位置。
    private var floatingCapsule: NSPanel?
    private var floatingBar: IslandBarView?

    private var railPanel: RailPanel?
    private var railView: RailView?
    private var settingsWindow: SettingsWindowController?

    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var hoverPoll: Timer?
    private var menuPoll: Timer?
    private var waveTimer: Timer?
    private var storeSink: AnyCancellable?
    private var pageSink: AnyCancellable?
    private var clipSink: AnyCancellable?
    private var capsuleSink: AnyCancellable?
    private var pluginMenuSink: AnyCancellable?
    private var shelfSink: AnyCancellable?
    private let hotkey = HotkeyService()
    private var volumeOverlayUntil: Date?
    /// 阶段结束时的临时文字（优先级高于音量与倒计时）
    private var notice: String?
    private var noticeUntil: Date?
    /// 面板可见期间的「点外部 / Esc 收起」监听；收起即移除，不常驻
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// 程序化移动面板时不要记录偏移，否则会把动画中间帧当成用户拖动
    private var programmaticMove = false
    private var moveObserver: Any?
    /// 用全局鼠标移动兜底：NSTrackingArea 在菜单栏重排后偶尔不再触发，
    /// 这里按「指针是否落在胶囊矩形内」自己判定，避免悬停时灵时不灵。
    private var mouseMonitor: Any?
    /// 面板内的滚轮仲裁：插件页的 ScrollView / WKWebView 会吃掉滚轮，
    /// 需要判断「内容已到顶/到底」后把这一下转给翻页。
    private var scrollMonitor: Any?
    private var pointerInsideBar = false
    /// 自动缩回顶边：空闲时胶囊窗口被推到屏幕上方，只留 capsulePeek 高度可见
    private var capsuleRetracted = false
    private var capsuleRetractWork: DispatchWorkItem?
    private var capsuleAnimating = false
    /// 缩回后轮询指针：光标停在屏幕最上沿时系统不一定发 mouseMoved，靠它兜底
    private var revealTimer: Timer?
    /// 歌词当前是否真的显示（决定加宽宽度）
    private var lyricVisible = false
    /// 缩回要等一下：换行/换歌的空档不想看到胶囊来回抽动
    private var widenOffWork: DispatchWorkItem?
    /// 开始播放的时刻：加宽给 4 秒宽限，歌词没到就缩回去（例如放视频时）
    private var advancingSince: Date?
    private var scrollAccum: CGFloat = 0
    private var lastScrollAt = Date.distantPast
    private var lastScrollDir: CGFloat = 0
    private var gestureTurned = false
    /// 上一轮状态（只用于 playdebug 日志）
    private var lastLoggedAdvancing: Bool?
    private var lastLoggedWiden: Bool?

    private var pinned = false
    private var menuBarItem: NSStatusItem?
    private var lastMenuBarHidden: Bool?
    /// 画布更新在同一轮 runloop 内合并：拖动时 @Published 会连续发好几次，
    /// 每发一次都改窗口 frame 会自己跟自己打架。
    private var canvasUpdateScheduled = false
    /// 只有「媒体开关」真的翻转才重启轮询；否则拖个滑杆也会反复 spawn osascript。
    private var lastMediaEnabled = SettingsStore.shared.mediaEnabled
    /// 切 App 触发的补拉节流
    private var lastActivationBurstAt = Date.distantPast
    /// 上一次的模块开关组合；翻转时自动整理画布（避免隐藏后留下大片空白/裁切）。
    private var lastModuleSignature = ""
    /// 设置变更统一防抖：滑杆拖动期间不要每次都 applyForm + show。
    private var settingsWork: DispatchWorkItem?
    /// 居中避让的 AX 扫描节流（10s 一次，够跟上状态项增减，也不抢 CPU）。
    private var lastMenuBarScanAt = Date.distantPast

    override init() {
        super.init()
        setupStatusItem()
        setupMenuBarIcon()
        setupPanel()
        lastModuleSignature = moduleSignature()
        applyForm()
        bindStore()
        let ok = hotkey.register { [weak self] in self?.toggleFromHotkey() }
        NSLog("Isla hotkey ⌥⌘Space registered: \(ok)")

        PomodoroService.shared.onPhaseComplete = { [weak self] phase in
            self?.flashCapsule(phase == .work ? L("专注完成") : L("休息结束"))
        }
        if UserDefaults.standard.bool(forKey: "pomodoroAuto") {
            PomodoroService.shared.start()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .islandSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarScanUpdated),
                                               name: .islandMenuBarScanUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // 指针跨屏切岛（或指定屏被拔掉）时，重排面板/胶囊
        NotificationCenter.default.addObserver(self, selector: #selector(activeScreenChanged),
                                               name: .islandActiveScreenChanged, object: nil)
        // 用户切到某个 App（多半是播放器）：补拉几次 NowPlaying。
        // 点播放后播放器会立刻把新状态写给系统，但我们要等下一次轮询才知道；
        // 这一拍让「切过去点播放」和「胶囊变宽」几乎同时发生。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.mediaEnabled else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastActivationBurstAt) > 1.5 else { return }
            self.lastActivationBurstAt = now
            NowPlayingService.shared.refreshBurst(times: 3, spacing: 0.6)
        }

        // 系统「降低透明度」切换时立即跟随
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        // 锁屏期间 WindowServer 可能改写浮层窗口的 frame
        // （实测：贴边胶囊 120×38@Y=0 被挪成 109×35@(797,54)，应用自身 frame 并没有变）。
        // 解锁 / 屏幕唤醒后强制重贴一次，恢复贴顶与槽位重合。
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.applyForm()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.applyForm()
            }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.pollPointer()
        }

        // 面板内的滚轮先经过这里：如果指针下的滚动容器还能朝这个方向滚，就让内容滚；
        // 到顶/到底（或根本没有滚动容器）才翻页。否则插件页会把滚轮全部吃掉。
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel,
                  CanvasLayout.shared.dragging == nil,
                  CanvasLayout.shared.resizing == nil else { return event }
            // 横向手势留给页签栏等横向滚动区域，不参与纵向翻页。
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                || event.scrollingDeltaY == 0 { return event }
            if self.scrollableUnderPointer(event) { return event }
            self.handlePanelScroll(event)
            return nil
        }

        // 切到别的 App 时（Cmd+Tab / 点 Dock）：面板没被钉住、鼠标也不在岛上就收起。
        // 只依赖鼠标移动的话，键盘切换 App 会让面板一直留在屏幕上。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.panel.isVisible, !self.pinned else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            if !self.isMouseInside() { self.hide() }
        }

        // 菜单栏显隐没有系统通知，1Hz 轮询代价可忽略（无面板时几乎零唤醒成本）
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkMenuBar() }
        RunLoop.main.add(t, forMode: .common)
        menuPoll = t

        applyTheme()
    }

    // MARK: - 装配

    private func setupStatusItem() {
        statusItem.length = CGFloat(settings.capsuleWidth)
        statusItem.view = barView
        barView.onHoverChange = { [weak self] inside in self?.hover(inside) }
        barView.onClick = { [weak self] in self?.capsuleClicked() }
        barView.onVolumeScroll = { [weak self] _ in
            self?.volumeOverlayUntil = Date().addingTimeInterval(1.2)
            self?.refreshCapsule()
        }
        barView.onFilesDropped = { [weak self] urls in self?.handleFilesDropped(urls) }
    }

    // MARK: - 菜单栏图标

    /// 屏幕右上角菜单栏里的独立应用图标。点左键/右键都会弹菜单，
    /// 与「胶囊」分开：胶囊显示内容，这个图标只做常用操作入口。
    private func setupMenuBarIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.image = menuBarIcon()
            b.image?.isTemplate = true
            b.toolTip = "Isla"
        }
        item.menu = buildMenuBarMenu()
        menuBarItem = item
    }

    /// 16×16 的单色模板图标：三根高低不同的竖条，像语音/声波。
    /// 只用实心圆角竖条，没有细线条，菜单栏里一眼能认出来。template 会自动适配深浅色。
    private func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            let bars: [(x: CGFloat, h: CGFloat)] = [(2.0, 8.0), (6.7, 13.0), (11.4, 9.5)]
            for bar in bars {
                let rect = NSRect(x: bar.x, y: 8 - bar.h / 2, width: 2.6, height: bar.h)
                NSBezierPath(roundedRect: rect, xRadius: 1.3, yRadius: 1.3).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func buildMenuBarMenu() -> NSMenu {
        let menu = NSMenu()

        let set = NSMenuItem(localizedTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        set.target = self
        menu.addItem(set)

        let pin = NSMenuItem(localizedTitle: "钉住面板", action: #selector(togglePinForMenu), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
        menu.addItem(.separator())

        let formParent = NSMenuItem(localizedTitle: "胶囊形态", action: nil, keyEquivalent: "")
        let formMenu = NSMenu(title: "胶囊形态")
        for f in IslandForm.allCases {
            let it = NSMenuItem(localizedTitle: f.title, action: #selector(setFormFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f.rawValue
            formMenu.addItem(it)
        }
        formParent.submenu = formMenu
        menu.addItem(formParent)

        let themeParent = NSMenuItem(localizedTitle: "图标与主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "图标与主题")
        for t in AppIconStyle.allCases {
            let it = NSMenuItem(localizedTitle: t.title, action: #selector(setThemeFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.rawValue
            themeMenu.addItem(it)
        }
        themeParent.submenu = themeMenu
        menu.addItem(themeParent)

        let modulesParent = NSMenuItem(localizedTitle: "显示模块", action: nil, keyEquivalent: "")
        let modulesMenu = NSMenu(title: "显示模块")
        for (i, d) in WidgetRegistry.descriptors.enumerated() {
            let it = NSMenuItem(localizedTitle: d.title, action: #selector(toggleModuleFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            modulesMenu.addItem(it)
        }
        modulesParent.submenu = modulesMenu
        menu.addItem(modulesParent)

        let arrange = NSMenuItem(localizedTitle: "网格整理", action: #selector(arrangeGridForMenu), keyEquivalent: "")
        arrange.target = self
        menu.addItem(arrange)

        // 插件命令：manifest.contributes.commands 声明，点击调用宿主的 run()。
        if !PluginManager.shared.pluginCommands.isEmpty {
            let cmdParent = NSMenuItem(localizedTitle: "插件命令", action: nil, keyEquivalent: "")
            let cmdMenu = NSMenu(title: "插件命令")
            for c in PluginManager.shared.pluginCommands {
                let it = NSMenuItem(localizedTitle: c.title,
                                    action: #selector(runPluginCommand(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                cmdMenu.addItem(it)
            }
            cmdParent.submenu = cmdMenu
            menu.addItem(cmdParent)
        }

        menu.addItem(.separator())
        let update = NSMenuItem(localizedTitle: "检查更新…", action: #selector(checkForUpdatesForMenu), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let refresh = NSMenuItem(localizedTitle: "刷新胶囊", action: #selector(refreshForMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let restart = NSMenuItem(localizedTitle: "重启胶囊", action: #selector(restartForMenu), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(localizedTitle: "退出 Isla", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func setFormFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let f = IslandForm(rawValue: raw) else { return }
        settings.form = f
    }

    @objc private func setThemeFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = AppIconStyle(rawValue: raw) else { return }
        settings.appIcon = t
    }

    @objc private func runPluginCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let command = PluginManager.shared.pluginCommands.first(where: { $0.id == id }) else { return }
        PluginRuntime.shared.invoke(pluginID: command.pluginID, command: command.commandID)
    }

    @objc private func toggleModuleFromMenu(_ sender: NSMenuItem) {
        let all = WidgetRegistry.descriptors
        guard all.indices.contains(sender.tag) else { return }
        let d = all[sender.tag]
        settings.setEnabled(d.id, !settings.isEnabled(d.id))
    }

    // MARK: - 数据绑定

    private func bindStore() {
        store.start()
        ShelfService.shared.load()
        storeSink = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在写入前触发，挪到下一轮 runloop 再读新值
            DispatchQueue.main.async { self?.refreshCapsule() }
        }
        // 切页会改变内容高度：等 SwiftUI 重排一拍再量
        pageSink = store.$page.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.resizeIfNeeded() }
        }
        // 剪贴板条目增减会让列表长高/变矮（只在剪贴板页）
        clipSink = ClipboardService.shared.$items.dropFirst().sink { [weak self] _ in
            guard let self, self.store.page == .clipboard else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.resizeIfNeeded() }
        }
        // 插件胶囊文本更新：立即重绘胶囊，不等下一轮媒体轮询。
        capsuleSink = PluginRuntime.shared.$capsuleTexts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshCapsule() }
        // 插件安装/启用状态变化后，重建状态栏菜单里的「插件命令」。
        pluginMenuSink = PluginManager.shared.$revision.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let item = self.menuBarItem else { return }
                item.menu = self.buildMenuBarMenu()
            }
        shelfSink = ShelfService.shared.$items.dropFirst().sink { [weak self] _ in
            guard let self, self.store.page == .shelf else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.resizeIfNeeded() }
        }
        // 拖动中同步跟手：SwiftUI 手势每改一次几何，面板 frame 当场跟上，
        // 不等 objectWillChange 的下一轮 async（那一拍会裁掉已经拖到边界外的卡片）。
        CanvasLayout.shared.onDragGeometryChanged = { [weak self] in
            self?.canvasChanged()
        }
        canvasSink = CanvasLayout.shared.objectWillChange.sink { [weak self] _ in
            guard let self, !self.canvasUpdateScheduled else { return }
            self.canvasUpdateScheduled = true
            DispatchQueue.main.async {
                self.canvasUpdateScheduled = false
                self.canvasChanged()
            }
        }
        refreshCapsule()
    }

    /// 画布变大/变小（拖动中会连续触发）——面板直接跟到目标 frame，不做动画。
    /// 之前的 0.10s NSAnimationContext 会被 60Hz 的拖动不断重入，视觉上就是「追不上手」；
    /// 这里改成拖动中直跟，松手后的尺寸落定（含重叠回弹导致的缩回）才带一点弹簧。
    private func canvasChanged() {
        updateContentSize()
        guard panel.isVisible else { return }
        let target = panelTargetFrame()
        guard panel.frame != target else { return }
        programmaticMove = true
        if CanvasLayout.shared.dragging == nil, CanvasLayout.shared.resizing == nil {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 1.18, 0.42, 1.0)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                self?.programmaticMove = false
            })
        } else {
            panel.setFrame(target, display: true)
            programmaticMove = false
        }
    }

    private func refreshCapsule() {
        var s = IslandBarView.CapsuleState()
        let content = settings.capsuleContent
        // 不能用 track.isPlaying：播放器会撒谎（QQ 音乐暂停后仍报 true）。
        // store.isAdvancing 是三道校验合出来的「真的在播」。
        let advancing = store.isAdvancing
        let playing = advancing
        let focus = store.pomodoroRunning
        let mediaChrome = content == .auto || content == .media || content == .lyrics
        s.isPlaying = (playing || advancing) && mediaChrome
        // 短视频 App 切换内容间隙 advancing 会短暂翻 false（音频中断 0.9s 判停）：
        // 3s 内确认过在播就让波形竖杠继续律动，否则竖杠频繁停住（2026-11-20 用户反馈）。
        s.waveAnimated = mediaChrome && (advancing || store.recentlyAdvancing)
        s.progress = 0

        if let text = notice, let until = noticeUntil, Date() < until {
            s.overlay = text
        } else if let until = volumeOverlayUntil, Date() < until {
            s.overlay = "\(Int(store.volume * 100))%"
        } else {
            switch content {
            case .auto:
                if focus {
                    s.text = timeString(store.pomodoroRemaining)
                    s.progress = PomodoroService.shared.progress
                } else if playing, let t = store.track, t.duration > 0 {
                    s.text = timeString(max(0, t.duration - store.elapsed))
                    s.progress = store.progress
                } else {
                    s.text = clockFormatter.string(from: Date())
                }
            case .time:
                s.text = clockFormatter.string(from: Date())
            case .network:
                s.text = "↓" + NetworkSpeedService.formatCompact(store.netDown)
            case .pomodoro:
                s.text = timeString(store.pomodoroRemaining)
                if focus { s.progress = PomodoroService.shared.progress }
            case .media:
                if playing, let t = store.track, t.duration > 0 {
                    s.text = timeString(max(0, t.duration - store.elapsed))
                    s.progress = store.progress
                } else {
                    s.text = "--:--"
                }
            case .lyrics:
                if let t = store.track {
                    // 标题是 app 名顶替的（上报本身为空）就不搜歌词：
                    // 拿「抖音」这类词去网易云会误匹配同名歌，显示不相干内容。
                    if t.titleIsFallback {
                        LyricsService.shared.sync(title: "", artist: "", duration: 0)
                    } else {
                        LyricsService.shared.sync(title: t.title, artist: t.artist, duration: t.duration)
                    }
                } else {
                    LyricsService.shared.sync(title: "", artist: "", duration: 0)
                }
                // 用「真的在前进」判断：QQ音乐暂停后仍报 rate=1，只看 playing 会继续跑词
                let elapsed = (LyricsService.shared.debugElapsed ?? store.liveElapsed)
                    + settings.lyricOffset
                if advancing || LyricsService.shared.debugElapsed != nil,
                   let line = LyricsService.shared.current(elapsed: elapsed) {
                    s.lyric = line.text
                    s.lyricProgress = line.progress
                    s.lyricActive = true
                    s.lyricKey = LyricsService.shared.activeKey
                } else if let t = store.track, !t.title.isEmpty {
                    s.text = t.title
                    s.titleMode = true
                } else {
                    s.text = clockFormatter.string(from: Date())
                }
            case .plugin:
                let modeID = settings.capsulePluginMode
                if modeID.isEmpty {
                    s.text = "插件"
                } else if let text = PluginRuntime.shared.capsuleText(for: modeID) {
                    s.text = text
                } else {
                    s.text = "…"
                    // 首次切到插件模式（或宿主刚重启）时补一次渲染；有缓存后不会重复请求。
                    PluginRuntime.shared.refreshCapsuleModes()
                }
            }
        }

        // 加宽跟着「真的在播」走，而不是等歌词到位：
        // 这样一点播放就已经是宽胶囊，不会先窄后宽跳一下；暂停后自动缩回。
        // 但歌词 4 秒还没到（放视频/纯音乐）就收回原宽，别一直占着菜单栏。
        if advancing {
            if advancingSince == nil { advancingSince = Date() }
        } else {
            advancingSince = nil
        }
        let graceExpired = advancingSince.map { Date().timeIntervalSince($0) > 4 } ?? true
        let wantWiden = advancing && settings.capsuleContent == .lyrics
            && settings.lyricsLayout == .widen && (s.lyricActive || !graceExpired)
            && widenSourceAllowed(store.track)
        updateWiden(wantWiden)
        logPlaybackIfNeeded(advancing: advancing, widen: lyricVisible,
                            track: store.track?.title ?? "-", position: store.liveElapsed,
                            audio: AudioService.shared.activeProcessCount)

        // 状态没变就不要碰 state：didSet 会 needsDisplay，
        // 而 NSStatusItem 每次重绘都要走一遍 replicant 快照（实测是空闲 CPU 的主要来源）
        if barView.state != s { barView.state = s }
        if let fb = floatingBar, fb.state != s { fb.state = s }
        syncWaveTimer(s.isPlaying || s.waveAnimated,
                      lyricAnimated: s.lyricActive && settings.capsuleContent == .lyrics)
    }

    /// 加宽只认「音乐类」App 的媒体会话。
    /// 抖音等视频 App 播放时同样占据系统「正在播放」：rate=1、进程在出声，
    /// 三道校验全过——但匹配不到歌词，胶囊加宽 4 秒宽限后又缩回，刷视频时反复抽动。
    /// `lyricsWidenMusicOnly`（默认开）= 白名单 + bundle 含 "music" 的 App 才触发加宽；
    /// 关掉开关回到旧行为。只挡「加宽」这个动作，标题/暂停态显示不受影响。
    static let musicAppBundles: Set<String> = [
        "com.tencent.qqmusicmac",   // QQ 音乐
        "com.netease.163music",     // 网易云音乐
        "com.spotify.client",       // Spotify
        "com.apple.music",          // Apple 音乐
        "com.apple.podcasts",       // 播客
        "com.kugou.mac",            // 酷狗音乐
        "com.kuwo.mac",             // 酷我音乐
        "com.migu.music.mac",       // 咪咕音乐
    ]
    private func widenSourceAllowed(_ track: NowPlayingService.Track?) -> Bool {
        guard settings.lyricsWidenMusicOnly else { return true }
        guard let bundle = track?.bundle.lowercased(), !bundle.isEmpty else { return false }
        return Self.musicAppBundles.contains(bundle) || bundle.contains("music")
    }

    /// 加宽/缩回带滞回：
    /// - 变宽立刻生效（用户点了播放就该马上看到）
    /// - 缩回等 0.7s，且期间又需要变宽就取消 —— 换歌、歌词空档都不会再抽一下
    private func updateWiden(_ want: Bool) {
        if want {
            widenOffWork?.cancel()
            widenOffWork = nil
            guard !lyricVisible else { return }
            lyricVisible = true
            DispatchQueue.main.async { [weak self] in self?.applyForm() }
            return
        }
        guard lyricVisible, widenOffWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.widenOffWork = nil
            guard self.lyricVisible else { return }
            self.lyricVisible = false
            self.applyForm()
        }
        widenOffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// 排查播放链路：`defaults write com.yopo.isla playbackDebug -bool true`
    /// 每次「播放状态 / 加宽状态」翻转都追加一行到 /tmp/macisland-playback.log（默认关闭，不产生 IO）。
    private func logPlaybackIfNeeded(advancing: Bool, widen: Bool, track: String,
                                     position: Double, audio: Int) {
        guard UserDefaults.standard.bool(forKey: "playbackDebug") else { return }
        guard lastLoggedAdvancing != advancing || lastLoggedWiden != widen else { return }
        lastLoggedAdvancing = advancing
        lastLoggedWiden = widen
        let line = String(format: "%.3f advancing=%@ widen=%@ pos=%.2f audio=%@ track=%@\n",
                          Date().timeIntervalSince1970, advancing ? "1" : "0", widen ? "1" : "0",
                          position, audio < 0 ? "?" : String(audio), track)
        let path = "/tmp/macisland-playback.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 文件暂存

    private func handleFilesDropped(_ urls: [URL]) {
        let added = ShelfService.shared.add(urls)
        if added > 0 {
            flashCapsule(added == 1 ? L("已暂存") : String(format: L("已暂存 %d"), added))
            if panel.isVisible { resizeIfNeeded() }
        } else {
            flashCapsule(L("已在暂存架"))
        }
    }

    /// 阶段结束：胶囊临时显示一句话，3 秒后自动回到常态
    private func flashCapsule(_ text: String) {
        notice = text
        noticeUntil = Date().addingTimeInterval(3)
        refreshCapsule()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self, let until = self.noticeUntil, Date() >= until else { return }
            self.notice = nil
            self.noticeUntil = nil
            self.refreshCapsule()
        }
    }

    private func timeString(_ t: Double) -> String {        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func toggleFromHotkey() {
        if panel.isVisible {
            hide()
        } else {
            pinned = true
            show()
        }
    }

    private var waveTimerLyric = false
    private func syncWaveTimer(_ playing: Bool, lyricAnimated: Bool) {
        // 歌词激活时按 60Hz 直调 refreshCapsule：lyricProgress 只在这里更新，
        // liveElapsed 本身按墙上时间外推，所以 60Hz 下滚动/逐字是连续的；
        // 15/20Hz 的旧实现肉眼能看出台阶。refreshCapsule 内部有 state 相等检查，不会白重绘。
        let lyric = playing && lyricAnimated
        let interval = lyric ? 1.0 / Double(max(1, settings.scrollFPS)) : 0.15
        // 旧实现的判断写反了：waveTimer 为 nil 时直接 return，
        // 于是「开始播放」这一下永远建不出定时器 —— 歌词进度只能等 0.25s 的
        // 媒体轮询才动一次，帧率设置（30/60/90/120）对歌词完全无效。
        // 现在按「状态/模式/帧率有变化才重建」来判断。
        let needNew = (playing != (waveTimer != nil))
            || (playing && lyric != waveTimerLyric)
            || (playing && abs(interval - (waveTimerInterval ?? 0)) > 0.0001)
        guard needNew else { return }
        waveTimer?.invalidate()
        waveTimer = nil
        guard playing else { return }
        waveTimerLyric = lyric
        waveTimerInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            if lyric {
                self?.waveProbeTick()
                self?.refreshCapsule()
            } else {
                self?.barView.needsDisplay = true
                self?.floatingBar?.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        waveTimer = t
    }

    private var waveTimerInterval: TimeInterval?

    /// 调试：统计歌词刷新定时器的实际回调频率（drawDebug 开启时写 /tmp/isla-wave.log）
    private var waveCallbacks = 0
    private var waveWindowStart = Date()
    private func waveProbeTick() {
        guard UserDefaults.standard.bool(forKey: "drawDebug") else { return }
        waveCallbacks += 1
        let now = Date()
        if waveCallbacks <= 3 || waveCallbacks % 20 == 0 {
            let dbg = String(format: "wave-cb n=%d t=%.3f\n", waveCallbacks, now.timeIntervalSince1970)
            if let h = FileHandle(forWritingAtPath: "/tmp/isla-wave.log") {
                h.seekToEndOfFile(); h.write(Data(dbg.utf8)); h.closeFile()
            }
        }
        if now.timeIntervalSince(waveWindowStart) >= 1 {
            let line = String(format: "wave-fps callbacks=%.0f interval=%.4f lyric=%@\n",
                              waveCallbacks, waveTimerInterval ?? 0, waveTimerLyric ? "yes" : "no")
            if let h = FileHandle(forWritingAtPath: "/tmp/isla-wave.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            } else {
                try? line.write(toFile: "/tmp/isla-wave.log", atomically: true, encoding: .utf8)
            }
            waveCallbacks = 0
            waveWindowStart = now
        }
    }

    private func setupPanel() {
        updateContentSize()
        panelHost.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        panelHost.autoresizingMask = [.width, .height]
        background.frame = panelHost.frame
        background.addSubview(panelHost)
        panel.contentView = background
        background.apply(theme: settings.panelTheme)
        background.onScroll = { [weak self] event in self?.handlePanelScroll(event) }

        // 面板任意空白处都能拖动（控件仍优先响应点击）
        panel.isMovableByWindowBackground = true
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.programmaticMove, self.panel.isVisible else { return }
            // 动画/程序化 setFrame 的完成通知可能晚于 programmaticMove 复位，
            // 再用目标 frame 兜底：落点已经是目标就不要记成用户拖动。
            let target = self.panelTargetFrame()
            if abs(self.panel.frame.origin.x - target.origin.x) < 0.5,
               abs(self.panel.frame.origin.y - target.origin.y) < 0.5 { return }
            let base = self.panelBaseFrame()
            self.settings.panelOffsetX = Double(self.panel.frame.origin.x - base.origin.x)
            self.settings.panelOffsetY = Double(self.panel.frame.origin.y - base.origin.y)
        }
        updateContentSize()
    }

    // MARK: - 滚轮翻页

    /// 滚轮翻页：**一格 = 一页**才是目标手感。
    ///
    /// 机械滚轮（有段落震动感的普通鼠标）的 `scrollingDeltaY` 单位是「行」，
    /// 一格通常只有 1~3；触控板是「像素」，一次滑动成百上千。
    /// 老实现把两者塞进同一个「累积 8」的尺子，等于机械滚轮要滚三四格才翻一页。
    private func handlePanelScroll(_ event: NSEvent) {
        let now = Date()
        let gap = now.timeIntervalSince(lastScrollAt)
        if gap > 0.20 {
            scrollAccum = 0
            gestureTurned = false
        }
        lastScrollAt = now

        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        // 方向反转 = 新手势，允许立刻反向翻页
        if lastScrollDir != 0, (dy < 0) != (lastScrollDir < 0) {
            scrollAccum = 0
            gestureTurned = false
        }
        lastScrollDir = dy

        if !event.hasPreciseScrollingDeltas {
            // 机械滚轮：一格一页。同一格可能连发两个事件，用 0.10s 冷却吞掉第二个；
            // 连滚多格时每格都翻（约 10 页/秒上限），跟手又不会飞页。
            guard gap > 0.10 else { return }
            let turned = store.turnPage(dy < 0 ? 1 : -1)
            scrollAccum = 0
            gestureTurned = turned
            if debugScroll { scrollLog("wheel dy=\(dy) turned=\(turned) page=\(store.page.rawValue)") }
            return
        }

        // 触控板（精确滚动，像素）：累积 8pt 翻一页，一个手势内只翻一次
        guard !gestureTurned else { return }
        scrollAccum += dy
        if scrollAccum <= -8 {
            gestureTurned = store.turnPage(1)
            scrollAccum = 0
        } else if scrollAccum >= 8 {
            gestureTurned = store.turnPage(-1)
            scrollAccum = 0
        }
        if debugScroll { scrollLog("trackpad dy=\(dy) accum=\(scrollAccum) turned=\(gestureTurned) page=\(store.page.rawValue)") }
    }

    /// 指针下的滚动容器还能不能朝滚轮方向滚。
    /// SwiftUI ScrollView 用 NSScrollView 的可见区域判断；WKWebView 用页面上报的边界。
    /// 找不到滚动容器（空白处）就返回 false，交给翻页。
    private func scrollableUnderPointer(_ event: NSEvent) -> Bool {
        guard let content = panel.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        guard let hit = content.hitTest(point) else { return false }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return false }

        // 1) Web 页：WKWebView 的滚动视图在远端进程，本地树里找不到；
        //    用注入脚本上报的 atTop / atBottom 判断。
        var node: NSView? = hit
        var webView: IslaWebView?
        while let view = node {
            if let web = view as? IslaWebView { webView = web; break }
            node = view.superview
        }
        if let web = webView {
            let state = web.scrollState
            let canScroll = dy > 0 ? !state.atTop : !state.atBottom
            if debugScroll {
                scrollLog("scroll web dy=\(dy) atTop=\(state.atTop) atBottom=\(state.atBottom) canScroll=\(canScroll)")
            }
            return canScroll
        }

        // 2) 普通 NSScrollView（SwiftUI ScrollView 底层就是 HostingScrollView）
        node = hit
        var scrollView: NSScrollView?
        while let view = node {
            if let sv = view as? NSScrollView { scrollView = sv; break }
            node = view.superview
        }
        guard let sv = scrollView, let doc = sv.documentView else {
            if debugScroll { scrollLog("scroll hit=\(type(of: hit)) sv=nil") }
            return false
        }
        let visible = sv.documentVisibleRect
        // dy > 0 = 手指/滚轮向上，内容要看更上面；dy < 0 = 向下看更多。
        let canScroll = dy > 0 ? visible.minY > 0.5
                               : visible.maxY < doc.bounds.height - 0.5
        if debugScroll {
            scrollLog("scroll sv=\(type(of: sv)) dy=\(dy) visible=\(Int(visible.minY))…\(Int(visible.maxY)) docH=\(Int(doc.bounds.height)) canScroll=\(canScroll)")
        }
        return canScroll
    }

    /// 排查滚轮用：`defaults write com.yopo.isla scrollDebug -bool true` 后
    /// 每次滚动会追加到 /tmp/macisland-scroll.log（默认关闭，不产生 IO）。
    private var debugScroll: Bool { UserDefaults.standard.bool(forKey: "scrollDebug") }
    private func scrollLog(_ line: String) {
        let path = "/tmp/macisland-scroll.log"
        let stamped = "\(Date()) \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(stamped.data(using: .utf8)!); h.closeFile()
        } else {
            try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 面板尺寸由画布决定：宽 = 画布宽 + 页签/内边距，高 = 画布高 + 页签行/圆点/内边距。
    /// 三页共用同一尺寸，切页不跳；拖动中实时跟随 preview（拖出变大 / 拖回缩回）。
    private func updateContentSize() {
        let canvas = CanvasLayout.shared
        let dragging = canvas.dragging != nil || canvas.resizing != nil
        let rawW = CGFloat(dragging ? canvas.previewW : canvas.canvasW) + IslandMetrics.panelChromeWidth
        var rawH = CGFloat(dragging ? canvas.previewH : canvas.canvasH) + IslandMetrics.panelChromeHeight
        // 插件页高度由 manifest.preferredHeight 决定；不给就用 300。
        // 面板高度仍受 panelMaxHeight 限制，插件内容过高时由页面自己滚动/裁剪。
        if let desc = PageRegistry.descriptor(for: store.page), desc.kind == .plugin {
            let preferred = CGFloat(desc.preferredHeight ?? 300)
            rawH = max(rawH, preferred + IslandMetrics.panelChromeHeight)
        }
        contentWidth = min(rawW, IslandMetrics.screen.frame.width - IslandMetrics.screenInset * 2)
        contentHeight = min(max(rawH, IslandMetrics.panelMinHeight), IslandMetrics.panelMaxHeight)
    }

    /// 切页后内容高度会变：面板若在屏上，就地重排（不闪）
    private func resizeIfNeeded() {
        guard panel.isVisible else { return }
        let before = contentHeight
        updateContentSize()
        guard abs(contentHeight - before) > 0.5 else { return }
        programmaticMove = true
        panel.setFrame(panelTargetFrame(), display: true)
        programmaticMove = false
    }

    @discardableResult
    private func ensureRail() -> RailPanel {
        if let r = railPanel, let v = railView {
            r.setFrame(IslandMetrics.railFrame(), display: true)
            v.frame = NSRect(origin: .zero, size: IslandMetrics.railFrame().size)
            return r
        }
        let frame = IslandMetrics.railFrame()
        let p = RailPanel(frame: frame)
        // 用材质做底，保证在浅色和深色桌面上都看得见；纯黑细线在深色窗口上会消失
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = frame.height / 2
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        bg.autoresizingMask = [.width, .height]

        let v = RailView(frame: NSRect(origin: .zero, size: frame.size))
        v.autoresizingMask = [.width, .height]
        v.onHoverChange = { [weak self] inside in self?.hover(inside) }
        v.onClick = { [weak self] in self?.togglePin() }
        bg.addSubview(v)
        p.contentView = bg
        railPanel = p
        railView = v
        return p
    }

    /// 居中形态的悬浮胶囊：确定性落在屏幕水平中线。
    /// macOS 27 上 CGWindowList 枚举不到别人 App 的状态项，「寻缝落位」没有数据源；
    /// 与其保留一个永远空转的扫描，不如把「自动居中」做成可复现的几何事实。
    /// 真正的避让需要 AX 权限路线，见 ROADMAP 方向 D。
    @discardableResult
    private func ensureFloatingCapsule(for form: IslandForm) -> NSPanel {
        let w = capsuleOverlayWidth
        let h = capsuleWindowHeight
        let yOffset = CGFloat(settings.capsuleYOffset)

        // 居中垂帘沿用旧版「菜单栏胶囊」的做法：状态项占一个真实菜单栏槽位，
        // 胶囊浮层正好盖在这个透明槽位上，所以不会压住其它 App 的图标。
        // 菜单栏胶囊则是纯浮层，允许拖到菜单栏任意位置。
        let centerX: CGFloat
        if form == .centered {
            // 居中垂帘：跟着系统分配的槽位走，固定不可拖
            centerX = slotCapsuleAnchorX()
        } else {
            // 菜单栏胶囊：屏幕中线/就近空位基准 + 用户拖出来的偏移
            centerX = applyCapsuleOffset(centeredBaseX())
        }
        let base = IslandMetrics.capsuleFrame(width: w, centerX: centerX,
                                              height: h, yOffset: yOffset)
        let frame = form == .centered ? retractedCapsuleFrame(base) : base

        if let p = floatingCapsule, let v = floatingBar {
            // 先改视图、再改窗口：反过来会出现「窗口已缩、视图还是旧宽度」的一帧，
            // 那一帧里文字按旧宽度排，就会闪一下（歌词溢出胶囊边缘）。
            v.frame = NSRect(origin: .zero, size: frame.size)
            p.setFrame(frame, display: true)
            v.needsDisplay = true
            return p
        }

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // 比系统状态项（同为 .statusBar）再高一层，否则居中位置正好压在
        // QQ 音乐/输入法等菜单栏窗口上时，岛会被它们盖住——看起来像“没显示”。
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = UserDefaults.standard.bool(forKey: "capsuleClickThrough")

        let v = IslandBarView(frame: NSRect(origin: .zero, size: frame.size))
        // 窗口宽度会随设置变化（歌词加宽），视图必须跟着铺满；否则形状还按旧宽度画，
        // 窗口再宽也只是一圈透明留白。
        v.autoresizingMask = [.width, .height]
        v.onHoverChange = { [weak self] inside in self?.hover(inside) }
        v.onClick = { [weak self] in self?.capsuleClicked() }
        v.onVolumeScroll = { [weak self] _ in
            self?.volumeOverlayUntil = Date().addingTimeInterval(1.2)
            self?.refreshCapsule()
        }
        v.onFilesDropped = { [weak self] urls in self?.handleFilesDropped(urls) }
        v.onDragRequest = { [weak self] event in self?.handleCapsuleDrag(event) ?? false }
        p.contentView = v

        floatingCapsule = p
        floatingBar = v
        return p
    }

    // MARK: - 拖动移动胶囊

    /// 拖动中：直接把浮层窗口移到目标 x（实时跟手），偏移先记在内存里
    private var capsuleDragOffset: CGFloat?
    /// 拖动进行中：忽略悬停进出，否则窗口从指针下挪开会反复触发 mouseEntered/Exited，
    /// 胶囊一边移动一边做悬停动画 —— 屏幕上就会出现两个半透明的「鬼影」。
    private var isDraggingCapsule = false

    /// 胶囊拖动入口（由视图回调）：
    /// - 居中垂帘：贴着状态项槽位，不响应拖动；
    /// - 菜单栏胶囊：直接左右拖动（不需要 ⌘）。
    private func handleCapsuleDrag(_ event: NSEvent) -> Bool {
        if UserDefaults.standard.bool(forKey: "drawDebug") {
            let msg = "drag request cmd=\(event.modifierFlags.contains(.command)) form=\(settings.form.rawValue)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/isla-drag.log") {
                h.seekToEndOfFile(); h.write(Data(msg.utf8)); h.closeFile()
            } else {
                try? msg.write(toFile: "/tmp/isla-drag.log", atomically: true, encoding: .utf8)
            }
        }
        switch settings.form {
        case .centered:
            // 居中垂帘：贴状态项槽位，不允许移动
            return false
        case .menuBar:
            // 菜单栏胶囊：直接左右拖，不需要按 ⌘
            return startCustomCapsuleDrag()
        case .rail:
            return false
        }
    }

    /// 自定义拖动（菜单栏胶囊用）：按住拖 → 水平移动浮层 → 松手记住位置
    private func startCustomCapsuleDrag() -> Bool {
        guard let panel = floatingCapsule else { return false }
        let startX = NSEvent.mouseLocation.x
        let originX = panel.frame.origin.x
        isDraggingCapsule = true
        defer { isDraggingCapsule = false }
        var events = 0
        while let e = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            events += 1
            if e.type == .leftMouseUp { break }
            let dx = NSEvent.mouseLocation.x - startX
            dragCapsule(to: originX + dx)
        }
        if UserDefaults.standard.bool(forKey: "drawDebug") {
            let msg = "custom drag events=\(events) dx=\(NSEvent.mouseLocation.x - startX)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/isla-drag.log") {
                h.seekToEndOfFile(); h.write(Data(msg.utf8)); h.closeFile()
            } else {
                try? msg.write(toFile: "/tmp/isla-drag.log", atomically: true, encoding: .utf8)
            }
        }
        finishCapsuleDrag()
        return true
    }

    private func dragCapsule(to targetX: CGFloat) {
        guard let panel = floatingCapsule else { return }
        let half = capsuleOverlayWidth / 2
        let screen = IslandMetrics.screen.frame
        let minX = screen.minX + half + 4
        let maxX = screen.maxX - half - 4
        let clamped = max(minX, min(maxX, targetX))
        var f = panel.frame
        f.origin.x = clamped - half
        panel.setFrame(f, display: true)
        floatingBar?.needsDisplay = true
        capsuleDragOffset = CapsuleAnchor.offset(forCurrentX: clamped,
                                                 baseAnchor: capsuleAnchorXWithoutOffset())
    }

    /// 不含用户偏移的锚点（拖动时用来算偏移量）：菜单栏胶囊的基准落点。
    private func capsuleAnchorXWithoutOffset() -> CGFloat {
        centeredBaseX()
    }

    /// 松手：把偏移写进设置，下次启动还在原位
    private func finishCapsuleDrag() {
        guard let offset = capsuleDragOffset else { return }
        capsuleDragOffset = nil
        settings.capsuleXOffset = CapsuleAnchor.sanitizedOffset(offset)
        applyForm()
    }

    // MARK: - 自动缩回顶边

    private var capsulePeekHeight: CGFloat { CGFloat(settings.capsulePeek) }

    /// 缩回后的窗口矩形：把胶囊整体推到屏幕上沿之外，只留底部 peek 高度可见。
    /// 改的是窗口 y 而不是视图内容——窗口被屏幕裁掉，视觉上就是胶囊缩回了顶边。
    private func retractedCapsuleFrame(_ base: NSRect) -> NSRect {
        guard settings.form == .centered, settings.capsuleAutoRetract, capsuleRetracted else {
            return base
        }
        let screen = IslandMetrics.screen
        let notch = screen.safeAreaInsets.top
        let mid = base.midX
        let inNotch = notch > 0
            && mid + base.width / 2 > screen.frame.midX - 110
            && mid - base.width / 2 < screen.frame.midX + 110
        let topY = inNotch ? screen.frame.maxY - notch : screen.frame.maxY
        return NSRect(x: base.origin.x, y: topY - capsulePeekHeight,
                      width: base.width, height: base.height)
    }

    private func capsuleBaseFrame() -> NSRect {
        IslandMetrics.capsuleFrame(width: capsuleOverlayWidth,
                                   centerX: capsuleAnchorX(),
                                   height: capsuleWindowHeight,
                                   yOffset: CGFloat(settings.capsuleYOffset))
    }

    /// 依据当前设置与指针状态收敛缩回状态（不带动画，供 applyForm 重建窗口时使用）
    private func syncCapsuleRetraction() {
        guard settings.form == .centered, settings.capsuleAutoRetract else {
            capsuleRetracted = false
            stopRevealPoll()
            return
        }
        let mouseInside = isMouseInside()
        // 与真实指针状态对齐，避免菜单跟踪丢失 mouseExited 后 pointerInsideBar 卡在 true。
        pointerInsideBar = mouseInside
        capsuleRetracted = !mouseInside && !panel.isVisible && !pinned
        if capsuleRetracted { startRevealPoll() } else { stopRevealPoll() }
    }

    @discardableResult
    private func setCapsuleRetracted(_ retracted: Bool, animated: Bool = true) -> Bool {
        guard settings.form == .centered, settings.capsuleAutoRetract,
              let capsule = floatingCapsule else { return false }
        capsuleRetractWork?.cancel()
        capsuleRetractWork = nil
        guard capsuleRetracted != retracted else { return false }
        capsuleRetracted = retracted
        if retracted { startRevealPoll() } else { stopRevealPoll() }
        let target = retractedCapsuleFrame(capsuleBaseFrame())
        guard animated else {
            capsule.setFrame(target, display: true)
            return true
        }
        capsuleAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = retracted ? 0.26 : 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: retracted ? .easeIn : .easeOut)
            capsule.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.capsuleAnimating = false
        })
        return true
    }

    /// 指针离开胶囊后延迟缩回；面板展开、钉住、关闭设置时都不缩。
    private func scheduleCapsuleRetract(after delay: TimeInterval = 0.9) {
        capsuleRetractWork?.cancel()
        guard settings.capsuleAutoRetract, settings.form == .centered,
              !capsuleRetracted, !pinned, !panel.isVisible, !isMouseInside() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned, !self.panel.isVisible, !self.isMouseInside() else { return }
            self.setCapsuleRetracted(true)
        }
        capsuleRetractWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 缩回期间低频轮询指针，避免「鼠标已经停在顶边但没触发 mouseMoved」。
    private func startRevealPoll() {
        guard revealTimer == nil else { return }
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.pollPointer() }
        RunLoop.main.add(t, forMode: .common)
        revealTimer = t
    }

    private func stopRevealPoll() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    /// 缩回状态与窗口 frame 自愈：动画被打断、系统改写 frame 时，
    /// 让 state 和「窗口是否在屏幕上方」重新一致，避免 hover 逻辑停摆。
    private func healCapsuleRetractionIfNeeded() {
        guard settings.form == .centered, settings.capsuleAutoRetract,
              !capsuleAnimating, let capsule = floatingCapsule else { return }
        let base = capsuleBaseFrame()
        let offscreen = capsule.frame.minY >= base.maxY - capsulePeekHeight - 1
        guard offscreen != capsuleRetracted else { return }
        capsuleRetracted = offscreen
        if offscreen { startRevealPoll() } else { stopRevealPoll() }
    }

    /// 贴边时胶囊两侧各多留的宽度 = 当前肩弧档位的 extend（与 IslandBarView 保持一致）。
    private var capsuleShoulder: CGFloat {
        settings.islandStyle == .attached ? settings.attachedShoulder.extend : 0
    }
    /// 悬停「Q 弹」的垂直余量：浮层窗口比胶囊高出 8pt（贴边形态才给），
    /// 悬停时胶囊在这段余量里向下拉伸（弹簧过冲最大约 13% ≈ 0.9pt，不会顶到余量上限）。
    /// 悬浮样式没有余量——胶囊居中于自己的窗口，拉伸会越过菜单栏边缘。
    private var capsuleHoverRoom: CGFloat { settings.islandStyle == .attached ? 8 : 0 }
    private var capsuleWindowHeight: CGFloat { CGFloat(settings.capsuleHeight) + capsuleHoverRoom }
    private var capsuleOverlayWidth: CGFloat {
        var w = CGFloat(settings.capsuleWidth) + capsuleShoulder * 2
        // 歌词「加宽」只在**真的有歌词且在播**时生效：暂停/无歌词自动缩回
        if settings.capsuleContent == .lyrics, settings.lyricsLayout == .widen, lyricVisible {
            w *= CGFloat(settings.lyricWidenFactor)
        }
        return w
    }

    /// 菜单栏胶囊的基础锚点（不含用户拖出来的偏移）：屏幕中线或「就近空位」。
    private func centeredBaseX() -> CGFloat {
        let w = capsuleOverlayWidth
        if settings.centeredPlacement == .avoid, MenuBarScanner.isTrusted {
            // 「就近空位」优先用本轮扫描结果；没有快照时用上次成功落点，避免启动时先落中线再跳。
            // 无辅助功能权限时仍回退屏幕正中（UI 也是这么承诺的）。
            if let scanned = MenuBarScanner.shared.bestCenter(forWidth: w) {
                MenuBarScanner.shared.rememberCenter(scanned, forWidth: w)
                return scanned
            }
            if let cached = MenuBarScanner.shared.cachedCenter(forWidth: w) {
                MenuBarScanner.shared.scan()
                return cached
            }
            MenuBarScanner.shared.scan()
        }
        return IslandMetrics.screen.frame.midX
    }

    /// 居中垂帘的锚点：贴着系统分配的状态项槽位（像其它菜单栏图标一样占位），
    /// 歌词加宽时按「加宽方向」向一侧生长；不叠加任何用户拖动偏移。
    private func slotCapsuleAnchorX() -> CGFloat {
        let slot = capsuleSlotCenterX()
        guard lyricVisible else { return slot }
        let base = CGFloat(settings.capsuleWidth) + capsuleShoulder * 2
        let extra = capsuleOverlayWidth - base
        guard extra > 0.5 else { return slot }
        let dir: CapsuleAnchor.Direction
        switch settings.widenDirection {
        case .left: dir = .left
        case .right: dir = .right
        case .both: dir = .both
        }
        return CapsuleAnchor.widened(slot: slot, extra: extra, direction: dir,
                                      screen: IslandMetrics.screen.frame,
                                      overlayWidth: capsuleOverlayWidth)
    }

    /// 当前形态下的水平锚点：居中垂帘贴槽位，菜单栏胶囊叠加用户拖动偏移。
    private func capsuleAnchorX() -> CGFloat {
        switch settings.form {
        case .centered:
            return slotCapsuleAnchorX()
        case .menuBar:
            return applyCapsuleOffset(centeredBaseX())
        case .rail:
            return centeredBaseX()
        }
    }

    /// 用户拖出来的水平偏移（夹在屏幕内）
    private func applyCapsuleOffset(_ x: CGFloat) -> CGFloat {
        CapsuleAnchor.clamped(slot: x, offset: CGFloat(settings.capsuleXOffset),
                              screen: IslandMetrics.screen.frame,
                              overlayWidth: capsuleOverlayWidth)
    }

    /// 状态栏槽位的水平中点。状态项被系统重新排布后，这个值会自己更新。
    ///
    /// macOS 27 实测：状态项用自定义 view 时 `barView.window` 恒为 `(0,0,136×0)`，
    /// 系统把状态项托管在远程视图里，窗口坐标不可读。此时退回 AX 扫描：
    /// 取状态区最左一项，把岛贴在它左边，视觉上等价于「最左那一格」。
    /// 再不行就用上次成功落点；都没有才落屏幕正中（绝不落 x=8 遮住苹果菜单）。
    private func capsuleSlotCenterX() -> CGFloat {
        if let w = barView.window, w.frame.height > 1, w.frame.width > 1 {
            return w.frame.midX
        }
        let width = capsuleOverlayWidth
        if let edge = MenuBarScanner.shared.reservedSlotRightEdge(forWidth: width) {
            rememberSlotRightEdge(edge)
            return edge - width / 2
        }
        if let edge = cachedSlotRightEdge(width: width) { return edge - width / 2 }
        return IslandMetrics.screen.frame.midX
    }

    /// 状态项窗口失效时，胶囊槽位只能靠 AX 扫描推出来。
    /// 扫描要遍历所有 App（实机约 3s），不能做成高频轮询：
    /// 启动 / 换屏时扫一次，之后 5 分钟对账一次，避免为了几个像素把空闲 CPU 吃掉。
    private var lastSlotScanAt = Date.distantPast
    private func scheduleSlotRescanIfNeeded(force: Bool = false) {
        guard settings.form == .centered else { return }
        let valid = (barView.window?.frame.height ?? 0) > 1
        guard !valid else { return }
        // 还没有任何可用落点（首次启动/换到新屏）时 15s 重试；已有缓存则 5 分钟对账一次
        let hasSlot = MenuBarScanner.shared.reservedSlotRightEdge(forWidth: capsuleOverlayWidth) != nil
            || cachedSlotRightEdge(width: capsuleOverlayWidth) != nil
        let interval: TimeInterval = hasSlot ? 300 : 15
        if !force, Date().timeIntervalSince(lastSlotScanAt) < interval { return }
        lastSlotScanAt = Date()
        MenuBarScanner.shared.scan()
    }

    /// 落点缓存按「屏」存右缘：歌词加宽只改胶囊宽度，右缘必须保持不动。
    private var slotCacheKey: String { "\(DisplayResolver.shared.activeID)" }

    private func rememberSlotRightEdge(_ edge: CGFloat) {
        var map = UserDefaults.standard.dictionary(forKey: "macisland.capsuleSlotEdges") as? [String: Double] ?? [:]
        if let old = map[slotCacheKey], abs(old - Double(edge)) < 0.5 { return }
        map[slotCacheKey] = Double(edge)
        UserDefaults.standard.set(map, forKey: "macisland.capsuleSlotEdges")
    }

    private func cachedSlotRightEdge(width: CGFloat) -> CGFloat? {
        let map = UserDefaults.standard.dictionary(forKey: "macisland.capsuleSlotEdges") as? [String: Double] ?? [:]
        guard let v = map[slotCacheKey] else { return nil }
        let screen = IslandMetrics.screen.frame
        guard v - width >= screen.minX, v <= screen.maxX else { return nil }
        return CGFloat(v)
    }

    /// 维护参数 `--dump-state` 用：把多屏决策与三个关键窗口的几何打成一行行文本。
    /// 单屏机器上排查「胶囊为什么贴在左上角」时，这是唯一能看到内部 frame 的口子。
    func dumpGeometry() -> String {
        let screens = NSScreen.screens.map(DisplayResolver.snapshot(of:))
        var lines: [String] = []
        lines.append("screens=\(screens.count) active=\(DisplayResolver.shared.activeID) "
                     + "name=\(DisplayResolver.snapshot(of: IslandMetrics.screen).name) target=\(settings.screenTarget.rawValue)")
        for s in screens {
            lines.append(String(format: "  screen id=%u primary=%@ frame=(%.0f,%.0f,%.0f×%.0f) visible=(%.0f,%.0f,%.0f×%.0f) menu=%.0f notch=%.0f",
                                s.id, s.isPrimary ? "yes" : "no",
                                s.frame.minX, s.frame.minY, s.frame.width, s.frame.height,
                                s.visibleFrame.minX, s.visibleFrame.minY, s.visibleFrame.width, s.visibleFrame.height,
                                s.menuBarHeight, s.safeAreaTop))
        }
        let bar = barView.window?.frame ?? .zero
        let slot = statusItem.button?.window?.frame ?? .zero
        let icon = menuBarItem?.button?.window?.frame ?? .zero
        let floating = floatingCapsule?.frame ?? .zero
        lines.append(String(format: "statusItem visible=%@ length=%.0f buttonWindow=(%.0f,%.0f,%.0f×%.0f)",
                            statusItem.isVisible ? "yes" : "no", statusItem.length,
                            slot.minX, slot.minY, slot.width, slot.height))
        lines.append(String(format: "menuBarIcon buttonWindow=(%.0f,%.0f,%.0f×%.0f)",
                            icon.minX, icon.minY, icon.width, icon.height))
        lines.append(String(format: "barView.window=(%.0f,%.0f,%.0f×%.0f) alpha=%.2f",
                            bar.minX, bar.minY, bar.width, bar.height, barView.alphaValue))
        lines.append(String(format: "floatingCapsule=(%.0f,%.0f,%.0f×%.0f) retracted=%@",
                            floating.minX, floating.minY, floating.width, floating.height,
                            capsuleRetracted ? "yes" : "no"))
        lines.append(String(format: "panel visible=%@ frame=(%.0f,%.0f,%.0f×%.0f)",
                            panel.isVisible ? "yes" : "no",
                            panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height))
        if let snap = MenuBarScanner.shared.snapshot {
            let leftmost = snap.items.map(\.minX).min() ?? -1
            let age = Date().timeIntervalSince(snap.timestamp)
            lines.append(String(format: "axSnapshot display=%u items=%d leftmost=%.0f search=[%.0f,%.0f] age=%.1fs",
                                snap.displayID, snap.items.count, leftmost,
                                snap.searchMinX, snap.searchMaxX, age))
        } else {
            lines.append("axSnapshot nil")
        }
        lines.append(String(format: "capsuleAnchor=%.0f offset=%.0f form=%@ placement=%@",
                            capsuleAnchorX(), settings.capsuleXOffset,
                            settings.form.rawValue, settings.centeredPlacement.rawValue))
        lines.append(String(format: "slotCenter=%.0f cachedEdge=%@",
                            capsuleSlotCenterX(),
                            cachedSlotRightEdge(width: capsuleOverlayWidth).map { String(format: "%.0f", $0) } ?? "nil"))
        return lines.joined(separator: "\n")
    }

    /// 形态与菜单栏显隐统一在这里落地
    private func applyForm() {
        // 居中垂帘用系统状态项占一个真实菜单栏槽位（所以不会盖住其它图标），
        // 槽位可读时跟着它所在屏走；菜单栏胶囊按设置选屏（主屏 / 跟随鼠标 / 指定屏）。
        let slotWindow = barView.window
        let slotScreen = (slotWindow?.frame.height ?? 0) > 1 ? slotWindow?.screen : nil
        DisplayResolver.shared.setForcedScreen(settings.form == .centered ? slotScreen : nil)
        let forceRail = IslandMetrics.menuBarHidden || settings.form == .rail
        // 形态切换时先收敛缩回状态：非居中垂帘形态要确保浮层恢复完整。
        syncCapsuleRetraction()
        statusItem.length = CGFloat(settings.capsuleWidth)
        barView.alphaValue = 1

        if forceRail {
            statusItem.isVisible = false
            floatingCapsule?.orderOut(nil)
        } else if settings.form == .centered {
            // 居中垂帘：状态栏留一个透明槽位，浮层正好盖在槽位上。
            statusItem.isVisible = true
            barView.alphaValue = 0
            ensureFloatingCapsule(for: .centered).orderFrontRegardless()
            // 状态项刚插入时窗口坐标还没稳定（第一帧可能落到 x=8），多校准几次。
            for delay in [0.12, 0.35, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.syncCapsulePosition()
                }
            }
        } else {
            // 菜单栏胶囊：纯浮层，不占系统槽位。
            statusItem.isVisible = false
            ensureFloatingCapsule(for: .menuBar).orderFrontRegardless()
        }

        if forceRail {
            ensureRail().orderFrontRegardless()
        } else {
            railPanel?.orderOut(nil)
        }
        lastMenuBarHidden = IslandMetrics.menuBarHidden
        // 状态项窗口读不到坐标时，槽位要靠 AX 扫描推出来
        scheduleSlotRescanIfNeeded()

        if panel.isVisible { show() }
    }

    // MARK: - 显隐

    /// 贴边样式下面板紧贴菜单栏下沿（不越界，只是不留缝隙）
    private var panelGap: CGFloat {
        settings.islandStyle == .attached ? 0 : IslandMetrics.panelGap
    }

    var anchorMidX: CGFloat? {
        if settings.form != .rail, let f = floatingCapsule?.frame { return f.midX }
        if IslandMetrics.menuBarHidden || settings.form == .rail {
            return railView?.window?.frame.midX
        }
        return barView.window?.frame.midX
    }

    /// 面板中心线始终跟随胶囊中心线。
    /// 画布宽度已经按中心线对称扩展，所以这里不能再按 originX 平移一半；
    /// 否则用户把媒体卡往左拖时，面板中心会明显偏向左边。
    private var panelAnchorMidX: CGFloat? {
        anchorMidX
    }

    /// 当前形态下胶囊的屏幕矩形：胶囊/居中形态都取浮层，其余取边缘手柄
    private func capsuleFrame() -> NSRect? {
        if settings.form != .rail, let f = floatingCapsule?.frame { return f }
        if IslandMetrics.menuBarHidden || settings.form == .rail {
            return railView?.window?.frame
        }
        return barView.window?.frame
    }

    /// 缩回后放宽触发的纵向范围：窗口只露 3pt，但用户通常会把鼠标放到
    /// 「胶囊原来的位置」。这里把基准胶囊矩形也并入命中区。
    private func pollPointer() {
        healCapsuleRetractionIfNeeded()
        syncActiveScreenWithPointer()
        guard let frame = capsuleFrame() else { return }
        var hit = frame.insetBy(dx: -2, dy: -2)
        if capsuleRetracted, settings.form == .centered {
            hit = hit.union(capsuleBaseFrame().insetBy(dx: -2, dy: -4))
        }
        let inside = hit.contains(NSEvent.mouseLocation)
        // 缩回状态下只要指针在命中区，就一定要滑出。
        // 不能只靠 inside != pointerInsideBar：菜单栏菜单跟踪期间可能收不到 mouseExited，
        // pointerInsideBar 会停在 true，导致回到胶囊位置反而没反应。
        if inside, capsuleRetracted {
            pointerInsideBar = true
            hover(true)
            return
        }
        guard inside != pointerInsideBar else { return }
        pointerInsideBar = inside
        hover(inside)
    }

    private func hover(_ inside: Bool) {
        // 拖动画布组件期间挂起悬停收起：指针跟着卡片移出面板帧是正常状态，
        // 不能因为「不在岛内」把正拖着的面板收掉
        if CanvasLayout.shared.dragging != nil || CanvasLayout.shared.resizing != nil {
            hideWork?.cancel()
            return
        }
        if inside {
            hideWork?.cancel()
            capsuleRetractWork?.cancel()
            capsuleRetractWork = nil
            // 缩回状态下指针回到顶边：先把胶囊滑下来，面板照旧按悬停设置展开
            if capsuleRetracted { setCapsuleRetracted(false) }
            // 未开启「悬停驻留」时，展开只由点击触发（老行为）
            guard settings.hoverDwell else { return }
            let w = DispatchWorkItem { [weak self] in self?.show() }
            showWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: w)
        } else if !pinned {
            hideWork?.cancel()
            // 关键：从胶囊移进面板也会触发 mouseExited，
            // 必须等延迟到了再确认「指针确实不在岛内」才收起，否则面板刚展开就被自己关掉
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.pinned, !self.isMouseInside() else { return }
                self.hide()
            }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.autoHideDelay, execute: w)
            scheduleCapsuleRetract()
        }
    }

    func show() {
        showWork?.cancel()
        // 面板展开时胶囊必须先露出来，否则面板会挂在一颗看不见的胶囊下面
        capsuleRetractWork?.cancel()
        if capsuleRetracted { setCapsuleRetracted(false) }
        updateContentSize()
        let target = panelTargetFrame()
        if panel.isVisible {
            programmaticMove = true
            panel.setFrame(target, display: true)
            programmaticMove = false
            return
        }

        // 驻留模式：从胶囊尺度长出来（先变大变宽，再展开内容）。
        // 用一条接近弹簧的 ease-out 曲线，而不是硬邦邦的线性 easeOut；
        // 内容比外框晚 40ms 淡入，避免文字被窗口边缘「挤」出来。
        let morph = settings.hoverDwell
        // 联动动画：面板从胶囊里长出来的同一瞬间，胶囊自己也「跳一下」，
        // 两个界面的运动出自同一个起点，看起来才像一颗岛在展开。
        floatingBar?.pulse()
        barView.pulse()
        panel.alphaValue = 0
        panelHost.alphaValue = 0
        programmaticMove = true
        panel.setFrame(morph ? morphRect() : target, display: false)
        panel.orderFrontRegardless()
        // 非激活面板也要在展示时就成为 key，否则 SwiftUI 的第一次拖拽手势
        // （比如直接拖缩放手柄）可能只被当成“激活窗口”而丢掉。
        panel.makeKey()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = morph ? 0.46 : 0.24
            // 轻微回弹：先长过目标一点点，再收回来，像水滴被拉开后回弹。
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.34, 0.30, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            if morph { panel.animator().setFrame(target, display: true) }
        }, completionHandler: { [weak self] in
            self?.programmaticMove = false
            // 首帧的 SwiftUI 布局可能还没稳定（量到的是最小高度），展开后再校一次
            guard let self else { return }
            let before = self.contentHeight
            self.updateContentSize()
            if abs(self.contentHeight - before) > 0.5 {
                self.programmaticMove = true
                self.panel.setFrame(self.panelTargetFrame(), display: true)
                self.programmaticMove = false
            }
        })

        // 内容晚一点淡入，给窗口外框一个「先呼吸、再落字」的层次。
        DispatchQueue.main.asyncAfter(deadline: .now() + (morph ? 0.04 : 0.0)) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = morph ? 0.24 : 0.16
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.92, 0.26, 1.0)
                self.panelHost.animator().alphaValue = 1
            }
        }
        startHoverPoll()
        installDismissMonitors()
        // 媒体关闭时不要把 NowPlayingService 激活：setActive(true) 会立刻 poll 一次，
        // 即使模块关掉，胶囊仍会显示别人的播放时间。
        NowPlayingService.shared.setActive(settings.mediaEnabled)
    }

    func hide() {
        guard panel.isVisible else { return }
        pinned = false
        removeDismissMonitors()
        NowPlayingService.shared.setActive(false)
        stopHoverPoll()

        let morph = settings.hoverDwell
        programmaticMove = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = morph ? 0.24 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.22, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            panelHost.animator().alphaValue = 0
            if morph { panel.animator().setFrame(morphRect(), display: true) }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panelHost.alphaValue = 1
            self.programmaticMove = false
            // 先让面板缩回胶囊，稍等一拍再把胶囊缩回屏幕顶边。
            self.scheduleCapsuleRetract(after: 0.25)
        })
    }

    /// 胶囊尺度的起始/结束矩形：贴住菜单栏下沿，居中在锚点
    private func morphRect() -> NSRect {
        let center = panelAnchorMidX ?? IslandMetrics.screen.frame.midX
        let w: CGFloat = 136, h: CGFloat = max(CGFloat(settings.capsuleHeight), 24)
        return NSRect(x: center - w / 2,
                      y: IslandMetrics.ceilingY - panelGap - h,
                      width: w, height: h)
    }

    /// 默认位置 + 用户拖动偏移，并钳制在屏幕内、不越过菜单栏下沿
    private func panelTargetFrame() -> NSRect {
        var r = IslandMetrics.panelFrame(anchorMidX: panelAnchorMidX,
                                         width: contentWidth,
                                         height: contentHeight,
                                         gap: panelGap)
        // 胶囊形态的面板横向锚死胶囊中心线；用户手动拖面板只保留纵向偏移。
        // 否则一次旧的水平偏移就会让「组件移动后中心线」看起来仍然偏左。
        if settings.form != .centered {
            r.origin.x += CGFloat(settings.panelOffsetX)
        }
        r.origin.y += CGFloat(settings.panelOffsetY)

        let screen = IslandMetrics.screen.frame
        r.origin.x = min(max(r.minX, screen.minX + IslandMetrics.screenInset),
                         screen.maxX - r.width - IslandMetrics.screenInset)
        if r.maxY > IslandMetrics.ceilingY { r.origin.y = IslandMetrics.ceilingY - r.height }
        if r.minY < screen.minY + IslandMetrics.screenInset { r.origin.y = screen.minY + IslandMetrics.screenInset }
        return r
    }

    private func panelBaseFrame() -> NSRect {
        IslandMetrics.panelFrame(anchorMidX: panelAnchorMidX,
                                 width: contentWidth,
                                 height: contentHeight,
                                 gap: panelGap)
    }

    private func togglePin() {
        pinned.toggle()
        if pinned { show() } else if !isMouseInside() { hide() }
    }

    /// 左键点击胶囊：只负责展开，不会钉住也不会收起。
    /// 悬停驻留本身会在 0.12s 后展开；如果点击又把它收起来，用户会觉得「点一下就没了」。
    /// 收起统一走「鼠标离开 / Esc / 点外部」，钉住只走菜单栏「钉住面板」。
    private func capsuleClicked() {
        if !panel.isVisible { show() }
    }

    // MARK: - 鼠标越界判定

    private func isMouseInside() -> Bool {
        let p = NSEvent.mouseLocation
        // 两个形态真正显示的都是浮层胶囊，必须算「在岛内」，
        // 否则指针停在胶囊上、还没进面板时面板就会被 0.06s 轮询收掉。
        if settings.form != .rail, let f = floatingCapsule?.frame,
           f.insetBy(dx: -6, dy: -4).contains(p) { return true }
        // 居中垂帘的状态项槽位是透明占位，补一份命中区，避免槽位边缘漏判。
        if settings.form == .centered, let f = barView.window?.frame,
           f.insetBy(dx: -6, dy: -4).contains(p) { return true }
        if let f = railView?.window?.frame, f.insetBy(dx: -8, dy: -8).contains(p) { return true }
        if panel.isVisible, panel.frame.insetBy(dx: -6, dy: -10).contains(p) { return true }
        return false
    }

    private func startHoverPoll() {
        stopHoverPoll()
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.pinned else { return }
            // 拖动画布组件/缩放时不自动收起（指针跟随卡片移动，出面板帧是正常状态）
            if CanvasLayout.shared.dragging != nil || CanvasLayout.shared.resizing != nil { return }
            if !self.isMouseInside() { self.hide() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverPoll = t
    }

    private func stopHoverPoll() {
        hoverPoll?.invalidate()
        hoverPoll = nil
    }

    // MARK: - 点外部 / Esc 收起

    private func installDismissMonitors() {
        guard clickMonitor == nil, keyMonitor == nil else { return }

        // 全局鼠标监听不需要辅助功能权限；只要点在岛以外就收起。
        // 钉住（pinned）时例外：用户明确要求面板留在屏上，点别处不应把它收掉。
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.pinned else { return }
            if self.isMouseInside() { return }
            self.hide()
        }

        // 本地监听：点到自己 App 的其它窗口（如设置）也算「外面」；
        // 面板因点击成为 key 时，Esc 直接收起。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.panel.isVisible {   // Esc
                    self.hide()
                    return nil
                }
                return event
            }
            if event.window === self.panel { return event }
            if !self.isMouseInside() { self.hide() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - 系统事件

    /// 状态栏槽位会随系统状态项增删而变化；App 自己不能监听状态栏重排，
    /// 定期校正透明占位与浮层胶囊的位置，保证两者始终重合。
    private func syncCapsulePosition() {
        guard settings.form == .centered, let capsule = floatingCapsule, !capsuleAnimating else { return }
        let target = retractedCapsuleFrame(capsuleBaseFrame())
        if let v = floatingBar, v.frame.size != target.size {
            v.frame = NSRect(origin: .zero, size: target.size)
            v.needsDisplay = true
        }
        guard capsule.frame != target else { return }
        capsule.setFrame(target, display: true)
        if panel.isVisible { show() }
    }

    private func checkMenuBar() {
        healCapsuleRetractionIfNeeded()
        let hidden = IslandMetrics.menuBarHidden
        if hidden != lastMenuBarHidden { applyForm() }

        // 居中垂帘的槽位会随系统状态项增删而变化；每秒校正一次。
        // 槽位被系统挪到另一块屏（独立空间/菜单栏跟随前台）时，强制屏也要自愈。
        if settings.form == .centered {
            if let slot = barView.window, slot.frame.height > 1, let slotScreen = slot.screen,
               DisplayResolver.id(of: slotScreen) != DisplayResolver.shared.activeID {
                applyForm()
            }
            syncCapsulePosition()
            scheduleSlotRescanIfNeeded()
        } else {
            // 跟随鼠标模式：键盘切屏后指针可能没动，靠 1Hz 兜底补一次判断
            syncActiveScreenWithPointer()
        }

        // 歌词加宽需要知道左右邻居在哪：没有快照或太旧就重扫一次（15s 节流）
        if settings.capsuleContent == .lyrics, settings.lyricsLayout == .widen,
           MenuBarScanner.shared.snapshot == nil
            || Date().timeIntervalSince(lastMenuBarScanAt) > 15 {
            lastMenuBarScanAt = Date()
            MenuBarScanner.shared.scan()
        }

        // 菜单栏胶囊的「就近空位」：状态项会随 App 启停/用户调整而变化，10s 重扫一次。
        if settings.form == .menuBar, settings.centeredPlacement == .avoid,
           Date().timeIntervalSince(lastMenuBarScanAt) > 10 {
            lastMenuBarScanAt = Date()
            MenuBarScanner.shared.scan()
        }
    }

    /// AX 快照更新：居中垂帘重贴槽位；菜单栏胶囊在「就近空位」下挪到新的空位。
    @objc private func menuBarScanUpdated() {
        if settings.form == .centered, (barView.window?.frame.height ?? 0) <= 1 {
            syncCapsulePosition()
        }
        guard settings.form == .menuBar, settings.centeredPlacement == .avoid,
              let capsule = floatingCapsule else { return }
        let w = capsuleOverlayWidth
        guard let base = MenuBarScanner.shared.bestCenter(forWidth: w) else { return }
        MenuBarScanner.shared.rememberCenter(base, forWidth: w)
        let center = applyCapsuleOffset(base)
        let target = IslandMetrics.capsuleFrame(width: w, centerX: center,
                                                height: capsuleWindowHeight,
                                                yOffset: CGFloat(settings.capsuleYOffset))
        guard abs(capsule.frame.origin.x - target.origin.x) > 0.5 else { return }
        capsule.setFrame(target, display: true)
        floatingBar?.frame = NSRect(origin: .zero, size: target.size)
        if panel.isVisible { show() }
    }

    @objc private func screenChanged() {
        // 插拔/改分辨率/重新排列：先让解析器丢掉失效的屏与菜单栏高度缓存
        DisplayResolver.shared.screenParametersChanged()
        applyForm()
        scheduleSlotRescanIfNeeded(force: true)
        // 热插拔/改分辨率时 NSScreen 的几何量可能晚一拍才稳定，
        // 再补一次，避免胶囊和面板停在旧屏幕的坐标上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            DisplayResolver.shared.screenParametersChanged()
            self.applyForm()
            self.scheduleSlotRescanIfNeeded(force: true)
            if self.panel.isVisible { self.show() }
        }
    }

    /// 指针跨屏决策的统一入口：面板展开、拖动组件、缩回顶边时不搬家。
    private func syncActiveScreenWithPointer() {
        let busy = panel.isVisible || capsuleRetracted
            || CanvasLayout.shared.dragging != nil
            || CanvasLayout.shared.resizing != nil
        DisplayResolver.shared.pointerMoved(to: NSEvent.mouseLocation, busy: busy)
    }

    /// 岛换屏：面板/胶囊都按新屏几何重排；面板开着就跟着搬过去。
    @objc private func activeScreenChanged() {
        applyForm()
    }

    @objc private func accessibilityChanged() { applyTheme() }

    /// 主题（深色/浅色/跟随设备）落地：面板底、窗口外观、胶囊重绘。
    /// appIcon 设置变化 → settingsChanged → applySettingsChanges → 这里；
    /// 跟随设备时系统外观切换 → AppDelegate 的 AppleInterfaceThemeChanged 监听 → 同一条链。
    private func applyTheme() {
        background.apply(theme: settings.panelTheme)
        let appearance = NSAppearance(named: Theme.isDarkUI ? .darkAqua : .aqua)
        panel.appearance = appearance          // 玻璃材质跟着翻转
        settingsWindow?.window?.appearance = appearance
        if let w = settingsWindow?.window {
            w.backgroundColor = Theme.isDarkUI
                ? NSColor(srgbRed: 0.039, green: 0.043, blue: 0.051, alpha: 1)
                : NSColor(srgbRed: 0.937, green: 0.941, blue: 0.949, alpha: 1)
            w.contentView?.needsDisplay = true
        }
        barView.needsDisplay = true
        floatingBar?.needsDisplay = true
    }

    private func moduleSignature() -> String {
        WidgetRegistry.descriptors.map { settings.isEnabled($0.id) ? "1" : "0" }.joined()
    }

    @objc private func settingsChanged() {
        settingsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySettingsChanges() }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 设置变更统一在这里落地。滑杆拖动会连续发通知，所以先防抖；
    /// 媒体轮询只在「媒体开关」真的翻转时重启，避免拖胶囊宽度也 spawn osascript。
    private func applySettingsChanges() {
        let signature = moduleSignature()
        if signature != lastModuleSignature {
            lastModuleSignature = signature
            CanvasLayout.shared.arrange()
        }
        if settings.mediaEnabled != lastMediaEnabled {
            lastMediaEnabled = settings.mediaEnabled
            store.reloadMedia()
        }
        applyTheme()
        applyForm()
        barView.needsDisplay = true
        floatingBar?.needsDisplay = true
        refreshCapsule()
        if settings.form == .menuBar, settings.centeredPlacement == .avoid {
            lastMenuBarScanAt = Date()
            MenuBarScanner.shared.scan()
        }
        // SwiftUI 重排发生在下一轮 runloop：等一拍再量高，避免量到旧高度
        if panel.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.show()
            }
        }
    }

    // MARK: - 设置窗口

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show()
    }

    @objc private func restartIsland() {
        // 不能在本进程里直接 open：旧实例还在，单实例守卫会把新实例劝退。
        // 交给一个独立 shell：等当前 PID 真正退出后，再 open -n 同一个 bundle。
        let bundle = Bundle.main.bundlePath
        let quoted = bundle.replacingOccurrences(of: "'", with: "'\\''")
        let pid = ProcessInfo.processInfo.processIdentifier
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", """
            i=0
            while [ "$i" -lt 50 ]; do
                kill -0 \(pid) 2>/dev/null || break
                sleep 0.2
                i=$((i + 1))
            done
            sleep 0.4
            /usr/bin/open -n '\(quoted)'
            """]
        relauncher.standardOutput = FileHandle.nullDevice
        relauncher.standardError = FileHandle.nullDevice
        try? relauncher.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 演示

    func showDemo() {
        pinned = true
        show()
    }

    // MARK: - 菜单栏入口（AppDelegate 的菜单调用）

    var isPinnedForMenu: Bool { pinned }
    /// 菜单栏「窗口」菜单用：即使当前没有 key window 也能拿到设置窗口
    var preferencesWindow: NSWindow? { settingsWindow?.window }
    @objc func togglePinForMenu() { togglePin() }
    @objc func arrangeGridForMenu() { CanvasLayout.shared.arrangeGrid() }
    @objc func checkForUpdatesForMenu() { UpdateService.shared.present() }
    @objc func refreshForMenu() {
        refreshCapsule()
        barView.needsDisplay = true
        floatingBar?.needsDisplay = true
        // 用户点了「刷新胶囊」：重扫菜单栏槽位并按当前形态重排（状态项增删后手动纠位）
        scheduleSlotRescanIfNeeded(force: true)
        applyForm()
    }
    @objc func restartForMenu() { restartIsland() }

    func openPreferences() { openSettings() }

    /// 滚轮翻页自检：进程内直接把合成 NSEvent 喂给 background.scrollWheel，
    /// 同时覆盖两条路径——机械滚轮（行单位，一格一页）与触控板（像素，累积 12pt）。
    /// （系统级 CGEvent 合成 scroll 在 macOS 27 上不投递，HID/session/postToPid 三路均实测无效；
    ///   窗口 server → NSView 的真实投递由 v1.2.0 起的真机触控板覆盖。）
    func runScrollSelfTest() {
        pinned = true
        show()
        // 起点归位概览页（page 会持久化，上次测试可能停在别的页）：
        // 这样第 2 发若 gestureTurned 失效会从剪贴板跳到暂存，与「被挡住」形成明确区分
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.store.go(to: .overview)
        }
        let feed: [(Double, Double, Bool, String)] = [
            (0.45, -1, true,  "滚轮 1 格（-1 行，最小幅度）→ 必须翻页"),
            (0.90, -3, true,  "再过一格（-3 行）→ 已在最后一页，应停在暂存"),
            (0.50, -1, true,  "同一格的重复事件（间隔 0.05s）→ 应被冷却挡住"),
            (1.45, +1, true,  "反向 1 格 → 应往回翻"),
            (2.20, -6, false, "触控板 -6pt（低于 8pt 阈值）→ 不动"),
            (2.32, -8, false, "触控板再 -8pt（累积 -14）→ 应翻到暂存")
        ]
        for (delay, delta, isLine, label) in feed {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: isLine ? .line : .pixel,
                                 wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)!
                let ev = NSEvent(cgEvent: cg)!
                NSLog("Isla selftest | \(label) | precise=\(ev.hasPreciseScrollingDeltas) dy=\(ev.scrollingDeltaY) | before page=\(self.store.page.rawValue)")
                self.background.scrollWheel(with: ev)
                DispatchQueue.main.async {
                    NSLog("Isla selftest | after page=\(self.store.page.rawValue) panel=\(self.panel.frame.size)")
                }
            }
        }
    }
}

// MARK: - 菜单栏图标菜单的勾选状态

extension IslandController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(togglePinForMenu):
            menuItem.title = pinned ? "取消钉住面板" : "钉住面板"
            menuItem.state = pinned ? .on : .off
        case #selector(setFormFromMenu(_:)):
            menuItem.state = settings.form.rawValue == (menuItem.representedObject as? String) ? .on : .off
        case #selector(setThemeFromMenu(_:)):
            menuItem.state = settings.appIcon.rawValue == (menuItem.representedObject as? String) ? .on : .off
        case #selector(toggleModuleFromMenu(_:)):
            let all = WidgetRegistry.descriptors
            guard all.indices.contains(menuItem.tag) else { return false }
            menuItem.state = settings.isEnabled(all[menuItem.tag].id) ? .on : .off
        default:
            break
        }
        return true
    }
}

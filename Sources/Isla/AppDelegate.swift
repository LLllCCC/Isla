import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?
    private var settingsObserver: NSObjectProtocol?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Brand.migrateLegacyDefaults()
        if handleMaintenanceArguments() { return }
        if enforceSingleInstance() { return }

        PluginManager.shared.scan()
        let c = IslandController()
        controller = c
        applyActivationPolicy()
        applyAppIcon(SettingsStore.shared.appIcon)
        SettingsStore.shared.$appIcon
            .removeDuplicates()
            .sink { [weak self] style in self?.applyAppIcon(style) }
            .store(in: &bag)
        // 「跟随设备」：系统深浅色切换时（含手动切换与日落定时）重新解析图标。
        // 通知到达的瞬间 effectiveAppearance 可能尚未翻转，稍等再应用并补一拍兜底。
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard SettingsStore.shared.appIcon == .auto else { return }
            self?.applyAppIcon(.auto)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.applyAppIcon(.auto)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .islaRestartRequested, object: nil, queue: .main
        ) { [weak self] _ in self?.controller?.restartForMenu() }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .islandSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        }
        showFirstRunGuideIfNeeded()
        let skipUpdateCheck = CommandLine.arguments.contains("--dump-state")
            || CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--demo")
        if !skipUpdateCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                UpdateService.shared.autoCheckIfNeeded()
            }
        }
        if CommandLine.arguments.contains("--demo") || UserDefaults.standard.bool(forKey: "demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { c.showDemo() }
        }
        if CommandLine.arguments.contains("--settings") || UserDefaults.standard.bool(forKey: "openSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { c.openPreferences() }
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { c.runScrollSelfTest() }
        }
        // 维护/验收用：启动后直接打开更新窗口（可配合 ISLA_UPDATE_URL 指向本地 appcast）
        if CommandLine.arguments.contains("--update-now") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { UpdateService.shared.present() }
        }
        // 多屏/贴边排查：等状态项、AX 扫描与浮层都落位后打印内部几何，然后退出。
        // 6s：AX 扫描要遍历所有 App，实机 3-5s，太早打印会看到 nil 快照。
        if CommandLine.arguments.contains("--dump-state") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                print(c.dumpGeometry())
                exit(0)
            }
        }
    }

    /// 首次启动引导：只弹一次。自动化验收（--demo/--selftest/--verify）不弹，
    /// 已经授权辅助功能也不打扰。
    private func showFirstRunGuideIfNeeded() {
        let d = UserDefaults.standard
        let skip = CommandLine.arguments.contains("--demo")
            || CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--verify")
        guard !skip, !d.bool(forKey: "didShowFirstRunGuide") else { return }
        d.set(true, forKey: "didShowFirstRunGuide")
        guard !MenuBarScanner.isTrusted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = "欢迎使用 Isla"
            a.informativeText = """
            悬停菜单栏胶囊：展开面板
            点菜单栏右侧的三根竖条：设置、钉住、模块开关
            左键点胶囊：钉住 / 取消钉住

            「居中避让」和播放器快速探测需要辅助功能权限；不授权也能用，只是这两项会退化。
            """
            a.addButton(withTitle: "授予辅助功能权限")
            a.addButton(withTitle: "打开设置")
            a.addButton(withTitle: "稍后")
            switch a.runModal() {
            case .alertFirstButtonReturn:
                MenuBarScanner.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            case .alertSecondButtonReturn:
                self.controller?.openPreferences()
            default:
                break
            }
        }
    }

    /// 系统当前是否深色外观（「跟随设备」解析用）
    static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 切换 Dock / 设置页头部显示的图标。auto 按系统外观解析成深色/浅色；
    /// 浅色外观必须用浅色图标，其余保持 dark→AppIcon、light→AppIconLight 的映射。
    private func applyAppIcon(_ style: AppIconStyle) {
        let resolved = style.resolved
        guard let url = Bundle.main.url(forResource: resolved.resource, withExtension: "icns"),
              let img = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = img
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 从 Dock / Cmd-Tab 回到 App：把面板钉住展示出来（没有窗口时 Dock 点击会走到这里）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点 Dock 图标 = 打开设置（面板有单独的入口：胶囊悬停 / 快捷键）
        sender.activate(ignoringOtherApps: true)
        controller?.openPreferences()
        return true
    }

    // MARK: - Dock / 激活策略

    private func applyActivationPolicy() {
        let regular = SettingsStore.shared.showInDock
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
        if regular { installMainMenuIfNeeded() }
    }

    /// 有 Dock 图标就必须有一套完整主菜单：应用 / 文件 / 编辑 / 查看 / 窗口 / 帮助。
    /// 胶囊右键菜单里的功能也全部搬到这里（右键菜单已移除）。
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        // MARK: 应用菜单
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        main.addItem(appItem)

        appMenu.addItem(withTitle: "关于 Isla",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let updateItem = NSMenuItem(localizedTitle: "检查更新…",
                                    action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())

        let show = NSMenuItem(localizedTitle: "显示面板", action: #selector(showPanelFromMenu), keyEquivalent: "")
        show.target = self
        appMenu.addItem(show)
        let settingsItem = NSMenuItem(localizedTitle: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(localizedTitle: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "隐藏 Isla",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Isla",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // MARK: 文件
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let newPlan = NSMenuItem(localizedTitle: "新建计划…", action: #selector(newPlanFromMenu), keyEquivalent: "n")
        newPlan.target = self
        fileMenu.addItem(newPlan)
        let openSettings = NSMenuItem(localizedTitle: "打开设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        openSettings.target = self
        fileMenu.addItem(openSettings)
        fileMenu.addItem(.separator())
        let close = NSMenuItem(localizedTitle: "关闭窗口", action: #selector(closeWindowFromMenu), keyEquivalent: "w")
        close.target = self
        fileMenu.addItem(close)

        // MARK: 编辑
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        main.addItem(editItem)

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // MARK: 查看
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "查看")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let pin = NSMenuItem(localizedTitle: "钉住面板", action: #selector(togglePinFromMenu), keyEquivalent: "")
        pin.target = self
        viewMenu.addItem(pin)

        let formParent = NSMenuItem(localizedTitle: "胶囊形态", action: nil, keyEquivalent: "")
        let formMenu = NSMenu(title: "胶囊形态")
        for f in IslandForm.allCases {
            let it = NSMenuItem(localizedTitle: f.title, action: #selector(setFormFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f.rawValue
            formMenu.addItem(it)
        }
        formParent.submenu = formMenu
        viewMenu.addItem(formParent)

        let themeParent = NSMenuItem(localizedTitle: "图标与主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "图标与主题")
        for t in AppIconStyle.allCases {
            let it = NSMenuItem(localizedTitle: t.title, action: #selector(setThemeFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.rawValue
            themeMenu.addItem(it)
        }
        themeParent.submenu = themeMenu
        viewMenu.addItem(themeParent)

        let modulesParent = NSMenuItem(localizedTitle: "显示模块", action: nil, keyEquivalent: "")
        let modulesMenu = NSMenu(title: "显示模块")
        for (i, d) in WidgetRegistry.descriptors.enumerated() {
            let it = NSMenuItem(localizedTitle: d.title, action: #selector(toggleModuleFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            modulesMenu.addItem(it)
        }
        modulesParent.submenu = modulesMenu
        viewMenu.addItem(modulesParent)
        viewMenu.addItem(.separator())

        let refresh = NSMenuItem(localizedTitle: "刷新胶囊", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        viewMenu.addItem(refresh)
        let restart = NSMenuItem(localizedTitle: "重启胶囊", action: #selector(restartFromMenu), keyEquivalent: "")
        restart.target = self
        viewMenu.addItem(restart)

        // MARK: 窗口
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let mini = NSMenuItem(localizedTitle: "最小化", action: #selector(minimizeWindowFromMenu), keyEquivalent: "m")
        mini.target = self
        windowMenu.addItem(mini)
        let zoom = NSMenuItem(localizedTitle: "缩放", action: #selector(zoomWindowFromMenu), keyEquivalent: "")
        zoom.target = self
        windowMenu.addItem(zoom)
        windowMenu.addItem(.separator())
        let front = NSMenuItem(localizedTitle: "前置全部窗口", action: #selector(frontAllFromMenu), keyEquivalent: "")
        front.target = self
        windowMenu.addItem(front)
        NSApp.windowsMenu = windowMenu

        // MARK: 帮助
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        let help = NSMenuItem(localizedTitle: "Isla 帮助", action: #selector(showHelpFromMenu), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(help)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    // MARK: 菜单动作

    @objc private func showPanelFromMenu() { controller?.showDemo() }
    @objc private func openSettingsFromMenu() { controller?.openPreferences() }
    @objc private func checkForUpdatesFromMenu() { UpdateService.shared.present() }
    @objc private func togglePinFromMenu() { controller?.togglePinForMenu() }
    @objc private func refreshFromMenu() { controller?.refreshForMenu() }
    @objc private func restartFromMenu() { controller?.restartForMenu() }

    private var targetWindow: NSWindow? { controller?.preferencesWindow ?? NSApp.keyWindow }
    @objc private func minimizeWindowFromMenu() { targetWindow?.performMiniaturize(nil) }
    @objc private func zoomWindowFromMenu() { targetWindow?.performZoom(nil) }
    @objc private func closeWindowFromMenu() { targetWindow?.performClose(nil) }
    @objc private func frontAllFromMenu() { NSApp.arrangeInFront(nil) }

    @objc private func setFormFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let f = IslandForm(rawValue: raw) else { return }
        SettingsStore.shared.form = f
    }

    @objc private func setThemeFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = AppIconStyle(rawValue: raw) else { return }
        SettingsStore.shared.appIcon = t
    }

    @objc private func toggleModuleFromMenu(_ sender: NSMenuItem) {
        let all = WidgetRegistry.descriptors
        guard all.indices.contains(sender.tag) else { return }
        let d = all[sender.tag]
        SettingsStore.shared.setEnabled(d.id, !SettingsStore.shared.isEnabled(d.id))
    }

    @objc private func newPlanFromMenu() {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        SettingsStore.shared.plans.append(PlanItem(title: "新计划", date: date))
        SettingsNav.shared.tab = .study
        controller?.openPreferences()
    }

    @objc private func showHelpFromMenu() {
        let a = NSAlert()
        a.messageText = "Isla 帮助"
        a.informativeText = """
        悬停菜单栏胶囊：展开面板
        左键点胶囊：钉住 / 取消钉住面板
        ⌥⌘Space：钉住面板
        ⌘,：打开设置
        ⌘N：新建计划
        ⌘R：刷新胶囊

        设置页顶部可以搜索所有选项；胶囊右键菜单已移到本菜单栏。
        """
        a.addButton(withTitle: "好")
        a.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 把今日专注统计落盘，避免强退丢最后一段
        PomodoroService.shared.flush()
        // 宿主是独立子进程，退出时显式收掉，避免留下孤儿进程。
        PluginRuntime.shared.stop()
    }

    // MARK: - 维护用 CLI（不建 UI，执行完即退出）
    //   --set-login on|off   注册 / 注销登录项（必须从 /Applications 下的 App 运行）
    //   --login-status       打印当前登录项状态
    //   --dump-state         打印屏幕/状态项/胶囊/面板/AX 快照（建 UI，6s 后退出）

    // MARK: - 单实例

    /// 同一 bundle 被直接启动第二次时，激活已有实例并退出本进程。
    /// 开发/并行验证需要两个实例时显式传 `--allow-multiple`；不同 bundle id 的测试包不受影响。
    private func enforceSingleInstance() -> Bool {
        guard !CommandLine.arguments.contains("--allow-multiple"),
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current && !$0.isTerminated }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateIgnoringOtherApps])
        NSApp.terminate(nil)
        return true
    }

    // MARK: - 维护参数

    private func handleMaintenanceArguments() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--set-login") {
            let on = i + 1 < args.count && args[i + 1].lowercased() == "on"
            do {
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                FileHandle.standardError.write(Data("login-item error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            print("login-item: \(describe(SMAppService.mainApp.status))")
            NSApp.terminate(nil)
            return true
        }
        if args.contains("--login-status") {
            print("login-item: \(describe(SMAppService.mainApp.status))")
            NSApp.terminate(nil)
            return true
        }
        if let i = args.firstIndex(of: "--install-sample"), i + 1 < args.count {
            let name = args[i + 1]
            do {
                try PluginManager.shared.installSample(name, overwrite: true, confirmPermissions: false)
                print("installed sample: \(name)")
                exit(0)
            } catch {
                print("install failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.contains("--l10n-check") {
            print("preferred=\(Bundle.main.preferredLocalizations)")
            print("localizations=\(Bundle.main.localizations)")
            for key in ["通用", "岛所在的屏幕", "Launch & display", "登录时启动"] {
                print("\(key) -> \(L(key))")
            }
            exit(0)
        }
        if args.contains("--ax-status") {
            print("ax-trusted: \(MenuBarScanner.isTrusted)")
            print("form: \(SettingsStore.shared.form.rawValue)  placement: \(SettingsStore.shared.centeredPlacement.rawValue)")
            exit(0)
        }
        if args.contains("--arrange-layout") {
            CanvasLayout.shared.arrange()
            print("canvas: \(Int(CanvasLayout.shared.canvasW))×\(Int(CanvasLayout.shared.canvasH))")
            exit(0)
        }
        return false
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:          return "enabled"
        case .notRegistered:    return "notRegistered"
        case .notFound:         return L("notFound（App 不在 /Applications？）")
        case .requiresApproval: return L("requiresApproval（需在系统设置里允许）")
        @unknown default:       return "unknown(\(status.rawValue))"
        }
    }
}

// MARK: - 菜单校验（勾选状态 / 可用性）

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(togglePinFromMenu):
            let pinned = controller?.isPinnedForMenu ?? false
            menuItem.title = pinned ? "取消钉住面板" : "钉住面板"
            menuItem.state = pinned ? .on : .off
        case #selector(setFormFromMenu(_:)):
            menuItem.state = SettingsStore.shared.form.rawValue == (menuItem.representedObject as? String) ? .on : .off
        case #selector(setThemeFromMenu(_:)):
            menuItem.state = SettingsStore.shared.appIcon.rawValue == (menuItem.representedObject as? String) ? .on : .off
        case #selector(toggleModuleFromMenu(_:)):
            let all = WidgetRegistry.descriptors
            guard all.indices.contains(menuItem.tag) else { return false }
            menuItem.state = SettingsStore.shared.isEnabled(all[menuItem.tag].id) ? .on : .off
        default:
            break
        }
        return true
    }
}

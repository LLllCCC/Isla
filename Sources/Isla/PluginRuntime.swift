import Foundation
import AppKit
import Combine

/// 插件宿主进程的客户端：负责启动 `IslaPluginHost`、发送 JSON-RPC、
/// 接收渲染树与失效通知。宿主是独立进程，插件死循环/崩溃不会拖死主 App。
final class PluginRuntime: ObservableObject {
    static let shared = PluginRuntime()

    /// 渲染树缓存，key = "pluginID/pageID"
    @Published private(set) var trees: [String: PluginNode] = [:]
    /// 概览卡片渲染树，key = "pluginID/cardID"
    @Published private(set) var cardTrees: [String: PluginNode] = [:]
    /// 插件胶囊文本，key = "plugin.<插件id>.<模式id>"
    @Published private(set) var capsuleTexts: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var cardErrors: [String: String] = [:]
    /// 宿主通知插件需要重绘时 +1；页面视图监听它重新请求渲染。
    @Published private(set) var invalidation = 0
    /// 渲染树更新（成功或失败）时 +1，驱动视图刷新。
    @Published private(set) var treeRevision = 0
    /// 插件加载完成时 +1；页面视图据此补发渲染请求。
    @Published private(set) var loadRevision = 0

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var loaded: Set<String> = []
    private var rendering: Set<String> = []
    private var pendingRenders = Set<String>()
    private var pendingCards = Set<String>()
    private var pendingCapsules = Set<String>()
    private var isStopping = false
    private var restartTimes: [Date] = []
    private var clipboardSink: AnyCancellable?
    private let ioQueue = DispatchQueue(label: "com.yopo.isla.plugin.runtime")

    var loadedIDs: Set<String> { loaded }

    private init() {
        // 剪贴板历史变化时同步给宿主；插件页会收到 invalidate 后自动重绘。
        clipboardSink = ClipboardService.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncClipboard() }
    }

    // MARK: 生命周期

    private func ensureHost() -> Bool {
        if let p = process, p.isRunning { return true }
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "IslaPluginHost"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return false
        }
        let p = Process()
        p.executableURL = url
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.process = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.loaded.removeAll()
                let error = NSError(domain: "IslaPlugin", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: L("插件宿主已退出")])
                for (_, cb) in self.pending { cb(.failure(error)) }
                self.pending.removeAll()
                if !self.isStopping { self.autoRestart() }
            }
        }
        do {
            try p.run()
        } catch {
            return false
        }
        process = p
        stdinPipe = inPipe
        stdoutPipe = outPipe
        return true
    }

    func stop() {
        isStopping = true
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        loaded.removeAll()
        pending.removeAll()
        cardTrees.removeAll()
        cardErrors.removeAll()
        capsuleTexts.removeAll()
    }

    /// 宿主崩溃或超时：限频重启，并让 PluginManager 重新加载启用插件。
    private func autoRestart() {
        guard !isStopping else { return }
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 60 }
        guard restartTimes.count < 3 else {
            errors["host"] = L("插件宿主多次异常退出，已暂停自动重启；请检查插件或重新扫描")
            treeRevision += 1
            return
        }
        restartTimes.append(now)

        isStopping = true
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        loaded.removeAll()
        pending.removeAll()
        trees.removeAll()
        cardTrees.removeAll()
        errors.removeAll()
        cardErrors.removeAll()
        capsuleTexts.removeAll()
        rendering.removeAll()
        pendingRenders.removeAll()
        pendingCards.removeAll()
        pendingCapsules.removeAll()
        treeRevision += 1
        isStopping = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            PluginManager.shared.scan()
        }
    }

    // MARK: 请求

    private func send(_ method: String, _ params: [String: Any],
                      timeout: TimeInterval = 2.0,
                      completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard ensureHost(), let stdin = stdinPipe else {
            let error = NSError(domain: "IslaPlugin", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: L("插件宿主不可用")])
            completion?(.failure(error))
            return
        }
        let id = nextID
        nextID += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        payload["jsonrpc"] = "2.0"
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(.failure(NSError(domain: "IslaPlugin", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: L("请求序列化失败")])))
            return
        }
        if let completion {
            pending[id] = completion
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.ioQueue.async {
                    guard let cb = self.pending.removeValue(forKey: id) else { return }
                    let error = NSError(domain: "IslaPlugin", code: 4,
                                        userInfo: [NSLocalizedDescriptionKey: L("插件响应超时")])
                    DispatchQueue.main.async {
                        cb(.failure(error))
                        self.autoRestart()
                    }
                }
            }
        }
        var line = data
        line.append(0x0A)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: line)
        } catch {
            completion?(.failure(error))
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<newline)
            buffer.removeSubrange(0...newline)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int {
            let cb = pending.removeValue(forKey: id)
            if let cb { DispatchQueue.main.async { cb(.success(obj)) } }
            return
        }
        guard let method = obj["method"] as? String else { return }
        switch method {
        case "invalidate":
            DispatchQueue.main.async {
                self.invalidation += 1
                self.refreshCapsuleModes()
            }
        case "clipboardCommand":
            let params = obj["params"] as? [String: Any] ?? [:]
            guard let action = params["action"] as? String,
                  let raw = params["id"] as? String,
                  let id = UUID(uuidString: raw) else { return }
            DispatchQueue.main.async {
                switch action {
                case "copy":
                    ClipboardService.shared.copy(id: id)
                case "pin":
                    ClipboardService.shared.setPinned(id, params["pinned"] as? Bool ?? true)
                    self.syncClipboard()
                case "remove":
                    ClipboardService.shared.remove(id)
                default:
                    break
                }
                self.invalidation += 1
            }
        case "log":
            // 宿主自己写日志文件；这里只保留通知入口，避免重复写两份。
            break
        default:
            break
        }
    }

    // MARK: 插件操作

    /// 插件看到的语言（zh-Hans / en…），供插件自己决定文案
    static var currentLocale: String {
        (Locale.preferredLanguages.first ?? "zh-Hans")
    }

    func load(pluginID: String, directory: URL, manifest: PluginManifest) {
        guard !loaded.contains(pluginID) else { return }
        let logURL = Self.logURL(pluginID)
        let params: [String: Any] = [
            "pluginID": pluginID,
            "directory": directory.path,
            "main": manifest.main,
            "permissions": manifest.permissions ?? [],
            "canPublish": manifest.events?.publish ?? [],
            "canSubscribe": manifest.events?.subscribe ?? [],
            "logPath": logURL.path,
            // 宿主是独立进程，拿不到 App 的 AppleLanguages 覆盖，语言从这边传过去
            "locale": Self.currentLocale
        ]
        send("load", params, timeout: 3.0) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.loaded.insert(pluginID)
                    self?.loadRevision += 1
                    self?.syncClipboard()
                    self?.flushPendingRenders(pluginID)
                    self?.flushPendingCards(pluginID)
                    self?.flushPendingCapsules(pluginID)
                    self?.refreshCapsuleModes()
                case .failure(let error):
                    self?.errors["\(pluginID)/*"] = error.localizedDescription
                    let prefix = "\(pluginID)/"
                    for key in self?.pendingRenders.filter({ $0.hasPrefix(prefix) }) ?? [] {
                        self?.errors[key] = error.localizedDescription
                        self?.pendingRenders.remove(key)
                    }
                    self?.treeRevision += 1
                }
            }
        }
    }

    /// 热重载：先卸载再加载，页面/卡片/胶囊视图会在 loadRevision 变化后自动重绘。
    func reload(pluginID: String, directory: URL, manifest: PluginManifest) {
        unload(pluginID: pluginID)
        load(pluginID: pluginID, directory: directory, manifest: manifest)
    }

    private func flushPendingRenders(_ pluginID: String) {
        let prefix = "\(pluginID)/"
        let keys = pendingRenders.filter { $0.hasPrefix(prefix) }
        pendingRenders.subtract(keys)
        for key in keys {
            let pageID = String(key.dropFirst(prefix.count))
            render(pluginID: pluginID, pageID: pageID)
        }
    }

    private func flushPendingCards(_ pluginID: String) {
        let prefix = "\(pluginID)/"
        let keys = pendingCards.filter { $0.hasPrefix(prefix) }
        pendingCards.subtract(keys)
        for key in keys {
            let cardID = String(key.dropFirst(prefix.count))
            renderCard(pluginID: pluginID, cardID: cardID)
        }
    }

    func unload(pluginID: String) {
        guard loaded.contains(pluginID) else { return }
        send("unload", ["pluginID": pluginID])
        loaded.remove(pluginID)
        let prefix = "\(pluginID)/"
        trees = trees.filter { !$0.key.hasPrefix(prefix) }
        cardTrees = cardTrees.filter { !$0.key.hasPrefix(prefix) }
        let capsulePrefix = "plugin.\(pluginID)."
        capsuleTexts = capsuleTexts.filter { !$0.key.hasPrefix(capsulePrefix) }
        errors = errors.filter { !$0.key.hasPrefix(prefix) }
        cardErrors = cardErrors.filter { !$0.key.hasPrefix(prefix) }
        pendingRenders = pendingRenders.filter { !$0.hasPrefix(prefix) }
        pendingCards = pendingCards.filter { !$0.hasPrefix(prefix) }
        pendingCapsules = pendingCapsules.filter { !$0.hasPrefix(capsulePrefix) }
        treeRevision += 1
    }

    func render(pluginID: String, pageID: String) {
        let key = "\(pluginID)/\(pageID)"
        guard !rendering.contains(key) else { return }
        guard loaded.contains(pluginID) else {
            // 宿主还在加载：先记下来，load 成功后会补发。
            pendingRenders.insert(key)
            return
        }
        rendering.insert(key)
        send("render", ["pluginID": pluginID, "pageID": pageID]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering.remove(key)
                switch result {
                case .success(let obj):
                    if let resultObj = obj["result"] as? [String: Any],
                       let tree = resultObj["tree"] as? [String: Any],
                       let data = try? JSONSerialization.data(withJSONObject: tree),
                       let node = try? JSONDecoder().decode(PluginNode.self, from: data) {
                        self.trees[key] = node
                        self.errors.removeValue(forKey: key)
                    } else if let err = (obj["error"] as? [String: Any])?["message"] as? String {
                        self.errors[key] = err
                    } else {
                        self.errors[key] = L("渲染树解析失败")
                    }
                case .failure(let error):
                    self.errors[key] = error.localizedDescription
                }
                self.treeRevision += 1
            }
        }
    }

    /// 概览卡片渲染：与页面渲染走同一套请求/缓存，key 前缀避免与页面 id 冲突。
    func renderCard(pluginID: String, cardID: String) {
        let key = "\(pluginID)/\(cardID)"
        guard !rendering.contains("card:\(key)") else { return }
        guard loaded.contains(pluginID) else {
            pendingCards.insert(key)
            return
        }
        rendering.insert("card:\(key)")
        send("renderCard", ["pluginID": pluginID, "cardID": cardID]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering.remove("card:\(key)")
                switch result {
                case .success(let obj):
                    if let resultObj = obj["result"] as? [String: Any],
                       let tree = resultObj["tree"] as? [String: Any],
                       let data = try? JSONSerialization.data(withJSONObject: tree),
                       let node = try? JSONDecoder().decode(PluginNode.self, from: data) {
                        self.cardTrees[key] = node
                        self.cardErrors.removeValue(forKey: key)
                    } else if let err = (obj["error"] as? [String: Any])?["message"] as? String {
                        self.cardErrors[key] = err
                    } else {
                        self.cardErrors[key] = L("卡片渲染树解析失败")
                    }
                case .failure(let error):
                    self.cardErrors[key] = error.localizedDescription
                }
                self.treeRevision += 1
            }
        }
    }

    func card(pluginID: String, cardID: String) -> PluginNode? {
        cardTrees["\(pluginID)/\(cardID)"]
    }

    func cardError(pluginID: String, cardID: String) -> String? {
        cardErrors["\(pluginID)/\(cardID)"]
    }

    // MARK: - 插件胶囊

    /// 渲染一个胶囊模式；结果是一段文本，主 App 直接画进胶囊。
    func renderCapsule(pluginID: String, modeID: String) {
        let key = "plugin.\(pluginID).\(modeID)"
        guard !rendering.contains("capsule:\(key)") else { return }
        guard loaded.contains(pluginID) else {
            pendingCapsules.insert(key)
            return
        }
        rendering.insert("capsule:\(key)")
        send("renderCapsule", ["pluginID": pluginID, "capsuleID": modeID]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering.remove("capsule:\(key)")
                switch result {
                case .success(let obj):
                    if let capsule = (obj["result"] as? [String: Any])?["capsule"] as? [String: Any],
                       let text = capsule["text"] as? String {
                        self.capsuleTexts[key] = text
                    }
                case .failure:
                    break
                }
            }
        }
    }

    /// 刷新所有已注册的胶囊模式。剪贴板变化、插件加载、宿主 invalidate 后调用。
    func refreshCapsuleModes() {
        for mode in PluginManager.shared.capsuleModes {
            renderCapsule(pluginID: mode.pluginID, modeID: mode.modeID)
        }
    }

    func capsuleText(for descriptorID: String) -> String? {
        capsuleTexts[descriptorID]
    }

    private func flushPendingCapsules(_ pluginID: String) {
        let prefix = "plugin.\(pluginID)."
        let keys = pendingCapsules.filter { $0.hasPrefix(prefix) }
        pendingCapsules.subtract(keys)
        for key in keys {
            let modeID = String(key.dropFirst(prefix.count))
            renderCapsule(pluginID: pluginID, modeID: modeID)
        }
    }

    func invoke(pluginID: String, command: String, value: Any? = nil) {
        var params: [String: Any] = ["pluginID": pluginID, "command": command]
        if let value { params["value"] = value }
        send("invoke", params)
    }

    /// 把主 App 的剪贴板历史推给宿主。图片/文件只推 preview，
    /// 文本条目带全文，插件用它做回填。
    func syncClipboard() {
        guard !loaded.isEmpty else { return }
        let items: [[String: Any]] = ClipboardService.shared.items.map { item in
            let kind: String
            switch item.kind {
            case .text:  kind = "text"
            case .image: kind = "image"
            case .files: kind = "files"
            }
            return [
                "id": item.id.uuidString,
                "kind": kind,
                "preview": item.preview,
                "text": item.text ?? "",
                "pinned": ClipboardService.shared.isPinned(item.id)
            ]
        }
        let current = NSPasteboard.general.string(forType: .string) ?? ""
        send("clipboardSync", ["items": items, "current": current])
    }

    func tree(pluginID: String, pageID: String) -> PluginNode? {
        trees["\(pluginID)/\(pageID)"]
    }

    func error(pluginID: String, pageID: String) -> String? {
        errors["\(pluginID)/\(pageID)"] ?? errors["\(pluginID)/*"]
    }

    // MARK: 日志

    static func logURL(_ pluginID: String) -> URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(Brand.supportFolder, isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("\(pluginID).log")
    }
}

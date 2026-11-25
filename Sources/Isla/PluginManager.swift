import Foundation
import Combine
import AppKit
import CoreGraphics
import CryptoKit

// MARK: - Manifest

/// 插件清单（manifest.json）。字段保持宽松可选：缺省项走默认值，
/// 未知权限/不兼容版本会被 PluginManager 拒绝并显示原因。
struct PluginManifest: Codable, Equatable {
    struct ContributionPage: Codable, Equatable {
        var id: String
        var title: String
        /// 英文标题（可选）；英文界面优先用它，缺省回退 title
        var titleEn: String?
        var icon: String?
        /// "js"（默认，声明式渲染）或 "web"（WKWebView 自定义页）
        var kind: String?
        /// kind=web 时的入口 HTML，相对插件目录，例如 web/index.html
        var entry: String?
        var preferredHeight: CGFloat?
    }

    struct ContributionCard: Codable, Equatable {
        struct Size: Codable, Equatable {
            var w: CGFloat
            var h: CGFloat
        }
        var id: String
        var title: String
        var titleEn: String?
        var defaultSize: Size?
    }

    struct ContributionCommand: Codable, Equatable {
        var id: String
        var title: String
        var titleEn: String?
    }

    struct ContributionCapsule: Codable, Equatable {
        var id: String
        var title: String
        var titleEn: String?
    }

    struct Contributes: Codable, Equatable {
        var pages: [ContributionPage]?
        var panelCards: [ContributionCard]?
        var capsuleModes: [ContributionCapsule]?
        var commands: [ContributionCommand]?
    }

    struct EventSpec: Codable, Equatable {
        var publish: [String]?
        var subscribe: [String]?
    }

    var id: String
    var name: String
    /// 英文名称 / 描述（可选）。英文界面优先，缺省回退中文原文。
    var nameEn: String?
    var version: String
    var description: String?
    var descriptionEn: String?
    var minAppVersion: String?
    /// 插件 API 版本（缺省 1）。将来桥协议破坏性升级时用它挡老 App。
    var apiVersion: Int?
    var main: String
    var icon: String?
    var permissions: [String]?
    var contributes: Contributes?
    var events: EventSpec?
}

extension PluginManifest {
    /// 英文界面时优先用 *En 字段；缺失就回退中文，保证老插件照常工作。
    static var isEnglishUI: Bool { isEnglishUIEnabled }

    func localized(_ base: String, _ en: String?) -> String {
        guard Self.isEnglishUI, let en, !en.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        return en
    }

    var localizedName: String { localized(name, nameEn) }
    var localizedDescription: String? {
        guard let description else { return nil }
        return localized(description, descriptionEn)
    }
}

// MARK: - Record

/// 插件注册的胶囊模式。id 形如 `plugin.<插件id>.<模式id>`。
struct PluginCapsuleMode: Identifiable, Equatable {
    let id: String
    let pluginID: String
    let modeID: String
    let title: String
}

/// 插件注册的命令。id 形如 `plugin.<插件id>.<命令id>`。
struct PluginCommandRef: Identifiable, Equatable {
    let id: String
    let pluginID: String
    let commandID: String
    let title: String
}

struct PluginRecord: Identifiable, Equatable {
    let directory: URL
    let manifest: PluginManifest?
    /// 安装/校验失败原因；有值时不允许启用。
    let error: String?
    var enabled: Bool
    /// 安装时记录的 SHA-256 与当前文件对比结果。
    let integrity: PluginIntegrity
    let hash: String?

    var id: String { manifest?.id ?? directory.lastPathComponent }
    var name: String { manifest?.localizedName ?? directory.lastPathComponent }
    var permissions: [String] { manifest?.permissions ?? [] }
    var version: String { manifest?.version ?? "?" }
    var isUsable: Bool { manifest != nil && error == nil }
}

/// 插件文件完整性。
enum PluginIntegrity: String, Equatable {
    /// 与安装时记录的 SHA-256 一致。
    case ok
    /// 安装后文件被修改（开发热重载 / 手动改动 / 被篡改）。
    case changed
    /// 旧安装没有记录过 hash（升级到本版本之前装的）。
    case unrecorded
}

/// 权限说明：用于安装确认、插件行和权限总览。
struct PluginPermissionInfo: Identifiable, Equatable {
    enum Risk: Equatable {
        case normal
        case sensitive
    }
    let id: String
    let title: String
    let detail: String
    let risk: Risk
}

/// 权限总览的一行：某个权限被哪些插件使用。
struct PluginPermissionUsage: Identifiable, Equatable {
    let info: PluginPermissionInfo
    let pluginNames: [String]
    var id: String { info.id }
}

// MARK: - Manager

final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    static let permissionCatalog: [PluginPermissionInfo] = [
        .init(id: "clipboard", title: "剪贴板", detail: "读取和写入剪贴板内容", risk: .sensitive),
        .init(id: "shelf", title: "暂存架", detail: "读写拖到胶囊上的文件路径", risk: .normal),
        .init(id: "storage", title: "本地存储", detail: "在插件自己的目录里保存数据", risk: .normal),
        .init(id: "notifications", title: "通知", detail: "发送系统通知", risk: .normal),
        .init(id: "network", title: "网络", detail: "访问网络；未声明时宿主会拦截所有 http(s) 请求", risk: .sensitive),
        .init(id: "nowplaying", title: "正在播放", detail: "读取当前播放的歌曲信息", risk: .normal),
        .init(id: "lyrics", title: "歌词", detail: "读取当前歌曲的歌词", risk: .normal),
        .init(id: "files", title: "文件", detail: "通过系统文件选择器访问你选择的文件", risk: .sensitive)
    ]
    static var supportedPermissions: [String] { permissionCatalog.map(\.id) }
    static func permissionInfo(_ id: String) -> PluginPermissionInfo? {
        permissionCatalog.first { $0.id == id }
    }

    @Published private(set) var plugins: [PluginRecord] = []
    /// 启用插件注册的胶囊模式（设置页选择、胶囊渲染用）。
    @Published private(set) var capsuleModes: [PluginCapsuleMode] = []
    /// 启用插件注册的命令（菜单 / 命令入口）。
    @Published private(set) var pluginCommands: [PluginCommandRef] = []
    /// 每次注册表变化 +1；PanelContent / 设置页读它来触发重绘。
    @Published private(set) var revision = 0
    /// 开发模式：监听 manifest / main.js 修改时间，自动重载插件。
    @Published var hotReloadEnabled: Bool {
        didSet {
            d.set(hotReloadEnabled, forKey: "pluginHotReload")
            syncHotReloadTimer()
        }
    }

    let pluginsDirectory: URL
    let logsDirectory: URL

    private let d = UserDefaults.standard
    private let fm = FileManager.default
    private var hotReloadTimer: Timer?
    private var fileStamps: [String: String] = [:]

    private init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        pluginsDirectory = support
            .appendingPathComponent(Brand.supportFolder, isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(Brand.supportFolder, isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        logsDirectory = logs
        hotReloadEnabled = (d.object(forKey: "pluginHotReload") as? Bool) ?? true
        ensureDirectories()
    }

    // MARK: 扫描与注册

    /// 扫描插件目录，校验 manifest，并把启用的插件页注册到 PageRegistry。
    func scan() {
        ensureDirectories()
        let dirs = (try? fm.contentsOfDirectory(at: pluginsDirectory,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
        var loaded: [PluginRecord] = []
        var seenIDs = Set<String>()

        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            var record = loadRecord(at: dir)
            if let manifest = record.manifest {
                if seenIDs.contains(manifest.id) {
                    record = PluginRecord(directory: dir, manifest: manifest,
                                          error: "插件 id 重复：\(manifest.id)", enabled: false,
                                          integrity: .unrecorded, hash: record.hash)
                } else {
                    seenIDs.insert(manifest.id)
                }
            }
            loaded.append(record)
        }
        plugins = loaded
        refreshRegistries()
        syncHotReloadTimer()
    }

    // MARK: - 开发模式热重载

    /// 编辑 manifest.json / main.js 后 1~2 秒内自动重载，不用反复重启 App。
    /// 用修改时间轮询而不是文件事件：编辑器「原子保存」会换 inode，文件监听容易失效。
    private func syncHotReloadTimer() {
        if hotReloadEnabled {
            guard hotReloadTimer == nil else { return }
            let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in self?.checkHotReload() }
            RunLoop.main.add(t, forMode: .common)
            hotReloadTimer = t
        } else {
            hotReloadTimer?.invalidate()
            hotReloadTimer = nil
        }
    }

    private func fileStamp(_ record: PluginRecord, _ manifest: PluginManifest) -> String {
        func mtime(_ url: URL) -> String {
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            return String(format: "%.3f", date?.timeIntervalSince1970 ?? 0)
        }
        func dirStamp(_ dir: URL) -> String {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { return "0" }
            var maxTime: TimeInterval = 0
            var count = 0
            for case let url as URL in e {
                count += 1
                if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    maxTime = max(maxTime, d.timeIntervalSince1970)
                }
            }
            return String(format: "%.3f-%d", maxTime, count)
        }
        let manifestURL = record.directory.appendingPathComponent("manifest.json")
        let mainURL = record.directory.appendingPathComponent(manifest.main)
        var parts = [mtime(manifestURL), mtime(mainURL)]
        // Web 页资源也要参与：改 HTML/CSS/JS 后自动重建 WKWebView。
        for page in manifest.contributes?.pages ?? [] where (page.kind ?? "js").lowercased() == "web" {
            if let entry = page.entry {
                let base = record.directory.appendingPathComponent(entry).deletingLastPathComponent()
                parts.append(dirStamp(base))
            }
        }
        return parts.joined(separator: "|")
    }

    private func checkHotReload() {
        guard hotReloadEnabled else { return }
        for record in plugins where record.enabled && record.isUsable {
            guard let manifest = record.manifest else { continue }
            let stamp = fileStamp(record, manifest)
            guard let old = fileStamps[record.id] else {
                fileStamps[record.id] = stamp
                continue
            }
            guard stamp != old else { continue }
            fileStamps[record.id] = stamp

            let oldParts = old.split(separator: "|", omittingEmptySubsequences: false)
            let newParts = stamp.split(separator: "|", omittingEmptySubsequences: false)
            let manifestChanged = oldParts.first != newParts.first
            let mainChanged = oldParts.count > 1 && newParts.count > 1 && oldParts[1] != newParts[1]
            if manifestChanged {
                // manifest 改了要重新校验、重新注册页面/卡片/胶囊。
                scan()
            } else if mainChanged {
                PluginRuntime.shared.reload(pluginID: manifest.id,
                                            directory: record.directory,
                                            manifest: manifest)
                refreshIntegrity()
            } else {
                // 只改了 Web 资源：让插件页的 WKWebView 重建，读取新文件。
                revision += 1
                refreshIntegrity()
            }
            return
        }
    }

    /// 重新计算所有插件的完整性状态（不重新注册页面/卡片）。
    private func refreshIntegrity() {
        var updated = plugins
        for i in updated.indices {
            let record = updated[i]
            let actual = packageHash(of: record.directory)
            updated[i] = PluginRecord(directory: record.directory,
                                      manifest: record.manifest,
                                      error: record.error,
                                      enabled: record.enabled,
                                      integrity: integrityStatus(id: record.id, actualHash: actual),
                                      hash: actual)
        }
        if updated != plugins { plugins = updated }
    }

    private func loadRecord(at dir: URL) -> PluginRecord {
        let actualHash = packageHash(of: dir)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            return PluginRecord(directory: dir, manifest: nil,
                                error: "缺少 manifest.json", enabled: false,
                                integrity: .unrecorded, hash: actualHash)
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            let error = validate(manifest, at: dir)
            let enabled = error == nil && isEnabledInDefaults(manifest.id)
            let integrity = integrityStatus(id: manifest.id, actualHash: actualHash)
            return PluginRecord(directory: dir, manifest: manifest, error: error, enabled: enabled,
                                integrity: integrity, hash: actualHash)
        } catch {
            return PluginRecord(directory: dir, manifest: nil,
                                error: "manifest 解析失败：\(error.localizedDescription)", enabled: false,
                                integrity: .unrecorded, hash: actualHash)
        }
    }

    // MARK: - 完整性（SHA-256）

    private var storedHashes: [String: String] {
        get { d.dictionary(forKey: "pluginHashes") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "pluginHashes") }
    }

    private func integrityStatus(id: String, actualHash: String?) -> PluginIntegrity {
        guard let actualHash, let expected = storedHashes[id] else { return .unrecorded }
        return expected == actualHash ? .ok : .changed
    }

    /// 对插件目录计算 SHA-256：按相对路径排序，路径 + 文件内容全部入哈希。
    /// 排除顶层 data/（插件自己的运行数据，不属于代码完整性）。
    private func packageHash(of dir: URL) -> String? {
        guard let enumerator = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        var entries: [(String, URL)] = []
        for case let url as URL in enumerator {
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            if rel == "data" || rel.hasPrefix("data/") { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            entries.append((rel, url))
        }
        guard !entries.isEmpty else { return nil }
        var hasher = SHA256()
        for (rel, url) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(rel.utf8))
            hasher.update(data: Data([0]))
            if let data = try? Data(contentsOf: url) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func recordHash(id: String, directory: URL) {
        guard let hash = packageHash(of: directory) else { return }
        var map = storedHashes
        map[id] = hash
        storedHashes = map
    }

    /// 用户确认「当前文件就是我信任的版本」：把当前 hash 记为基线。
    func trustCurrentFiles(id: String) {
        guard let record = plugins.first(where: { $0.id == id }) else { return }
        recordHash(id: id, directory: record.directory)
        scan()
    }

    /// 当前 App 支持的插件 API 版本
    static let supportedAPIVersion = 1

    private func validate(_ m: PluginManifest, at dir: URL) -> String? {
        if (m.apiVersion ?? 1) > Self.supportedAPIVersion {
            return "插件需要更新的 Isla（插件 API \(m.apiVersion ?? 1)，当前支持 \(Self.supportedAPIVersion)）"
        }
        var errors: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        if m.id.isEmpty || m.id.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            errors.append("插件 id 只能包含字母、数字、点、横线、下划线")
        }
        if m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("name 不能为空")
        }
        if m.version.isEmpty { errors.append("version 不能为空") }
        if !fm.fileExists(atPath: dir.appendingPathComponent(m.main).path) {
            errors.append("入口文件不存在：\(m.main)")
        }
        let unknown = (m.permissions ?? []).filter { !Self.supportedPermissions.contains($0) }
        if !unknown.isEmpty {
            errors.append("未知权限：\(unknown.joined(separator: ", "))")
        }
        if let required = m.minAppVersion, !Self.versionAtLeast(required, current: AppInfo.version) {
            errors.append("需要 Isla \(required)+，当前 \(AppInfo.version)")
        }
        let pages = m.contributes?.pages ?? []
        var pageIDs = Set<String>()
        for p in pages {
            if p.id.isEmpty || p.title.isEmpty {
                errors.append("页面 id / title 不能为空")
            }
            if !pageIDs.insert(p.id).inserted {
                errors.append("页面 id 重复：\(p.id)")
            }
            let kind = (p.kind ?? "js").lowercased()
            if kind == "web" {
                let entry = (p.entry ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if entry.isEmpty {
                    errors.append("页面 \(p.id) 是 web 类型，必须提供 entry")
                } else {
                    let target = dir.appendingPathComponent(entry).standardizedFileURL
                    let root = dir.standardizedFileURL.path
                    if !target.path.hasPrefix(root + "/") {
                        errors.append("页面 \(p.id) 的 entry 不能指向插件目录之外")
                    } else if !fm.fileExists(atPath: target.path) {
                        errors.append("页面 \(p.id) 的 entry 不存在：\(entry)")
                    }
                }
            } else if kind != "js" && kind != "native" {
                // native 是 Phase 1/2 的旧写法，等价于今天的 js（声明式渲染）。
                errors.append("页面 \(p.id) 的 kind 只能是 js / native / web")
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "；")
    }

    /// 把启用插件的页面 / 概览卡片写进注册表；禁用/卸载后自动移除。
    private func refreshRegistries() {
        var pages = PageRegistry.builtins
        var widgets = WidgetRegistry.builtins
        var modes: [PluginCapsuleMode] = []
        var commands: [PluginCommandRef] = []
        var sortKey = 10
        var widgetSort = 100
        var enabledIDs = Set<String>()
        for record in plugins where record.enabled && record.isUsable {
            guard let m = record.manifest else { continue }
            enabledIDs.insert(m.id)
            PluginRuntime.shared.load(pluginID: m.id, directory: record.directory, manifest: m)
            for page in m.contributes?.pages ?? [] {
                let isWeb = (page.kind ?? "js").lowercased() == "web"
                pages.append(PageDescriptor(
                    id: "plugin.\(m.id).\(page.id)",
                    title: m.localized(page.title, page.titleEn),
                    icon: page.icon ?? "puzzlepiece.extension",
                    kind: .plugin,
                    preferredHeight: page.preferredHeight,
                    sortKey: sortKey,
                    webEntry: isWeb ? page.entry : nil
                ))
                sortKey += 1
            }
            for card in m.contributes?.panelCards ?? [] {
                let size = card.defaultSize.map { CGSize(width: $0.w, height: $0.h) }
                widgets.append(WidgetDescriptor(
                    id: "plugin.\(m.id).\(card.id)",
                    title: m.localized(card.title, card.titleEn),
                    renderer: .plugin(pluginID: m.id, cardID: card.id),
                    sortKey: widgetSort,
                    defaultSize: size
                ))
                widgetSort += 1
            }
            for capsule in m.contributes?.capsuleModes ?? [] {
                modes.append(PluginCapsuleMode(
                    id: "plugin.\(m.id).\(capsule.id)",
                    pluginID: m.id,
                    modeID: capsule.id,
                    title: m.localized(capsule.title, capsule.titleEn)
                ))
            }
            for command in m.contributes?.commands ?? [] {
                commands.append(PluginCommandRef(
                    id: "plugin.\(m.id).\(command.id)",
                    pluginID: m.id,
                    commandID: command.id,
                    title: m.localized(command.title, command.titleEn)
                ))
            }
        }
        for id in PluginRuntime.shared.loadedIDs where !enabledIDs.contains(id) {
            PluginRuntime.shared.unload(pluginID: id)
        }
        PageRegistry.descriptors = pages
        WidgetRegistry.descriptors = widgets
        capsuleModes = modes
        pluginCommands = commands

        // 让新增的插件卡片进入排序表与开关表；默认启用。
        let store = SettingsStore.shared
        let known = Set(widgets.map(\.id))
        var order = store.widgetOrder.filter { known.contains($0) }
        for w in widgets where !order.contains(w.id) { order.append(w.id) }
        if order != store.widgetOrder { store.widgetOrder = order }
        var enabled = store.widgetEnabled
        for w in widgets where enabled[w.id] == nil { enabled[w.id] = true }
        if enabled != store.widgetEnabled { store.widgetEnabled = enabled }

        // 选中的胶囊模式被禁用/卸载时，自动落到第一个可用模式。
        if !modes.isEmpty, !modes.contains(where: { $0.id == store.capsulePluginMode }) {
            store.capsulePluginMode = modes[0].id
        }

        // 画布按新注册表补齐 / 清理盒子。
        CanvasLayout.shared.syncWidgets()

        revision += 1
        IslandStore.shared.ensureValidPage()
    }

    /// 把注册表里的 `plugin.<插件id>.<页面id>` 拆回宿主需要的两段。
    func pageRef(for descriptorID: String) -> (pluginID: String, pageID: String)? {
        for record in plugins where record.enabled && record.isUsable {
            guard let m = record.manifest else { continue }
            let prefix = "plugin.\(m.id)."
            if descriptorID.hasPrefix(prefix) {
                return (m.id, String(descriptorID.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// Web 页宿主需要插件目录（loadFileURL 的读取根）与权限集。
    func directory(forPlugin id: String) -> URL? {
        plugins.first { $0.id == id }?.directory
    }

    func permissions(forPlugin id: String) -> [String] {
        plugins.first { $0.id == id }?.permissions ?? []
    }

    /// 权限总览：当前已安装插件用到了哪些权限、分别被谁使用。
    func permissionUsage() -> [PluginPermissionUsage] {
        var map: [String: [String]] = [:]
        for record in plugins where record.isUsable {
            for perm in record.permissions {
                map[perm, default: []].append(record.name)
            }
        }
        return Self.permissionCatalog.compactMap { info in
            guard let names = map[info.id], !names.isEmpty else { return nil }
            return PluginPermissionUsage(info: info, pluginNames: names.sorted())
        }
    }

    // MARK: 启用 / 卸载

    private func isEnabledInDefaults(_ id: String) -> Bool {
        let map = d.dictionary(forKey: "enabledPlugins") as? [String: Bool] ?? [:]
        return map[id] ?? true
    }

    func setEnabled(id: String, _ on: Bool) {
        var map = d.dictionary(forKey: "enabledPlugins") as? [String: Bool] ?? [:]
        map[id] = on
        d.set(map, forKey: "enabledPlugins")
        scan()
    }

    func uninstall(id: String) {
        guard let record = plugins.first(where: { $0.id == id }) else { return }
        try? fm.removeItem(at: record.directory)
        var map = d.dictionary(forKey: "enabledPlugins") as? [String: Bool] ?? [:]
        map.removeValue(forKey: id)
        d.set(map, forKey: "enabledPlugins")
        scan()
    }

    // MARK: 安装

    enum PluginError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }

    func install(from url: URL, overwrite: Bool = false, confirmPermissions: Bool = true) throws {
        ensureDirectories()
        let sourceIsZip = url.pathExtension.lowercased() == "zip"
        let working = sourceIsZip ? try unzip(url) : url
        defer { if sourceIsZip { try? fm.removeItem(at: working) } }

        guard let root = pluginRoot(in: working) else {
            throw PluginError.message("没有找到 manifest.json（文件夹或 zip 根目录）")
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest: PluginManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginError.message("manifest 解析失败：\(error.localizedDescription)")
        }
        if let error = validate(manifest, at: root) {
            throw PluginError.message(error)
        }
        // 安装前把 manifest 声明的权限逐项展示，用户确认后才落位。
        let permissions = manifest.permissions ?? []
        if confirmPermissions && !permissions.isEmpty {
            let list = permissions.map { perm -> String in
                guard let info = Self.permissionInfo(perm) else { return "• \(perm)" }
                let mark = info.risk == .sensitive ? L("（敏感）") : ""
                return "• " + String(format: L("%@%@：%@"), L(info.title), mark, L(info.detail))
            }.joined(separator: "\n")
            let alert = NSAlert()
            alert.messageText = String(format: L("%@ 请求权限"), manifest.localizedName)
            alert.informativeText = L(overwrite ? "更新后会获得以下权限：" : "安装后会获得以下权限：")
                + "\n\n" + list
            alert.addButton(withTitle: L(overwrite ? "更新" : "安装"))
            alert.addButton(withTitle: L("取消"))
            if alert.runModal() != .alertFirstButtonReturn {
                throw PluginError.message("已取消安装")
            }
        }

        let dest = pluginsDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        // 先复制到暂存目录，成功后再替换；失败不会把旧版本弄丢。
        let staging = pluginsDirectory.appendingPathComponent(".isla-staging-\(UUID().uuidString)",
                                                              isDirectory: true)
        do {
            try fm.copyItem(at: root, to: staging)
        } catch {
            throw PluginError.message("复制插件失败：\(error.localizedDescription)")
        }

        var backupData: URL?
        var oldDir: URL?
        if fm.fileExists(atPath: dest.path) {
            guard overwrite else {
                try? fm.removeItem(at: staging)
                throw PluginError.message("插件 \(manifest.id) 已安装，请先卸载再装")
            }
            // 更新时保留插件自己的 data/（storage 等）。
            let dataDir = dest.appendingPathComponent("data", isDirectory: true)
            if fm.fileExists(atPath: dataDir.path) {
                let backup = fm.temporaryDirectory
                    .appendingPathComponent("isla-plugin-data-\(UUID().uuidString)", isDirectory: true)
                if (try? fm.copyItem(at: dataDir, to: backup)) != nil { backupData = backup }
            }
            let stale = pluginsDirectory.appendingPathComponent(".isla-old-\(UUID().uuidString)",
                                                                isDirectory: true)
            do {
                try fm.moveItem(at: dest, to: stale)
                oldDir = stale
            } catch {
                try? fm.removeItem(at: staging)
                throw PluginError.message("替换旧插件失败：\(error.localizedDescription)")
            }
        }

        do {
            try fm.moveItem(at: staging, to: dest)
        } catch {
            if let oldDir { try? fm.moveItem(at: oldDir, to: dest) }
            try? fm.removeItem(at: staging)
            throw PluginError.message("安装插件失败：\(error.localizedDescription)")
        }
        if let backupData {
            let dataDir = dest.appendingPathComponent("data", isDirectory: true)
            try? fm.removeItem(at: dataDir)
            try? fm.moveItem(at: backupData, to: dataDir)
        }
        if let oldDir { try? fm.removeItem(at: oldDir) }

        // 新版本文件落位后记录完整性基线。
        recordHash(id: manifest.id, directory: dest)

        // 覆盖安装后必须重新加载宿主，否则运行时还停在旧代码上。
        PluginRuntime.shared.unload(pluginID: manifest.id)
        scan()
    }

    /// 安装 App 内置示例插件（Resources/Samples/<name>）。
    func installSample(_ name: String = "clipboard-board", overwrite: Bool = false,
                       confirmPermissions: Bool = true) throws {
        guard let resource = Bundle.main.resourceURL else {
            throw PluginError.message("找不到 App 资源目录")
        }
        let sample = resource.appendingPathComponent("Samples/\(name)", isDirectory: true)
        guard fm.fileExists(atPath: sample.path) else {
            throw PluginError.message("示例插件资源缺失：\(name)")
        }
        try install(from: sample, overwrite: overwrite, confirmPermissions: confirmPermissions)
    }

    var sampleInstalled: Bool {
        plugins.contains { $0.id == "com.example.clipboard-board" }
    }

    // MARK: - 本地插件目录（Phase 3）

    struct CatalogEntry: Identifiable, Equatable {
        let id: String
        let name: String
        let version: String
        let summary: String
        let directory: URL
        let installed: Bool
        /// 已安装版本；nil = 未安装。
        let installedVersion: String?
        /// 本地目录版本比已装版本新。
        let hasUpdate: Bool
    }

    /// 扫描 App 内置的 Samples 目录，形成"本地插件目录"。
    /// 不依赖网络，也不引入签名体系：条目就是随 App 分发的官方示例。
    func catalogPlugins() -> [CatalogEntry] {
        guard let resource = Bundle.main.resourceURL else { return [] }
        let samples = resource.appendingPathComponent("Samples", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: samples,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
        let installedVersions = Dictionary(uniqueKeysWithValues:
            plugins.compactMap { p in p.manifest.map { ($0.id, $0.version) } })
        var out: [CatalogEntry] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: data) else { continue }
            let installedVersion = installedVersions[m.id]
            let hasUpdate = installedVersion.map {
                // versionAtLeast(required, current)：已装版本 ≤ 目录版本，且不相等。
                Self.versionAtLeast($0, current: m.version) && m.version != $0
            } ?? false
            out.append(CatalogEntry(id: m.id, name: m.localizedName, version: m.version,
                                    summary: m.localizedDescription ?? "",
                                    directory: dir,
                                    installed: installedVersion != nil,
                                    installedVersion: installedVersion,
                                    hasUpdate: hasUpdate))
        }
        return out
    }

    func installCatalog(id: String) throws {
        guard let entry = catalogPlugins().first(where: { $0.id == id }) else {
            throw PluginError.message("本地目录里没有这个插件：\(id)")
        }
        guard !entry.installed else {
            throw PluginError.message("插件 \(entry.name) 已安装，请先卸载再装")
        }
        try install(from: entry.directory)
    }

    /// 从本地目录覆盖安装新版本；插件自己的 data/ 会保留。
    func updateCatalog(id: String) throws {
        guard let entry = catalogPlugins().first(where: { $0.id == id }) else {
            throw PluginError.message("本地目录里没有这个插件：\(id)")
        }
        guard entry.installed else {
            try install(from: entry.directory)
            return
        }
        try install(from: entry.directory, overwrite: true)
    }

    private func pluginRoot(in dir: URL) -> URL? {
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let subs = (try? fm.contentsOfDirectory(at: dir,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
        let candidates = subs.filter {
            fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func unzip(_ zip: URL) throws -> URL {
        let tmp = fm.temporaryDirectory.appendingPathComponent("isla-plugin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: tmp)
            throw PluginError.message("zip 解压失败")
        }
        return tmp
    }

    // MARK: 目录 / 日志

    func openPluginsFolder() {
        ensureDirectories()
        NSWorkspace.shared.open(pluginsDirectory)
    }

    func openLogsFolder() {
        ensureDirectories()
        NSWorkspace.shared.open(logsDirectory)
    }

    func openLog(for id: String) {
        ensureDirectories()
        let url = logsDirectory.appendingPathComponent("\(id).log")
        if !fm.fileExists(atPath: url.path) {
            let header = "Isla 插件日志 · \(id)\n\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func ensureDirectories() {
        try? fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    // MARK: 版本比较

    private static func versionAtLeast(_ required: String, current: String) -> Bool {
        let a = required.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return true
    }
}

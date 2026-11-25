import Foundation
import AppKit
import Combine

/// 一个商店源。`pinnedKey` 是用户/预置信任的 Ed25519 公钥（base64），
/// 有它才做「发布者连续性」校验：换钥匙必须显式重新信任。
struct StoreSource: Codable, Identifiable, Equatable {
    var url: String
    var pinnedKey: String? = nil
    var keyID: String? = nil
    var publisherName: String? = nil

    var id: String { url }
    var host: String { URL(string: url)?.host ?? url }
}

enum StoreSignatureState: Equatable {
    case none
    case unsigned
    case untrusted(StorePublisher)
    case verified(StorePublisher)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var publisher: StorePublisher? {
        switch self {
        case .untrusted(let p), .verified(let p): return p
        default: return nil
        }
    }
}

/// 远端插件商店的 UI 状态与安装编排。
///
/// 信任链：HTTPS 传输 → 索引签名（Ed25519，`index.json.sig`）→ 公钥固定（首次信任 / 预置）
/// → 安装包 SHA-256 → zip 路径检查 → PluginManager（权限逐项确认、落位、完整性基线）。
/// 签名只证明「索引与这把钥匙匹配」；钥匙是否可信由固定决定。未固定/未签名时安装要二次确认。
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    /// 预置示例源：随公开仓 `store/` 目录部署到 GitHub Pages。
    /// 用户可以在设置里移除或换成自己的商店。
    static let defaultSource = "https://llllccc.github.io/Isla/index.json"
    /// 旧版 WorkBuddy Sites 源：只在迁移时识别，公开版不再使用（sharecode 已暴露）。
    static let legacyHost = "isla-plugin-store.app.workbuddy.host"
    /// 预置信任的官方发布者公钥（base64）。为空 = 首次使用时由用户点「信任并校验」。
    static let defaultSourcePin: String? = "REabHGrblkP6pnaaOpYwVr9k2t9WhGxrwIf+tgFJGWI="

    private static let sourcesKey = "pluginStoreSourcesV2"
    private static let legacySourcesKey = "pluginStoreSources"
    private static let activeKey = "pluginStoreActiveSource"
    private let d = UserDefaults.standard
    private let session = StoreClient.makeSession()

    @Published private(set) var sources: [StoreSource]
    @Published private(set) var activeSource: String
    @Published private(set) var plugins: [StorePlugin] = []
    @Published private(set) var storeName = ""
    @Published private(set) var updatedAt: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var installing: Set<String> = []
    @Published private(set) var signature: StoreSignatureState = .none

    private init() {
        let loaded = Self.loadSources(d)
        sources = loaded
        if let remembered = d.string(forKey: Self.activeKey), loaded.contains(where: { $0.url == remembered }) {
            activeSource = remembered
        } else {
            activeSource = loaded.first?.url ?? ""
        }
    }

    private static func loadSources(_ d: UserDefaults) -> [StoreSource] {
        var list: [StoreSource]
        if let data = d.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([StoreSource].self, from: data) {
            list = decoded
        } else if let legacy = d.stringArray(forKey: legacySourcesKey) {
            list = legacy.map { StoreSource(url: $0) }
        } else if !defaultSource.isEmpty {
            list = [StoreSource(url: defaultSource, pinnedKey: defaultSourcePin)]
        } else {
            list = []
        }
        let before = list
        var seen = Set<String>()
        list = list.compactMap { source in
            var s = source
            if s.url.contains(legacyHost) {
                // 旧 sharecode 源已不适合公开版；保留用户已固定的钥匙，换到公开 Pages 源。
                s.url = defaultSource
                if s.pinnedKey == nil { s.pinnedKey = defaultSourcePin }
            }
            return seen.insert(s.url).inserted ? s : nil
        }
        if list != before, let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: sourcesKey)
        }
        if list.isEmpty, !defaultSource.isEmpty {
            list = [StoreSource(url: defaultSource, pinnedKey: defaultSourcePin)]
            if let data = try? JSONEncoder().encode(list) {
                d.set(data, forKey: sourcesKey)
            }
        }
        return list
    }

    // MARK: 源管理

    var hasSource: Bool { !activeSource.isEmpty }

    var activeRecord: StoreSource? { sources.first { $0.url == activeSource } }

    var activeHost: String { activeRecord?.host ?? activeSource }

    /// 设置页第一次显示时按需拉取；不在启动时偷偷联网。
    func ensureLoaded() {
        guard hasSource, lastSyncedAt == nil, !isRefreshing else { return }
        refresh()
    }

    func addSource(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), StoreClient.isAllowed(url) else {
            throw StoreError.message("商店地址必须是 https:// 开头（本机调试可用 http://127.0.0.1）")
        }
        let normalized = url.absoluteString
        guard !sources.contains(where: { $0.url == normalized }) else {
            throw StoreError.message("这个商店源已经在列表里了")
        }
        sources.append(StoreSource(url: normalized))
        persistSources()
        activate(normalized)
    }

    func removeSource(_ source: String) {
        sources.removeAll { $0.url == source }
        persistSources()
        if activeSource == source {
            plugins = []
            lastSyncedAt = nil
            lastError = nil
            storeName = ""
            signature = .none
            activeSource = sources.first?.url ?? ""
            d.set(activeSource, forKey: Self.activeKey)
            if hasSource { refresh() }
        }
    }

    func activate(_ source: String) {
        guard sources.contains(where: { $0.url == source }),
              source != activeSource || plugins.isEmpty else { return }
        activeSource = source
        d.set(source, forKey: Self.activeKey)
        plugins = []
        storeName = ""
        updatedAt = nil
        lastSyncedAt = nil
        signature = .none
        refresh()
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            d.set(data, forKey: Self.sourcesKey)
        }
    }

    // MARK: 信任

    /// 把当前索引声明的发布者公钥固定到这个源上（首次信任 / 换钥匙后重新信任）。
    func trustCurrentPublisher() {
        guard case .untrusted(let publisher) = signature,
              let i = sources.firstIndex(where: { $0.url == activeSource }) else { return }
        sources[i].pinnedKey = publisher.publicKey
        sources[i].keyID = publisher.keyID
        sources[i].publisherName = publisher.name
        persistSources()
        signature = .verified(publisher)
    }

    /// 清除固定：下次刷新回到「未信任」，可重新走一次指纹确认。
    func forgetPublisher() {
        guard let i = sources.firstIndex(where: { $0.url == activeSource }) else { return }
        sources[i].pinnedKey = nil
        sources[i].keyID = nil
        sources[i].publisherName = nil
        persistSources()
        if case .verified(let p) = signature { signature = .untrusted(p) }
    }

    // MARK: 拉取

    func refresh() {
        guard hasSource, !isRefreshing, let base = URL(string: activeSource) else { return }
        isRefreshing = true
        lastError = nil
        signature = .none
        let installed = installedVersions()
        let pinned = activeRecord?.pinnedKey
        let pinnedKeyID = activeRecord?.keyID
        Task { [weak self] in
            guard let self else { return }
            do {
                let signed = try await StoreClient.fetchSignedIndex(from: base, session: self.session)
                // 发布者存在 → 签名已在 fetchSignedIndex 内验过；再看钥匙是否被固定
                var state: StoreSignatureState = .unsigned
                if let publisher = signed.publisher {
                    if let pinned, !pinned.isEmpty {
                        guard pinned == publisher.publicKey else {
                            throw StoreError.message("发布者密钥已更换：已信任 \(pinnedKeyID ?? "未知")，"
                                                     + "索引声明 \(publisher.keyID)。若不是你主动换钥匙，请不要继续。")
                        }
                        state = .verified(publisher)
                    } else {
                        state = .untrusted(publisher)
                    }
                } else if let pinned, !pinned.isEmpty {
                    // 已经固定了发布者，却收到一份没签名的索引：按降级处理，绝不悄悄退回「未签名」。
                    throw StoreError.message("这个源已固定发布者（\(pinnedKeyID ?? "未知")），但索引没有签名；"
                                             + "可能被降级替换，已拒绝加载。")
                }
                let list = try StoreClient.buildCatalog(index: signed.index, baseURL: base,
                                                        installed: installed,
                                                        appVersion: AppInfo.version,
                                                        english: isEnglishUIEnabled)
                await MainActor.run {
                    self.plugins = list
                    self.storeName = (isEnglishUIEnabled ? (signed.index.nameEn ?? signed.index.name) : signed.index.name)
                        ?? (base.host ?? L("插件商店"))
                    self.updatedAt = signed.index.updatedAt
                    self.lastSyncedAt = Date()
                    self.isRefreshing = false
                    self.signature = state
                    self.lastError = list.isEmpty ? "这个商店里暂时没有插件" : nil
                }
            } catch {
                await MainActor.run {
                    self.isRefreshing = false
                    self.plugins = []
                    self.signature = .none
                    self.lastError = Self.describe(error)
                }
            }
        }
    }

    // MARK: 安装

    /// `allowUntrusted` 只能由 UI 在用户看过指纹/未签名提示并确认后传 true。
    func install(_ plugin: StorePlugin, allowUntrusted: Bool = false) {
        guard plugin.compatible, !installing.contains(plugin.id) else { return }
        guard allowUntrusted || signature.isVerified else {
            lastError = L("当前商店未通过签名校验，安装已取消")
            return
        }
        installing.insert(plugin.id)
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            var downloaded: URL?
            do {
                let file = try await StoreClient.downloadPackage(
                    from: plugin.downloadURL,
                    expectedSHA256: plugin.sha256,
                    expectedSize: plugin.size,
                    session: self.session
                )
                downloaded = file
                try StoreClient.validateArchive(at: file)
                try await MainActor.run {
                    try PluginManager.shared.install(from: file, overwrite: plugin.installed)
                }
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
                await MainActor.run {
                    self.installing.remove(plugin.id)
                    self.refreshInstalledState()
                }
            } catch {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
                await MainActor.run {
                    self.installing.remove(plugin.id)
                    // 用户自己点了「取消」不是错误，不要弹红字
                    if !error.localizedDescription.contains("已取消") {
                        self.lastError = Self.describe(error)
                    }
                }
            }
        }
    }

    // MARK: 已安装状态

    func refreshInstalledState() {
        guard !plugins.isEmpty else { return }
        let map = installedVersions()
        for i in plugins.indices {
            plugins[i].installedVersion = map[plugins[i].id]
        }
    }

    private func installedVersions() -> [String: String] {
        var map: [String: String] = [:]
        for p in PluginManager.shared.plugins {
            if let m = p.manifest { map[m.id] = m.version }
        }
        return map
    }

    // MARK: 展示

    var statusLine: String {
        if isRefreshing { return L("正在读取商店…") }
        if let error = lastError { return error }
        if plugins.isEmpty { return hasSource ? L("商店里暂时没有插件") : L("还没有添加商店源") }
        var parts: [String] = [String(format: L("%d 个插件"), plugins.count)]
        if let lastSyncedAt {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            parts.append(String(format: L("更新于 %@"), f.string(from: lastSyncedAt)))
        }
        return parts.joined(separator: " · ")
    }

    var signatureLine: String {
        switch signature {
        case .none:
            return hasSource ? "" : L("未添加商店源")
        case .unsigned:
            return L("未签名：无法确认发布者，安装前会再确认一次")
        case .untrusted(let p):
            return String(format: L("发布者 %@ · 指纹 %@（尚未信任）"), p.name, p.keyID)
        case .verified(let p):
            return String(format: L("已签名 · 发布者 %@ · 指纹 %@"), p.name, p.keyID)
        }
    }

    var canTrustCurrentPublisher: Bool {
        if case .untrusted = signature { return true }
        return false
    }

    /// URLError 的中文说明：默认文案（“无法连接服务器”）对排查没帮助。
    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .appTransportSecurityRequiresSecureConnection:
                return "系统阻止了非 HTTPS 连接（商店源必须是 https）"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "连不上商店服务器，检查地址或网络"
            case .timedOut:
                return "连接商店超时"
            case .notConnectedToInternet:
                return "当前没有网络"
            case .cancelled:
                return "已取消"
            default:
                return "网络错误 \(e.code.rawValue)：\(e.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}

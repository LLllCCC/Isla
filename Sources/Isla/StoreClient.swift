import Foundation
import CryptoKit

// MARK: - 索引格式

/// 商店索引（index.json）。字段全部宽松：单个坏条目只丢它自己，不拖垮整份索引。
struct StoreIndex: Decodable {
    let schema: Int?
    let name: String?
    /// 英文商店名（可选）
    let nameEn: String?
    let updatedAt: String?
    /// 发布者声明（可选）。有它就必须有合法的 index.json.sig，否则整份索引拒绝加载。
    let publisher: StorePublisher?
    let plugins: [StoreIndexPlugin]

    /// 数组中单个元素解码失败时不影响其它元素。
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private enum CodingKeys: String, CodingKey { case schema, name, nameEn, updatedAt, publisher, plugins }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        nameEn = try c.decodeIfPresent(String.self, forKey: .nameEn)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        publisher = try c.decodeIfPresent(StorePublisher.self, forKey: .publisher)
        let raw = try c.decodeIfPresent([Failable<StoreIndexPlugin>].self, forKey: .plugins) ?? []
        plugins = raw.compactMap(\.value)
    }
}

/// 发布者公钥声明。keyID = SHA-256(公钥原始字节) 的前 16 位十六进制。
/// 注意：公钥写在索引里只能证明「签名与这把钥匙匹配」，不能证明「钥匙属于谁」——
/// 真正的信任来自 App 侧对钥匙的固定（首次信任 / 预置）。
struct StorePublisher: Decodable, Equatable {
    let name: String
    let keyID: String
    /// Ed25519 公钥（32 字节）的 base64
    let publicKey: String
}

/// 拉取并验签后的索引。
struct SignedStoreIndex {
    let index: StoreIndex
    let raw: Data
    let publisher: StorePublisher?
    let signature: String?
    /// 密码学上签名有效（不代表这把钥匙已被用户信任）
    let signatureValid: Bool
}

struct StoreIndexPlugin: Decodable {
    let id: String
    let name: String
    /// 英文名 / 简介（可选）
    let nameEn: String?
    let version: String
    let summary: String?
    let summaryEn: String?
    let author: String?
    let minAppVersion: String?
    let permissions: [String]?
    /// 相对索引地址或绝对 https 地址
    let package: String
    let sha256: String?
    let size: Int?
}

/// 通过校验、可以直接展示/安装的商店条目。
struct StorePlugin: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let author: String
    let permissions: [String]
    let downloadURL: URL
    let sha256: String
    let size: Int?
    let minAppVersion: String?
    /// 已安装版本（nil = 未安装）。安装完成后由 PluginStore 就地刷新。
    var installedVersion: String?
    let compatible: Bool

    var installed: Bool { installedVersion != nil }
    var hasUpdate: Bool {
        guard let installedVersion else { return false }
        return StoreClient.compareVersions(installedVersion, version) < 0
    }
    var sizeText: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

enum StoreError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

// MARK: - 网络与校验

/// 远端商店的传输层：只做 HTTPS 拉取、大小限制、SHA-256、压缩包路径校验。
/// 不碰 UI，也不依赖 AppKit——可以直接编进命令行断言程序。
enum StoreClient {
    static let maxIndexBytes = 2 * 1024 * 1024
    static let maxPackageBytes = 24 * 1024 * 1024
    static let maxPlugins = 200
    static let maxArchiveEntries = 5000

    /// 只允许 https；http 仅限本机回环，供开发时自建商店调试。
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }
        return false
    }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 60
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "Isla/\(StoreClient.appVersion) (plugin-store)"]
        return URLSession(configuration: cfg)
    }

    /// 不依赖 AppKit：命令行断言程序里 Bundle.main 是测试程序自己，版本号会退化，无妨。
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
    }

    static func fetchIndex(from url: URL, session: URLSession = makeSession()) async throws -> StoreIndex {
        try await fetchSignedIndex(from: url, session: session).index
    }

    /// 拉索引 + `index.json.sig`（若有发布者）。
    /// 规则：声明了 publisher 就必须有合法签名；有 .sig 但没 publisher 视为异常。
    static func fetchSignedIndex(from url: URL, session: URLSession = makeSession()) async throws -> SignedStoreIndex {
        guard isAllowed(url) else {
            throw StoreError.message("商店地址必须是 https（本机调试可用 http://127.0.0.1）")
        }
        let data = try await fetchData(from: url, limit: maxIndexBytes, session: session)
        let index: StoreIndex
        do {
            index = try JSONDecoder().decode(StoreIndex.self, from: data)
        } catch {
            throw StoreError.message("索引不是合法 JSON：\(error.localizedDescription)")
        }
        if let schema = index.schema, schema > 1 {
            throw StoreError.message("索引版本 \(schema) 比当前 Isla 支持的版本新，请先更新 App")
        }

        let sigURL = signatureURL(for: url)
        let rawSignature = try await fetchOptionalText(from: sigURL, session: session)
        let signature = rawSignature?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 有些静态托管对不存在的路径返回 200 + HTML 兜底页，不能被当成签名。
        let looksLikeSignature = signature.flatMap { Data(base64Encoded: $0) }?.count == 64

        if let publisher = index.publisher {
            guard let signature, !signature.isEmpty else {
                throw StoreError.message("索引声明了发布者，但缺少 \(sigURL.lastPathComponent)")
            }
            try verify(indexBytes: data, signatureBase64: signature, publisher: publisher)
            return SignedStoreIndex(index: index, raw: data, publisher: publisher,
                                    signature: signature, signatureValid: true)
        }
        if looksLikeSignature {
            throw StoreError.message("商店有签名文件，但索引没有 publisher 声明，拒绝加载")
        }
        return SignedStoreIndex(index: index, raw: data, publisher: nil,
                                signature: nil, signatureValid: false)
    }

    /// 索引同目录下的 `<文件名>.sig`，保留 query（托管平台的 sharecode）。
    static func signatureURL(for indexURL: URL) -> URL {
        var comps = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)
        comps?.path += ".sig"
        return comps?.url ?? indexURL.appendingPathExtension("sig")
    }

    static func verify(indexBytes: Data, signatureBase64: String, publisher: StorePublisher) throws {
        guard let keyData = Data(base64Encoded: publisher.publicKey), keyData.count == 32 else {
            throw StoreError.message("发布者公钥格式不对（需要 32 字节 Ed25519 公钥的 base64）")
        }
        guard keyID(forPublicKey: keyData) == publisher.keyID.lowercased() else {
            throw StoreError.message("发布者 keyID 与公钥不匹配")
        }
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64 else {
            throw StoreError.message("签名文件不是合法的 base64 Ed25519 签名")
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            throw StoreError.message("无法解析发布者公钥：\(error.localizedDescription)")
        }
        guard key.isValidSignature(sig, for: indexBytes) else {
            throw StoreError.message("商店签名校验失败：索引可能被改动，或不是这把钥匙签的")
        }
    }

    /// keyID = SHA-256(公钥原始字节) 的前 16 位十六进制
    static func keyID(forPublicKey key: Data) -> String {
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(16))
    }

    /// 可选文本文件：404 → nil，其它非 2xx 抛错。
    static func fetchOptionalText(from url: URL, session: URLSession = makeSession()) async throws -> String? {
        guard isAllowed(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw StoreError.message("签名文件返回 HTTP \(http.statusCode)")
        }
        guard data.count <= 16 * 1024 else {
            throw StoreError.message("签名文件异常大（> 16 KB），拒绝解析")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func fetchData(from url: URL, limit: Int, session: URLSession = makeSession()) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StoreError.message("商店没有返回 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StoreError.message("商店返回 HTTP \(http.statusCode)")
        }
        guard data.count <= limit else {
            throw StoreError.message("文件超过 \(limit / 1024 / 1024) MB 上限，拒绝解析")
        }
        return data
    }

    /// 把索引条目变成可展示列表：补上已安装版本、兼容性，剔掉缺字段/不安全地址/重复 id 的条目。
    static func buildCatalog(index: StoreIndex, baseURL: URL,
                             installed: [String: String], appVersion: String,
                             english: Bool = false) throws -> [StorePlugin] {
        var seen = Set<String>()
        var out: [StorePlugin] = []
        for p in index.plugins {
            guard out.count < maxPlugins else { break }
            guard isValidID(p.id), !p.name.isEmpty, !p.version.isEmpty else { continue }
            guard seen.insert(p.id).inserted else { continue }
            guard let download = resolvePackageURL(p.package, base: baseURL), isAllowed(download) else { continue }
            guard let rawHash = p.sha256?.lowercased(), isSHA256(rawHash) else { continue }
            if let size = p.size, size <= 0 || size > maxPackageBytes { continue }
            let compatible = p.minAppVersion.map { compareVersions(appVersion, $0) >= 0 } ?? true
            let installedVersion = installed[p.id]
            let displayName = english ? (p.nameEn ?? p.name) : p.name
            let displaySummary = english ? (p.summaryEn ?? p.summary ?? "") : (p.summary ?? "")
            out.append(StorePlugin(
                id: p.id, name: displayName, version: p.version,
                summary: displaySummary, author: p.author ?? "",
                permissions: p.permissions ?? [],
                downloadURL: download, sha256: rawHash, size: p.size,
                minAppVersion: p.minAppVersion,
                installedVersion: installedVersion,
                compatible: compatible
            ))
        }
        if out.isEmpty, !index.plugins.isEmpty {
            throw StoreError.message("索引里的条目都缺字段或地址不安全，已全部忽略")
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolvePackageURL(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        // 相对路径解析会丢掉索引 URL 的 query（比如托管平台的 sharecode）。
        // 同源且自身没有 query 时把索引的 query 带上，否则安装包会 403。
        if resolved.host == base.host, resolved.query == nil,
           let query = base.query, !query.isEmpty {
            var comps = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            comps?.query = query
            if let withQuery = comps?.url { return withQuery }
        }
        return resolved
    }

    static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, id != ".", id != ".." else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// 语义版本比较（数字段逐位比，缺失位按 0）。返回值 -1 / 0 / 1。
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    // MARK: 下载

    /// 下载到临时目录并校验大小与 SHA-256（大小写在索引里也必须匹配）。
    static func downloadPackage(from url: URL, expectedSHA256: String, expectedSize: Int?,
                                session: URLSession = makeSession()) async throws -> URL {
        guard isAllowed(url) else { throw StoreError.message("安装包地址不安全（必须是 https）") }
        let (temp, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreError.message("下载安装包失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: temp.path)
        let size = attrs?[.size] as? Int
        guard let size, size > 0, size <= maxPackageBytes else {
            throw StoreError.message("安装包为空或超过 \(maxPackageBytes / 1024 / 1024) MB 上限")
        }
        if let expectedSize, expectedSize != size {
            throw StoreError.message("安装包大小与索引不一致（索引 \(expectedSize) B，实际 \(size) B）")
        }
        let actual = try sha256(ofFile: temp)
        guard actual == expectedSHA256.lowercased() else {
            throw StoreError.message("SHA-256 校验失败，安装包可能被替换")
        }
        // PluginManager 靠扩展名判断要不要解压，临时文件必须补上 .zip
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-store-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    static func sha256(ofFile url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 解压前检查条目名：拒绝绝对路径、`..` 和超多文件的压缩包。
    /// ditto 本身不保证挡住路径穿越，这一层是安装前的最后一道。
    static func validateArchive(at url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { throw StoreError.message("无法读取安装包：\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw StoreError.message("安装包不是合法的 zip") }
        let names = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !names.isEmpty else { throw StoreError.message("安装包是空的") }
        guard names.count <= maxArchiveEntries else { throw StoreError.message("安装包文件数过多") }
        for name in names {
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                throw StoreError.message("安装包含有越界路径：\(name)")
            }
        }
    }
}

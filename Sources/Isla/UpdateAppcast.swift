import Foundation
import CryptoKit

/// 单文件 appcast：payload 是 base64 后的 JSON 字节，signature 是对解码后字节的 Ed25519 签名。
/// 单文件是为了避免「新 json + 旧 sig」的 CDN 缓存错配。
struct UpdateEnvelope: Decodable {
    let schema: Int?
    let payload: String
    let signature: String
}

/// appcast payload。build 是单调递增的整数，更新判断只认它。
struct UpdateRelease: Decodable, Equatable {
    let version: String
    let build: Int
    let minSystem: String?
    let notes: String?
    let notesEn: String?
    let zip: String
    let zipSha256: String
    let zipSize: Int?
    let dmg: String?
    let dmgSha256: String?
    let dmgSize: Int?
    let publishedAt: String?
}

/// appcast 的纯校验逻辑（不碰 AppKit / 网络），方便单独跑断言。
enum UpdateAppcast {
    static let maxAppcastBytes = 512 * 1024
    static let maxUpdateBytes = 200 * 1024 * 1024

    static func decodeAndVerify(data: Data, pinnedKeys: [String], currentBuild: Int,
                                source: URL, now: Date = Date()) throws -> UpdateRelease? {
        let envelope: UpdateEnvelope
        do {
            envelope = try JSONDecoder().decode(UpdateEnvelope.self, from: data)
        } catch {
            throw StoreError.message(String(format: L("appcast 格式不对：%@"), error.localizedDescription))
        }
        guard (envelope.schema ?? 1) == 1 else {
            throw StoreError.message("appcast 版本比当前 Isla 支持的更新器新")
        }
        guard let payload = Data(base64Encoded: envelope.payload) else {
            throw StoreError.message("appcast payload 不是合法 base64")
        }
        try verify(payload: payload, signatureBase64: envelope.signature, pinnedKeys: pinnedKeys)

        let release: UpdateRelease
        do {
            release = try JSONDecoder().decode(UpdateRelease.self, from: payload)
        } catch {
            throw StoreError.message(String(format: L("appcast payload 不是合法 JSON：%@"), error.localizedDescription))
        }
        try validate(release, source: source, now: now)
        return release.build > currentBuild ? release : nil
    }

    static func verify(payload: Data, signatureBase64: String, pinnedKeys: [String]) throws {
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64 else {
            throw StoreError.message("appcast 签名不是合法的 Ed25519 签名")
        }
        for keyBase64 in pinnedKeys {
            guard let keyData = Data(base64Encoded: keyBase64), keyData.count == 32,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { continue }
            if key.isValidSignature(sig, for: payload) { return }
        }
        throw StoreError.message("appcast 签名校验失败：更新源可能被篡改")
    }

    static func validate(_ release: UpdateRelease, source: URL, now: Date = Date()) throws {
        guard !release.version.isEmpty, release.build > 0 else {
            throw StoreError.message("appcast 缺少版本号或 build")
        }
        // build ≤ 当前版本不是错误：返回 nil 表示「已是最新」，同时天然拒绝降级。
        if let minSystem = release.minSystem,
           StoreClient.compareVersions(operatingSystemVersion, minSystem) < 0 {
            throw StoreError.message(String(format: L("这个版本需要 macOS %@ 或更高"), minSystem))
        }
        guard let zipURL = URL(string: release.zip), StoreClient.isAllowed(zipURL) else {
            throw StoreError.message("appcast 的 zip 地址不安全")
        }
        guard StoreClient.isSHA256(release.zipSha256) else {
            throw StoreError.message("appcast 的 zip SHA-256 格式不对")
        }
        if let size = release.zipSize, size <= 0 || size > maxUpdateBytes {
            throw StoreError.message("appcast 的 zip 大小异常")
        }
        if let raw = release.dmg, !raw.isEmpty {
            guard let dmgURL = URL(string: raw), StoreClient.isAllowed(dmgURL) else {
                throw StoreError.message("appcast 的 DMG 地址不安全")
            }
            if let sha = release.dmgSha256, !StoreClient.isSHA256(sha) {
                throw StoreError.message("appcast 的 DMG SHA-256 格式不对")
            }
            if let size = release.dmgSize, size <= 0 || size > maxUpdateBytes {
                throw StoreError.message("appcast 的 DMG 大小异常")
            }
        }
        let local = source.host == "127.0.0.1" || source.host == "localhost" || source.host == "::1"
        if !local {
            guard let publishedAt = release.publishedAt,
                  let date = ISO8601DateFormatter().date(from: publishedAt) else {
                throw StoreError.message("appcast 缺少合法的 publishedAt")
            }
            guard now.timeIntervalSince(date) < 90 * 24 * 3600 else {
                throw StoreError.message("appcast 已过期（超过 90 天），请手动下载安装包")
            }
        }
    }

    static var operatingSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// Isla appcast 纯逻辑断言。
//
// 运行：
//   cd tools/sim/update && swiftc -O -swift-version 5 \
//     main.swift ../../../Sources/Isla/UpdateAppcast.swift \
//     ../../../Sources/Isla/StoreClient.swift ../../../Sources/Isla/L10n.swift \
//     -o simupdate -framework Cocoa && ./simupdate

import Foundation
import CryptoKit

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ what: String) {
    checks += 1
    if condition {
        print("  ✓ \(what)")
    } else {
        failures += 1
        print("  ✗ \(what)")
    }
}

func expectThrows(_ what: String, _ body: () throws -> Void) {
    do {
        try body()
        failures += 1
        checks += 1
        print("  ✗ \(what)（没有抛错）")
    } catch {
        checks += 1
        print("  ✓ \(what)")
    }
}

func makePayload(build: Int, version: String = "1.7.1",
                 zip: String = "https://example.com/Isla.zip",
                 sha: String = String(repeating: "a", count: 64),
                 size: Int = 1024,
                 publishedAt: String? = nil,
                 minSystem: String? = nil) -> Data {
    var obj: [String: Any] = [
        "version": version,
        "build": build,
        "zip": zip,
        "zipSha256": sha,
        "zipSize": size
    ]
    if let publishedAt { obj["publishedAt"] = publishedAt }
    if let minSystem { obj["minSystem"] = minSystem }
    return try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
}

func makeEnvelope(payload: Data, key: Curve25519.Signing.PrivateKey,
                  schema: Int = 1, payloadOverride: Data? = nil,
                  signatureOverride: String? = nil) -> Data {
    let envPayload = payloadOverride ?? payload
    let sig = signatureOverride ?? (try! key.signature(for: payload)).base64EncodedString()
    let obj: [String: Any] = [
        "schema": schema,
        "payload": envPayload.base64EncodedString(),
        "signature": sig
    ]
    return try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
}

let source = URL(string: "https://example.com/appcast.json")!
let localSource = URL(string: "http://127.0.0.1:8765/appcast.json")!
let key = Curve25519.Signing.PrivateKey()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
let otherKey = Curve25519.Signing.PrivateKey()
let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
let fresh = "2026-11-25T10:00:00Z"

print("=== appcast 解析与验签 ===")

do {
    let payload = makePayload(build: 111, publishedAt: fresh)
    let data = makeEnvelope(payload: payload, key: key)
    let release = try UpdateAppcast.decodeAndVerify(data: data, pinnedKeys: [publicKey],
                                                     currentBuild: 110, source: source, now: now)
    expect(release?.build == 111, "合法 appcast 返回新版本")
    expect(release?.version == "1.7.1", "版本号解析正确")
} catch {
    expect(false, "合法 appcast 不应抛错：\(error)")
}

do {
    let payload = makePayload(build: 110, publishedAt: fresh)
    let data = makeEnvelope(payload: payload, key: key)
    let release = try UpdateAppcast.decodeAndVerify(data: data, pinnedKeys: [publicKey],
                                                     currentBuild: 110, source: source, now: now)
    expect(release == nil, "build 等于当前版本 → 已是最新")
}

do {
    let payload = makePayload(build: 109, publishedAt: fresh)
    let data = makeEnvelope(payload: payload, key: key)
    let release = try UpdateAppcast.decodeAndVerify(data: data, pinnedKeys: [publicKey],
                                                     currentBuild: 110, source: source, now: now)
    expect(release == nil, "build 低于当前版本 → 拒绝降级（当作已是最新）")
}

expectThrows("签名被篡改") {
    let payload = makePayload(build: 111, publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: key,
                           payloadOverride: makePayload(build: 112, publishedAt: fresh))
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("用错公钥") {
    let payload = makePayload(build: 111, publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: otherKey)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("schema 过新") {
    let payload = makePayload(build: 111, publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: key, schema: 2)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("payload 不是合法 base64") {
    let obj: [String: Any] = ["schema": 1, "payload": "!!!", "signature": "AAAA"]
    let data = try JSONSerialization.data(withJSONObject: obj)
    _ = try UpdateAppcast.decodeAndVerify(data: data, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("payload 不是合法 JSON") {
    let payload = Data("not json".utf8)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

print("=== 元数据校验 ===")

expectThrows("build 为 0") {
    let payload = makePayload(build: 0, publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("zip 不是 https") {
    let payload = makePayload(build: 111, zip: "http://example.com/Isla.zip", publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("zip SHA-256 格式不对") {
    let payload = makePayload(build: 111, sha: "xyz", publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("zip 大小为 0") {
    let payload = makePayload(build: 111, size: 0, publishedAt: fresh)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("minSystem 高于当前系统") {
    let payload = makePayload(build: 111, publishedAt: fresh, minSystem: "99.0")
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("publishedAt 超过 90 天") {
    let old = "2026-06-01T00:00:00Z"
    let payload = makePayload(build: 111, publishedAt: old)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

expectThrows("缺少 publishedAt（公网源）") {
    let payload = makePayload(build: 111)
    let env = makeEnvelope(payload: payload, key: key)
    _ = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                           currentBuild: 110, source: source, now: now)
}

do {
    let old = "2026-06-01T00:00:00Z"
    let payload = makePayload(build: 111, publishedAt: old)
    let env = makeEnvelope(payload: payload, key: key)
    let release = try UpdateAppcast.decodeAndVerify(data: env, pinnedKeys: [publicKey],
                                                     currentBuild: 110, source: localSource, now: now)
    expect(release?.build == 111, "本机调试源允许过期/缺 publishedAt")
} catch {
    expect(false, "本机调试源不应抛错：\(error)")
}

print("")
if failures == 0 {
    print("✓ appcast 断言全部通过（\(checks) 项）")
    exit(0)
} else {
    print("✗ \(failures)/\(checks) 项断言失败")
    exit(1)
}

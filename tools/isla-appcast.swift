// Appcast 签名工具（零第三方依赖，只用 CryptoKit）。
//
//   isla-appcast <payload.json> <key.json> <out.json>
//
// payload.json 是更新元数据（version/build/zip/sha256/...），本工具对它的
// 原始字节做 Ed25519 签名，输出单文件 envelope：
//   { "schema": 1, "payload": "<base64(payload bytes)>", "signature": "<base64>" }
// 单文件可以避免「新 json + 旧 sig」的 CDN 缓存错配。
//
// 私钥只留在本机，绝不进仓库。

import Foundation
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

struct KeyFile: Codable {
    let algorithm: String
    let keyID: String
    let publicKey: String
    let privateKey: String
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    print("用法：isla-appcast <payload.json> <key.json> <out.json>")
    exit(2)
}
let payloadURL = URL(fileURLWithPath: args[0])
let keyURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let payload = try? Data(contentsOf: payloadURL) else {
    fail("读不到 payload：\(args[0])")
}
guard let keyData = try? Data(contentsOf: keyURL),
      let keyFile = try? JSONDecoder().decode(KeyFile.self, from: keyData),
      keyFile.algorithm == "ed25519",
      let raw = Data(base64Encoded: keyFile.privateKey),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("私钥文件格式不对：\(args[1])")
}
let signature = try key.signature(for: payload)
let envelope: [String: Any] = [
    "schema": 1,
    "payload": payload.base64EncodedString(),
    "signature": signature.base64EncodedString()
]
let data = try JSONSerialization.data(withJSONObject: envelope,
                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
var out = data
out.append(0x0A)
try out.write(to: outURL, options: .atomic)
print("✓ 已生成 \(args[2])")
print("  keyID:     \(keyFile.keyID)")
print("  payload:   \(payload.count) B")

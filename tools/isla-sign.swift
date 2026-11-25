// Isla 商店签名工具（零第三方依赖，只用 CryptoKit）。
//
//   keygen <key.json> [--force]        生成 Ed25519 私钥（0600），打印公钥与 keyID
//   sign   <index.json> <key.json> [--name Isla]
//                                      把 publisher{name,keyID,publicKey} 写进索引，
//                                      再对写盘后的字节签名 → index.json.sig（base64）
//   verify <index.json> <index.json.sig> <key.json|公钥base64>
//                                      自检：公钥/keyID/签名是否一致
//
// 私钥只留在本机，绝不进仓库。仓库根目录的 .gitignore 已忽略 .isla-store-key.json。

import Foundation
import CryptoKit

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

func keyID(for publicKey: Data) -> String {
    let digest = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    return String(digest.prefix(16))
}

struct KeyFile: Codable {
    let algorithm: String
    let keyID: String
    let publicKey: String
    let privateKey: String
}

func loadKey(_ path: String) -> (KeyFile, Curve25519.Signing.PrivateKey) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("找不到私钥文件：\(path)") }
    guard let file = try? JSONDecoder().decode(KeyFile.self, from: data) else { fail("私钥文件格式不对") }
    guard file.algorithm == "ed25519",
          let raw = Data(base64Encoded: file.privateKey),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("私钥不是合法的 Ed25519 私钥")
    }
    return (file, key)
}

func usage() -> Never {
    print("""
    用法：
      isla-sign keygen <key.json> [--force]
      isla-sign sign <index.json> <key.json> [--name Isla]
      isla-sign verify <index.json> <index.json.sig> <key.json|公钥base64>
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

switch command {
case "keygen":
    guard let path = args.first else { usage() }
    let force = args.contains("--force")
    if FileManager.default.fileExists(atPath: path), !force {
        fail("\(path) 已存在；要覆盖请加 --force（覆盖后旧签名全部失效）")
    }
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation
    let file = KeyFile(algorithm: "ed25519",
                       keyID: keyID(for: pub),
                       publicKey: pub.base64EncodedString(),
                       privateKey: key.rawRepresentation.base64EncodedString())
    let data = try encoder.encode(file)
    let url = URL(fileURLWithPath: path)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    print("✓ 私钥已写入 \(path)（权限 0600，不要提交到仓库）")
    print("  keyID:     \(file.keyID)")
    print("  publicKey: \(file.publicKey)")

case "sign":
    guard args.count >= 2 else { usage() }
    let indexPath = args[0]
    let keyPath = args[1]
    var publisherName = "Isla"
    if let i = args.firstIndex(of: "--name"), i + 1 < args.count { publisherName = args[i + 1] }

    let (keyFile, key) = loadKey(keyPath)
    guard var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: indexPath))))
            as? [String: Any] else {
        fail("索引不是 JSON 对象：\(indexPath)")
    }
    object["publisher"] = [
        "name": publisherName,
        "keyID": keyFile.keyID,
        "publicKey": keyFile.publicKey
    ]
    var out = try JSONSerialization.data(withJSONObject: object,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    out.append(0x0A)
    try out.write(to: URL(fileURLWithPath: indexPath), options: [.atomic])

    // 对写盘后的字节签名——App 校验的是原始响应体，不是重新序列化的结果
    let signature = try key.signature(for: out)
    let sigPath = indexPath + ".sig"
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: sigPath), options: [.atomic])
    print("✓ 已签名 \(indexPath)")
    print("  publisher: \(publisherName)")
    print("  keyID:     \(keyFile.keyID)")
    print("  signature: \(sigPath)")

case "verify":
    guard args.count >= 3 else { usage() }
    let indexData = try Data(contentsOf: URL(fileURLWithPath: args[0]))
    let sigText = (try String(contentsOfFile: args[1], encoding: .utf8))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let keyArg = args[2]
    let publicKey: Data
    var expectedKeyID: String?
    if keyArg.hasSuffix(".json") || FileManager.default.fileExists(atPath: keyArg) {
        let (file, _) = loadKey(keyArg)
        publicKey = Data(base64Encoded: file.publicKey) ?? Data()
        expectedKeyID = file.keyID
    } else {
        publicKey = Data(base64Encoded: keyArg) ?? Data()
        expectedKeyID = nil
    }
    guard publicKey.count == 32 else { fail("公钥格式不对（需要 32 字节 base64）") }
    guard let sig = Data(base64Encoded: sigText), sig.count == 64 else { fail("签名文件不是 64 字节 base64") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(sig, for: indexData) else { fail("签名不匹配") }
    if let expectedKeyID, expectedKeyID != keyID(for: publicKey) { fail("keyID 与公钥不一致") }
    // 再核对索引里的 publisher 声明
    if let object = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
       let pub = object["publisher"] as? [String: Any] {
        guard pub["keyID"] as? String == keyID(for: publicKey) else { fail("索引里的 keyID 与公钥不一致") }
        guard pub["publicKey"] as? String == publicKey.base64EncodedString() else { fail("索引里的公钥与给定公钥不一致") }
    } else {
        fail("索引里没有 publisher 声明")
    }
    print("✓ 签名有效 · keyID \(keyID(for: publicKey))")

default:
    usage()
}

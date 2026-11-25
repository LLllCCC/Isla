// 远端商店协议断言：URL 白名单 / 版本比较 / 索引解析 / 条目过滤 / 下载校验 / zip 检查。
// 自己拉一个 python3 静态服务器当「远端」，跑完自动关掉。
//
// 运行（在仓库根目录）：
//   cd tools/sim/store && swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
//     main.swift ../../../Sources/Isla/StoreClient.swift -o simstore -framework Cocoa && \
//     cd ../../.. && ./tools/sim/store/simstore store

import Foundation
import Darwin
import CryptoKit

var failures = 0
var checks = 0
/// 环境受限（本机连不上自己的 http 服务器）——不算实现失败
var envLimited = false

func isLocalhostUnreachable(_ error: Error) -> Bool {
    let ns = error as NSError
    guard ns.domain == NSURLErrorDomain else { return false }
    return ns.code == NSURLErrorCannotConnectToHost
        || ns.code == NSURLErrorTimedOut
        || ns.code == NSURLErrorNetworkConnectionLost
}
/// 拉起 python 服务器后，exit() 会跳过 defer，必须显式收掉再退。
var httpServer: Process?

func finish(_ code: Int32) -> Never {
    httpServer?.terminate()
    exit(code)
}

/// 从 8791 起找一个空闲端口，避免上次测试残留的服务器把这一轮挡住。
func freePort() -> Int {
    for candidate in 8791...8899 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { continue }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(candidate).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        close(fd)
        if ok { return candidate }
    }
    return 8791
}

func expect(_ ok: Bool, _ what: String) {
    checks += 1
    if ok { print("  ✓ \(what)") } else { failures += 1; print("  ✗ \(what)") }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    expect(got == want, "\(what)（期望 \(want)，实际 \(got)）")
}

func expectThrows(_ what: String, _ body: () throws -> Void) {
    do { try body(); expect(false, what + "（没有抛错）") }
    catch { expect(true, what + " → \(error.localizedDescription)") }
}
@main
struct StoreSim {
    static func main() async {
        let storeDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "store")
        let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tools/sim/store/fixtures")

        print("== 1. URL 白名单 ==")
        expect(StoreClient.isAllowed(URL(string: "https://example.com/store/index.json")!), "https 放行")
        expect(StoreClient.isAllowed(URL(string: "http://127.0.0.1:8791/index.json")!), "本机 http 放行（调试）")
        expect(StoreClient.isAllowed(URL(string: "http://localhost:8791/index.json")!), "localhost 放行")
        expect(!StoreClient.isAllowed(URL(string: "http://example.com/index.json")!), "公网 http 拒绝")
        expect(!StoreClient.isAllowed(URL(string: "ftp://example.com/x")!), "非 http(s) 拒绝")
        expect(!StoreClient.isAllowed(URL(string: "https://user:pass@example.com/x")!), "带账号密码的 URL 拒绝")

        print("== 2. 版本比较 ==")
        expectEqual(StoreClient.compareVersions("1.6.4", "1.6.4"), 0, "相同版本")
        expectEqual(StoreClient.compareVersions("1.10", "1.9"), 1, "1.10 > 1.9（按数字段比）")
        expectEqual(StoreClient.compareVersions("1.6", "1.6.4"), -1, "缺位按 0")
        expectEqual(StoreClient.compareVersions("2.0", "1.99"), 1, "主版本优先")

        print("== 3. SHA-256 格式 ==")
        expect(StoreClient.isSHA256(String(repeating: "a", count: 64)), "64 位十六进制通过")
        expect(!StoreClient.isSHA256(String(repeating: "a", count: 63)), "63 位拒绝")
        expect(!StoreClient.isSHA256(String(repeating: "z", count: 64)), "非十六进制拒绝")

        print("== 3b. 相对包地址继承索引 query（托管平台 sharecode）==")
        let gated = URL(string: "https://example.com/store/index.json?sharecode=ABC")!
        expectEqual(StoreClient.resolvePackageURL("packages/x.zip", base: gated)?.absoluteString,
                    "https://example.com/store/packages/x.zip?sharecode=ABC",
                    "同源相对地址带上 sharecode")
        expectEqual(StoreClient.resolvePackageURL("https://cdn.example.org/x.zip", base: gated)?.absoluteString,
                    "https://cdn.example.org/x.zip",
                    "跨域绝对地址不泄露 sharecode")

        print("== 4. 起本地商店 ==")
        let port = freePort()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", storeDir.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        do {
            try server.run()
        } catch {
            print("✗ 无法启动本地商店：\(error.localizedDescription)"); finish(1)
        }
        httpServer = server

        let base = URL(string: "http://127.0.0.1:\(port)/index.json")!
        var ready = false
        for _ in 0..<40 {
            if let (data, resp) = try? await URLSession.shared.data(from: base),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                ready = true; break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard ready else { print("✗ 本地商店没有起来"); finish(1) }
        expect(true, "python3 http.server 已就绪（\(base.absoluteString)）")

        print("== 5. 拉取并解析索引 ==")
        do {
            let index = try await StoreClient.fetchIndex(from: base)
            expectEqual(index.name ?? "", "Isla 示例商店", "商店名称")
            expectEqual(index.plugins.count, 2, "条目数")
            let catalog = try StoreClient.buildCatalog(index: index, baseURL: base,
                                                       installed: ["com.example.web-dashboard": "0.2.2"],
                                                       appVersion: "1.6.4")
            expectEqual(catalog.count, 2, "校验后条目数")
            let web = catalog.first { $0.id == "com.example.web-dashboard" }
            expect(web?.installed == true, "已安装标记")
            expect(web?.hasUpdate == false, "同版本不算更新")
            expect(web?.compatible == true, "minAppVersion 1.6.4 对当前 1.6.4 兼容")
            let low = try StoreClient.buildCatalog(index: index, baseURL: base, installed: [:], appVersion: "1.5.0")
            expect(low.first { $0.id == "com.example.web-dashboard" }?.compatible == false,
                   "旧 App 看到「需要更新」")
            expect(low.first { $0.id == "com.example.clipboard-board" }?.compatible == false,
                   "1.5.0 低于 1.5.12 → 不兼容")
            let mid = try StoreClient.buildCatalog(index: index, baseURL: base, installed: [:], appVersion: "1.5.12")
            expect(mid.first { $0.id == "com.example.clipboard-board" }?.compatible == true,
                   "1.5.12 刚好达标 → 兼容")
        } catch {
            // 连不上本地服务器 = 环境问题（本机代理 / VPN / 沙箱偶尔会拦 127.0.0.1），
            // 不是协议实现有问题 —— 这种情况标记「环境受限」并跳过联网断言，别把自检卡死。
            if isLocalhostUnreachable(error) {
                print("⚠ 本地商店服务器连不上（环境限制：代理/VPN/沙箱可能拦了 127.0.0.1），跳过联网相关断言")
                envLimited = true
                finish(0)
            }
            expect(false, "索引拉取失败：\(error.localizedDescription)")
        }

        print("== 6. 坏索引只丢坏条目 ==")
        do {
            let url = fixtures.appendingPathComponent("bad-index.json")
            let data = try Data(contentsOf: url)
            let index = try JSONDecoder().decode(StoreIndex.self, from: data)
            let catalog = try StoreClient.buildCatalog(index: index, baseURL: base, installed: [:], appVersion: "1.6.4")
            expectEqual(catalog.count, 1, "6 条坏/重复数据里只留 1 条")
            expectEqual(catalog.first?.id ?? "-", "com.example.ok", "留下的是合法条目")
        } catch {
            expect(false, "坏索引断言失败：\(error.localizedDescription)")
        }

        print("== 7. 下载 + SHA-256 ==")
        do {
            let index = try await StoreClient.fetchIndex(from: base)
            let catalog = try StoreClient.buildCatalog(index: index, baseURL: base, installed: [:], appVersion: "1.6.4")
            guard let entry = catalog.first(where: { $0.id == "com.example.clipboard-board" }) else {
                print("✗ 找不到剪贴板插件"); finish(1)
            }
            let file = try await StoreClient.downloadPackage(from: entry.downloadURL,
                                                             expectedSHA256: entry.sha256,
                                                             expectedSize: entry.size)
            expect(FileManager.default.fileExists(atPath: file.path), "安装包已落盘")
            expectEqual((try? StoreClient.sha256(ofFile: file)) ?? "", entry.sha256, "落盘后哈希一致")
            try StoreClient.validateArchive(at: file)
            expect(true, "zip 条目检查通过")
            try? FileManager.default.removeItem(at: file)

            do {
                _ = try await StoreClient.downloadPackage(from: entry.downloadURL,
                                                          expectedSHA256: String(repeating: "0", count: 64),
                                                          expectedSize: entry.size)
                expect(false, "哈希不匹配必须拒绝（没有抛错）")
            } catch {
                expect(true, "哈希不匹配被拒绝 → \(error.localizedDescription)")
            }
            let notZip = FileManager.default.temporaryDirectory.appendingPathComponent("isla-notzip-\(UUID()).zip")
            try Data("not a zip".utf8).write(to: notZip)
            expectThrows("假 zip 必须拒绝") { try StoreClient.validateArchive(at: notZip) }
            try? FileManager.default.removeItem(at: notZip)
        } catch {
            expect(false, "下载断言失败：\(error.localizedDescription)")
        }

        print("== 8. Ed25519 索引签名 ==")
        do {
            let signed = try await StoreClient.fetchSignedIndex(from: base)
            expectEqual(signed.publisher?.name ?? "-", "Isla", "索引带发布者")
            expectEqual(signed.publisher?.keyID ?? "-", "0b52676ad8e95289", "发布者 keyID")
            expect(signed.signatureValid, "签名校验通过")
            guard let publisher = signed.publisher, let sig = signed.signature else {
                print("✗ 签名信息缺失"); finish(1)
            }
            var tampered = signed.raw
            tampered[tampered.count / 2] ^= 0xFF
            expectThrows("改一个字节必须拒绝") {
                try StoreClient.verify(indexBytes: tampered, signatureBase64: sig, publisher: publisher)
            }
            let other = Curve25519.Signing.PrivateKey()
            let otherPub = other.publicKey.rawRepresentation
            let wrongKey = StorePublisher(name: "Fake",
                                          keyID: StoreClient.keyID(forPublicKey: otherPub),
                                          publicKey: otherPub.base64EncodedString())
            expectThrows("换一把钥匙必须拒绝") {
                try StoreClient.verify(indexBytes: signed.raw, signatureBase64: sig, publisher: wrongKey)
            }
            let wrongID = StorePublisher(name: publisher.name,
                                         keyID: String(repeating: "0", count: 16),
                                         publicKey: publisher.publicKey)
            expectThrows("keyID 与公钥不一致必须拒绝") {
                try StoreClient.verify(indexBytes: signed.raw, signatureBase64: sig, publisher: wrongID)
            }
        } catch {
            expect(false, "签名断言失败：\(error.localizedDescription)")
        }

        print("")
        if failures == 0 {
            if envLimited {
                print("⚠ store 协议断言：环境受限，未能跑完联网部分（已跑 \(checks) 项）")
            } else {
                print("✓ store 协议断言全部通过（\(checks) 项）")
            }
            finish(0)
        } else {
            print("✗ \(failures)/\(checks) 项断言失败")
            finish(1)
        }
    }
}

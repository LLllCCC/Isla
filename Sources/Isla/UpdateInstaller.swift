import Foundation
import AppKit
import Security
import CryptoKit

/// 下载完成后的安装：校验新 App、同卷 staging、原子换位、helper 重启。
/// 只负责「可写目录」；不可写 / translocation 时由上层回退到 DMG 手动安装。
enum UpdateInstaller {

    static let bundleIdentifier = "com.yopo.isla"
    static let signingCN = "Isla Self Signed"
    /// 当前自签证书叶证书 SHA-256；换证书时必须先发一版旧证书签名的 App 来更新这个常量。
    static let signingLeafSHA256 = "a3ecde8c724147847839f92128827785bc1ed0a77534a0b0b749757ffb846d1e"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    // MARK: 校验

    static func validate(app: URL, release: UpdateRelease) throws {
        guard let bundle = Bundle(url: app) else {
            throw StoreError.message("更新包不是合法的 App")
        }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            throw StoreError.message("更新包的 bundle id 不对")
        }
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let build = Int((bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "") ?? 0
        guard version == release.version, build == release.build else {
            throw StoreError.message("更新包版本与 appcast 不一致")
        }
        try validateSignature(at: app)
        let host = app.appendingPathComponent("Contents/MacOS/IslaPluginHost")
        if FileManager.default.fileExists(atPath: host.path) {
            try validateSignature(at: host)
        }
    }

    /// 除了 codesign 自洽，还固定叶证书 SHA-256 与 CN，防止换一张自签证书冒充。
    static func validateSignature(at url: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw StoreError.message("无法读取更新包签名")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw StoreError.message("更新包签名校验失败")
        }
        var info: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, infoFlags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else {
            throw StoreError.message("更新包没有签名证书")
        }
        let data = SecCertificateCopyData(leaf) as Data
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == signingLeafSHA256 else {
            throw StoreError.message("更新包签名证书不是 Isla 的证书")
        }
        let cn = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        guard cn == signingCN else {
            throw StoreError.message("更新包签名证书名称不对")
        }
    }

    // MARK: 可安装性

    /// nil = 可以原地更新；非 nil = 回退 DMG 的原因。
    static func inPlaceBlocker() -> String? {
        let target = Bundle.main.bundleURL
        if target.path.contains("/AppTranslocation/") {
            return "当前是从临时位置运行的，请先把 Isla 拖进「应用程序」再更新"
        }
        let dir = target.deletingLastPathComponent()
        let probe = dir.appendingPathComponent(".isla-write-test-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            return "Isla 所在目录不可写，请下载安装包手动更新"
        }
        return nil
    }

    // MARK: 安装

    /// 准备好 staging + helper 后立即返回；调用方随后退出 App。
    static func install(newApp: URL, release: UpdateRelease) throws {
        if let blocker = inPlaceBlocker() {
            throw StoreError.message(blocker)
        }
        let target = Bundle.main.bundleURL
        let dir = target.deletingLastPathComponent()
        let id = UUID().uuidString
        let staging = dir.appendingPathComponent(".\(target.lastPathComponent).staging-\(id)")
        let old = dir.appendingPathComponent(".\(target.lastPathComponent).old-\(id)")

        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try run("/usr/bin/ditto", [newApp.path, staging.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
        try validate(app: staging, release: release)

        let support = appSupportDir()
        let backupDir = support.appendingPathComponent("Backup", isDirectory: true)
        let updaterDir = support.appendingPathComponent("updater", isDirectory: true)
        let logDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Isla", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: updaterDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = backupDir.appendingPathComponent("Isla-\(AppInfo.version)-\(AppInfo.build)-\(stamp).app")
        let log = logDir.appendingPathComponent("update.log")
        let script = updaterDir.appendingPathComponent("update-\(id).sh")
        guard let template = Bundle.main.url(forResource: "update-helper", withExtension: "sh"),
              let scriptText = try? String(contentsOf: template, encoding: .utf8) else {
            throw StoreError.message("更新助手脚本缺失")
        }
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        if !fm.fileExists(atPath: log.path) {
            fm.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path,
                       "\(ProcessInfo.processInfo.processIdentifier)",
                       target.path, staging.path, old.path, backup.path, log.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        do {
            try p.run()
        } catch {
            try? fm.removeItem(at: staging)
            throw StoreError.message(String(format: L("无法启动更新助手：%@"), error.localizedDescription))
        }
    }

    private static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Isla", isDirectory: true)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw StoreError.message(String(format: L("%@ 执行失败"), URL(fileURLWithPath: path).lastPathComponent))
        }
        return p.terminationStatus
    }
}

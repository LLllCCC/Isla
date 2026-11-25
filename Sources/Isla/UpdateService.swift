import Foundation
import AppKit

// MARK: - 更新服务

/// App 自身更新：检查 appcast、下载、校验、调用安装器。
/// 更新源只允许 HTTPS；appcast 公钥固定在二进制里，插件商店 key 与更新 key 分开。
final class UpdateService: ObservableObject {

    static let shared = UpdateService()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case verifying
        case installing
        case failed(String)
    }

    /// 默认 appcast。GitHub Pages 公开地址；本地调试可用 UserDefaults["updateFeedURL"] 覆盖。
    static let defaultFeedURL = URL(string: "https://llllccc.github.io/Isla/appcast.json")!
    static let releasePageURL = URL(string: "https://github.com/LLllCCC/Isla/releases/latest")!
    /// 更新签名公钥（appcast 专用），与插件商店 key 分开。
    static let pinnedPublicKeys = ["zvfhfeRxoA0jZ70rsTHpekVLk5wYqi5dERXq7T0SVQo="]
    static let maxUpdateBytes = UpdateAppcast.maxUpdateBytes
    static let maxAppcastBytes = UpdateAppcast.maxAppcastBytes

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: UpdateRelease?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?

    var currentVersion: String { AppInfo.version }
    var currentBuild: Int { AppInfo.buildInt }
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    private init() {}

    // MARK: 检查

    /// manual = true 时失败会显示错误；自动检查失败只记录，不打扰。
    func check(manual: Bool, presentIfAvailable: Bool = true) {
        guard !isBusy else { return }
        phase = .checking
        lastError = nil
        let currentBuild = self.currentBuild
        Task { [weak self] in
            do {
                let release = try await Self.fetchRelease(currentBuild: currentBuild)
                DispatchQueue.main.async {
                    guard let self else { return }
                    SettingsStore.shared.lastUpdateCheck = Date().timeIntervalSince1970
                    if let release {
                        self.release = release
                        self.phase = .available
                        if presentIfAvailable {
                            let shouldPrompt = manual || SettingsStore.shared.lastPromptedBuild != release.build
                            if shouldPrompt {
                                SettingsStore.shared.lastPromptedBuild = release.build
                                UpdateWindowController.shared.show()
                            }
                        }
                    } else {
                        self.release = nil
                        self.phase = .upToDate
                        if manual { UpdateWindowController.shared.show() }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastError = error.localizedDescription
                    if manual {
                        self.phase = .failed(error.localizedDescription)
                        UpdateWindowController.shared.show()
                    } else {
                        self.phase = .idle
                    }
                }
            }
        }
    }

    /// 启动后/每 24 小时自动检查一次；只在发现新版本时提示。
    func autoCheckIfNeeded() {
        guard SettingsStore.shared.autoCheckUpdates else { return }
        let last = SettingsStore.shared.lastUpdateCheck
        let now = Date().timeIntervalSince1970
        guard now - last > 24 * 3600 else { return }
        check(manual: false, presentIfAvailable: true)
    }

    func present() {
        UpdateWindowController.shared.show()
        if case .available = phase { return }
        if isBusy { return }
        check(manual: true, presentIfAvailable: true)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(Self.releasePageURL)
    }

    // MARK: 手动下载安装包

    func downloadInstaller() {
        guard let release, !isBusy else { return }
        guard let raw = release.dmg, let url = URL(string: raw), StoreClient.isAllowed(url),
              let sha = release.dmgSha256, StoreClient.isSHA256(sha) else {
            phase = .failed("这个版本没有提供安装包，请打开 Release 页面")
            return
        }
        phase = .downloading
        progress = 0
        Task { [weak self] in
            do {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
                let name = "Isla-\(release.version)-\(release.build).dmg"
                let dest = downloads.appendingPathComponent(name)
                _ = try await self?.download(url, expectedSize: release.dmgSize,
                                             expectedSHA256: sha, to: dest)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.progress = 1
                    self.phase = .available
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastError = error.localizedDescription
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: 直接更新

    func installDirect() {
        guard let release, !isBusy else { return }
        guard let url = URL(string: release.zip), StoreClient.isAllowed(url),
              StoreClient.isSHA256(release.zipSha256) else {
            phase = .failed("更新包地址无效")
            return
        }
        phase = .downloading
        progress = 0
        Task { [weak self] in
            do {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("isla-update-\(release.build)-\(UUID().uuidString).zip")
                _ = try await self?.download(url, expectedSize: release.zipSize,
                                             expectedSHA256: release.zipSha256, to: temp)
                DispatchQueue.main.async { self?.phase = .verifying }
                try StoreClient.validateArchive(at: temp)
                let unzipDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("isla-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
                try Self.unzip(temp, to: unzipDir)
                let newApp = unzipDir.appendingPathComponent("Isla.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw StoreError.message("更新包里没有 Isla.app")
                }
                try UpdateInstaller.validate(app: newApp, release: release)
                DispatchQueue.main.async { self?.phase = .installing }
                try UpdateInstaller.install(newApp: newApp, release: release)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastError = error.localizedDescription
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: 网络

    private static func feedURL() -> URL {
        let raw = UserDefaults.standard.string(forKey: "updateFeedURL")
            ?? ProcessInfo.processInfo.environment["ISLA_UPDATE_URL"]
            ?? defaultFeedURL.absoluteString
        let base = URL(string: raw) ?? defaultFeedURL
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
        comps?.queryItems = items
        return comps?.url ?? base
    }

    private static func fetchRelease(currentBuild: Int) async throws -> UpdateRelease? {
        let url = feedURL()
        guard StoreClient.isAllowed(url) else {
            throw StoreError.message("更新地址必须是 HTTPS")
        }
        let data = try await StoreClient.fetchData(from: url, limit: maxAppcastBytes)
        return try UpdateAppcast.decodeAndVerify(data: data,
                                                 pinnedKeys: pinnedPublicKeys,
                                                 currentBuild: currentBuild,
                                                 source: url)
    }

    // MARK: 下载（带进度）

    @discardableResult
    private func download(_ url: URL, expectedSize: Int?, expectedSHA256: String,
                          to destination: URL) async throws -> URL {
        let downloader = UpdateDownloader(destination: destination,
                                          expectedSize: expectedSize,
                                          expectedSHA256: expectedSHA256,
                                          maxBytes: Self.maxUpdateBytes) { [weak self] p in
            DispatchQueue.main.async { self?.progress = p }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            downloader.start(url: url, continuation: continuation)
        }
        return destination
    }

    private static func unzip(_ zip: URL, to dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw StoreError.message("解压更新包失败")
        }
    }
}

// MARK: - 下载器

private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedSize: Int?
    private let expectedSHA256: String
    private let maxBytes: Int
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var finished = false

    init(destination: URL, expectedSize: Int?, expectedSHA256: String,
         maxBytes: Int, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    func start(url: URL, continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        session.downloadTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = expectedSize.map(Double.init)
            ?? (totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : 0)
        guard total > 0 else { return }
        onProgress(min(1, max(0, Double(totalBytesWritten) / total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw StoreError.message(String(format: L("下载失败：HTTP %d"), http.statusCode))
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= maxBytes else {
                throw StoreError.message("更新包为空或超过大小上限")
            }
            if let expectedSize, expectedSize != size {
                throw StoreError.message("更新包大小与 appcast 不一致")
            }
            let actual = try StoreClient.sha256(ofFile: location)
            guard actual == expectedSHA256.lowercased() else {
                throw StoreError.message("更新包 SHA-256 校验失败，可能被替换")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(())) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

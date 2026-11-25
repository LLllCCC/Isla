import SwiftUI
import AppKit

/// App 更新窗口：检查、下载、直接更新并重启。
/// 只依赖 UpdateService；不使用 @State 宏（CLT 环境缺 SwiftUIMacros）。
struct UpdateView: View {
    @ObservedObject var service = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().opacity(0.35)
            status
            if let release = service.release, service.phase == .available {
                releaseInfo(release)
            }
            if service.phase == .downloading {
                ProgressView(value: service.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(service.progress * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 10) {
                buttons
                Spacer(minLength: 12)
                Button("关闭") { NSApp.keyWindow?.close() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Isla 更新")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(String(format: L("当前 v%@ (build %@)"),
                            service.currentVersion, String(service.currentBuild)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch service.phase {
        case .idle:
            Text("检查是否有新版本。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查更新…")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
        case .upToDate:
            Text("当前已是最新版本。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        case .available:
            if let release = service.release {
                Text(String(format: L("发现新版本 v%@ (build %d)"), release.version, release.build))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
        case .downloading:
            Text("正在下载更新包…")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        case .verifying:
            Text("正在校验更新包…")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        case .installing:
            Text("正在安装，Isla 即将重启…")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func releaseInfo(_ release: UpdateRelease) -> some View {
        let notes = isEnglishUIEnabled ? (release.notesEn ?? release.notes ?? "") : (release.notes ?? "")
        if !notes.isEmpty {
            ScrollView {
                Text(notes)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if case .available = service.phase, let release = service.release {
            Button("直接更新并重启") { service.installDirect() }
                .buttonStyle(.borderedProminent)
            if release.dmg != nil {
                Button("下载安装包") { service.downloadInstaller() }
            }
            Button("打开 Release 页面") { service.openReleasePage() }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
        } else {
            Button("检查更新") { service.check(manual: true, presentIfAvailable: false) }
                .disabled(service.isBusy)
        }
    }
}

final class UpdateWindowController: NSWindowController {
    static let shared = UpdateWindowController()

    private init() {
        let hosting = NSHostingController(rootView: UpdateView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Isla 更新")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: Theme.isDarkUI ? .darkAqua : .aqua)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

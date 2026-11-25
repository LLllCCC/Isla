import AppKit
import Combine
import UniformTypeIdentifiers

/// 文件暂存架：把文件拖到菜单栏胶囊上收进来，需要时从面板拖到 Finder / 邮件 / AirDrop。
/// 只存「引用」（路径 + 时间），不复制文件内容，所以不占磁盘；
/// 重启后仍在，但每次加载都会剔除已不存在的文件。
final class ShelfService: ObservableObject {
    static let shared = ShelfService()

    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let added: Date

        var name: String { url.lastPathComponent }
        var folder: String { url.deletingLastPathComponent().path }
    }

    @Published private(set) var items: [Item] = []

    private let key = "shelfItems"
    private let d = UserDefaults.standard
    private let maxItems = 20

    private init() {}

    func load() {
        let raw = d.array(forKey: key) as? [[String: Any]] ?? []
        let fm = FileManager.default
        items = raw.compactMap { entry -> Item? in
            guard let path = entry["path"] as? String,
                  fm.fileExists(atPath: path) else { return nil }   // 文件没了就别留死链
            let ts = entry["added"] as? Double ?? 0
            return Item(id: UUID(), url: URL(fileURLWithPath: path),
                        added: Date(timeIntervalSince1970: ts))
        }
        if items.count != raw.count { save() }
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        var added = 0
        for url in urls.reversed() where fm.fileExists(atPath: url.path) {
            if items.contains(where: { $0.url.path == url.path }) { continue }
            items.insert(Item(id: UUID(), url: url, added: Date()), at: 0)
            added += 1
        }
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        save()
        return added
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func ageText(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return L("刚刚") }
        if s < 3600 { return String(format: L("%d 分"), Int(s / 60)) }
        if s < 86400 { return String(format: L("%d 时"), Int(s / 3600)) }
        return String(format: L("%d 天"), Int(s / 86400))
    }

    func icon(for item: Item) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    private func save() {
        d.set(items.map { ["path": $0.url.path, "added": $0.added.timeIntervalSince1970] }, forKey: key)
    }
}

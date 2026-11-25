import Foundation

/// 品牌常量与旧版数据迁移。
/// 改名的应用：显示名/可执行文件/插件目录用 `name`，bundle id 用 `bundleID`；
/// 旧版本 `com.yopo.macisland` 的 UserDefaults 在首次启动时复制过来，避免丢设置。
enum Brand {
    static let name = "Isla"
    static let bundleID = "com.yopo.isla"
    static let legacyBundleID = "com.yopo.macisland"
    static let supportFolder = "Isla"

    /// 新 bundle id 第一次启动时，把旧域名的偏好复制到新域名。
    /// 只复制缺失的键，不覆盖新值；旧数据保留，方便回滚。
    static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        let marker = "didMigrateFromMacIsland"
        guard !d.bool(forKey: marker) else { return }
        d.set(true, forKey: marker)

        guard let old = d.persistentDomain(forName: legacyBundleID) else { return }
        // 首次启动引导不迁移：bundle id 变了，辅助功能/自动化授权要重新给，
        // 让新名字下的第一次启动重新出现引导。
        let skip: Set<String> = ["didShowFirstRunGuide", marker]
        for (key, value) in old {
            if key.hasPrefix("NS") || key.hasPrefix("Apple") { continue }
            if skip.contains(key) { continue }
            if d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }
    }
}

import AppKit

/// 轻量本地化入口。
///
/// SwiftUI 的 `Text("中文")` / `Button("中文")` 会自动以中文原文为 key 去
/// `en.lproj/Localizable.strings` 查英文；AppKit 的菜单、弹窗标题不是自动的，
/// 用 `L("中文")` 手动过一次。没有对应条目时原样返回中文，所以漏翻译只会退化为中文，
/// 不会出现空白或 key。
/// 当前是否英文界面（跟随 App 的 AppleLanguages）
var isEnglishUIEnabled: Bool {
    (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("en")
}

func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

extension Notification.Name {
    /// 用户改了界面语言，需要重启 App 才能让 bundle 重新选择语言。
    static let islaRestartRequested = Notification.Name("islaRestartRequested")
}

extension NSMenuItem {
    /// 菜单项标题走一次本地化表；其余参数与原生 init 一致。
    convenience init(localizedTitle: String, action: Selector?, keyEquivalent: String) {
        self.init(title: L(localizedTitle), action: action, keyEquivalent: keyEquivalent)
    }
}

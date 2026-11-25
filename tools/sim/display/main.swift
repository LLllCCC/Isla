// Isla 多显示器选屏逻辑的仿真断言。
// 只编译纯逻辑文件 Sources/Isla/DisplaySelection.swift（不碰 AppKit 窗口），
// 用假的显示器几何覆盖：主屏 / 副屏在右 / 副屏在下 / 刘海屏 / 自动隐藏菜单栏 / 拔屏回退。
//
// 运行：
//   swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
//     main.swift ../../../Sources/Isla/DisplaySelection.swift -o simdisplay -framework Cocoa && ./simdisplay

import AppKit

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

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    expect(got == want, "\(what)（期望 \(want)，实际 \(got)）")
}

// 主屏 1920×1080，菜单栏 30（AppKit 原点左下）
let primary = DisplaySnapshot(
    id: 1, name: "内置显示器",
    frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1050),
    safeAreaTop: 0, isPrimary: true
)
// 副屏在右侧，1440×900，菜单栏 24（不同屏高度不同）
let right = DisplaySnapshot(
    id: 2, name: "外接显示器",
    frame: NSRect(x: 1920, y: 0, width: 1440, height: 900),
    visibleFrame: NSRect(x: 1920, y: 0, width: 1440, height: 876),
    safeAreaTop: 0, isPrimary: false
)
// 副屏在下方，1280×720
let below = DisplaySnapshot(
    id: 3, name: "投影仪",
    frame: NSRect(x: 200, y: -720, width: 1280, height: 720),
    visibleFrame: NSRect(x: 200, y: -720, width: 1280, height: 720),
    safeAreaTop: 0, isPrimary: false
)
// 刘海笔记本屏：safeAreaTop = 32
let notched = DisplaySnapshot(
    id: 4, name: "MacBook 屏",
    frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
    safeAreaTop: 32, isPrimary: true
)

let screens = [primary, right, below]

print("== 1. 主显示器 ==")
expectEqual(DisplaySelection.resolve(target: .main, fixedID: nil,
                                      pointer: CGPoint(x: 2500, y: 400),
                                      screens: screens)?.id, 1,
            "即使指针在副屏，主屏模式也留在主屏")

print("== 2. 跟随鼠标 ==")
expectEqual(DisplaySelection.resolve(target: .pointer, fixedID: nil,
                                      pointer: CGPoint(x: 2500, y: 400),
                                      screens: screens)?.id, 2,
            "指针在右侧副屏 → 选副屏")
expectEqual(DisplaySelection.resolve(target: .pointer, fixedID: nil,
                                      pointer: CGPoint(x: 300, y: -300),
                                      screens: screens)?.id, 3,
            "指针在下方副屏（负坐标）→ 选下方屏")
expectEqual(DisplaySelection.resolve(target: .pointer, fixedID: nil,
                                      pointer: CGPoint(x: 100, y: -800),
                                      screens: screens, current: 2)?.id, 2,
            "指针落在屏幕缝隙（所有屏之外）时保留当前屏，不跳回主屏")
expectEqual(DisplaySelection.resolve(target: .pointer, fixedID: nil,
                                      pointer: CGPoint(x: 100, y: -800),
                                      screens: screens)?.id, 1,
            "没有当前屏时缝隙回退主屏")

print("== 3. 指定显示器 ==")
expectEqual(DisplaySelection.resolve(target: .fixed, fixedID: 2,
                                      pointer: CGPoint(x: 100, y: 100),
                                      screens: screens)?.id, 2,
            "指定 id=2 → 副屏，不受指针影响")
expectEqual(DisplaySelection.resolve(target: .fixed, fixedID: 99,
                                      pointer: CGPoint(x: 100, y: 100),
                                      screens: screens, current: 2)?.id, 2,
            "指定屏被拔掉 → 回退当前屏")
expectEqual(DisplaySelection.resolve(target: .fixed, fixedID: nil,
                                      pointer: CGPoint(x: 100, y: 100),
                                      screens: screens)?.id, 1,
            "未指定（nil）→ 回退主屏")

print("== 4. 空屏幕列表 ==")
expect(DisplaySelection.resolve(target: .main, fixedID: nil,
                                pointer: .zero, screens: []) == nil,
       "无屏可选用时返回 nil，由调用方保留旧值")

print("== 5. 菜单栏高度分屏缓存 ==")
var cache: [CGDirectDisplayID: CGFloat] = [:]
expectEqual(DisplaySelection.menuBarHeight(for: primary, cache: &cache), 30,
            "主屏菜单栏 30（1080 − 1050）")
expectEqual(DisplaySelection.menuBarHeight(for: right, cache: &cache), 24,
            "副屏菜单栏 24，独立记一份")
expectEqual(DisplaySelection.menuBarHeight(for: below, cache: &cache), 30,
            "菜单栏自动隐藏（visibleFrame == frame）且无缓存 → 用 30 兜底")
var secondaryCache: [CGDirectDisplayID: CGFloat] = [:]
expectEqual(DisplaySelection.menuBarHeight(for: below, cache: &secondaryCache, fallback: 0), 0,
            "副屏没有菜单栏且无缓存 → 0，不留 30pt 空缝")
_ = DisplaySelection.menuBarHeight(for: primary, cache: &cache)
// 模拟主屏自动隐藏：visibleFrame 顶到 frame 顶
let primaryHidden = DisplaySnapshot(id: 1, name: primary.name,
                                    frame: primary.frame,
                                    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                                    safeAreaTop: 0, isPrimary: true)
expectEqual(DisplaySelection.menuBarHeight(for: primaryHidden, cache: &cache), 30,
            "主屏自动隐藏时沿用该屏上次的 30，不塌成 0")
expectEqual(DisplaySelection.menuBarHeight(for: notched, cache: &cache), 32,
            "刘海屏按 safeArea 计算菜单栏 32")

print("== 6. 尺寸容纳判断 ==")
expect(DisplaySelection.fits(size: CGSize(width: 400, height: 620), in: below),
       "400×620 能放进 1280×720 副屏（留 40pt 余量）")
expect(!DisplaySelection.fits(size: CGSize(width: 400, height: 700), in: below),
       "400×700 放不进 720 高的屏")
expect(!DisplaySelection.fits(size: CGSize(width: 2000, height: 300), in: primary),
       "比屏还宽的布局放不下")

print("")
if failures == 0 {
    print("✓ display 逻辑断言全部通过（\(checks) 项）")
    exit(0)
} else {
    print("✗ \(failures)/\(checks) 项断言失败")
    exit(1)
}

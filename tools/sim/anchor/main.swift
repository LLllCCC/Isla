// Isla 胶囊水平锚点逻辑的仿真断言。
//
// 只编译纯逻辑文件 Sources/Isla/CapsuleAnchor.swift（不碰 AppKit 窗口），
// 覆盖：加宽方向（左/右/两边）、屏幕边界夹取、拖动偏移换算与落盘夹取。
//
// 运行：
//   cd tools/sim/anchor && swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
//     main.swift ../../../Sources/Isla/CapsuleAnchor.swift -o simanchor -framework Cocoa && ./simanchor

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

let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let slot: CGFloat = 1000          // 状态项槽位中心
let extra: CGFloat = 280          // 歌词加宽出来的额外宽度
let overlay: CGFloat = 400        // 加宽后的浮层总宽

print("=== 胶囊锚点 ===")

// 未加宽时，锚点就是槽位
expectEqual(CapsuleAnchor.widened(slot: slot, extra: 0, direction: .left,
                                  screen: screen, overlayWidth: overlay),
            slot, "没有加宽时锚点不动")

// 向左加宽：中心左移半个增量
expectEqual(CapsuleAnchor.widened(slot: slot, extra: extra, direction: .left,
                                  screen: screen, overlayWidth: overlay),
            slot - extra / 2, "向左加宽：中心左移半个增量")

// 向右加宽：中心右移半个增量
expectEqual(CapsuleAnchor.widened(slot: slot, extra: extra, direction: .right,
                                  screen: screen, overlayWidth: overlay),
            slot + extra / 2, "向右加宽：中心右移半个增量")

// 向两边展开：中心不动
expectEqual(CapsuleAnchor.widened(slot: slot, extra: extra, direction: .both,
                                  screen: screen, overlayWidth: overlay),
            slot, "向两边展开：中心不动")

// 左边界：向左加宽时不能把胶囊推出屏幕
let nearLeft: CGFloat = 120
expectEqual(CapsuleAnchor.widened(slot: nearLeft, extra: extra, direction: .left,
                                  screen: screen, overlayWidth: overlay),
            screen.minX + overlay / 2 + 4, "靠近左边界时向左加宽被夹住")

// 右边界：向右加宽时同理
let nearRight: CGFloat = 1850
expectEqual(CapsuleAnchor.widened(slot: nearRight, extra: extra, direction: .right,
                                  screen: screen, overlayWidth: overlay),
            screen.maxX - overlay / 2 - 4, "靠近右边界时向右加宽被夹住")

print("=== 偏移夹取 ===")

expectEqual(CapsuleAnchor.clamped(slot: slot, offset: 0, screen: screen, overlayWidth: overlay),
            slot, "没有偏移时不动")

expectEqual(CapsuleAnchor.clamped(slot: slot, offset: -120, screen: screen, overlayWidth: overlay),
            slot - 120, "负偏移生效")

expectEqual(CapsuleAnchor.clamped(slot: slot, offset: 99999, screen: screen, overlayWidth: overlay),
            screen.maxX - overlay / 2 - 4, "偏移过大被右边界夹住")

expectEqual(CapsuleAnchor.clamped(slot: slot, offset: -99999, screen: screen, overlayWidth: overlay),
            screen.minX + overlay / 2 + 4, "偏移过小被左边界夹住")

// 屏幕太窄时（半宽超过屏幕）不乱夹
let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
expectEqual(CapsuleAnchor.clamped(slot: 50, offset: -30, screen: tiny, overlayWidth: 400),
            50, "屏幕装不下胶囊时保持原位")

print("=== 拖动偏移换算 ===")

expectEqual(CapsuleAnchor.offset(forCurrentX: 880, baseAnchor: 1000), -120, "当前位置减基准锚点")
expectEqual(CapsuleAnchor.sanitizedOffset(-9999), -400, "落盘前夹到 -400")
expectEqual(CapsuleAnchor.sanitizedOffset(9999), 400, "落盘前夹到 +400")
expectEqual(CapsuleAnchor.sanitizedOffset(37.5), 37.5, "正常值原样保留")

print("")
if failures == 0 {
    print("✓ 胶囊锚点断言全部通过（\(checks) 项）")
    exit(0)
} else {
    print("✗ \(failures)/\(checks) 项断言失败")
    exit(1)
}

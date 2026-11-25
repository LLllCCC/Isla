import AppKit
import CoreGraphics

// 校验「居中」形态下面板是否真的跟着浮胶囊走。
// 读 App 的 UserDefaults 拿 form / panelOffsetX；用 CGWindowList 取真实窗口 frame。
// 通过条件：|面板中点 − (胶囊中点 + 用户拖动偏移)| <= 2pt。

let domain = ProcessInfo.processInfo.environment["ISLA_BUNDLE_ID"] ?? "com.yopo.isla"
let ownerName = ProcessInfo.processInfo.environment["ISLA_OWNER"] ?? "Isla"
let pidFilter = ProcessInfo.processInfo.environment["MACISLAND_PID"].flatMap(Int.init)
let defaults = UserDefaults(suiteName: domain)
let form = defaults?.string(forKey: "form") ?? "capsule"
let placement = defaults?.string(forKey: "centeredPlacement") ?? "exact"
let offsetX = defaults?.double(forKey: "panelOffsetX") ?? 0

if form != "centered" {
    print("form=\(form)（非居中形态，跳过跟随断言）")
    exit(0)
}

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(2)
}

var capsule: CGRect?
var panel: CGRect?
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == ownerName else { continue }
    if let pidFilter, (w[kCGWindowOwnerPID as String] as? Int) != pidFilter { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    guard layer >= 25,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
    let rect = CGRect(x: x, y: y, width: width, height: height)
    if width <= 140, height <= 40 {
        capsule = rect
    } else {
        panel = rect
    }
}

guard let c = capsule, let p = panel else {
    print("居中形态下没有同时找到浮胶囊和面板（面板是否收起？）")
    exit(2)
}

let expectedPanelMid = c.midX + offsetX
let delta = p.midX - expectedPanelMid
print(String(format: "placement=%@  capsule midX=%.1f  panel midX=%.1f  offsetX=%.1f  expected=%.1f  delta=%.1f",
             placement, c.midX, p.midX, offsetX, expectedPanelMid, delta))

if placement == "exact" {
    guard let screen = NSScreen.main else {
        print("找不到主屏"); exit(2)
    }
    let centerDelta = c.midX - screen.frame.midX
    print(String(format: "screen midX=%.1f  capsule-to-center=%.1f", screen.frame.midX, centerDelta))
    if abs(centerDelta) > 1.5 {
        print("✗ 胶囊没有落在屏幕正中")
        exit(3)
    }
}

if abs(delta) <= 2 {
    print("✓ 面板跟随浮胶囊\(placement == "exact" ? "，胶囊居中" : "")")
    exit(0)
} else {
    print("✗ 面板没有跟随浮胶囊")
    exit(3)
}

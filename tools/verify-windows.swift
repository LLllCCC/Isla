import AppKit
import CoreGraphics

// 校验 Isla 的「面板」：顶边不得高于所在那块屏的菜单栏下沿。
// 例外：胶囊窗口本来就有意落在菜单栏条带里（会遮挡中间的图标，这是产品选择），
// 按尺寸识别后单独计数，不混进面板几何不变量。
// CGWindowList 用左上角原点（主屏顶边 y=0），每块屏的菜单栏高度可能不同，
// 因此必须按窗口中心所在的 NSScreen 逐块判断，不能统一用主屏的 30pt。

let primaryTop = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
let ownerName = ProcessInfo.processInfo.environment["ISLA_OWNER"] ?? "Isla"
let pidFilter = ProcessInfo.processInfo.environment["MACISLAND_PID"].flatMap(Int.init)

func screen(forCGPoint p: CGPoint) -> NSScreen? {
    let appkit = CGPoint(x: p.x, y: primaryTop - p.y)
    return NSScreen.screens.first { $0.frame.contains(appkit) }
}

func menuBarHeight(_ s: NSScreen) -> CGFloat {
    let h = s.frame.maxY - s.visibleFrame.maxY
    return (h > 1 && h < 64) ? h : 30
}

print("screens = \(NSScreen.screens.count)  primaryTop = \(primaryTop)  owner=\(ownerName)  pid=\(pidFilter.map(String.init) ?? "-")")
for s in NSScreen.screens {
    print(String(format: "  screen %@ frame=(%.0f,%.0f,%.0f×%.0f) menu=%.0f",
                 s.localizedName, s.frame.minX, s.frame.minY, s.frame.width, s.frame.height, menuBarHeight(s)))
}

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}

var panels = 0
var capsules = 0
var violations = 0
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == ownerName else { continue }
    if let pidFilter, (w[kCGWindowOwnerPID as String] as? Int) != pidFilter { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    // 只看「岛」自己的浮层（NSPanel level = .statusBar = 25）。
    // 设置窗口是普通窗口（layer 0），用户拖到菜单栏下面也不该算违规。
    guard layer >= 25 else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }

    let host = screen(forCGPoint: CGPoint(x: x + width / 2, y: y + height / 2))
    let menuH = host.map(menuBarHeight) ?? 30
    // 该屏顶边在 CG 坐标里的 y
    let screenTop = host.map { primaryTop - $0.frame.maxY } ?? 0
    let menuBottom = screenTop + menuH

    // 胶囊：高度 <= 40 就是胶囊（歌词「加宽」模式最宽可到 460pt，不能再用宽度判）。
    if height <= 40 {
        capsules += 1
        print(String(format: "win#%d layer=%d CAPSULE frame=(%.0f, %.0f, %.0f×%.0f) screen=%@（有意位于菜单栏内）",
                     num, layer, x, y, width, height, host?.localizedName ?? "?"))
        continue
    }

    panels += 1
    let ok = y >= menuBottom - 0.5
    if !ok { violations += 1 }
    print(String(format: "win#%d layer=%d alpha=%.2f  PANEL frame=(%.0f, %.0f, %.0f×%.0f) screen=%@ menuBottom=%.0f  %@",
                 num, layer, alpha, x, y, width, height, host?.localizedName ?? "?", menuBottom,
                 ok ? "OK" : "VIOLATION"))
}

print("panels=\(panels) capsules=\(capsules) violations=\(violations)")
exit(violations == 0 && panels > 0 ? 0 : 2)

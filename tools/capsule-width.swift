import CoreGraphics
import Foundation
// 输出：epoch 秒 + 胶囊窗口宽度；只在变化时打印，便于算「多久之后变宽/缩回」。
let dur = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "20") ?? 20
var last = ""
let end = Date().addingTimeInterval(dur)
while Date() < end {
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "Isla" else { continue }
            guard (w[kCGWindowLayer as String] as? Int ?? -1) >= 25 else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = b["Width"] as? Double ?? 0
            let height = b["Height"] as? Double ?? 0
            guard height <= 40 else { continue }
            let x = b["X"] as? Double ?? 0
            let key = String(format: "%.0f@%.0f", width, x)
            if key != last {
                last = key
                print(String(format: "%.3f %.0f %.0f", Date().timeIntervalSince1970, width, x))
                fflush(stdout)
            }
        }
    }
    usleep(30_000)
}

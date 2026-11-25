import AppKit

// 无 Xcode 环境下的入口：直接用 swiftc 编译，setActivationPolicy(.accessory) 让它成为纯菜单栏 App
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

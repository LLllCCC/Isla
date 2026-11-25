import AppKit

// Isla 图标生成器：矢量绘制 1024 母版，再导出 iconset 交给 iconutil。
// 设计：无刘海（Mac mini）——不放缺口，画「菜单栏下挂着的玻璃胶囊」本身。
// 用法：swift tools/make-icon.swift <输出目录> [dark|light]
//   dark  = 深灰底 + 黑色胶囊（默认，Dock 深色观感）
//   light = 乳白底 + 同一个黑色胶囊（浅色 Dock / 亮壁纸更清楚）

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let scheme = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
let isLight = scheme == "light"
let mint = NSColor(srgbRed: 0.42, green: 0.92, blue: 0.72, alpha: 1)

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    ctx.setShouldAntialias(true)

    // 背景：深色 squircle（Apple 图标网格：1024 画布内 824 内容，这里取 840 视觉更饱满）
    let content = NSRect(x: 92, y: 92, width: 840, height: 840)
    let bgPath = NSBezierPath(roundedRect: content, xRadius: 232, yRadius: 232)
    let bgColors: [NSColor] = isLight
        ? [NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
           NSColor(srgbRed: 0.95, green: 0.93, blue: 0.90, alpha: 1)]
        : [NSColor(srgbRed: 0.24, green: 0.28, blue: 0.34, alpha: 1),
           NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)]
    NSGradient(colors: bgColors)!.draw(in: bgPath, angle: -90)

    // 内容裁剪在 squircle 内
    NSGraphicsContext.saveGraphicsState()
    bgPath.addClip()

    // 菜单栏条：顶部一条稍亮的带子 + 右侧三个状态点
    let barColor = isLight
        ? NSColor(srgbRed: 0.965, green: 0.955, blue: 0.94, alpha: 1)
        : NSColor(srgbRed: 0.11, green: 0.13, blue: 0.16, alpha: 1)
    barColor.setFill()
    NSRect(x: 92, y: 806, width: 840, height: 126).fill()
    (isLight ? NSColor(calibratedWhite: 0, alpha: 0.07) : NSColor(calibratedWhite: 1, alpha: 0.06)).setFill()
    NSRect(x: 92, y: 806, width: 840, height: 2).fill()
    for i in 0..<3 {
        let dot = NSRect(x: 766 + CGFloat(i) * 44, y: 850, width: 16, height: 16)
        (isLight ? NSColor(calibratedWhite: 0, alpha: 0.32) : NSColor(calibratedWhite: 1, alpha: 0.28)).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    // 胶囊面板：从菜单栏垂下来的那块（垂直居中，别让下半部分空掉）
    let panel = NSRect(x: 160, y: 342, width: 704, height: 356)
    let panelPath = NSBezierPath(roundedRect: panel, xRadius: 96, yRadius: 96)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 48
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 1).setFill()
    panelPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 玻璃质感：自上而下一点高光
    NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.10),
                        NSColor(calibratedWhite: 1, alpha: 0.01)])!
        .draw(in: panelPath, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
    panelPath.lineWidth = 4
    panelPath.stroke()

    // 波形三柱（垂直居中于面板）
    let heights: [CGFloat] = [118, 204, 152]
    for (i, h) in heights.enumerated() {
        let bar = NSRect(x: 240 + CGFloat(i) * 80, y: 552 - h / 2, width: 52, height: h)
        mint.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 20, yRadius: 20).fill()
    }

    // 右侧两条信息线（暗示标题 / 副标题），避免右侧留白
    NSColor(calibratedWhite: 1, alpha: 0.26).setFill()
    NSBezierPath(roundedRect: NSRect(x: 556, y: 566, width: 236, height: 22),
                 xRadius: 11, yRadius: 11).fill()

    // 进度线：薄荷色已播放段 + 半透明轨道
    NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
    NSBezierPath(roundedRect: NSRect(x: 240, y: 400, width: 552, height: 18),
                 xRadius: 9, yRadius: 9).fill()
    mint.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 240, y: 400, width: 352, height: 18),
                 xRadius: 9, yRadius: 9).fill()

    NSGraphicsContext.restoreGraphicsState()

    // 外描边，避免纯深色在深色 Dock 上糊掉
    (isLight ? NSColor(calibratedWhite: 0, alpha: 0.10) : NSColor(calibratedWhite: 1, alpha: 0.10)).setStroke()
    bgPath.lineWidth = 2
    bgPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconset 需要的档位
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let rep = render(size)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

print("iconset 已生成：\(outDir)（\(scheme)）")

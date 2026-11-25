import AppKit

// Isla 图标：**同一份矢量构图**，深/浅两套配色。
// 深色与浅色只差背景与描边，形状、胶囊、波形完全一致。
// 用法：swift tools/make-icon-v2.swift <out.iconset> <dark|light>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let scheme = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
let isLight = scheme == "light"
let mint = NSColor(srgbRed: 0.42, green: 0.92, blue: 0.72, alpha: 1)

// 两套配色
struct Palette {
    let bgTop: NSColor
    let bgBottom: NSColor
    let pill: NSColor
    let pillStroke: NSColor
    let outerStroke: NSColor
    let highlight: NSColor
}
let dark = Palette(
    bgTop: NSColor(srgbRed: 0.335, green: 0.375, blue: 0.445, alpha: 1),
    bgBottom: NSColor(srgbRed: 0.115, green: 0.13, blue: 0.16, alpha: 1),
    pill: NSColor(srgbRed: 0.03, green: 0.035, blue: 0.045, alpha: 1),
    // 深底上黑胶囊要靠边线才看得出来：0.16 太淡，Dock 64px 下几乎消失
    pillStroke: NSColor(calibratedWhite: 1, alpha: 0.42),
    outerStroke: NSColor(calibratedWhite: 1, alpha: 0.10),
    highlight: NSColor(calibratedWhite: 1, alpha: 0.08))
let light = Palette(
    bgTop: NSColor(srgbRed: 1.0, green: 0.999, blue: 0.995, alpha: 1),
    bgBottom: NSColor(srgbRed: 0.952, green: 0.937, blue: 0.914, alpha: 1),
    pill: NSColor(srgbRed: 0.035, green: 0.04, blue: 0.05, alpha: 1),
    pillStroke: NSColor(calibratedWhite: 1, alpha: 0.16),
    outerStroke: NSColor(calibratedWhite: 0, alpha: 0.10),
    highlight: NSColor(calibratedWhite: 1, alpha: 0.55))
let pal = isLight ? light : dark

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

    // 外壳 squircle
    let content = NSRect(x: 46, y: 46, width: 932, height: 932)
    let bg = NSBezierPath(roundedRect: content, xRadius: 232, yRadius: 232)
    NSGradient(colors: [pal.bgTop, pal.bgBottom])!.draw(in: bg, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    // 顶部高光（浅色版更强一点，否则大面积纯白太平）
    NSGradient(colors: [pal.highlight, pal.highlight.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 46, y: 690, width: 932, height: 288), angle: -90)

    // 黑色胶囊：两套配色完全同一颗
    let pill = NSRect(x: 116, y: 350, width: 792, height: 324)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: 162, yRadius: 162)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(isLight ? 0.26 : 0.55)
    shadow.shadowBlurRadius = 44
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    pal.pill.setFill()
    pillPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.08),
                        NSColor(calibratedWhite: 1, alpha: 0)])!
        .draw(in: pillPath, angle: -90)
    pal.pillStroke.setStroke()
    pillPath.lineWidth = 3
    pillPath.stroke()

    // 薄荷波形三柱
    let heights: [CGFloat] = [104, 188, 140]
    for (i, h) in heights.enumerated() {
        let bar = NSRect(x: 196 + CGFloat(i) * 66, y: 512 - h / 2, width: 44, height: h)
        mint.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 22, yRadius: 22).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    pal.outerStroke.setStroke()
    bg.lineWidth = 2
    bg.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, size) in variants {
    let rep = render(size)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
// 设置页头部用 256 PNG，避免从 icns 里挑到 16pt 那一档放大后发糊
let png256 = render(256).representation(using: .png, properties: [:])!
try! png256.write(to: URL(fileURLWithPath: "\(outDir)/preview-256.png"))
print("iconset 已生成：\(outDir)（\(scheme)）")

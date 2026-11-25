import AppKit

// Isla 图标 v3：同一份几何，两套「一眼能分清」的配色。
//   dark  = 近黑底 + 薄荷胶囊（亮块在黑底上，Dock 深色背景里最跳）
//   light = 乳白底 + 近黑胶囊（黑块在白底上，浅色壁纸里最清楚）
// 与胶囊本体同构：一颗圆角胶囊 + 三道波形。
// 用法：swift tools/make-icon-v3.swift <out.iconset> <dark|light>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let scheme = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
let isLight = scheme == "light"

struct Palette {
    let bgTop: NSColor
    let bgBottom: NSColor
    let capsuleTop: NSColor
    let capsuleBottom: NSColor
    let capsuleStroke: NSColor
    let bar: NSColor
    let outerStroke: NSColor
    let glow: NSColor?
    let shadow: NSColor
}

// 深色：黑底 + 薄荷胶囊。胶囊本体是「亮的」，和真实胶囊相反 ——
// 但图标要在 Dock 里第一眼被认出来，深底黑胶囊等于没有图形。
let dark = Palette(
    bgTop: NSColor(srgbRed: 0.153, green: 0.184, blue: 0.235, alpha: 1),
    bgBottom: NSColor(srgbRed: 0.035, green: 0.047, blue: 0.063, alpha: 1),
    capsuleTop: NSColor(srgbRed: 0.427, green: 0.949, blue: 0.741, alpha: 1),
    capsuleBottom: NSColor(srgbRed: 0.176, green: 0.788, blue: 0.596, alpha: 1),
    capsuleStroke: NSColor(calibratedWhite: 1, alpha: 0.55),
    bar: NSColor(srgbRed: 0.027, green: 0.075, blue: 0.059, alpha: 1),
    outerStroke: NSColor(calibratedWhite: 1, alpha: 0.10),
    glow: NSColor(srgbRed: 0.30, green: 0.90, blue: 0.68, alpha: 0.42),
    shadow: NSColor.black.withAlphaComponent(0.55))

// 浅色：乳白底 + 近黑胶囊 + 薄荷波形，和深色版共用同一颗胶囊几何。
let light = Palette(
    bgTop: NSColor(srgbRed: 1.0, green: 0.998, blue: 0.992, alpha: 1),
    bgBottom: NSColor(srgbRed: 0.929, green: 0.909, blue: 0.878, alpha: 1),
    capsuleTop: NSColor(srgbRed: 0.094, green: 0.110, blue: 0.129, alpha: 1),
    capsuleBottom: NSColor(srgbRed: 0.043, green: 0.051, blue: 0.063, alpha: 1),
    capsuleStroke: NSColor(calibratedWhite: 0, alpha: 0.35),
    bar: NSColor(srgbRed: 0.231, green: 0.878, blue: 0.651, alpha: 1),
    outerStroke: NSColor(calibratedWhite: 0, alpha: 0.08),
    glow: nil,
    shadow: NSColor.black.withAlphaComponent(0.28))

// 亮色：薄荷渐变底 + 近黑胶囊。放在浅色 Dock / 浅色壁纸里也不会糊成一片白。
let vivid = Palette(
    bgTop: NSColor(srgbRed: 0.545, green: 0.973, blue: 0.788, alpha: 1),
    bgBottom: NSColor(srgbRed: 0.114, green: 0.741, blue: 0.588, alpha: 1),
    capsuleTop: NSColor(srgbRed: 0.078, green: 0.094, blue: 0.110, alpha: 1),
    capsuleBottom: NSColor(srgbRed: 0.031, green: 0.039, blue: 0.047, alpha: 1),
    capsuleStroke: NSColor(calibratedWhite: 0, alpha: 0.30),
    bar: NSColor(srgbRed: 0.545, green: 0.973, blue: 0.788, alpha: 1),
    outerStroke: NSColor(calibratedWhite: 0, alpha: 0.10),
    glow: nil,
    shadow: NSColor.black.withAlphaComponent(0.32))

let pal: Palette
switch scheme {
case "light": pal = light
case "vivid": pal = vivid
default: pal = dark
}

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

    // 外壳 squircle（贴近 macOS 图标网格：1024 画布里留 50 的边）
    let content = NSRect(x: 50, y: 50, width: 924, height: 924)
    let squircle = NSBezierPath(roundedRect: content, xRadius: 214, yRadius: 214)
    NSGradient(colors: [pal.bgTop, pal.bgBottom])!.draw(in: squircle, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // 胶囊：比 v2 更大，占满视觉中心
    let pillW: CGFloat = 812
    let pillH: CGFloat = 344
    let pill = NSRect(x: (1024 - pillW) / 2, y: 500 - pillH / 2, width: pillW, height: pillH)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)

    // 深色版给胶囊加一圈薄荷光晕，让它从黑底上「浮」起来
    if let glow = pal.glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 58, color: glow.cgColor)
        glow.setFill()
        pillPath.fill()
        ctx.restoreGState()
    }

    let shadow = NSShadow()
    shadow.shadowColor = pal.shadow
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: [pal.capsuleTop, pal.capsuleBottom])!.draw(in: pillPath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    pal.capsuleStroke.setStroke()
    pillPath.lineWidth = 3
    pillPath.stroke()

    // 三道波形：等比放大，居中
    let barW: CGFloat = 54
    let gap: CGFloat = 30
    let heights: [CGFloat] = [104, 196, 144]
    let blockW = barW * 3 + gap * 2
    var x = (1024 - blockW) / 2
    for (i, h) in heights.enumerated() {
        let bar = NSRect(x: x, y: 500 - h / 2, width: barW, height: h)
        pal.bar.setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
        _ = i
    }

    NSGraphicsContext.restoreGraphicsState()

    pal.outerStroke.setStroke()
    squircle.lineWidth = 2
    squircle.stroke()

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
let png256 = render(256).representation(using: .png, properties: [:])!
try! png256.write(to: URL(fileURLWithPath: "\(outDir)/preview-256.png"))
let png64 = render(64).representation(using: .png, properties: [:])!
try! png64.write(to: URL(fileURLWithPath: "\(outDir)/preview-64.png"))
print("iconset 已生成：\(outDir)（\(scheme)）")

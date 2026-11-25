import AppKit

// Isla 浅色图标：乳白 squircle + 同一个黑色胶囊与薄荷波形。
// 构图与现有深色图标一致（居中一颗药丸、波形靠左），只是把周围的灰改成乳白。
// 用法：swift tools/make-icon-light.swift <out.iconset>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIconLight.iconset"
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

    // 乳白 squircle
    let content = NSRect(x: 46, y: 46, width: 932, height: 932)
    let bg = NSBezierPath(roundedRect: content, xRadius: 232, yRadius: 232)
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.998, blue: 0.992, alpha: 1),
                        NSColor(srgbRed: 0.955, green: 0.941, blue: 0.918, alpha: 1)])!
        .draw(in: bg, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    bg.addClip()

    // 顶部一层极淡的高光，避免大面积纯白显得平
    NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.9),
                        NSColor(calibratedWhite: 1, alpha: 0)])!
        .draw(in: NSRect(x: 46, y: 700, width: 932, height: 278), angle: -90)

    // 黑色胶囊（与深色图标同一颗）
    let pill = NSRect(x: 168, y: 376, width: 688, height: 272)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: 136, yRadius: 136)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 44
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.035, green: 0.04, blue: 0.05, alpha: 1).setFill()
    pillPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 胶囊内一点点玻璃高光
    NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.08),
                        NSColor(calibratedWhite: 1, alpha: 0.0)])!
        .draw(in: pillPath, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    pillPath.lineWidth = 3
    pillPath.stroke()

    // 薄荷波形三柱
    let heights: [CGFloat] = [86, 138, 108]
    for (i, h) in heights.enumerated() {
        let bar = NSRect(x: 236 + CGFloat(i) * 56, y: 512 - h / 2, width: 34, height: h)
        mint.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 17, yRadius: 17).fill()
    }

    NSGraphicsContext.restoreGraphicsState()

    // 外描边：浅底上要有一点点边界，否则贴在同色 Dock 上会糊
    NSColor(calibratedWhite: 0, alpha: 0.10).setStroke()
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
print("浅色 iconset 已生成：\(outDir)")

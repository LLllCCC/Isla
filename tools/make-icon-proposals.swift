import AppKit

// Isla 图标备选方案生成器（不替换正式图标！）
// 输出 icon-proposals/P{n}-{名字}/ 下 1024/256/64 三档 PNG，供用户挑选。
// 挑中后再用 tools/make-icon-v3.swift 的 iconset 流程落成 AppIcon.icns。
// 用法：swift tools/make-icon-proposals.swift [outDir]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-proposals"

// MARK: - 公共几何

func squirclePath() -> NSBezierPath {
    let content = NSRect(x: 50, y: 50, width: 924, height: 924)
    return NSBezierPath(roundedRect: content, xRadius: 214, yRadius: 214)
}

func pillPath(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
}

/// 播放三角（等边，指向右）
func playPath(center: NSPoint, size: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let r = size / 2
    p.move(to: NSPoint(x: center.x - r * 0.75, y: center.y + r))
    p.line(to: NSPoint(x: center.x + r, y: center.y))
    p.line(to: NSPoint(x: center.x - r * 0.75, y: center.y - r))
    p.close()
    return p
}

struct Design {
    let name: String
    let subtitle: String
    let render: (_ size: CGFloat) -> NSBitmapImageRep
}

func baseCanvas(_ size: CGFloat) -> (NSBitmapImageRep, CGContext, NSBezierPath) {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let nctx = NSGraphicsContext(bitmapImageRep: rep)!
    // 关键：AppKit 的 NSGradient/NSBezierPath 绘制走 current context，
    // 不设置的话所有绘制都会落空（输出全黑）
    NSGraphicsContext.current = nctx
    let ctx = nctx.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    ctx.setShouldAntialias(true)
    return (rep, ctx, squirclePath())
}

/// 标准胶囊 + 波形布局（1024 坐标系）
func drawPill(ctx: CGContext, bgTop: NSColor, bgBottom: NSColor,
              capsuleTop: NSColor, capsuleBottom: NSColor,
              capsuleStroke: NSColor?, glow: NSColor?, shadow: NSColor,
              outerStroke: NSColor, pillW: CGFloat = 812, pillH: CGFloat = 344,
              bars: Bool = true, barColor: NSColor? = nil,
              barHeights: [CGFloat] = [104, 196, 144]) {
    let squircle = squirclePath()
    NSGradient(colors: [bgTop, bgBottom])!.draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    let pill = NSRect(x: (1024 - pillW) / 2, y: 500 - pillH / 2, width: pillW, height: pillH)
    let path = pillPath(pill)

    if let glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 58, color: glow.cgColor)
        glow.setFill()
        path.fill()
        ctx.restoreGState()
    }

    let sh = NSShadow()
    sh.shadowColor = shadow
    sh.shadowBlurRadius = 34
    sh.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    sh.set()
    NSGradient(colors: [capsuleTop, capsuleBottom])!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    if let capsuleStroke {
        capsuleStroke.setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    if bars {
        let barW: CGFloat = 54
        let gap: CGFloat = 30
        let blockW = barW * CGFloat(barHeights.count) + gap * CGFloat(barHeights.count - 1)
        var x = (1024 - blockW) / 2
        for h in barHeights {
            let bar = NSRect(x: x, y: 500 - h / 2, width: barW, height: h)
            (barColor ?? capsuleBottom).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    outerStroke.setStroke()
    squircle.lineWidth = 2
    squircle.stroke()
}

// MARK: - 八个方案

let designs: [Design] = [

    // ---------- 第一批：深色系 ----------
    Design(name: "P1-墨玉", subtitle: "近黑底 · 薄薄荷胶囊 · 光晕（现行深色版的收敛版）") { size in
        let (rep, ctx, _) = baseCanvas(size)
        drawPill(ctx: ctx,
                 bgTop: NSColor(srgbRed: 0.118, green: 0.145, blue: 0.192, alpha: 1),
                 bgBottom: NSColor(srgbRed: 0.024, green: 0.031, blue: 0.047, alpha: 1),
                 capsuleTop: NSColor(srgbRed: 0.427, green: 0.949, blue: 0.741, alpha: 1),
                 capsuleBottom: NSColor(srgbRed: 0.165, green: 0.776, blue: 0.580, alpha: 1),
                 capsuleStroke: NSColor(calibratedWhite: 1, alpha: 0.50),
                 glow: NSColor(srgbRed: 0.30, green: 0.90, blue: 0.68, alpha: 0.40),
                 shadow: NSColor.black.withAlphaComponent(0.55),
                 outerStroke: NSColor(calibratedWhite: 1, alpha: 0.10),
                 barColor: NSColor(srgbRed: 0.016, green: 0.086, blue: 0.063, alpha: 1))
        return rep
    },

    Design(name: "P2-晨雾", subtitle: "乳白底 · 近黑胶囊 · 薄荷波形（现行浅色版的收敛版）") { size in
        let (rep, ctx, _) = baseCanvas(size)
        drawPill(ctx: ctx,
                 bgTop: NSColor(srgbRed: 1.0, green: 0.996, blue: 0.988, alpha: 1),
                 bgBottom: NSColor(srgbRed: 0.918, green: 0.898, blue: 0.865, alpha: 1),
                 capsuleTop: NSColor(srgbRed: 0.094, green: 0.110, blue: 0.129, alpha: 1),
                 capsuleBottom: NSColor(srgbRed: 0.039, green: 0.047, blue: 0.059, alpha: 1),
                 capsuleStroke: NSColor(calibratedWhite: 0, alpha: 0.30),
                 glow: nil,
                 shadow: NSColor.black.withAlphaComponent(0.26),
                 outerStroke: NSColor(calibratedWhite: 0, alpha: 0.08),
                 barColor: NSColor(srgbRed: 0.231, green: 0.878, blue: 0.651, alpha: 1))
        return rep
    },

    Design(name: "P3-夜航", subtitle: "深靛蓝夜空 · 白胶囊 · 星点（深色壁纸上更安静、有辨识度）") { size in
        let (rep, ctx, squircle) = baseCanvas(size)
        NSGradient(colors: [
            NSColor(srgbRed: 0.086, green: 0.102, blue: 0.212, alpha: 1),
            NSColor(srgbRed: 0.024, green: 0.031, blue: 0.078, alpha: 1)
        ])!.draw(in: squircle, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        // 星点：固定伪随机种子，几何可复现
        var seed: UInt64 = 20261119
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
        NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
        for _ in 0..<46 {
            let x = 70 + rnd() * 880
            let y = 70 + rnd() * 880
            let r = 1.5 + rnd() * 3.5
            if abs(y - 500) < 220 && abs(x - 512) < 440 { continue } // 胶囊区域避让
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
        }
        let pill = NSRect(x: 106, y: 328, width: 812, height: 344)
        let path = pillPath(pill)
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.5)
        sh.shadowBlurRadius = 30
        sh.shadowOffset = NSSize(width: 0, height: -10)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.99, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.82, green: 0.86, blue: 0.93, alpha: 1)
        ])!.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let indigo = NSColor(srgbRed: 0.196, green: 0.235, blue: 0.408, alpha: 1)
        let barW: CGFloat = 54, gap: CGFloat = 30
        var x: CGFloat = (1024 - (barW * 3 + gap * 2)) / 2
        for h: CGFloat in [104, 196, 144] {
            indigo.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 500 - h / 2, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        squircle.lineWidth = 2
        squircle.stroke()
        return rep
    },

    Design(name: "P4-线稿", subtitle: "纸白底 · 细线胶囊轮廓（极简、浅色环境最清爽）") { size in
        let (rep, ctx, squircle) = baseCanvas(size)
        NSGradient(colors: [
            NSColor(srgbRed: 0.995, green: 0.995, blue: 0.995, alpha: 1),
            NSColor(srgbRed: 0.902, green: 0.906, blue: 0.914, alpha: 1)
        ])!.draw(in: squircle, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        let pill = NSRect(x: 106, y: 328, width: 812, height: 344)
        let path = pillPath(pill)
        let ink = NSColor(calibratedWhite: 0.05, alpha: 1)
        ink.setStroke()
        path.lineWidth = 16
        path.stroke()
        let barW: CGFloat = 54, gap: CGFloat = 30
        var x: CGFloat = (1024 - (barW * 3 + gap * 2)) / 2
        for h: CGFloat in [104, 196, 144] {
            let bar = NSRect(x: x, y: 500 - h / 2, width: barW, height: h)
            let bp = NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2)
            bp.lineWidth = 14
            bp.stroke()
            x += barW + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0, alpha: 0.10).setStroke()
        squircle.lineWidth = 2
        squircle.stroke()
        return rep
    },

    // ---------- 第二批：彩色系 ----------
    Design(name: "P5-霓虹", subtitle: "纯黑底 · 霓虹描边胶囊 + 外发光（赛博感、暗 Dock 极醒目）") { size in
        let (rep, ctx, squircle) = baseCanvas(size)
        NSGradient(colors: [
            NSColor(srgbRed: 0.043, green: 0.047, blue: 0.059, alpha: 1),
            NSColor.black
        ])!.draw(in: squircle, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        let neon = NSColor(calibratedWhite: 1, alpha: 1)
        let pill = NSRect(x: 106, y: 328, width: 812, height: 344)
        let path = pillPath(pill)
        // 两层光晕
        for (blur, alpha) in [(64.0, 0.55), (28.0, 0.8)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: neon.withAlphaComponent(alpha).cgColor)
            neon.setStroke()
            path.lineWidth = 10
            path.stroke()
            ctx.restoreGState()
        }
        neon.setStroke()
        path.lineWidth = 10
        path.stroke()
        let barW: CGFloat = 54, gap: CGFloat = 30
        var x: CGFloat = (1024 - (barW * 3 + gap * 2)) / 2
        for h: CGFloat in [104, 196, 144] {
            let bar = NSRect(x: x, y: 500 - h / 2, width: barW, height: h)
            let bp = NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2)
            for (blur, alpha) in [(40.0, 0.5), (16.0, 0.8)] {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: blur, color: neon.withAlphaComponent(alpha).cgColor)
                bp.lineWidth = 9
                bp.stroke()
                ctx.restoreGState()
            }
            bp.lineWidth = 9
            bp.stroke()
            x += barW + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        squircle.lineWidth = 2
        squircle.stroke()
        return rep
    },

    Design(name: "P6-薄荷", subtitle: "薄荷纯色底 · 白胶囊 · 墨绿波形（彩色 Dock 里最跳）") { size in
        let (rep, ctx, _) = baseCanvas(size)
        drawPill(ctx: ctx,
                 bgTop: NSColor(srgbRed: 0.545, green: 0.973, blue: 0.788, alpha: 1),
                 bgBottom: NSColor(srgbRed: 0.110, green: 0.741, blue: 0.580, alpha: 1),
                 capsuleTop: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                 capsuleBottom: NSColor(srgbRed: 0.925, green: 0.957, blue: 0.945, alpha: 1),
                 capsuleStroke: NSColor(srgbRed: 0.110, green: 0.741, blue: 0.580, alpha: 0.8),
                 glow: nil,
                 shadow: NSColor.black.withAlphaComponent(0.22),
                 outerStroke: NSColor(calibratedWhite: 0, alpha: 0.10),
                 barColor: NSColor(srgbRed: 0.055, green: 0.278, blue: 0.196, alpha: 1))
        return rep
    },

    Design(name: "P7-声纹", subtitle: "石墨底 · 深胶囊 · 胶囊两侧声波扩散（表达「声音岛」）") { size in
        let (rep, ctx, squircle) = baseCanvas(size)
        NSGradient(colors: [
            NSColor(srgbRed: 0.196, green: 0.208, blue: 0.227, alpha: 1),
            NSColor(srgbRed: 0.071, green: 0.078, blue: 0.090, alpha: 1)
        ])!.draw(in: squircle, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        // 两侧扩散弧线（胶囊外）
        let mint = NSColor(srgbRed: 0.30, green: 0.95, blue: 0.70, alpha: 1)
        for (r, alpha) in [(190.0, 0.30), (260.0, 0.18), (330.0, 0.10)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 512, y: 500), radius: r,
                          startAngle: 150, endAngle: 210, clockwise: false)
            arc.appendArc(withCenter: NSPoint(x: 512, y: 500), radius: r,
                          startAngle: 330, endAngle: 30, clockwise: false)
            mint.withAlphaComponent(alpha).setStroke()
            arc.lineWidth = 18
            arc.stroke()
        }
        let pill = NSRect(x: 106, y: 328, width: 812, height: 344)
        let path = pillPath(pill)
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.5)
        sh.shadowBlurRadius = 30
        sh.shadowOffset = NSSize(width: 0, height: -10)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        NSGradient(colors: [
            NSColor(srgbRed: 0.118, green: 0.129, blue: 0.149, alpha: 1),
            NSColor(srgbRed: 0.039, green: 0.043, blue: 0.055, alpha: 1)
        ])!.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
        path.lineWidth = 3
        path.stroke()
        let barW: CGFloat = 54, gap: CGFloat = 30
        var x: CGFloat = (1024 - (barW * 3 + gap * 2)) / 2
        for h: CGFloat in [104, 196, 144] {
            mint.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 500 - h / 2, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        squircle.lineWidth = 2
        squircle.stroke()
        return rep
    },

    Design(name: "P8-绛夜", subtitle: "紫罗兰渐变底 · 白胶囊 · 播放三角（媒体感最强）") { size in
        let (rep, ctx, squircle) = baseCanvas(size)
        NSGradient(colors: [
            NSColor(srgbRed: 0.545, green: 0.400, blue: 0.960, alpha: 1),
            NSColor(srgbRed: 0.196, green: 0.110, blue: 0.412, alpha: 1)
        ])!.draw(in: squircle, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        let pill = NSRect(x: 106, y: 328, width: 812, height: 344)
        let path = pillPath(pill)
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
        sh.shadowBlurRadius = 30
        sh.shadowOffset = NSSize(width: 0, height: -10)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.906, green: 0.914, blue: 0.960, alpha: 1)
        ])!.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let violet = NSColor(srgbRed: 0.408, green: 0.290, blue: 0.760, alpha: 1)
        violet.setFill()
        playPath(center: NSPoint(x: 512, y: 500), size: 150).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        squircle.lineWidth = 2
        squircle.stroke()
        return rep
    }
]

// MARK: - 输出

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for d in designs {
    let dir = "\(outDir)/\(d.name)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, size) in [("icon_1024.png", CGFloat(1024)), ("icon_256.png", 256), ("icon_64.png", 64)] {
        let png = d.render(size).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
    print("✓ \(d.name) —— \(d.subtitle)")
}
print("共 \(designs.count) 个方案 → \(outDir)/")

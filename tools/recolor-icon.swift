import AppKit

// 从现有深色图标派生浅色版本：
// 保留「黑色胶囊 + 薄荷波形」原样，只把胶囊周围的深灰底换成乳白底，
// 并按原图的明暗（胶囊投影）在乳白底上保留一点灰阶，避免看起来是贴上去的。
// 用法：recolor-icon <source.png> <out.iconset>

let src = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon-dark-1024.png"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/AppIconLight.iconset"

guard let img = NSImage(contentsOfFile: src), let tiff = img.tiffRepresentation,
      let srcRep = NSBitmapImageRep(data: tiff), let data = srcRep.bitmapData else {
    print("无法读取 \(src)"); exit(1)
}
let W = srcRep.pixelsWide, H = srcRep.pixelsHigh
let bpr = srcRep.bytesPerRow
let spp = srcRep.samplesPerPixel

func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
    let o = y * bpr + x * spp
    let r = Double(data[o]) / 255, g = Double(data[o + 1]) / 255, b = Double(data[o + 2]) / 255
    let a = spp >= 4 ? Double(data[o + 3]) / 255 : 1
    return (r, g, b, a)
}

// 乳白底的两端
let creamTop = (r: 1.0, g: 0.995, b: 0.985)
let creamBottom = (r: 0.955, g: 0.94, b: 0.915)

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let pxN = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxN, pixelsHigh: pxN,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    guard let out = rep.bitmapData else { return rep }
    let obpr = rep.bytesPerRow
    let scale = Double(W) / Double(pxN)

    for y in 0..<pxN {
        for x in 0..<pxN {
            let sx = min(W - 1, Int(Double(x) * scale))
            let sy = min(H - 1, Int(Double(y) * scale))
            let (r, g, b, a) = px(sx, sy)
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            let isMint = g > 0.45 && g > r + 0.12 && b < g
            let isPill = lum < 0.14 && a > 0.5

            var orr = 0.0, og = 0.0, ob = 0.0, oa = a
            if a < 0.02 {
                orr = 0; og = 0; ob = 0; oa = 0
            } else if isPill || isMint {
                // 胶囊与波形原样保留
                orr = r; og = g; ob = b
            } else {
                // 背景：按纵向做乳白渐变，再用原图亮度做 ±12% 的调制（保留投影/高光）
                let ty = Double(y) / Double(pxN)
                let br = creamTop.r + (creamBottom.r - creamTop.r) * ty
                let bg2 = creamTop.g + (creamBottom.g - creamTop.g) * ty
                let bb = creamTop.b + (creamBottom.b - creamTop.b) * ty
                let norm = min(1.0, max(0.0, (lum - 0.02) / 0.28))
                let k = 0.86 + 0.14 * norm
                orr = br * k; og = bg2 * k; ob = bb * k
            }
            let o = y * obpr + x * 4
            out[o] = UInt8(min(255, max(0, orr * 255)))
            out[o + 1] = UInt8(min(255, max(0, og * 255)))
            out[o + 2] = UInt8(min(255, max(0, ob * 255)))
            out[o + 3] = UInt8(min(255, max(0, oa * 255)))
        }
    }
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

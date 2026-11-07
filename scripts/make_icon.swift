// 生成应用图标：用法 make_icon <输出的 .iconset 目录>
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // 圆角背景（macOS 图标网格：824×824 居中）
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.48, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.33, green: 0.25, blue: 0.85, alpha: 1)])!
        .draw(in: bg, angle: -90)
    ctx.restoreGState()

    // 2×2 的小窗口
    let tile: CGFloat = 300 * s, gap: CGFloat = 44 * s
    let originX = 512 * s - tile - gap / 2, originY = 512 * s - tile - gap / 2
    for row in 0..<2 {
        for col in 0..<2 {
            let r = NSRect(x: originX + CGFloat(col) * (tile + gap), y: originY + CGFloat(row) * (tile + gap), width: tile, height: tile * 0.82)
            let selected = (row == 1 && col == 0) || (row == 0 && col == 1)
            let win = NSBezierPath(roundedRect: r, xRadius: 34 * s, yRadius: 34 * s)
            NSColor.white.withAlphaComponent(selected ? 1 : 0.55).setFill()
            win.fill()
            // 标题栏三个圆点
            let dotY = r.maxY - 42 * s
            for (i, c) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
                c.withAlphaComponent(selected ? 1 : 0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + 30 * s + CGFloat(i) * 40 * s, y: dotY - 13 * s, width: 26 * s, height: 26 * s)).fill()
            }
            if selected {
                // 选中标记
                let badge = NSRect(x: r.maxX - 96 * s, y: r.minY + 22 * s, width: 74 * s, height: 74 * s)
                NSColor(srgbRed: 0.20, green: 0.48, blue: 0.98, alpha: 1).setFill()
                NSBezierPath(ovalIn: badge).fill()
                let check = NSBezierPath()
                check.lineWidth = 11 * s
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(to: NSPoint(x: badge.minX + 20 * s, y: badge.midY + 1 * s))
                check.line(to: NSPoint(x: badge.minX + 33 * s, y: badge.minY + 22 * s))
                check.line(to: NSPoint(x: badge.maxX - 18 * s, y: badge.maxY - 22 * s))
                NSColor.white.setStroke()
                check.stroke()
            }
        }
    }
    img.unlockFocus()
    return img
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let img = drawIcon(size: CGFloat(px))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}

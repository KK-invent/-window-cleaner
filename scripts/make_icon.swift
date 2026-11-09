// “扫把”应用图标：纯 AppKit 绘制，暖瓷底板、木柄、黄铜色刷毛与墨绿束带。
// 用法：make_icon <输出 .iconset 目录> [1024px 预览 PNG 路径]
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ colors: [NSColor], in path: NSBezierPath, angle: CGFloat) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func stroke(_ points: [NSPoint], color c: NSColor, width: CGFloat) {
    guard let first = points.first else { return }
    let p = NSBezierPath()
    p.move(to: first)
    for point in points.dropFirst() { p.line(to: point) }
    p.lineWidth = width
    p.lineCapStyle = .round
    c.setStroke()
    p.stroke()
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // 凸起键帽：先画下沿厚度和两层落地阴影，再画带宽倒角的瓷白顶面。
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 79, width: 824, height: 824), xRadius: 184, yRadius: 184)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -21), blur: 27, color: color(0x363B2F, alpha: 0.30).cgColor)
    color(0xB8B3A4).setFill()
    body.fill()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 5, color: color(0x4D493D, alpha: 0.28).cgColor)
    body.fill()
    ctx.restoreGState()
    gradient([color(0xAAA493), color(0xDCD5C5), color(0xF2EDE2)], in: body, angle: 90)

    let top = NSBezierPath(roundedRect: NSRect(x: 100, y: 117, width: 824, height: 807), xRadius: 184, yRadius: 184)
    gradient([color(0xD9D1C0), color(0xFFFDF6)], in: top, angle: 90)
    top.lineWidth = 2
    color(0xFFFFFF, alpha: 0.92).setStroke()
    top.stroke()
    let face = NSBezierPath(roundedRect: NSRect(x: 122, y: 141, width: 780, height: 760), xRadius: 164, yRadius: 164)
    gradient([color(0xE8E1D2), color(0xFFFEF9)], in: face, angle: 130)
    ctx.saveGState()
    face.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: 120, y: 495, width: 900, height: 650))
    gradient([color(0xFFFFFF, alpha: 0), color(0xFFFFFF, alpha: 0.70)], in: sheen, angle: 90)
    ctx.restoreGState()
    face.lineWidth = 1.5
    color(0xFFFFFF, alpha: 0.65).setStroke()
    face.stroke()

    // 顶部弧形高光与下沿凹阴影，强调“可以按下去”的厚度。
    let glint = NSBezierPath()
    glint.move(to: NSPoint(x: 130, y: 677))
    glint.curve(to: NSPoint(x: 303, y: 903), controlPoint1: NSPoint(x: 130, y: 849), controlPoint2: NSPoint(x: 178, y: 903))
    glint.line(to: NSPoint(x: 728, y: 903))
    glint.lineWidth = 7
    glint.lineCapStyle = .round
    color(0xFFFFFF, alpha: 0.72).setStroke()
    glint.stroke()
    let lower = NSBezierPath()
    lower.move(to: NSPoint(x: 153, y: 272))
    lower.curve(to: NSPoint(x: 310, y: 134), controlPoint1: NSPoint(x: 178, y: 166), controlPoint2: NSPoint(x: 215, y: 134))
    lower.line(to: NSPoint(x: 716, y: 134))
    lower.curve(to: NSPoint(x: 879, y: 277), controlPoint1: NSPoint(x: 819, y: 134), controlPoint2: NSPoint(x: 861, y: 177))
    lower.lineWidth = 3
    color(0x988E78, alpha: 0.28).setStroke()
    lower.stroke()

    // 扫帚顺时针倾斜 31 度：刷头在左下，手柄在右上。
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 506)
    ctx.rotate(by: -31 * .pi / 180)
    ctx.translateBy(x: -512, y: -506)

    // 木柄：保留清晰轮廓和一束窄高光，小尺寸仍能辨认。
    let handle = NSBezierPath(roundedRect: NSRect(x: 489, y: 438, width: 46, height: 390), xRadius: 23, yRadius: 23)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 12, height: -13), blur: 11, color: color(0x4B3822, alpha: 0.30).cgColor)
    color(0xAE7B45).setFill()
    handle.fill()
    ctx.restoreGState()
    gradient([color(0x966A3A), color(0xE8C28A), color(0xCFA26A), color(0x997044)], in: handle, angle: 0)
    handle.lineWidth = 1.5
    color(0x906B45, alpha: 0.65).setStroke()
    handle.stroke()
    stroke([NSPoint(x: 500, y: 530), NSPoint(x: 500, y: 797)], color: color(0xFFEBBD, alpha: 0.65), width: 3)
    stroke([NSPoint(x: 526, y: 550), NSPoint(x: 526, y: 784)], color: color(0x805A35, alpha: 0.18), width: 1.5)
    let cap = NSBezierPath(ovalIn: NSRect(x: 499, y: 805, width: 25, height: 10))
    color(0xE8CAA1, alpha: 0.65).setFill()
    cap.fill()

    // 刷头轮廓：柔和扇形，不加入额外符号或字母。
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 441, y: 502))
    head.curve(to: NSPoint(x: 355, y: 280), controlPoint1: NSPoint(x: 420, y: 422), controlPoint2: NSPoint(x: 376, y: 329))
    head.curve(to: NSPoint(x: 371, y: 248), controlPoint1: NSPoint(x: 349, y: 264), controlPoint2: NSPoint(x: 356, y: 252))
    head.curve(to: NSPoint(x: 653, y: 248), controlPoint1: NSPoint(x: 451, y: 229), controlPoint2: NSPoint(x: 573, y: 229))
    head.curve(to: NSPoint(x: 669, y: 280), controlPoint1: NSPoint(x: 668, y: 252), controlPoint2: NSPoint(x: 675, y: 264))
    head.curve(to: NSPoint(x: 583, y: 502), controlPoint1: NSPoint(x: 648, y: 329), controlPoint2: NSPoint(x: 604, y: 422))
    head.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 14, height: -17), blur: 13, color: color(0x5B4825, alpha: 0.34).cgColor)
    color(0xB58C45).setFill()
    head.fill()
    ctx.restoreGState()
    let edge = head.copy() as! NSBezierPath
    edge.transform(using: AffineTransform(translationByX: 5, byY: -6))
    gradient([color(0xA77D38), color(0xD1AA5F)], in: edge, angle: 90)
    gradient([color(0xC4943C), color(0xF7D991), color(0xD3A958)], in: head, angle: 0)
    head.lineWidth = 1.5
    color(0xAE813F, alpha: 0.5).setStroke()
    head.stroke()

    // 稀疏的刷毛纹理：沿扇形发散，明暗成对，避免缩小时变得杂乱。
    ctx.saveGState()
    head.addClip()
    for i in 0..<13 {
        let t = CGFloat(i) / 12
        let topX = 449 + t * 126
        let bottomX = 365 + t * 294
        let fiber = NSBezierPath()
        fiber.move(to: NSPoint(x: topX, y: 484))
        fiber.curve(to: NSPoint(x: bottomX, y: 235),
                    controlPoint1: NSPoint(x: topX + (bottomX - topX) * 0.3, y: 400),
                    controlPoint2: NSPoint(x: bottomX, y: 284))
        fiber.lineWidth = i.isMultiple(of: 3) ? 3 : 2
        color(0x947133, alpha: i.isMultiple(of: 3) ? 0.35 : 0.22).setStroke()
        fiber.stroke()
        let light = NSAffineTransform()
        light.translateX(by: 4, yBy: 0)
        fiber.transform(using: light as AffineTransform)
        fiber.lineWidth = 2
        color(0xFFF0BC, alpha: 0.58).setStroke()
        fiber.stroke()
    }
    ctx.restoreGState()

    // 墨绿束带：圆润织物质感，用一条顶边高光体现厚度。
    let band = NSBezierPath(roundedRect: NSRect(x: 427, y: 458, width: 170, height: 65), xRadius: 15, yRadius: 15)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 3, height: -5), blur: 5, color: color(0x303924, alpha: 0.35).cgColor)
    color(0x1E4638).setFill()
    band.fill()
    ctx.restoreGState()
    gradient([color(0x163B2E), color(0x34634C), color(0x628D70), color(0x38634E)], in: band, angle: 90)
    band.lineWidth = 1.3
    color(0x244D3D, alpha: 0.8).setStroke()
    band.stroke()
    stroke([NSPoint(x: 444, y: 515), NSPoint(x: 580, y: 515)], color: color(0x96B6A0, alpha: 0.6), width: 2)
    stroke([NSPoint(x: 443, y: 468), NSPoint(x: 581, y: 468)], color: color(0x142F26, alpha: 0.3), width: 1.5)
    ctx.restoreGState()

    func sparkle(x: CGFloat, y: CGFloat, radius: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y + radius))
        p.curve(to: NSPoint(x: x + radius, y: y), controlPoint1: NSPoint(x: x + radius * 0.15, y: y + radius * 0.15), controlPoint2: NSPoint(x: x + radius * 0.2, y: y + radius * 0.1))
        p.curve(to: NSPoint(x: x, y: y - radius), controlPoint1: NSPoint(x: x + radius * 0.15, y: y - radius * 0.15), controlPoint2: NSPoint(x: x + radius * 0.1, y: y - radius * 0.2))
        p.curve(to: NSPoint(x: x - radius, y: y), controlPoint1: NSPoint(x: x - radius * 0.15, y: y - radius * 0.15), controlPoint2: NSPoint(x: x - radius * 0.2, y: y - radius * 0.1))
        p.curve(to: NSPoint(x: x, y: y + radius), controlPoint1: NSPoint(x: x - radius * 0.15, y: y + radius * 0.15), controlPoint2: NSPoint(x: x - radius * 0.1, y: y + radius * 0.2))
        p.close()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -3), blur: 3, color: color(0x325540, alpha: 0.18).cgColor)
        color(0x79A187).setFill()
        p.fill()
        ctx.restoreGState()
        gradient([color(0x416E54), color(0xA3C4A7)], in: p, angle: 90)
    }
    sparkle(x: 294, y: 644, radius: 29)
    sparkle(x: 337, y: 702, radius: 14)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(pixels: base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
if CommandLine.arguments.count > 2 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    try drawIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: preview)
}

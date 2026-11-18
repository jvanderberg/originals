// Draws the Originals app icon at 1024×1024 and writes the AppIcon sizes.
//   swift scripts/make-icon.swift <AppIcon.appiconset dir>
import AppKit

let side: CGFloat = 1024

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    }

    // Base: Apple's macOS icon grid, an 824 pt rounded square centered on the canvas.
    let base = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(roundedRect(base, 185))
    ctx.setFillColor(color(0x1E5BD8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRect(base, 185))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x7FD3FF), color(0x2F7BF0), color(0x1B3FA8)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // A small stack of prints.
    func print(center: CGPoint, angle: CGFloat, scene: Bool, shade: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle * .pi / 180)
        let card = CGRect(x: -230, y: -190, width: 460, height: 380)
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x0A1A50, 0.45))
        ctx.addPath(roundedRect(card, 30))
        ctx.setFillColor(color(0xFFFFFF, 1 - shade))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if scene {
            let photo = card.insetBy(dx: 26, dy: 26).offsetBy(dx: 0, dy: 0)
            ctx.saveGState()
            ctx.addPath(roundedRect(photo, 14))
            ctx.clip()
            ctx.drawLinearGradient(gradient([color(0xFFB347), color(0xFF6F61), color(0x8E44AD)]),
                                   start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])
            // Sun
            ctx.setFillColor(color(0xFFF3C4))
            ctx.fillEllipse(in: CGRect(x: 50, y: 30, width: 110, height: 110))
            // Mountains
            ctx.setFillColor(color(0x3B2A6B))
            ctx.move(to: CGPoint(x: photo.minX, y: photo.minY))
            ctx.addLine(to: CGPoint(x: photo.minX, y: -40))
            ctx.addLine(to: CGPoint(x: -90, y: 70))
            ctx.addLine(to: CGPoint(x: 10, y: -20))
            ctx.addLine(to: CGPoint(x: 90, y: 40))
            ctx.addLine(to: CGPoint(x: photo.maxX, y: -70))
            ctx.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
            ctx.closePath()
            ctx.fillPath()
            ctx.setFillColor(color(0x241A4A))
            ctx.move(to: CGPoint(x: photo.minX, y: photo.minY))
            ctx.addLine(to: CGPoint(x: photo.minX, y: -110))
            ctx.addLine(to: CGPoint(x: -40, y: -40))
            ctx.addLine(to: CGPoint(x: 60, y: -120))
            ctx.addLine(to: CGPoint(x: photo.maxX, y: -60))
            ctx.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
    print(center: CGPoint(x: 492, y: 560), angle: 9, scene: false, shade: 0.12)
    print(center: CGPoint(x: 500, y: 540), angle: -4, scene: true, shade: 0)

    // Download badge.
    let badge = CGRect(x: 600, y: 170, width: 260, height: 260)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x0A1A50, 0.5))
    ctx.setFillColor(color(0xFF9F0A))
    ctx.fillEllipse(in: badge)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: badge)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFC043), color(0xFF7A00)]),
                           start: CGPoint(x: 0, y: badge.maxY), end: CGPoint(x: 0, y: badge.minY), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let cx = badge.midX
    ctx.move(to: CGPoint(x: cx, y: badge.maxY - 62)); ctx.addLine(to: CGPoint(x: cx, y: badge.minY + 78))
    ctx.move(to: CGPoint(x: cx - 58, y: badge.minY + 132)); ctx.addLine(to: CGPoint(x: cx, y: badge.minY + 74))
    ctx.addLine(to: CGPoint(x: cx + 58, y: badge.minY + 132))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: cx - 66, y: badge.minY + 52)); ctx.addLine(to: CGPoint(x: cx + 66, y: badge.minY + 52))
    ctx.setLineWidth(22)
    ctx.strokePath()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / side, y: CGFloat(pixels) / side)
    ctx.interpolationQuality = .high
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try render(point * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))

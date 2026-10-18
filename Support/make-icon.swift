// Draws the app icon and writes Support/AppIcon.icns.
// Usage: make icon  (or: swift Support/make-icon.swift)

import AppKit

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    }

    // macOS icon grid: 824pt body centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x1B1F2A))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x2A3142), color(0x151925)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft light from the top.
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 860), endRadius: 560, options: [])
    ctx.restoreGState()

    // Inner edge highlight.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // Workbench: wooden top and two legs.
    let wood = gradient([color(0xE0A15A), color(0xB86F2E)])
    let legs = [CGRect(x: 262, y: 230, width: 64, height: 150),
                CGRect(x: 698, y: 230, width: 64, height: 150)]
    for leg in legs {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: leg, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0xA0602A), color(0x7E4A20)]),
                               start: CGPoint(x: 0, y: leg.maxY), end: CGPoint(x: 0, y: leg.minY), options: [])
        ctx.restoreGState()
    }
    let top = CGRect(x: 212, y: 360, width: 600, height: 72)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x000000, 0.4))
    ctx.addPath(CGPath(roundedRect: top, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color(0xB86F2E))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: top, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(wood, start: CGPoint(x: 0, y: top.maxY), end: CGPoint(x: 0, y: top.minY), options: [])
    // Wood grain.
    ctx.setStrokeColor(color(0x8A5222, 0.35))
    ctx.setLineWidth(3)
    for (y, x0, x1) in [(410.0, 250.0, 520.0), (392.0, 470.0, 780.0), (378.0, 300.0, 420.0)] {
        ctx.move(to: CGPoint(x: x0, y: y))
        ctx.addLine(to: CGPoint(x: x1, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Terminal prompt ">_" resting on the bench.
    let accent = color(0x7EE2B8)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0x7EE2B8, 0.45))
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(68)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 300, y: 760))
    ctx.addLine(to: CGPoint(x: 460, y: 620))
    ctx.addLine(to: CGPoint(x: 300, y: 480))
    ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 530, y: 466, width: 200, height: 64),
                       cornerWidth: 32, cornerHeight: 32, transform: nil))
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(in: ctx, size: CGFloat(size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)

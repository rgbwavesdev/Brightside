// Draws the Brightside app icon: a sun rising behind a monitor whose right half is lit (the bright side).
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let S = CGFloat(size)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background squircle: dusk blue.
let inset: CGFloat = 100
let bgRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x161B3A).setFill()
bg.fill()
ctx.restoreGState()
bg.addClip()
NSGradient(colors: [color(0x3B4A8C), color(0x1E2550), color(0x10132B)])!.draw(in: bgRect, angle: -90)

// Sun glow, rays and disc, peeking over the top of the monitor.
let sunCenter = CGPoint(x: 512, y: 616)
NSGradient(colors: [color(0xFFC857, 0.55), color(0xFFC857, 0)])!
    .draw(fromCenter: sunCenter, radius: 0, toCenter: sunCenter, radius: 360, options: [])
ctx.saveGState()
ctx.translateBy(x: sunCenter.x, y: sunCenter.y)
color(0xFFD36B).setFill()
for i in 0..<12 {
    ctx.saveGState()
    ctx.rotate(by: CGFloat(i) * .pi / 6)
    NSBezierPath(roundedRect: CGRect(x: -16, y: 196, width: 32, height: 60), xRadius: 17, yRadius: 17).fill()
    ctx.restoreGState()
}
ctx.restoreGState()
let disc = NSBezierPath(ovalIn: CGRect(x: sunCenter.x - 168, y: sunCenter.y - 168, width: 336, height: 336))
NSGradient(colors: [color(0xFFE08A), color(0xFFA63D)])!.draw(in: disc, angle: -90)

// Monitor body.
let body = CGRect(x: 212, y: 286, width: 600, height: 370)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
color(0x1A1D2B).setFill()
NSBezierPath(roundedRect: body, xRadius: 34, yRadius: 34).fill()
ctx.restoreGState()

// Screen: dim on the left, lit on the right.
let screen = body.insetBy(dx: 24, dy: 24)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 14, yRadius: 14)
ctx.saveGState()
screenPath.addClip()
NSGradient(colors: [color(0x2B3358), color(0x46507E)])!.draw(in: CGRect(x: screen.minX, y: screen.minY,
                                                                      width: screen.width / 2, height: screen.height), angle: -90)
NSGradient(colors: [color(0xFFF6DF), color(0xFFD98A)])!.draw(in: CGRect(x: screen.midX, y: screen.minY,
                                                                      width: screen.width / 2, height: screen.height), angle: -60)
ctx.restoreGState()

// Stand.
color(0xC9CEDD).setFill()
NSBezierPath(roundedRect: CGRect(x: 470, y: 214, width: 84, height: 80), xRadius: 10, yRadius: 10).fill()
color(0xE4E7F0).setFill()
NSBezierPath(roundedRect: CGRect(x: 380, y: 196, width: 264, height: 34), xRadius: 17, yRadius: 17).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

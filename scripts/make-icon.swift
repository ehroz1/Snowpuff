// Draws the app icon at 1024 px: a night scene under a street lamp, with snow falling and drifting below.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Apple's icon outline is close to a superellipse with exponent 5.
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let outline = squircle(in: body)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(outline)
ctx.setFillColor(color(0x15110d))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(outline)
ctx.clip()

let night = CGGradient(colorsSpace: space, colors: [color(0x221b15), color(0x0e0c0a)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(night, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

let lamp = CGPoint(x: body.midX, y: body.maxY - 150)
let halo = CGGradient(colorsSpace: space, colors: [color(0xffd696, 0.42), color(0xffd696, 0.12), color(0xffd696, 0)] as CFArray,
                      locations: [0, 0.4, 1])!
ctx.drawRadialGradient(halo, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: 420, options: [])

// The beam widens as it falls; its edges are softened by stacking slightly wider, fainter copies.
for layer in 0..<30 {
    let spread = 220 + CGFloat(layer) * 7
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: lamp.x - 20, y: lamp.y))
    beam.addLine(to: CGPoint(x: lamp.x + 20, y: lamp.y))
    beam.addLine(to: CGPoint(x: lamp.x + spread, y: body.minY))
    beam.addLine(to: CGPoint(x: lamp.x - spread, y: body.minY))
    beam.closeSubpath()
    ctx.saveGState()
    ctx.addPath(beam)
    ctx.clip()
    let light = CGGradient(colorsSpace: space, colors: [color(0xffdca5, 0.018), color(0xffdca5, 0.002)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: lamp.y), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
}

let arm = CGRect(x: lamp.x, y: body.maxY - 118, width: body.maxX - lamp.x, height: 7)
ctx.setFillColor(color(0x2e2924))
ctx.fill(arm)
let head = CGMutablePath()
head.move(to: CGPoint(x: lamp.x - 54, y: lamp.y + 2))
head.addLine(to: CGPoint(x: lamp.x + 54, y: lamp.y + 2))
head.addLine(to: CGPoint(x: lamp.x + 26, y: lamp.y + 46))
head.addLine(to: CGPoint(x: lamp.x - 26, y: lamp.y + 46))
head.closeSubpath()
ctx.setFillColor(color(0x2c2722))
ctx.addPath(head)
ctx.fillPath()
let bulbGlow = CGGradient(colorsSpace: space, colors: [color(0xfff1d6, 0.9), color(0xffd99a, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bulbGlow, startCenter: CGPoint(x: lamp.x, y: lamp.y), startRadius: 0,
                       endCenter: CGPoint(x: lamp.x, y: lamp.y), endRadius: 70, options: [])
ctx.setFillColor(color(0xfff6e4))
ctx.fillEllipse(in: CGRect(x: lamp.x - 34, y: lamp.y - 6, width: 68, height: 14))

let flakes: [(CGFloat, CGFloat, CGFloat)] = [
    (-120, 520, 9), (40, 590, 6), (150, 470, 11), (-40, 420, 7), (90, 360, 13), (-170, 330, 8),
    (200, 300, 7), (-90, 250, 12), (20, 230, 6), (250, 410, 6), (-230, 470, 5), (130, 560, 5),
]
for (dx, height, radius) in flakes {
    let center = CGPoint(x: body.midX + dx, y: body.minY + height)
    let glow = CGGradient(colorsSpace: space, colors: [color(0xfff3dc, 0.95), color(0xfff3dc, 0.55), color(0xffd696, 0)] as CFArray,
                          locations: [0, 0.35, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * 1.9, options: [])
}

let drift = CGMutablePath()
drift.move(to: CGPoint(x: body.minX - 10, y: body.minY - 10))
drift.addLine(to: CGPoint(x: body.minX - 10, y: body.minY + 196))
drift.addCurve(to: CGPoint(x: body.minX + 300, y: body.minY + 172),
               control1: CGPoint(x: body.minX + 90, y: body.minY + 214), control2: CGPoint(x: body.minX + 200, y: body.minY + 160))
drift.addCurve(to: CGPoint(x: body.minX + 560, y: body.minY + 214),
               control1: CGPoint(x: body.minX + 400, y: body.minY + 184), control2: CGPoint(x: body.minX + 470, y: body.minY + 222))
drift.addCurve(to: CGPoint(x: body.maxX + 10, y: body.minY + 168),
               control1: CGPoint(x: body.minX + 660, y: body.minY + 206), control2: CGPoint(x: body.minX + 740, y: body.minY + 160))
drift.addLine(to: CGPoint(x: body.maxX + 10, y: body.minY - 10))
drift.closeSubpath()
ctx.saveGState()
ctx.addPath(drift)
ctx.clip()
let pool = CGPoint(x: body.midX, y: body.minY + 120)
let snow = CGGradient(colorsSpace: space, colors: [color(0xf7ecd9), color(0xc9bba6), color(0x5d5a5c), color(0x2a2b30)] as CFArray,
                      locations: [0, 0.35, 0.72, 1])!
ctx.drawRadialGradient(snow, startCenter: pool, startRadius: 0, endCenter: pool, endRadius: 520, options: [.drawsAfterEndLocation])
let crust = CGGradient(colorsSpace: space, colors: [color(0xffffff, 0.16), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(crust, start: CGPoint(x: 0, y: body.minY + 220), end: CGPoint(x: 0, y: body.minY + 120), options: [])
ctx.restoreGState()

ctx.restoreGState()

ctx.saveGState()
ctx.addPath(outline)
ctx.setStrokeColor(color(0xffffff, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")

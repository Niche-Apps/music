// Renders the app icon at 1024 px and writes every size into the asset catalog.
//   swift tools/make-icon.swift [out.png]
// A near-black squircle with a low oxblood glow and a single record: fine grooves, a soft sheen,
// and an accent-colored label — the same palette as the app's dark surfaces.
import AppKit

let size: CGFloat = 1024
let accent = NSColor(srgbRed: 0.980, green: 0.176, blue: 0.333, alpha: 1)

let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r, g, b, a])! }

// macOS icon grid: 824 pt body centered on a 1024 canvas, continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
ctx.addPath(shape)
ctx.setFillColor(color(0.07, 0.06, 0.08))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Background: graphite, warming to oxblood toward the lower left.
let bg = CGGradient(colorsSpace: rgb, colors: [color(0.13, 0.11, 0.14), color(0.05, 0.045, 0.06)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: rgb, colors: [color(0.55, 0.06, 0.16, 0.55), color(0.55, 0.06, 0.16, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 250, y: 220), startRadius: 0, endCenter: CGPoint(x: 250, y: 220), endRadius: 620, options: [])

// The record.
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 318
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.6))
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.setFillColor(color(0.035, 0.032, 0.04))
ctx.fillPath()
ctx.restoreGState()

// Grooves.
ctx.setLineWidth(1.4)
var r = radius - 14
while r > 118 {
    let band = (r - 118) / (radius - 132)
    ctx.setStrokeColor(color(1, 1, 1, 0.035 + 0.03 * (1 - band)))
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    r -= 7
}
// Two quiet gaps between "tracks".
for gap in [CGFloat(258), 196] {
    ctx.setStrokeColor(color(0, 0, 0, 0.9))
    ctx.setLineWidth(5)
    ctx.strokeEllipse(in: CGRect(x: center.x - gap, y: center.y - gap, width: gap * 2, height: gap * 2))
}

// Sheen: two opposing light wedges, like a ceiling light on vinyl.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.clip()
// A conic falloff built from thin wedges, so the light fades smoothly around the disc.
let steps = 720
let peak = CGFloat.pi * 0.3
for i in 0..<steps {
    let start = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let end = start + 2 * .pi / CGFloat(steps) + 0.002
    let strength = pow(max(0, cos(2 * (start - peak))), 5)
    guard strength > 0.01 else { continue }
    let path = CGMutablePath()
    path.move(to: center)
    path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    path.closeSubpath()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let sheen = CGGradient(
        colorsSpace: rgb, colors: [color(1, 1, 1, 0), color(1, 1, 1, 0.16 * strength)] as CFArray, locations: [0.3, 1])!
    ctx.drawRadialGradient(sheen, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}
ctx.restoreGState()

// Rim highlight.
ctx.setLineWidth(2)
ctx.setStrokeColor(color(1, 1, 1, 0.10))
ctx.strokeEllipse(in: CGRect(x: center.x - radius + 1, y: center.y - radius + 1, width: radius * 2 - 2, height: radius * 2 - 2))

// Label.
let labelR: CGFloat = 104
let a = accent.cgColor.components!
let label = CGGradient(
    colorsSpace: rgb,
    colors: [color(a[0], a[1], a[2]), color(a[0] * 0.62, a[1] * 0.5, a[2] * 0.55)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - labelR, y: center.y - labelR, width: labelR * 2, height: labelR * 2))
ctx.clip()
ctx.drawLinearGradient(label, start: CGPoint(x: center.x - labelR, y: center.y + labelR), end: CGPoint(x: center.x + labelR, y: center.y - labelR), options: [])
ctx.setStrokeColor(color(0, 0, 0, 0.18))
ctx.setLineWidth(1.5)
ctx.strokeEllipse(in: CGRect(x: center.x - 70, y: center.y - 70, width: 140, height: 140))
ctx.restoreGState()

// Spindle hole.
ctx.setFillColor(color(0.05, 0.045, 0.06))
ctx.fillEllipse(in: CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26))

// Fine top-edge highlight on the body.
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape)
ctx.setLineWidth(2)
ctx.setStrokeColor(color(1, 1, 1, 0.08))
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appending(path: "StandardMusic/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
try png.write(to: out)
print("wrote \(out.path)")

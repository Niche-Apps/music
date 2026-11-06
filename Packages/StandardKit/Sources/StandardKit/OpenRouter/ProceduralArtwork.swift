import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Zero-cost, deterministic artwork for when no image model is used (or one fails): layered gradients,
/// soft shapes and grain seeded by the prompt, so every album and artist looks distinct but stable.
public enum ProceduralArtwork {
    public static func jpeg(prompt: String, size: String = "1024x1024") -> Data? {
        let dims = size.split(separator: "x").compactMap { Int($0) }
        let w = dims.first ?? 1024, h = dims.count > 1 ? dims[1] : w
        var rng = SeededRNG(seed: fnv1a(prompt))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let baseHue = Double(rng.next() % 360) / 360
        func color(_ dh: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            let (r, g, bl) = hsb((baseHue + dh).truncatingRemainder(dividingBy: 1), s, b)
            return CGColor(colorSpace: space, components: [r, g, bl, a])!
        }
        let style = rng.next() % 3
        let gradient = CGGradient(colorsSpace: space, colors: [color(0, 0.65, 0.35), color(0.08 + Double(style) * 0.1, 0.7, 0.85)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        // Soft orbs / bands.
        for i in 0 ..< 7 {
            let r = CGFloat(Double(min(w, h)) * (0.12 + rng.unit() * 0.4))
            let c = CGPoint(x: CGFloat(rng.unit()) * CGFloat(w), y: CGFloat(rng.unit()) * CGFloat(h))
            let orb = CGGradient(colorsSpace: space, colors: [color(0.15 * Double(i % 3) - 0.1, 0.6, 0.95, 0.55), color(0, 0.5, 0.5, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(orb, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
        if style == 1 {
            ctx.setStrokeColor(color(0.5, 0.2, 1, 0.18))
            ctx.setLineWidth(CGFloat(w) / 220)
            for k in 0 ..< 24 {
                let y = CGFloat(k) * CGFloat(h) / 24
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: CGFloat(w), y: y + CGFloat(h) * 0.15))
            }
            ctx.strokePath()
        } else if style == 2 {
            ctx.setFillColor(color(0.5, 0.3, 0.1, 0.35))
            ctx.fillEllipse(in: CGRect(x: CGFloat(w) * 0.2, y: CGFloat(h) * 0.2, width: CGFloat(w) * 0.6, height: CGFloat(h) * 0.6))
        }
        // Film grain.
        for _ in 0 ..< (w * h / 180) {
            ctx.setFillColor(CGColor(gray: rng.unit() > 0.5 ? 1 : 0, alpha: 0.05))
            ctx.fill(CGRect(x: Int(rng.next() % UInt64(w)), y: Int(rng.next() % UInt64(h)), width: 2, height: 2))
        }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h &*= 0x100_0000_01b3 }
        return h
    }

    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    struct SeededRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    }
}

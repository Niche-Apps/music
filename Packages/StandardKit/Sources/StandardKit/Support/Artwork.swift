import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stores artwork on disk (full size + thumbnail) and extracts page colours.
public struct ArtworkStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public enum Kind: String, Sendable { case artist = "Artists", album = "Albums" }

    /// Relative path stored in the database.
    public func relativePath(kind: Kind, id: ID) -> String { "\(kind.rawValue)/\(id).jpg" }

    public func url(for relativePath: String) -> URL { root.appending(path: relativePath) }

    public func thumbnailURL(for relativePath: String) -> URL {
        root.appending(path: relativePath.replacingOccurrences(of: ".jpg", with: "@thumb.jpg"))
    }

    /// Writes the image and a 400 px thumbnail; returns the relative path.
    @discardableResult
    public func save(_ data: Data, kind: Kind, id: ID) throws -> String {
        let relative = relativePath(kind: kind, id: id)
        let url = url(for: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let thumb = Self.thumbnail(data, maxPixel: 400) {
            try thumb.write(to: thumbnailURL(for: relative), options: .atomic)
        }
        return relative
    }

    static func thumbnail(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Palette

    /// Apple-Music-style page colours: [background, primary text, secondary text, tertiary text] as hex.
    public static func palette(from data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary)
        else { return [] }
        let w = image.width
        let h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Quantise into a 4-bit-per-channel histogram, weighting the bottom edge (where text usually sits).
        var buckets: [Int: (count: Double, r: Double, g: Double, b: Double)] = [:]
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
                let weight = y < h / 3 ? 1.6 : 1.0  // CGContext origin is bottom-left
                var e = buckets[key] ?? (0, 0, 0, 0)
                e.count += weight
                e.r += r * weight
                e.g += g * weight
                e.b += b * weight
                buckets[key] = e
            }
        }
        let colors = buckets.values.sorted { $0.count > $1.count }.map {
            RGB(r: $0.r / $0.count, g: $0.g / $0.count, b: $0.b / $0.count)
        }
        guard let background = colors.first else { return [] }
        let candidates = colors.dropFirst().filter { $0.contrast(with: background) > 3.0 }
        let primary = candidates.first ?? (background.luminance > 0.45 ? RGB(r: 0.08, g: 0.08, b: 0.08) : RGB(r: 1, g: 1, b: 1))
        let secondary = candidates.dropFirst().first { $0.distance(to: primary) > 0.12 } ?? primary.mixed(with: background, 0.3)
        let tertiary = primary.mixed(with: background, 0.45)
        return [background, primary, secondary, tertiary].map(\.hex)
    }

    struct RGB {
        var r, g, b: Double

        var luminance: Double {
            func c(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
        }

        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance + 0.05, other.luminance + 0.05)
            return max(a, b) / min(a, b)
        }

        func distance(to o: RGB) -> Double { sqrt(pow(r - o.r, 2) + pow(g - o.g, 2) + pow(b - o.b, 2)) }

        func mixed(with o: RGB, _ t: Double) -> RGB {
            RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
        }

        var hex: String {
            String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }
}

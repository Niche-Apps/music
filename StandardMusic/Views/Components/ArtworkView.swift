import AppKit
import ImageIO
import StandardKit
import SwiftUI

/// In-memory cache for decoded artwork.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 600 }

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    /// Loads a local or remote image off the main thread, caching the result.
    func load(_ url: URL) async -> NSImage? {
        if let cached = image(for: url) { return cached }
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            if url.isFileURL { return Self.decode(CGImageSourceCreateWithURL(url as CFURL, nil)) }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return Self.decode(CGImageSourceCreateWithData(data as CFData, nil))
        }.value
        if let image { insert(image, for: url) }
        return image
    }
}

extension ImageCache {
    /// Decodes fully off the main thread (NSImage(contentsOf:) decodes lazily while drawing, which
    /// stalls scrolling) and caps the size at what the app ever displays.
    nonisolated static func decode(_ source: CGImageSource?, maxPixels: Int = 1600) -> NSImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Square artwork for an album (or a round/square portrait for an artist) with a graceful placeholder.
struct ArtworkView: View {
    enum Source: Equatable {
        case album(Album)
        case artist(Artist)
        case url(URL?)
    }

    let source: Source
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = Metrics.artworkCorner
    var circular = false
    /// Use the 400 px thumbnail (lists/grids) or the full image (hero).
    var highResolution = false
    var shadow = true
    /// Spoken description ("Album cover, … by …"). When nil the artwork is decorative and hidden from
    /// VoiceOver, which is right wherever a title next to it already says the same thing.
    var accessibilityDescription: String? = nil

    @State private var image: NSImage?
    @Environment(AppModel.self) private var model

    private var url: URL? {
        switch source {
        case .album(let a):
            return a.coverPath.map { highResolution ? model.services.artwork.url(for: $0) : model.services.artwork.thumbnailURL(for: $0) }
        case .artist(let a):
            return a.imagePath.map { highResolution ? model.services.artwork.url(for: $0) : model.services.artwork.thumbnailURL(for: $0) }
        case .url(let u):
            return u
        }
    }

    private var thumbnailURL: URL? {
        switch source {
        case .album(let a): a.coverPath.map { model.services.artwork.thumbnailURL(for: $0) }
        case .artist(let a): a.imagePath.map { model.services.artwork.thumbnailURL(for: $0) }
        case .url: nil
        }
    }

    private var placeholderColors: [Color] {
        switch source {
        case .album(let a):
            let c = a.palette.compactMap { Color(hex: $0) }
            return c.count >= 2 ? [c[0], c[1].opacity(0.6)] : Self.seeded(a.id)
        case .artist(let a):
            guard let accent = Color(hex: a.accentHex) else { return Self.seeded(a.id) }
            return [accent, accent.opacity(0.5)]
        case .url:
            return [Color.gray.opacity(0.25), Color.gray.opacity(0.15)]
        }
    }

    /// Stable per-id colours (String.hashValue changes every launch).
    static func seeded(_ id: String) -> [Color] {
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        let h = Double(hash % 360) / 360
        return [Color(hue: h, saturation: 0.45, brightness: 0.55), Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.35)]
    }

    var body: some View {
        let shape = circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        ZStack {
            LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if url == nil {
                PendingArtwork(source: source)
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(shadow ? 0.18 : 0), radius: shadow ? 6 : 0, y: shadow ? 3 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription ?? "")
        .accessibilityAddTraits(.isImage)
        .accessibilityHidden(accessibilityDescription == nil)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImageCache.shared.image(for: url) {
                image = cached
                return
            }
            if highResolution, let thumb = thumbnailURL, let cached = ImageCache.shared.image(for: thumb) { image = cached }
            let loaded = await ImageCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }

}

/// Stand-in while artwork hasn't been made yet: a typographic cover for albums, a monogram for
/// artists. Scales with whatever size it's given.
private struct PendingArtwork: View {
    let source: ArtworkView.Source

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            switch source {
            case .album(let album):
                VStack(alignment: .leading, spacing: s * 0.02) {
                    Text("\(String(album.releaseYear))\(album.kind == .album ? "" : " · \(album.kind.label)")".uppercased())
                        .font(.system(size: max(7, s * 0.055), weight: .semibold))
                        .tracking(s * 0.008)
                        .opacity(0.7)
                    Spacer(minLength: 0)
                    Text(album.title)
                        .font(.system(size: max(9, s * 0.11), weight: .bold, design: .serif))
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.2), radius: s * 0.02)
                    Rectangle().fill(.white.opacity(0.6)).frame(width: s * 0.16, height: max(1, s * 0.008))
                }
                .foregroundStyle(.white)
                .padding(s * 0.09)
                .frame(width: s, height: s, alignment: .topLeading)
                .opacity(s < 40 ? 0 : 1)
            case .artist(let artist):
                Text(Self.initials(artist.name))
                    .font(.system(size: s * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: s, height: s)
            case .url:
                Image(systemName: "music.note")
                    .font(.system(size: s * 0.28, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: s, height: s)
            }
        }
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let skip: Set<String> = ["the", "a", "an", "&", "and", "of", "de", "la", "le"]
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            .filter { !skip.contains($0.lowercased()) && $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

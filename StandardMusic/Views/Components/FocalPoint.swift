import AppKit
import SwiftUI
import Vision

/// Where the interesting part of a photo is, so wide crops of square portraits keep the people's
/// faces in frame instead of their chests. Normalized, origin top-left.
enum FocalPoint {
    @MainActor private static var cache: [URL: CGPoint] = [:]

    /// Portraits put heads high; a better guess than the middle when nothing is detected.
    static let fallback = CGPoint(x: 0.5, y: 0.35)

    @MainActor static func cached(for url: URL) -> CGPoint? { cache[url] }

    @MainActor static func find(in image: NSImage, for url: URL) async -> CGPoint {
        if let hit = cache[url] { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let point = await Task.detached(priority: .userInitiated) { detect(cg) }.value
        cache[url] = point
        return point
    }

    /// Faces first, then whole people (heads near the top), then visual attention.
    nonisolated static func detect(_ image: CGImage) -> CGPoint {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, humans, saliency])

        // Vision rects are normalized with a bottom-left origin.
        func top(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

        if let found = faces.results, !found.isEmpty {
            // Ignore small faces in the background (posters, crowds) next to the main subject.
            let largest = found.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
            let main = found.filter { $0.boundingBox.width * $0.boundingBox.height >= largest * 0.2 }
            let union = main.map { top($0.boundingBox) }.reduce(CGRect.null) { $0.union($1) }
            return CGPoint(x: union.midX, y: union.midY)
        }
        if let people = humans.results?.filter({ $0.confidence > 0.3 }), !people.isEmpty {
            let union = people.map { top($0.boundingBox) }.reduce(CGRect.null) { $0.union($1) }
            // A head sits in roughly the top eighth of a standing figure's box.
            return CGPoint(x: union.midX, y: union.minY + min(union.height * 0.12, 0.15))
        }
        if let salient = saliency.results?.first?.salientObjects, !salient.isEmpty {
            let union = salient.map { top($0.boundingBox) }.reduce(CGRect.null) { $0.union($1) }
            return CGPoint(x: union.midX, y: union.minY + union.height * 0.3)
        }
        return fallback
    }
}

/// An image that fills its frame like `.aspectRatio(contentMode: .fill)`, but slides the crop so
/// `focus` lands at `anchor` within the frame (as close as the image's edges allow).
struct FocusedFillImage: View {
    let image: NSImage
    let focus: CGPoint
    /// Where in the frame the focal point should sit. Slightly above center leaves room for
    /// titles drawn over the bottom of the frame.
    var anchor = CGPoint(x: 0.5, y: 0.4)

    var body: some View {
        GeometryReader { geo in
            let frame = geo.size
            let source = image.size
            let scale = max(frame.width / max(source.width, 1), frame.height / max(source.height, 1))
            let shown = CGSize(width: source.width * scale, height: source.height * scale)
            let x = Self.offset(focus: focus.x, anchor: anchor.x, frame: frame.width, shown: shown.width)
            let y = Self.offset(focus: focus.y, anchor: anchor.y, frame: frame.height, shown: shown.height)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: shown.width, height: shown.height)
                .offset(x: x, y: y)
        }
        .clipped()
    }

    /// The leading offset that puts `focus` at `anchor`, clamped so the image always covers the frame.
    static func offset(focus: CGFloat, anchor: CGFloat, frame: CGFloat, shown: CGFloat) -> CGFloat {
        let wanted = frame * anchor - shown * focus
        return min(0, max(frame - shown, wanted))
    }
}

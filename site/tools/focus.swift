// Prints the focal point ("x,y", normalized, top-left origin) of each image argument, using the
// same face/person/saliency detection as the app's artist banners (FocalPoint.swift).
import AppKit
import Vision

enum FocalPoint {
    static let fallback = CGPoint(x: 0.5, y: 0.35)
    static func detect(_ image: CGImage) -> CGPoint {
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

for path in CommandLine.arguments.dropFirst() {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("0.5,0.35"); continue }
    let p = FocalPoint.detect(image)
    print(String(format: "%.3f,%.3f", p.x, p.y))
}

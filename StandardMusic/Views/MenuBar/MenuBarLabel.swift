import AppKit
import StandardKit
import SwiftUI

/// Menu bar glyph: a resting equaliser that dances gently while playing, with a small progress ring
/// beside it while the studio is recording. Drawn as a template image so it follows the menu bar.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        let playing = model.player.isPlaying
        let ring: Double? = model.recording.active.map { $0.fraction }
        // Reduce Motion: a still "playing" pose instead of dancing bars (and no level-driven wobble).
        let glyph = reduceMotion
            ? MenuBarGlyph.image(phase: playing ? 2 : nil, level: 0.3, ring: ring)
            : MenuBarGlyph.image(phase: playing ? phase : nil, level: Double(model.player.level), ring: ring)
        Image(nsImage: glyph)
            .accessibilityLabel(accessibilityText)
            .menuBarDevHooks()
            .task(id: playing && !reduceMotion) {
                guard playing, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(140))
                    phase += 1
                }
            }
    }

    private var accessibilityText: String {
        var parts = ["Standard Music"]
        if let current = model.player.current, model.player.isPlaying { parts.append("playing \(current.track.title)") }
        if let active = model.recording.active {
            parts.append("recording \(active.title)" + (active.fraction > 0.005 ? ", \(Spoken.percent(active.fraction))" : ""))
        }
        return parts.joined(separator: ", ")
    }
}

enum MenuBarGlyph {
    /// - Parameters:
    ///   - phase: animation step while playing; nil draws the resting glyph.
    ///   - ring: recording progress (0…1) when the studio is busy.
    @MainActor
    static func image(phase: Double?, level: Double, ring: Double?) -> NSImage {
        let barsWidth: CGFloat = 13
        let ringSize: CGFloat = 9
        let gap: CGFloat = 3
        let height: CGFloat = 16
        let width = barsWidth + (ring == nil ? 0 : gap + ringSize)
        let rest: [CGFloat] = [0.45, 0.85, 0.6, 0.35]
        let heights: [CGFloat] = rest.enumerated().map { i, base in
            guard let phase else { return base }
            // Smooth pseudo-random motion per bar, a little livelier when the music is louder.
            let t = phase * 0.55 + Double(i) * 1.7
            let wobble = (sin(t) * 0.5 + sin(t * 1.9 + Double(i)) * 0.5) * 0.5 + 0.5
            let energy = 0.55 + min(1, level * 2.5) * 0.45
            return CGFloat(0.25 + wobble * 0.75 * energy)
        }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.black.setFill()
            let barWidth: CGFloat = 2.2
            let spacing = (barsWidth - barWidth * 4) / 3
            let maxBar: CGFloat = 12
            let baseY = (height - maxBar) / 2
            for (i, h) in heights.enumerated() {
                let barHeight = max(barWidth, maxBar * h)
                let rect = NSRect(x: CGFloat(i) * (barWidth + spacing), y: baseY, width: barWidth, height: barHeight)
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            if let ring {
                let center = NSPoint(x: barsWidth + gap + ringSize / 2, y: height / 2)
                let radius = ringSize / 2 - 0.75
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 1.5
                NSColor.black.withAlphaComponent(0.35).setStroke()
                track.stroke()
                let progress = NSBezierPath()
                let fraction = max(0.08, min(1, ring))
                progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                progress.lineWidth = 1.5
                progress.lineCapStyle = .round
                NSColor.black.setStroke()
                progress.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

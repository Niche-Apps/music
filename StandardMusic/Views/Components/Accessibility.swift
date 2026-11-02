import StandardKit
import SwiftUI

/// Phrases for VoiceOver: full words instead of the compact on-screen formats.
enum Spoken {
    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    /// "3 minutes, 12 seconds".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        return durationFormatter.string(from: seconds.rounded()) ?? ""
    }

    /// "about 5 minutes left".
    static func remaining(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        if seconds < 50 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes) minute\(minutes == 1 ? "" : "s") left"
    }

    /// "42 percent".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent"
    }

    /// "Recording, 42 percent, about 5 minutes left" (stage replaces "Recording" when given).
    static func recording(fraction: Double, stage: String? = nil, remaining: TimeInterval? = nil) -> String {
        var parts = [stage ?? "Recording"]
        if fraction > 0.005 { parts.append(percent(fraction)) }
        if let r = Self.remaining(remaining) { parts.append(r) }
        return parts.joined(separator: ", ")
    }

    static func albumCover(_ title: String, by artist: String?) -> String {
        artist.map { "Album cover, \(title) by \($0)" } ?? "Album cover, \(title)"
    }
}

extension TrackLiveState {
    /// Spoken state for a song: "Playing", "Recording, 42 percent, about 5 minutes left", "Not recorded yet" …
    /// Returns nil for a ready song that isn't playing (nothing extra to say).
    var spokenDescription: String? {
        switch self {
        case .playing: "Playing"
        case .paused: "Paused"
        case .waiting: "Waiting for the studio"
        case .recording(let fraction, let stage, let remaining):
            stage == "Recording" || stage.isEmpty
                ? Spoken.recording(fraction: fraction, remaining: remaining)
                : "Recording, " + Spoken.recording(fraction: fraction, stage: stage.lowercased(), remaining: remaining)
        case .queued(let n): n <= 1 ? "Recording next" : "In the studio queue, \(TrackStatusCaption.ordinal(n)) in line"
        case .failed: "Recording failed"
        case .ready: nil
        case .unrecorded: "Not recorded yet"
        }
    }
}

extension View {
    /// Marks a view as a section heading for VoiceOver's rotor.
    func accessibilityHeading() -> some View { accessibilityAddTraits(.isHeader) }

    /// A choice that can be switched on and off (genre tiles, artist bubbles, answer cards):
    /// VoiceOver reads it as a toggle and says whether it's selected.
    func accessibilityChoice(selected: Bool) -> some View {
        accessibilityAddTraits(.isToggle)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An invisible button that only exists to carry a keyboard shortcut (arrow keys, number keys) for
/// a screen whose controls are otherwise mouse-first. Hidden from VoiceOver, which has its own way in.
struct KeyboardShortcutHandler: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Solid backing behind text that sits on artwork or blur, shown only when the user asks for less
/// transparency or more contrast. Otherwise it renders nothing, so the design is unchanged.
struct LegibilityScrim<S: Shape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var shape: S
    var color: Color = .black
    var opacity: Double = 0.72

    var body: some View {
        if reduceTransparency || contrast == .increased {
            shape.fill(color.opacity(opacity))
        }
    }
}

extension LegibilityScrim where S == Rectangle {
    init(color: Color = .black, opacity: Double = 0.72) {
        self.init(shape: Rectangle(), color: color, opacity: opacity)
    }
}

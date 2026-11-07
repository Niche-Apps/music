import StandardKit
import SwiftUI

/// Previous / play-pause / next. Shows a recording ring instead of play when the current song is
/// still being recorded.
struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 17
    var spacing: CGFloat = 18

    var body: some View {
        let player = model.player
        HStack(spacing: spacing) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: size * 0.82))
            }
            .help("Previous")
            .accessibilityLabel("Previous")
            .disabled(player.currentEntry == nil)

            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.isWaiting {
                        RecordingRing(fraction: model.recording.active?.trackID == player.current?.track.id ? model.recording.active?.fraction ?? 0 : 0, lineWidth: 2)
                            .frame(width: size * 1.25, height: size * 1.25)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: size * 1.2))
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
                .frame(width: size * 1.6, height: size * 1.6)
            }
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityValue(player.isWaiting ? waitingDescription : "")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: size * 0.82))
            }
            .help("Next")
            .accessibilityLabel("Next")
            .disabled(player.currentEntry == nil)
        }
        .buttonStyle(.plain)
    }

    private var waitingDescription: String {
        guard let active = model.recording.active, active.trackID == model.player.current?.track.id else { return "Waiting for the studio" }
        return Spoken.recording(fraction: active.fraction, remaining: active.remaining)
    }
}

/// Circular progress used for songs being recorded.
struct RecordingRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 2.5
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsVisible) private var windowIsVisible

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: lineWidth)
            if fraction > 0.005 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: fraction)
            } else {
                // Driven by the clock rather than a repeating animation: a repeatForever animation
                // also captures layout changes (the toolbar settling) and slides the ring around.
                TimelineView(.animation(paused: reduceMotion || !windowIsVisible)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
                }
                .opacity(reduceMotion ? 0.6 : 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recording")
        .accessibilityValue(fraction > 0.005 ? Spoken.percent(fraction) : "Starting")
    }
}

/// Progress bar for playback, or for recording when the current song is still in the studio.
struct PlaybackScrubber: View {
    @Environment(AppModel.self) private var model
    var showsTimes = true
    var height: CGFloat = 4
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        let player = model.player
        let recordingThis = player.isWaiting && model.recording.active?.trackID == player.current?.track.id
        VStack(spacing: 3) {
            GeometryReader { geo in
                let fraction: Double =
                    player.isWaiting
                    ? (recordingThis ? model.recording.active?.fraction ?? 0 : 0)
                    : (dragValue ?? (player.duration > 0 ? player.time / player.duration : 0))
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.12))
                    Capsule()
                        .fill(player.isWaiting ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.primary.opacity(0.55)))
                        .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
                }
                .frame(height: hovering && !player.isWaiting ? height + 2 : height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard !player.isWaiting, player.duration > 0 else { return }
                            dragValue = min(max(g.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let v = dragValue { player.seek(to: v * player.duration) }
                            dragValue = nil
                        }
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel(player.isWaiting ? "Recording progress" : "Playback position")
            .accessibilityValue(scrubberValue(recordingThis: recordingThis))
            .accessibilityAdjustableAction { direction in
                guard !player.isWaiting, player.duration > 0 else { return }
                let step: Double = direction == .increment ? 10 : -10
                player.seek(to: min(max(player.time + step, 0), player.duration))
            }
            if showsTimes {
                HStack {
                    if player.isWaiting {
                        Text(recordingThis ? model.recording.active?.stageLabel ?? "Recording" : "Waiting for the studio")
                        Spacer()
                        Text(recordingThis ? Format.remaining(model.recording.active?.remaining) ?? "" : "")
                    } else {
                        Text(Format.duration(dragValue.map { $0 * player.duration } ?? player.time))
                        Spacer()
                        Text("-" + Format.duration(max(0, player.duration - (dragValue.map { $0 * player.duration } ?? player.time))))
                    }
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    private func scrubberValue(recordingThis: Bool) -> String {
        let player = model.player
        if player.isWaiting {
            guard recordingThis, let active = model.recording.active else { return "Waiting for the studio" }
            return Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining)
        }
        return "\(Spoken.duration(player.time)) of \(Spoken.duration(player.duration))"
    }
}

struct FavoriteButton: View {
    var isFavorite: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Favorite")
        .accessibilityLabel("Favorite")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
}

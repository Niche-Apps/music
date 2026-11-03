import StandardKit
import SwiftUI

/// The first song of the new library, made at the jump so there's something to listen to while the
/// rest is written: who's making it, the studio's progress, then a small player once it's recorded.
struct WhileYouWaitCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let song: OpenerSong
    /// Shown before the artist is cast.
    let genre: String?
    /// Whether this screen saw the song before it was ready (only then does it start by itself).
    @State private var sawUnready = false

    enum Stage: Equatable {
        case casting
        case writingSong
        case writingLyrics
        case waitingForStudio
        case queued
        case recording
        case ready
        case failed
    }

    static func stage(for song: OpenerSong, recording: RecordingQueue, modelInstalled: Bool) -> Stage {
        guard let track = song.track else { return song.artist == nil ? .casting : .writingSong }
        if track.isPlayable { return .ready }
        if track.status == .failed || recording.hasFailed(track.id) { return .failed }
        if let active = recording.active, active.trackID == track.id {
            switch active.phase {
            case .writingLyrics: return .writingLyrics
            case .waitingForModel: return .waitingForStudio
            case .recording: return .recording
            }
        }
        return modelInstalled ? .queued : .waitingForStudio
    }

    private var modelInstalled: Bool {
        if case .installed = model.modelState { return true }
        return false
    }

    private var stage: Stage { Self.stage(for: song, recording: model.recording, modelInstalled: modelInstalled) }
    private var activity: RecordingQueue.Activity? {
        guard let id = song.track?.id, model.recording.active?.trackID == id else { return nil }
        return model.recording.active
    }
    private var isCurrent: Bool { song.track.map { model.player.current?.track.id == $0.id } ?? false }
    private var isPlaying: Bool { isCurrent && model.player.isPlaying }

    var body: some View {
        HStack(spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHILE YOU WAIT")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(.pink)
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                    Text(detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                if stage == .ready, let track = song.track {
                    OpenerScrubber(track: track, isCurrent: isCurrent)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .foregroundStyle(.white)
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(width: 440)
        .glassEffect(.regular.tint(.pink.opacity(stage == .ready ? 0.14 : 0.06)), in: .rect(cornerRadius: 18))
        .animation(.smooth(duration: 0.5), value: stage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("While you wait")
        .onAppear { if stage != .ready { sawUnready = true } }
        .onChange(of: stage) { _, new in
            if new != .ready {
                sawUnready = true
            } else if sawUnready {
                autoPlay()
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let album = song.album, album.coverPath != nil {
                ArtworkView(source: .album(album), size: 64, cornerRadius: 10, shadow: false)
            } else if let artist = song.artist, artist.imagePath != nil {
                ArtworkView(source: .artist(artist), size: 64, cornerRadius: 10, shadow: false)
            } else {
                ZStack {
                    LinearGradient(
                        colors: song.artist.map { a in Color(hex: a.accentHex).map { [$0, $0.opacity(0.45)] } ?? ArtworkView.seeded(a.id) }
                            ?? [.pink.opacity(0.7), Color(hue: 0.98, saturation: 0.8, brightness: 0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    ShimmerBlock(cornerRadius: 10)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .shadow(color: (Color(hex: song.artist?.accentHex) ?? .pink).opacity(isPlaying ? 0.6 : 0.25), radius: isPlaying ? 18 : 10)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var control: some View {
        if stage == .ready, let track = song.track {
            Button {
                toggle(track)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: isPlaying ? 0 : 1.5)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play “\(track.title)”")
            .accessibilityLabel(isPlaying ? "Pause “\(track.title)”" : "Play “\(track.title)”")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            ZStack {
                RecordingRing(fraction: ringFraction, lineWidth: 2.5, tint: stage == .waitingForStudio ? .white.opacity(0.8) : .pink)
                if stage == .recording, let activity, activity.fraction > 0.005 {
                    Text(activity.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: activity.fraction))
                } else {
                    Image(systemName: stageIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(width: 38, height: 38)
            .animation(.smooth, value: ringFraction)
            .accessibilityElement()
            .accessibilityLabel(stage == .recording ? "Recording progress" : "Status")
            .accessibilityValue(spokenStatus)
        }
    }

    private var ringFraction: Double {
        switch stage {
        case .recording: return activity?.fraction ?? 0
        case .waitingForStudio:
            if case .downloading(let p) = model.modelState { return p.fraction }
            return 0
        default: return 0
        }
    }

    private var stageIcon: String {
        switch stage {
        case .casting: "person.crop.circle.badge.plus"
        case .writingSong, .writingLyrics: "pencil.and.scribble"
        case .waitingForStudio: "arrow.down"
        case .queued: "hourglass"
        case .recording: "waveform"
        case .ready, .failed: "music.note"
        }
    }

    private var title: String {
        if let track = song.track { return track.title }
        if let artist = song.artist { return "A new \(artist.primaryGenre) song" }
        if let genre, !genre.isEmpty { return "A \(genre) song, just for you" }
        return "Your first song"
    }

    private var detail: String {
        let artist = song.artist?.name
        let status: String
        switch stage {
        case .casting: return "Casting the artist who’ll record it…"
        case .writingSong: status = "Writing the song"
        case .writingLyrics: status = "Writing lyrics"
        case .waitingForStudio:
            if case .downloading(let p) = model.modelState, p.fraction > 0.005 {
                status = "Waiting for the studio to finish setting up · \(p.fraction.formatted(.percent.precision(.fractionLength(0))))"
            } else {
                status = "Waiting for the studio to finish setting up"
            }
        case .queued: status = "First in line at the studio"
        case .recording:
            var parts = [activity?.stageLabel ?? "Recording"]
            if let left = Format.remaining(activity?.remaining) { parts.append(left) }
            status = parts.joined(separator: " · ")
        case .ready:
            let album = song.album.map { " — \($0.title)" } ?? ""
            return (artist ?? "") + album
        case .failed: status = "Couldn’t be recorded"
        }
        return [artist, status].compactMap { $0 }.joined(separator: " · ")
    }

    private var spokenStatus: String {
        switch stage {
        case .recording:
            guard let activity else { return "Recording" }
            return Spoken.recording(fraction: activity.fraction, stage: activity.stageLabel, remaining: activity.remaining)
        case .waitingForStudio:
            if case .downloading(let p) = model.modelState {
                return "Waiting for the studio to finish setting up, \(Spoken.percent(p.fraction)) downloaded"
            }
            return "Waiting for the studio to finish setting up"
        default:
            return detail
        }
    }

    // MARK: Playback

    private func toggle(_ track: Track) {
        if isCurrent {
            model.player.togglePlayPause()
        } else {
            play(track)
        }
    }

    private func play(_ track: Track) {
        let context = song.album.map { PlaybackContext.album($0.id, $0.title) } ?? .songs("While You Wait")
        model.player.play(trackIDs: [track.id], startingAt: track.id, context: context)
    }

    /// Starts the song once it's recorded, unless the listener is already playing (or has paused) something.
    private func autoPlay() {
        guard let track = song.track, model.player.current == nil || model.player.state == .idle else { return }
        play(track)
    }
}

/// Elapsed / remaining with a draggable bar, styled like the build's progress bar.
private struct OpenerScrubber: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let isCurrent: Bool
    @State private var dragValue: Double?
    @State private var hovering = false

    private var duration: Double { isCurrent && model.player.duration > 0 ? model.player.duration : track.duration ?? 0 }
    private var time: Double { dragValue.map { $0 * duration } ?? (isCurrent ? model.player.time : 0) }

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.duration(time))
            GeometryReader { geo in
                let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(LinearGradient(colors: [.pink, .orange.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: hovering ? 5 : 3.5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard isCurrent, duration > 0 else { return }
                            dragValue = min(max(g.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let v = dragValue { model.player.seek(to: v * duration) }
                            dragValue = nil
                        }
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Spoken.duration(time)) of \(Spoken.duration(duration))")
            .accessibilityAdjustableAction { direction in
                guard isCurrent, duration > 0 else { return }
                let step: Double = direction == .increment ? 10 : -10
                model.player.seek(to: min(max(model.player.time + step, 0), duration))
            }
            Text("-" + Format.duration(max(0, duration - time)))
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }
}

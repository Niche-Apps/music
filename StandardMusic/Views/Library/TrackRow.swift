import StandardKit
import SwiftUI

/// Live state of a song, combining the player, the studio and the stored status.
enum TrackLiveState: Equatable {
    case playing, paused, waiting
    case recording(fraction: Double, stage: String, remaining: TimeInterval?)
    case queued(Int)
    case failed(String)
    case ready, unrecorded

    var isUnrecorded: Bool {
        switch self {
        case .ready, .playing, .paused: false
        default: true
        }
    }
}

extension AppModel {
    func liveState(of track: Track) -> TrackLiveState {
        liveState(id: track.id, isPlayable: track.isPlayable, failed: track.status == .failed)
    }

    func liveState(id: ID, isPlayable: Bool, failed: Bool) -> TrackLiveState {
        if player.current?.track.id == id {
            switch player.state {
            case .playing: return .playing
            case .paused, .idle: if isPlayable { return .paused }
            case .waiting: break
            }
        }
        if let active = recording.active, active.trackID == id {
            return .recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining)
        }
        if isPlayable { return .ready }
        if let failure = recording.failures[id] { return .failed(failure) }
        if failed { return .failed("The studio couldn’t finish this song.") }
        if player.current?.track.id == id { return .waiting }
        if let position = recording.position(of: id) { return .queued(position) }
        return .unrecorded
    }
}

/// Number column: track number, equaliser when playing, ring while recording, queue position.
struct TrackLeadingCell: View {
    let state: TrackLiveState
    let number: Int?
    var hovering = false

    var body: some View {
        ZStack {
            switch state {
            case .playing:
                if hovering { Image(systemName: "pause.fill").foregroundStyle(Color.accentColor) } else { Equalizer(animating: true) }
            case .paused:
                if hovering { Image(systemName: "play.fill").foregroundStyle(Color.accentColor) } else { Equalizer(animating: false) }
            case .waiting:
                RecordingRing(fraction: 0, lineWidth: 1.8).frame(width: 13, height: 13)
            case .recording(let fraction, _, _):
                RecordingRing(fraction: fraction, lineWidth: 1.8).frame(width: 13, height: 13)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .ready:
                if hovering { Image(systemName: "play.fill") } else { numberText }
            case .unrecorded:
                numberText.foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .frame(width: 26)
    }

    @ViewBuilder private var numberText: some View {
        if let number {
            Text("\(number)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Image(systemName: "music.note").foregroundStyle(.tertiary)
        }
    }
}

/// Three bouncing bars, driven by a timeline so it costs nothing when paused.
struct Equalizer: View {
    var animating: Bool
    var color: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion: hold the bars still (the "playing" pose) instead of bouncing.
        let animating = animating && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0 ..< 3, id: \.self) { i in
                    let phase = sin(t * (5.2 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: animating ? 4 + 8 * (phase + 1) / 2 : [6, 10, 4][i])
                }
            }
            .frame(width: 13, height: 12, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Caption under a song title describing its studio state.
struct TrackStatusCaption: View {
    @Environment(AppModel.self) private var model
    let state: TrackLiveState
    let trackID: ID

    var body: some View {
        switch state {
        case .recording(_, let stage, let remaining):
            Text([stage, Format.remaining(remaining)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(Color.accentColor)
        case .waiting:
            Text("Up first in the studio")
                .foregroundStyle(Color.accentColor)
        case .queued(let n):
            Text(n <= 1 ? "Recording next" : "In the studio queue · \(Self.ordinal(n)) in line")
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack(spacing: 6) {
                Text("Recording failed").foregroundStyle(.orange).help(message)
                Button("Try Again") { model.recording.retry(trackID) }
                    .buttonStyle(.link)
            }
        default:
            EmptyView()
        }
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }
}

/// One song in a list (album page, playlist, artist top songs, search).
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo
    var number: Int?
    var showsArtwork = false
    var showsArtist = false
    var showsAlbum = false
    var isSelected = false
    var striped = false
    var list: [TrackInfo]? = nil
    var playlist: (Playlist, Int)? = nil
    var onSelect: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let track = info.track
        let state = model.liveState(of: track)
        let dim = state.isUnrecorded
        HStack(spacing: 10) {
            if showsArtwork {
                ZStack {
                    ArtworkView(source: .album(info.album), size: 38, cornerRadius: 4, shadow: false)
                        .opacity(dim ? 0.55 : 1)
                    if state != .ready && state != .unrecorded {
                        RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.35))
                        TrackLeadingCell(state: state, number: nil, hovering: hovering)
                            .foregroundStyle(.white)
                            .environment(\.colorScheme, .dark)
                    }
                }
                .frame(width: 38, height: 38)
            } else {
                TrackLeadingCell(state: state, number: number, hovering: hovering)
                    .contentShape(Rectangle())
                    .onTapGesture { activate(state) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: state == .playing || state == .paused ? .semibold : .regular))
                    .foregroundStyle(dim ? .secondary : .primary)
                    .lineLimit(1)
                if showsArtist || showsAlbum, !isCaptioned(state) {
                    Text([showsArtist ? info.artist.name : nil, showsAlbum ? info.album.title : nil].compactMap { $0 }.joined(separator: " — "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TrackStatusCaption(state: state, trackID: track.id)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if track.isFavorite || hovering {
                FavoriteButton(isFavorite: track.isFavorite) { model.toggleFavorite(track: track.id) }
                    .font(.system(size: 12))
            }
            Text(Format.duration(track.duration))
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(dim ? .tertiary : .secondary)
                .frame(width: 44, alignment: .trailing)
            Menu {
                TrackMenuItems(info: info, list: list, playlist: playlist)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showsArtwork ? 5 : 7)
        .frame(minHeight: showsArtwork ? 48 : 40)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.primary.opacity(hovering ? 0.06 : striped ? 0.028 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { activate(state) }
        .simultaneousGesture(TapGesture().onEnded { onSelect?() })
        .contextMenu { TrackMenuItems(info: info, list: list, playlist: playlist) }
        .help(dim && state == .unrecorded ? "Not recorded yet — play the album to record it" : "")
        .draggable(info.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityState(state))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(state == .unrecorded ? "Plays the album and records this song" : "")
        .accessibilityAction { activate(state) }
        .accessibilityAction(named: state == .playing ? "Pause" : "Play") { activate(state) }
        .accessibilityAction(named: "Play Next") { model.playNext([info]) }
        .accessibilityAction(named: "Play Later") { model.playLater([info]) }
        .accessibilityAction(named: track.isFavorite ? "Undo Favorite" : "Favorite") { model.toggleFavorite(track: track.id) }
        .accessibilityActions {
            if case .failed = state {
                Button("Try Recording Again") { model.recording.retry(track.id) }
            }
            Button("Go to Album") { model.show(.album(info.album.id)) }
            Button("Go to Artist") { model.show(.artist(info.artist.id)) }
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let number, !showsArtwork { parts.append("\(number)") }
        parts.append(info.track.title)
        if showsArtist || showsAlbum || showsArtwork { parts.append(info.artist.name) }
        if showsAlbum { parts.append(info.album.title) }
        if info.track.isFavorite { parts.append("Favorite") }
        return parts.joined(separator: ", ")
    }

    private func isCaptioned(_ state: TrackLiveState) -> Bool {
        switch state {
        case .recording, .waiting, .queued, .failed: true
        default: false
        }
    }

    private func activate(_ state: TrackLiveState) {
        switch state {
        case .playing: model.player.pause()
        case .paused: model.player.resume()
        default: model.play(track: info, in: list, context: playlist.map { .playlist($0.0.id, $0.0.name) })
        }
    }

    private func accessibilityState(_ state: TrackLiveState) -> String {
        [Spoken.duration(info.track.duration), state.spokenDescription]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

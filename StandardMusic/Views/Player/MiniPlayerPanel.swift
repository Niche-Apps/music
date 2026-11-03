import StandardKit
import SwiftUI

/// Up Next or lyrics, unfolded below the MiniPlayer's artwork.
struct MiniPlayerPanel: View {
    let panel: MiniPlayerView.Panel

    var body: some View {
        switch panel {
        case .queue: MiniPlayerQueue()
        case .lyrics: MiniPlayerLyrics()
        }
    }
}

struct MiniPlayerQueue: View {
    @Environment(AppModel.self) private var model
    @State private var infos: [ID: TrackInfo] = [:]

    private var entries: [PlayerModel.Entry] { Array(model.player.upNext.prefix(50)) }

    var body: some View {
        let entries = entries
        let ids = entries.map(\.trackID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Up Next").font(.system(size: 13, weight: .semibold)).accessibilityHeading()
                    if let context = model.player.context {
                        Text("Playing from \(context.label)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !entries.isEmpty {
                    Button("Clear") { model.player.clearUpNext() }
                        .accessibilityLabel("Clear Up Next")
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if entries.isEmpty {
                Spacer()
                Text(model.player.autoplay ? "Autoplay will pick something similar." : "Nothing queued.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            if let info = infos[entry.trackID] {
                                MiniPlayerQueueRow(entry: entry, info: info)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
        }
        .observing(model.services.db, id: ids, { db in
            try AppDatabase.trackInfos().filter(keys: ids).fetchAll(db)
        }) { fetched in
            infos = Dictionary(fetched.map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

struct MiniPlayerQueueRow: View {
    @Environment(AppModel.self) private var model
    let entry: PlayerModel.Entry
    let info: TrackInfo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(source: .album(info.album), size: 34, cornerRadius: 4, shadow: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.track.title)
                    .font(.system(size: 12, weight: .medium))
                    .explicitBadge(info.track.isExplicit, size: 10)
                Text(info.artist.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            status
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.09 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.player.jump(to: entry) }
        .contextMenu {
            Button("Play Now") { model.player.jump(to: entry) }
            Button("Go to Album") { model.showAlbum(info.album.id) }
            Divider()
            Button("Remove from Up Next") { model.player.remove(entry) }
        }
        .help("Double-click to play")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.track.title), \(info.artist.name)")
        .accessibilityValue(statusDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.player.jump(to: entry) }
        .accessibilityAction(named: "Play Now") { model.player.jump(to: entry) }
        .accessibilityAction(named: "Remove from Up Next") { model.player.remove(entry) }
        .accessibilityAction(named: "Go to Album") { model.showAlbum(info.album.id) }
    }

    private var statusDescription: String {
        if let active = model.recording.active, active.trackID == info.track.id {
            return Spoken.recording(fraction: active.fraction, remaining: active.remaining)
        }
        if info.track.isPlayable { return Spoken.duration(info.track.duration) }
        if info.track.status == .failed { return "Recording failed" }
        return "Not recorded yet, will be recorded before it plays"
    }

    @ViewBuilder
    private var status: some View {
        if model.recording.active?.trackID == info.track.id {
            RecordingRing(fraction: model.recording.active?.fraction ?? 0, lineWidth: 2)
                .frame(width: 14, height: 14)
                .help(model.recording.active?.stageLabel ?? "Recording")
        } else if info.track.isPlayable {
            Text(Format.duration(info.track.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        } else if info.track.status == .failed {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .help("Recording failed")
        } else {
            Image(systemName: "waveform.badge.clock")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help("Will be recorded before it plays")
        }
    }
}

struct MiniPlayerLyrics: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let track = model.player.current?.track
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let lyrics = track?.lyrics, track?.isInstrumental == false {
                    ForEach(Array(Self.stanzas(lyrics).enumerated()), id: \.offset) { _, stanza in
                        Text(stanza)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(track?.isInstrumental == true ? "This one's an instrumental." : "Lyrics are written just before the studio records this song.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollIndicators(.never)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    /// Drops YuE section tags (`[verse]`, `[chorus]`) and splits on them.
    static func stanzas(_ lyrics: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(text) }
            current = []
        }
        for line in lyrics.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
                flush()
            } else {
                current.append(trimmed)
            }
        }
        flush()
        return result
    }
}

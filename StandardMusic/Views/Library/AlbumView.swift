import GRDB
import StandardKit
import SwiftUI

struct AlbumView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let albumID: ID

    struct Data: Equatable, Sendable {
        var info: AlbumInfo
        var tracks: [TrackInfo]
        var moreByArtist: [AlbumInfo]
        var similar: [AlbumInfo]
    }

    @State private var data: Data?
    @State private var loaded = false
    @State private var selected: ID?
    @State private var notesExpanded = false
    @FocusState private var listFocused: Bool

    var body: some View {
        Group {
            if let data {
                content(data)
            } else if loaded {
                ContentUnavailableView("Album not found", systemImage: "square.stack", description: Text("It may have been removed from your library."))
            } else {
                Color.clear
            }
        }
        .navigationTitle(data?.info.album.title ?? "")
        .observing(model.services.db, id: albumID) { [albumID] db in
            guard let info = try AppDatabase.albumInfos().filter(key: albumID).fetchOne(db) else { return nil as Data? }
            let tracks = try AppDatabase.trackInfos().filter(Column("albumID") == albumID)
                .order(Column("discNumber"), Column("trackNumber")).fetchAll(db)
            let more = try LibraryQuery.albums().filter(Column("artistID") == info.artist.id && Column("id") != albumID)
                .order(Column("releaseYear").desc).fetchAll(db)
            let candidates = try LibraryQuery.albums().filter(Column("artistID") != info.artist.id).fetchAll(db)
            return Data(info: info, tracks: tracks, moreByArtist: more, similar: Self.similar(to: info, among: candidates))
        } update: { value in
            data = value
            loaded = true
        }
    }

    nonisolated static func similar(to info: AlbumInfo, among candidates: [AlbumInfo]) -> [AlbumInfo] {
        let tags = Set((info.album.genres + info.artist.tags).map { $0.lowercased() })
        func score(_ c: AlbumInfo) -> Double {
            let other = Set((c.album.genres + c.artist.tags).map { $0.lowercased() })
            var s = Double(tags.intersection(other).count)
            if c.album.primaryGenre.lowercased() == info.album.primaryGenre.lowercased() { s += 2 }
            s -= Double(abs(c.album.releaseYear - info.album.releaseYear)) / 20
            return s
        }
        var seenArtists = Set<ID>()
        return candidates.sorted { score($0) > score($1) }
            .filter { score($0) > 0 && seenArtists.insert($0.artist.id).inserted }
            .prefix(12).map { $0 }
    }

    private func content(_ data: Data) -> some View {
        let album = data.info.album
        let colors = album.colors
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(data)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 28)
                        .padding(.bottom, 22)
                    trackList(data)
                        .padding(.horizontal, Metrics.pagePadding - 10)
                    footer(data)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 18)
                        .padding(.bottom, 34)
                    if !data.moreByArtist.isEmpty {
                        Shelf(title: "More by \(data.info.artist.name)", seeAll: { model.show(.artist(data.info.artist.id)) }) {
                            ForEach(data.moreByArtist) { AlbumCard(info: $0, showsArtist: false) }
                        }
                        .padding(.bottom, 30)
                    }
                    if !data.similar.isEmpty {
                        Shelf(title: "You Might Also Like") {
                            ForEach(data.similar) { AlbumCard(info: $0) }
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .background(alignment: .top) {
                LinearGradient(
                    colors: [(colors.first ?? .clear).opacity(0.28), (colors.dropFirst().first ?? .clear).opacity(0.08), .clear],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: 560)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .onAppear { revealIfNeeded(data, proxy) }
            .onChange(of: library.reveal) { revealIfNeeded(data, proxy) }
        }
    }

    private func revealIfNeeded(_ data: Data, _ proxy: ScrollViewProxy) {
        guard let id = library.reveal, data.tracks.contains(where: { $0.id == id }) else { return }
        selected = id
        library.reveal = nil
        DispatchQueue.main.async {
            withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    // MARK: Header

    private func header(_ data: Data) -> some View {
        let album = data.info.album
        let unrecorded = data.tracks.filter { !$0.track.isPlayable }
        return HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(source: .album(album), size: 270, cornerRadius: Metrics.largeArtworkCorner, highResolution: true,
                        accessibilityDescription: Spoken.albumCover(album.title, by: data.info.artist.name))
                .shadow(color: (album.colors.first ?? .black).opacity(0.35), radius: 22, y: 12)
                .overlay(alignment: .topTrailing) { AlbumRecordingBadge(albumID: album.id).padding(10) }
                .contextMenu { AlbumMenuItems(info: data.info) }
            VStack(alignment: .leading, spacing: 0) {
                Text(album.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityHeading()
                Button(data.info.artist.name) { model.show(.artist(data.info.artist.id)) }
                    .accessibilityHint("Goes to the artist")
                    .buttonStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                Text(album.subtitleLine.uppercased())
                    .accessibilityLabel(album.subtitleLine)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                if !album.notes.isEmpty {
                    notes(album.notes)
                        .padding(.top, 14)
                }
                StudioSummary(tracks: data.tracks)
                    .padding(.top, 12)
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    Button { model.player.play(albumID: album.id) } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 72)
                    }
                    .buttonStyle(.glassProminent)
                    .help(unrecorded.isEmpty ? "Play" : "Play — unrecorded songs record in order as you listen")
                    Button { model.player.play(albumID: album.id, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(minWidth: 72)
                    }
                    .buttonStyle(.glass)
                    if !unrecorded.isEmpty {
                        let queued = unrecorded.filter { model.recording.isQueued($0.id) || model.recording.active?.trackID == $0.id }
                        if queued.count == unrecorded.count {
                            Button { model.recording.cancelRequest(unrecorded.map(\.id)) } label: {
                                Label("Recording…", systemImage: "record.circle.fill")
                            }
                            .buttonStyle(.glass)
                            .help("Every unrecorded song is in the studio queue. Click to stop recording this album.")
                        } else {
                            Button { model.record(unrecorded.map(\.id)) } label: {
                                Label("Record Album", systemImage: "record.circle")
                            }
                            .buttonStyle(.glass)
                            .help("Record the \(unrecorded.count) remaining song\(unrecorded.count == 1 ? "" : "s") in the background")
                        }
                    }
                    Spacer()
                    Button { model.share(album: data.info) } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Share this album with a friend")
                    .accessibilityLabel("Share \(album.title)")
                    FavoriteButton(isFavorite: album.isFavorite) { model.toggleFavorite(album: album.id) }
                        .font(.system(size: 17))
                    Menu {
                        AlbumMenuItems(info: data.info)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("More options for \(album.title)")
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .fixedSize()
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, minHeight: 270, alignment: .leading)
        }
    }

    private func notes(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(notesExpanded ? nil : 3)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
            Button(notesExpanded ? "LESS" : "MORE") {
                withAnimation(.smooth(duration: 0.25)) { notesExpanded.toggle() }
            }
            .accessibilityLabel(notesExpanded ? "Show less" : "Show more")
            .accessibilityHint(notesExpanded ? "Collapses the album notes" : "Expands the album notes")
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.primary)
        }
    }

    // MARK: Tracks

    private func trackList(_ data: Data) -> some View {
        let discs = Set(data.tracks.map(\.track.discNumber))
        return LazyVStack(spacing: 0) {
            ForEach(Array(data.tracks.enumerated()), id: \.element.id) { i, info in
                if discs.count > 1, i == 0 || data.tracks[i - 1].track.discNumber != info.track.discNumber {
                    Text("Disc \(info.track.discNumber)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, i == 0 ? 0 : 14)
                        .padding(.bottom, 4)
                        .accessibilityHeading()
                }
                TrackRow(
                    info: info, number: info.track.trackNumber, isSelected: selected == info.id, striped: i % 2 == 0,
                    onSelect: { selected = info.id; listFocused = true }
                )
                .id(info.id)
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1, data); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1, data); return .handled }
        .onKeyPress(.return) {
            guard let selected, let info = data.tracks.first(where: { $0.id == selected }) else { return .ignored }
            model.play(track: info)
            return .handled
        }
    }

    private func moveSelection(_ delta: Int, _ data: Data) {
        let ids = data.tracks.map(\.id)
        let i = selected.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selected = ids[max(0, min(ids.count - 1, i + delta))]
    }

    private func footer(_ data: Data) -> some View {
        let album = data.info.album
        let recorded = data.tracks.filter(\.track.isPlayable)
        let minutes = recorded.reduce(0) { $0 + ($1.track.duration ?? 0) }
        var summary = "\(data.tracks.count) song\(data.tracks.count == 1 ? "" : "s")"
        if recorded.count == data.tracks.count, minutes > 0 {
            summary += ", \(Format.totalDuration(minutes))"
        } else if !recorded.isEmpty {
            summary += " · \(recorded.count) recorded, \(Format.totalDuration(minutes))"
        } else {
            summary += " · not recorded yet"
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(String(album.releaseYear))
            Text(summary)
            Text("℗ \(String(album.releaseYear)) \(album.label.isEmpty ? data.info.artist.name : album.label)")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// One line under the album header about recording: what's in the studio and how long is left.
struct StudioSummary: View {
    @Environment(AppModel.self) private var model
    let tracks: [TrackInfo]

    var body: some View {
        let ids = Set(tracks.map(\.id))
        let unrecorded = tracks.filter { !$0.track.isPlayable }
        let active = model.recording.active.flatMap { ids.contains($0.trackID) ? $0 : nil }
        let queued = unrecorded.filter { model.recording.isQueued($0.id) && $0.id != active?.trackID }
        let failed = unrecorded.filter { model.recording.failures[$0.id] != nil || $0.track.status == .failed }
        if let active {
            let remaining = (active.remaining ?? model.recording.averageSecondsPerSong) + Double(queued.count) * model.recording.averageSecondsPerSong
            Label {
                Text("Recording “\(active.title)” — \(active.stageLabel.lowercased())\(queued.isEmpty ? "" : ", then \(queued.count) more") · \(Format.remaining(remaining) ?? "")")
            } icon: {
                RecordingRing(fraction: active.fraction, lineWidth: 2).frame(width: 12, height: 12)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording “\(active.title)”\(queued.isEmpty ? "" : ", then \(queued.count) more")")
            .accessibilityValue(Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining))
        } else if !queued.isEmpty {
            Label("\(queued.count) song\(queued.count == 1 ? "" : "s") waiting for the studio", systemImage: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        } else if !failed.isEmpty {
            HStack(spacing: 8) {
                Label("\(failed.count) song\(failed.count == 1 ? "" : "s") couldn’t be recorded", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Try Again") { failed.forEach { model.recording.retry($0.id) } }
                    .buttonStyle(.link)
            }
            .font(.system(size: 12, weight: .medium))
        } else if !unrecorded.isEmpty {
            let minutes = Double(unrecorded.count) * model.recording.averageSecondsPerSong
            Text(unrecorded.count == tracks.count
                ? "Not recorded yet. Press Play to hear it as it’s recorded, about \(Format.totalDuration(minutes).replacingOccurrences(of: "minutes", with: "min")) for the album."
                : "\(unrecorded.count) of \(tracks.count) songs still to record.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

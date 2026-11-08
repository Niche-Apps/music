import StandardKit
import SwiftUI

// MARK: - Album & artist cards

struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    let info: AlbumInfo
    var width: CGFloat? = Metrics.cardWidth
    var showsArtist = true
    var subtitle: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(source: .album(info.album), size: width)
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        HStack {
                            Button { model.player.play(albumID: info.album.id) } label: {
                                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Play \(info.album.title)")
                            .accessibilityLabel("Play \(info.album.title)")
                            Spacer()
                            Menu {
                                AlbumMenuItems(info: info)
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                            }
                            .menuStyle(.button)
                            .menuIndicator(.hidden)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .fixedSize()
                            .accessibilityLabel("More options for \(info.album.title)")
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) { AlbumRecordingBadge(albumID: info.album.id).padding(7) }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.album.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle ?? (showsArtist ? info.artist.name : String(info.album.releaseYear)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { model.show(.album(info.album.id)) }
        .contextMenu { AlbumMenuItems(info: info) }
        .draggable(info.album.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(recordingValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the album")
        .accessibilityAction { model.show(.album(info.album.id)) }
        .accessibilityAction(named: "Play") { model.player.play(albumID: info.album.id) }
        .accessibilityAction(named: "Shuffle") { model.player.play(albumID: info.album.id, shuffled: true) }
        .accessibilityAction(named: "Play Next") { model.playNext(model.tracks(ofAlbum: info.album.id)) }
        .accessibilityAction(named: info.album.isFavorite ? "Undo Favorite" : "Favorite") { model.toggleFavorite(album: info.album.id) }
        .accessibilityAction(named: "Go to Artist") { model.show(.artist(info.artist.id)) }
    }

    private var accessibilityLabel: String {
        var parts = [info.album.title, subtitle ?? (showsArtist ? info.artist.name : String(info.album.releaseYear))]
        if info.album.isFavorite { parts.append("Favorite") }
        return parts.joined(separator: ", ")
    }

    private var recordingValue: String {
        guard let active = model.recording.active, active.albumID == info.album.id else { return "" }
        return "\(active.title) " + Spoken.recording(fraction: active.fraction, remaining: active.remaining).lowercased()
    }
}

/// Small glass badge on covers whose album is in the studio right now.
struct AlbumRecordingBadge: View {
    @Environment(AppModel.self) private var model
    let albumID: ID

    var body: some View {
        if let active = model.recording.active, active.albumID == albumID {
            RecordingRing(fraction: active.fraction, lineWidth: 2, tint: .white)
                .frame(width: 14, height: 14)
                .padding(6)
                .glassEffect(.regular.tint(.black.opacity(0.25)), in: .circle)
                .help("\(active.title): \(active.stageLabel.lowercased())")
                .accessibilityLabel("Recording \(active.title)")
                .accessibilityValue(Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining))
        }
    }
}

struct ArtistCard: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    var size: CGFloat = 150

    var body: some View {
        VStack(spacing: 8) {
            ArtworkView(source: .artist(artist), size: size, circular: true)
            Text(artist.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .onTapGesture { model.show(.artist(artist.id)) }
        .contextMenu { ArtistMenuItems(artist: artist) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(artist.isFavorite ? "\(artist.name), Favorite" : artist.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the artist")
        .accessibilityAction { model.show(.artist(artist.id)) }
        .accessibilityAction(named: artist.isFavorite ? "Undo Favorite" : "Favorite") { model.toggleFavorite(artist: artist.id) }
    }
}

// MARK: - Menus

struct AlbumMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let info: AlbumInfo

    var body: some View {
        Button("Play", systemImage: "play") { model.player.play(albumID: info.album.id) }
        Button("Shuffle", systemImage: "shuffle") { model.player.play(albumID: info.album.id, shuffled: true) }
        Divider()
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(model.tracks(ofAlbum: info.album.id)) }
        Button("Play Later", systemImage: "text.line.last.and.arrowtriangle.forward") { model.playLater(model.tracks(ofAlbum: info.album.id)) }
        Button("Record Album", systemImage: "record.circle") {
            model.record(model.tracks(ofAlbum: info.album.id).filter { !$0.track.isPlayable }.map(\.id))
        }
        Divider()
        Button(info.album.isFavorite ? "Undo Favorite" : "Favorite", systemImage: info.album.isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(album: info.album.id)
        }
        PlaylistMenu { model.tracks(ofAlbum: info.album.id).map(\.id) }
        Divider()
        Button("Go to Album", systemImage: "square.stack") { model.show(.album(info.album.id)) }
        Button("Go to Artist", systemImage: "music.microphone") { model.show(.artist(info.artist.id)) }
        Button("More Like \(info.artist.name)", systemImage: "sparkles") {
            Task { await model.generateSimilar(to: info.artist) }
        }
        Divider()
        Button("Share Album…", systemImage: "square.and.arrow.up") { model.share(album: info) }
        Button("Copy", systemImage: "doc.on.doc") { model.copy("\(info.album.title) — \(info.artist.name)") }
    }
}

struct ArtistMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let artist: Artist

    var body: some View {
        Button("Go to Artist", systemImage: "music.microphone") { model.show(.artist(artist.id)) }
        Button(artist.isFavorite ? "Undo Favorite" : "Favorite", systemImage: artist.isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(artist: artist.id)
        }
        Button("Find More Like This", systemImage: "sparkles") { Task { await model.generateSimilar(to: artist) } }
        Button("New Release", systemImage: "opticaldisc") { model.newRelease(from: artist, library: library) }
            .disabled(library.releasing.contains(artist.id))
        Divider()
        Button("Share Artist…", systemImage: "square.and.arrow.up") { model.share(artist: artist) }
        Button("Copy Name", systemImage: "doc.on.doc") { model.copy(artist.name) }
    }
}

struct TrackMenuItems: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo
    var list: [TrackInfo]? = nil
    var playlist: (Playlist, Int)? = nil

    var body: some View {
        let track = info.track
        if track.isPlayable {
            Button("Play", systemImage: "play") { model.play(track: info, in: list) }
        } else {
            Button("Play Album", systemImage: "play") { model.player.play(albumID: info.album.id, startingAt: info.id) }
        }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext([info]) }
        Button("Play Later", systemImage: "text.line.last.and.arrowtriangle.forward") { model.playLater([info]) }
        if !track.isPlayable {
            if model.recording.failures[track.id] != nil || track.status == .failed {
                Button("Try Recording Again", systemImage: "arrow.clockwise") { model.recording.retry(track.id) }
            } else if model.recording.isQueued(track.id) || model.recording.active?.trackID == track.id {
                Button("Remove from Studio Queue", systemImage: "xmark.circle") { model.recording.cancelRequest([track.id]) }
            } else {
                Button("Record", systemImage: "record.circle") { model.record([track.id]) }
            }
        }
        Divider()
        Button(track.isFavorite ? "Undo Favorite" : "Favorite", systemImage: track.isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(track: track.id)
        }
        PlaylistMenu { [info.id] }
        if let entry = playlist {
            let (playlist, position) = entry
            Button("Remove from “\(playlist.name)”", systemImage: "minus.circle") {
                let ids = (try? model.services.db.reader.read { db in
                    try LibraryQuery.playlistTracks(db, playlist.id)
                })?.filter { $0.position != position }.map(\.info.id) ?? []
                try? model.services.db.setPlaylistOrder(playlist.id, trackIDs: ids)
            }
        }
        Divider()
        Button("Look Up Lyrics", systemImage: "quote.bubble") { model.lookUpLyrics(info) }
            .help("Shows lyrics saved with this song. If there are none, opens a web search for the title and artist. Audio isn’t uploaded, and lyrics from the web stay in the browser.")
        if LyricsLookup.hasSingableLyrics(info.track.lyrics) {
            Button("Search the Web for Lyrics…", systemImage: "safari") { model.searchWebForLyrics(info) }
                .help("Opens a web search. Standard Music does not download or store those lyrics.")
        }
        Divider()
        Button("Go to Album", systemImage: "square.stack") { model.show(.album(info.album.id)) }
        Button("Go to Artist", systemImage: "music.microphone") { model.show(.artist(info.artist.id)) }
        if track.isPlayable {
            Button("Show in Finder", systemImage: "folder") { model.showInFinder(track) }
        }
        Divider()
        Button("Copy", systemImage: "doc.on.doc") { model.copy(info.copyText) }
    }
}

struct PlaylistMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let trackIDs: () -> [ID]

    var body: some View {
        Menu("Add to Playlist", systemImage: "music.note.list") {
            Button("New Playlist", systemImage: "plus") {
                if let p = model.newPlaylist(with: trackIDs()) {
                    model.toast = "Created “\(p.name)”."
                }
            }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { p in
                Button(p.name) { model.add(trackIDs(), to: p) }
            }
        }
    }
}

// MARK: - Shelves & headers

struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String?
    var seeAll: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, subtitle: subtitle, action: seeAll)
                .padding(.horizontal, Metrics.pagePadding)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) { content }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
    }
}

struct ShelfHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                if let action {
                    Button(action: action) {
                        HStack(spacing: 3) {
                            Text(title)
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                } else {
                    Text(title).accessibilityHeading()
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 19, weight: .bold))
            Spacer()
            if let action {
                Button("See All", action: action).buttonStyle(.link).font(.system(size: 12))
                    .accessibilityLabel("See All \(title)")
            }
        }
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 28, weight: .bold)).accessibilityHeading()
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grid of album cards that fills the available width.
struct AlbumGrid: View {
    let albums: [AlbumInfo]
    var showsArtist = true

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
            ForEach(albums) { info in
                AlbumCard(info: info, width: nil, showsArtist: showsArtist)
            }
        }
    }
}

// MARK: - Empty & building states

/// What to show when a screen has nothing yet — aware of whether the library is still being written.
struct LibraryEmptyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    var message: String

    var body: some View {
        let status = model.buildStatus
        let building = [.planning, .writing, .waiting].contains(status.phase)
        ContentUnavailableView {
            Label(building ? "Still writing your library" : title, systemImage: building ? "sparkles" : systemImage)
                .symbolEffect(.pulse, isActive: building && !reduceMotion)
        } description: {
            if building {
                Text("\(status.artistsReady) of \(status.artistsTotal) artists are ready. New music appears here as each one is finished.")
            } else {
                Text(message)
            }
        } actions: {
            if building {
                ProgressView(value: status.fraction).frame(width: 220)
                    .accessibilityLabel("Library progress")
                    .accessibilityValue("\(status.artistsReady) of \(status.artistsTotal) artists ready")
                Text(status.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Shown above library pages while new artists are still being written.
struct LibraryBuildingBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = model.buildStatus
        if [.planning, .writing, .waiting].contains(status.phase) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.phase == .planning ? "Planning your lineup…" : "Your library is still being written")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(status.artistsTotal > 0
                        ? "\(status.artistsReady) of \(status.artistsTotal) artists ready. New albums appear here as each one is finished — play anything already here."
                        : "New albums appear here as each one is finished.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if status.artistsTotal > 0 {
                        ProgressView(value: status.fraction).controlSize(.small).frame(maxWidth: 360)
                            .accessibilityLabel("Library progress")
                            .accessibilityValue("\(status.artistsReady) of \(status.artistsTotal) artists ready")
                    }
                }
                Spacer(minLength: 12)
                if !status.activity.isEmpty {
                    Text(status.activity)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            .padding(16)
            .background(LegibilityScrim(shape: RoundedRectangle(cornerRadius: 16), color: Color(nsColor: .windowBackgroundColor), opacity: 1))
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(LegibilityScrim(shape: Capsule(), color: Color(nsColor: .windowBackgroundColor), opacity: 1))
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

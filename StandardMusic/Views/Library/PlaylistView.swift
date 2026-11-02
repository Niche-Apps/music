import GRDB
import StandardKit
import SwiftUI

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let playlistID: ID

    struct Data: Equatable, Sendable {
        var playlist: Playlist
        var entries: [PlaylistEntry]
    }

    @State private var data: Data?
    @State private var loaded = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if let data {
                list(data)
            } else if loaded {
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        }
        .navigationTitle(data?.playlist.name ?? "Playlist")
        .observing(model.services.db, id: playlistID) { [playlistID] db in
            guard let playlist = try Playlist.fetchOne(db, key: playlistID) else { return nil as Data? }
            return Data(playlist: playlist, entries: try LibraryQuery.playlistTracks(db, playlistID))
        } update: { value in
            data = value
            loaded = true
            if !nameFocused { name = value?.playlist.name ?? "" }
        }
    }

    private func list(_ data: Data) -> some View {
        let infos = data.entries.map(\.info)
        return List {
            header(data)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 24, leading: Metrics.pagePadding, bottom: 18, trailing: Metrics.pagePadding))
            if data.entries.isEmpty {
                ContentUnavailableView(
                    "This playlist is empty", systemImage: "music.note.list",
                    description: Text("Add songs from any song’s menu, or drag them onto the playlist in the sidebar."))
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(data.entries.enumerated()), id: \.element.id) { i, entry in
                TrackRow(
                    info: entry.info, showsArtwork: true, showsArtist: true, showsAlbum: true, striped: i % 2 == 0,
                    list: infos, playlist: (data.playlist, entry.position))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: Metrics.pagePadding - 10, bottom: 0, trailing: Metrics.pagePadding - 10))
            }
            .onMove { from, to in
                var ids = infos.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                try? model.services.db.setPlaylistOrder(playlistID, trackIDs: ids)
            }
            .onDelete { offsets in
                var ids = infos.map(\.id)
                ids.remove(atOffsets: offsets)
                try? model.services.db.setPlaylistOrder(playlistID, trackIDs: ids)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .dropDestination(for: String.self) { ids, _ in
            let trackIDs = ids.filter { !$0.contains(" ") }
            guard !trackIDs.isEmpty else { return false }
            model.add(trackIDs, to: data.playlist)
            return true
        }
    }

    private func header(_ data: Data) -> some View {
        let infos = data.entries.map(\.info)
        let recorded = infos.filter(\.track.isPlayable)
        let minutes = recorded.reduce(0) { $0 + ($1.track.duration ?? 0) }
        var seen = Set<ID>()
        let covers = infos.map(\.album).filter { seen.insert($0.id).inserted }.prefix(4)
        return HStack(alignment: .bottom, spacing: 24) {
            PlaylistArtwork(albums: Array(covers))
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Playlist Name", text: $name)
                    .accessibilityLabel("Playlist name")
                    .accessibilityAddTraits(.isHeader)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .focused($nameFocused)
                    .onSubmit { rename(data.playlist) }
                    .onChange(of: nameFocused) { _, f in if !f { rename(data.playlist) } }
                Text("\(infos.count) song\(infos.count == 1 ? "" : "s")\(minutes > 0 ? " · \(Format.totalDuration(minutes))" : "")\(recorded.count < infos.count ? " · \(infos.count - recorded.count) not recorded yet" : "")")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack {
                    Button { play(data, shuffled: false) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 72) }
                        .buttonStyle(.glassProminent)
                    Button { play(data, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 72) }
                        .buttonStyle(.glass)
                    Spacer()
                    Menu {
                        Button("Rename", systemImage: "pencil") { nameFocused = true }
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            model.selection = .home
                            try? model.services.db.deletePlaylist(playlistID)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More options for \(data.playlist.name)")
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .fixedSize()
                }
                .controlSize(.large)
                .disabled(infos.isEmpty)
            }
            .frame(minHeight: 200)
        }
    }

    private func rename(_ playlist: Playlist) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { name = playlist.name } else if trimmed != playlist.name { try? model.services.db.renamePlaylist(playlistID, to: trimmed) }
    }

    private func play(_ data: Data, shuffled: Bool) {
        model.player.play(trackIDs: data.entries.map(\.info.id), context: .playlist(data.playlist.id, data.playlist.name), shuffled: shuffled)
    }
}

/// 2×2 cover mosaic (or a single cover / placeholder).
struct PlaylistArtwork: View {
    let albums: [Album]

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            Group {
                if albums.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ArtworkView(source: .album(albums[0]), size: s / 2, cornerRadius: 0, shadow: false)
                            ArtworkView(source: .album(albums[1]), size: s / 2, cornerRadius: 0, shadow: false)
                        }
                        GridRow {
                            ArtworkView(source: .album(albums[2]), size: s / 2, cornerRadius: 0, shadow: false)
                            ArtworkView(source: .album(albums[3]), size: s / 2, cornerRadius: 0, shadow: false)
                        }
                    }
                } else if let first = albums.first {
                    ArtworkView(source: .album(first), size: s, cornerRadius: 0, highResolution: true, shadow: false)
                } else {
                    ZStack {
                        LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note.list").font(.system(size: s * 0.3, weight: .light)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.largeArtworkCorner, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        }
        .accessibilityHidden(true)
    }
}

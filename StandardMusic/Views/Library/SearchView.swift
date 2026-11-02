import GRDB
import StandardKit
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model

    struct Results: Equatable, Sendable {
        var top: SearchHit?
        var artists: [Artist] = []
        var albums: [AlbumInfo] = []
        var songs: [TrackInfo] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
    }

    @State private var results = Results()
    @State private var searched = ""

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        Group {
            if query.isEmpty {
                ContentUnavailableView("Search your library", systemImage: "magnifyingglass", description: Text("Artists, albums, songs, genres, places and moods."))
            } else if results.isEmpty && searched == query {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if let top = results.top { topResult(top) }
                        if !results.songs.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ShelfHeader(title: "Songs")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20, alignment: .top)], spacing: 0) {
                                    ForEach(results.songs) { info in
                                        TrackRow(info: info, showsArtwork: true, showsArtist: true, list: results.songs)
                                    }
                                }
                                .padding(.horizontal, -10)
                            }
                            .padding(.horizontal, Metrics.pagePadding)
                        }
                        if !results.artists.isEmpty {
                            Shelf(title: "Artists") { ForEach(results.artists) { ArtistCard(artist: $0, size: 130) } }
                        }
                        if !results.albums.isEmpty {
                            Shelf(title: "Albums") { ForEach(results.albums) { AlbumCard(info: $0) } }
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle("Search")
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(120))
            let db = model.services.db
            let found = await Task.detached { Self.search(db, query) }.value
            guard !Task.isCancelled else { return }
            results = found
            searched = query
        }
    }

    nonisolated static func search(_ db: AppDatabase, _ text: String) -> Results {
        guard let hits = try? db.search(text, limit: 80) else { return Results() }
        return (try? db.reader.read { d -> Results in
            var r = Results()
            let ids = { (kind: SearchKind) in hits.filter { $0.kind == kind }.map(\.itemID) }
            let artists = try Artist.filter(keys: ids(.artist)).fetchAll(d)
            r.artists = ids(.artist).compactMap { id in artists.first { $0.id == id } }
            let albums = try LibraryQuery.albums().filter(keys: ids(.album)).fetchAll(d)
            r.albums = ids(.album).compactMap { id in albums.first { $0.id == id } }
            let songs = try AppDatabase.trackInfos().filter(keys: ids(.track)).fetchAll(d)
            r.songs = Array(ids(.track).compactMap { id in songs.first { $0.id == id } }.prefix(12))
            r.top = hits.first { hit in
                switch hit.kind {
                case .artist: r.artists.contains { $0.id == hit.itemID }
                case .album: r.albums.contains { $0.id == hit.itemID }
                case .track: r.songs.contains { $0.id == hit.itemID }
                }
            }
            return r
        }) ?? Results()
    }

    @ViewBuilder private func topResult(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Top Result")
            Group {
                switch hit.kind {
                case .artist:
                    if let artist = results.artists.first(where: { $0.id == hit.itemID }) {
                        topCard(kind: "Artist", title: artist.name, subtitle: artist.primaryGenre.capitalized) {
                            ArtworkView(source: .artist(artist), size: 92, circular: true)
                        } action: { model.show(.artist(artist.id)) }
                            .contextMenu { ArtistMenuItems(artist: artist) }
                    }
                case .album:
                    if let info = results.albums.first(where: { $0.id == hit.itemID }) {
                        topCard(kind: info.album.kind.label, title: info.album.title, subtitle: "\(info.artist.name) · \(info.album.releaseYear)") {
                            ArtworkView(source: .album(info.album), size: 92)
                        } action: { model.show(.album(info.album.id)) }
                            .contextMenu { AlbumMenuItems(info: info) }
                    }
                case .track:
                    if let info = results.songs.first(where: { $0.id == hit.itemID }) {
                        topCard(kind: "Song", title: info.track.title, subtitle: "\(info.artist.name) — \(info.album.title)") {
                            ArtworkView(source: .album(info.album), size: 92)
                        } action: {
                            if info.track.isPlayable { model.play(track: info) } else { reveal(info) }
                        }
                        .contextMenu { TrackMenuItems(info: info) }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    @Environment(LibraryState.self) private var library

    private func reveal(_ info: TrackInfo) {
        library.reveal = info.id
        model.show(.album(info.album.id))
    }

    private func topCard(kind: String, title: String, subtitle: String, @ViewBuilder art: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                art()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    Text(kind.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind), \(title), \(subtitle)")
    }
}

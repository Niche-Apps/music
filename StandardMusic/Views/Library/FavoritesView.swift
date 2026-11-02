import GRDB
import StandardKit
import SwiftUI

struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library

    struct Data: Equatable, Sendable {
        var songs: [TrackInfo] = []
        var albums: [AlbumInfo] = []
        var artists: [Artist] = []
    }

    @State private var data = Data()

    var body: some View {
        @Bindable var library = library
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .lastTextBaseline) {
                    PageHeader(title: "Favorites", subtitle: "Every star you give shapes the artists written next.")
                    Picker("Show", selection: $library.favoritesTab) {
                        ForEach(LibraryState.FavoritesTab.allCases, id: \.self) { tab in
                            Text("\(tab.rawValue) (\(count(tab)))").tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                switch library.favoritesTab {
                case .songs: songs
                case .albums: albums
                case .artists: artists
                }
            }
            .padding(Metrics.pagePadding)
        }
        .navigationTitle("Favorites")
        .observing(model.services.db) { db in
            Data(
                songs: try AppDatabase.trackInfos().filter(Column("isFavorite") == true).order(Column("title")).fetchAll(db),
                albums: try HomeShelf.favorites.albums(db),
                artists: try Artist.filter(Column("isFavorite") == true).order(Column("sortName")).fetchAll(db))
        } update: { data = $0 }
    }

    private func count(_ tab: LibraryState.FavoritesTab) -> Int {
        switch tab {
        case .songs: data.songs.count
        case .albums: data.albums.count
        case .artists: data.artists.count
        }
    }

    @ViewBuilder private var songs: some View {
        if data.songs.isEmpty {
            empty("No favorite songs yet", "Click the star next to any song.")
        } else {
            HStack {
                Button { playAll(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                Button { playAll(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
            LazyVStack(spacing: 0) {
                ForEach(Array(data.songs.enumerated()), id: \.element.id) { i, info in
                    TrackRow(info: info, showsArtwork: true, showsArtist: true, showsAlbum: true, striped: i % 2 == 0, list: data.songs)
                }
            }
            .padding(.horizontal, -10)
        }
    }

    @ViewBuilder private var albums: some View {
        if data.albums.isEmpty {
            empty("No favorite albums yet", "Star an album from its page or its menu.")
        } else {
            AlbumGrid(albums: data.albums)
        }
    }

    @ViewBuilder private var artists: some View {
        if data.artists.isEmpty {
            empty("No favorite artists yet", "Star an artist from their page.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)], spacing: 24) {
                ForEach(data.artists) { ArtistCard(artist: $0, size: 140) }
            }
        }
    }

    private func empty(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "star", description: Text(message))
            .padding(.top, 60)
    }

    private func playAll(shuffled: Bool) {
        let playable = data.songs.filter(\.track.isPlayable)
        guard !playable.isEmpty else {
            model.toast = "None of your favorite songs are recorded yet."
            return
        }
        model.player.play(trackIDs: playable.map(\.id), context: .songs("Favorites"), shuffled: shuffled)
    }
}

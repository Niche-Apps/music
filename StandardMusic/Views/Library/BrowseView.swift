import GRDB
import StandardKit
import SwiftUI

struct BrowseView: View {
    @Environment(AppModel.self) private var model

    struct Genre: Equatable, Identifiable, Sendable {
        var name: String
        var albums: [AlbumInfo]
        var artistCount: Int
        var id: String { name }
    }

    @State private var genres: [Genre] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && genres.isEmpty {
                LibraryEmptyView(title: "Nothing to browse yet", systemImage: "square.grid.2x2", message: "Genres appear as your library is written.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PageHeader(title: "Browse", subtitle: "Every sound in your library, by genre")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)], spacing: 16) {
                            ForEach(genres) { genre in
                                GenreTile(genre: genre)
                            }
                        }
                    }
                    .padding(Metrics.pagePadding)
                }
            }
        }
        .navigationTitle("Browse")
        .observing(model.services.db, immediate: false) { db in
            let albums = try LibraryQuery.albums().order(Column("createdAt").desc).fetchAll(db)
            let shelves = GenreGroups.make(albums.reduce(into: [:]) { $0[$1.album.primaryGenre.lowercased(), default: 0] += 1 })
            return Dictionary(grouping: albums) { shelves[$0.album.primaryGenre.lowercased()] ?? $0.album.primaryGenre.capitalized }
                .map { Genre(name: $0.key, albums: $0.value, artistCount: Set($0.value.map(\.artist.id)).count) }
                .sorted { ($0.albums.count, $1.name) > ($1.albums.count, $0.name) }
        } update: { list in
            genres = list
            loaded = true
        }
    }
}

struct GenreTile: View {
    @Environment(AppModel.self) private var model
    let genre: BrowseView.Genre
    @State private var hovering = false

    var body: some View {
        let lead = genre.albums.first?.album
        let colors = lead?.colors ?? []
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: colors.count >= 2 ? [colors[0], colors[1]] : ArtworkView.seeded(genre.name),
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.black.opacity(0.22)
            LegibilityScrim(opacity: 0.5)
            HStack(spacing: -34) {
                ForEach(Array(genre.albums.prefix(3).enumerated()), id: \.element.id) { i, info in
                    ArtworkView(source: .album(info.album), size: 84, cornerRadius: 5)
                        .rotationEffect(.degrees(Double(i - 1) * 8))
                        .zIndex(Double(3 - i))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 6, y: 18)
            .scaleEffect(hovering ? 1.04 : 1, anchor: .bottomTrailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(genre.name).font(.system(size: 19, weight: .bold)).lineLimit(2)
                Text("\(genre.artistCount) artist\(genre.artistCount == 1 ? "" : "s") · \(genre.albums.count) album\(genre.albums.count == 1 ? "" : "s")")
                    .font(.system(size: 11.5, weight: .medium)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 6)
            .padding(16)
        }
        .frame(minHeight: 130)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.smooth(duration: 0.2)) { hovering = h } }
        .onTapGesture { model.show(.genre(genre.name)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(genre.name)
        .accessibilityValue("\(genre.artistCount) artist\(genre.artistCount == 1 ? "" : "s"), \(genre.albums.count) album\(genre.albums.count == 1 ? "" : "s")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.show(.genre(genre.name)) }
    }
}

struct GenreView: View {
    @Environment(AppModel.self) private var model
    let genre: String
    @State private var albums: [AlbumInfo] = []

    var body: some View {
        let artists = albums.reduce(into: [Artist]()) { list, info in
            if !list.contains(where: { $0.id == info.artist.id }) { list.append(info.artist) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .lastTextBaseline) {
                    PageHeader(title: genre, subtitle: "\(artists.count) artist\(artists.count == 1 ? "" : "s") · \(albums.count) album\(albums.count == 1 ? "" : "s")")
                    Button {
                        if let pick = albums.randomElement() { model.player.play(albumID: pick.album.id) }
                    } label: {
                        Label("Play Something", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(albums.isEmpty)
                }
                .padding(.horizontal, Metrics.pagePadding)
                if artists.count > 1 {
                    Shelf(title: "Artists") { ForEach(artists) { ArtistCard(artist: $0, size: 130) } }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Albums").font(.system(size: 19, weight: .bold)).accessibilityHeading()
                    AlbumGrid(albums: albums)
                }
                .padding(.horizontal, Metrics.pagePadding)
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(genre)
        .observing(model.services.db, id: genre) { [genre] db in
            let all = try LibraryQuery.albums().fetchAll(db)
            // A Browse shelf shows exactly the albums folded into it (matching its tile); any other
            // genre shows every album that names it.
            let shelves = GenreGroups.make(all.reduce(into: [:]) { $0[$1.album.primaryGenre.lowercased(), default: 0] += 1 })
            let isShelf = shelves.values.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
            return all
                .filter {
                    isShelf
                        ? shelves[$0.album.primaryGenre.lowercased()]?.caseInsensitiveCompare(genre) == .orderedSame
                        : $0.album.primaryGenre.caseInsensitiveCompare(genre) == .orderedSame
                            || $0.album.genres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
                }
                .sorted { $0.album.releaseYear > $1.album.releaseYear }
        } update: { albums = $0 }
    }
}

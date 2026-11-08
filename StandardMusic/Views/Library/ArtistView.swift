import AppKit
import GRDB
import StandardKit
import SwiftUI

struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let artistID: ID

    struct Data: Equatable, Sendable {
        var artist: Artist
        var albums: [AlbumInfo]
        var topSongs: [TrackInfo]
        var similar: [Artist]
        var unrecordedCount: Int
    }

    @State private var data: Data?
    @State private var loaded = false
    @State private var bioExpanded = false

    var body: some View {
        Group {
            if let data {
                content(data)
            } else if loaded {
                ContentUnavailableView("Artist not found", systemImage: "music.microphone", description: Text("They may have been removed from your library."))
            } else {
                Color.clear
            }
        }
        .navigationTitle(data?.artist.name ?? "")
        .observing(model.services.db, id: artistID) { [artistID] db in
            guard let artist = try Artist.fetchOne(db, key: artistID) else { return nil as Data? }
            let albums = try LibraryQuery.albums().filter(Column("artistID") == artistID).order(Column("releaseYear").desc).fetchAll(db)
            let top = try AppDatabase.trackInfos()
                .filter(Column("artistID") == artistID && Column("status") == TrackStatus.ready.rawValue)
                .order(Column("playCount").desc, Column("isFavorite").desc, Column("generatedAt").desc)
                .limit(10).fetchAll(db)
            let others = try LibraryQuery.visibleArtists(db).filter { $0.id != artistID }
            let unrecorded = try Track.filter(Column("artistID") == artistID && Column("status") != TrackStatus.ready.rawValue).fetchCount(db)
            return Data(artist: artist, albums: albums, topSongs: top, similar: Self.similar(to: artist, among: others), unrecordedCount: unrecorded)
        } update: { value in
            data = value
            loaded = true
        }
    }

    nonisolated static func similar(to artist: Artist, among others: [Artist]) -> [Artist] {
        let tags = Set((artist.genres + artist.tags).map { $0.lowercased() })
        func score(_ a: Artist) -> Int {
            Set((a.genres + a.tags).map { $0.lowercased() }).intersection(tags).count
                + (a.primaryGenre.lowercased() == artist.primaryGenre.lowercased() ? 2 : 0)
        }
        return others.filter { score($0) > 0 }.sorted { score($0) > score($1) }.prefix(12).map { $0 }
    }

    private func content(_ data: Data) -> some View {
        let artist = data.artist
        let full = data.albums.filter { $0.album.kind == .album || $0.album.kind == .compilation }
        let short = data.albums.filter { $0.album.kind == .ep || $0.album.kind == .single }
        let live = data.albums.filter { $0.album.kind == .live }
        return ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                hero(data)
                if !data.topSongs.isEmpty {
                    topSongs(data)
                } else if !data.albums.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nothing recorded yet").font(.system(size: 13, weight: .semibold))
                            Text("Play any album and \(artist.name)’s songs are recorded as you listen. Top songs show up here.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                }
                if !full.isEmpty {
                    Shelf(title: "Albums") { ForEach(full) { AlbumCard(info: $0, showsArtist: false) } }
                }
                if !short.isEmpty {
                    Shelf(title: "Singles & EPs") { ForEach(short) { AlbumCard(info: $0, showsArtist: false) } }
                }
                if !live.isEmpty {
                    Shelf(title: "Live Albums") { ForEach(live) { AlbumCard(info: $0, showsArtist: false) } }
                }
                if data.albums.isEmpty {
                    Text("\(artist.name)’s discography is still being written.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.pagePadding)
                }
                about(artist)
                if !data.similar.isEmpty {
                    Shelf(title: "Similar Artists") {
                        ForEach(data.similar) { ArtistCard(artist: $0, size: 140) }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
    }

    private func hero(_ data: Data) -> some View {
        let artist = data.artist
        let accent = Color(hex: artist.accentHex) ?? .gray
        return ZStack(alignment: .bottomLeading) {
            HeroImage(artist: artist, fallback: data.albums.first?.album.colors ?? [])
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(artist.imagePath == nil ? "" : "Photo of \(artist.name)")
                .accessibilityAddTraits(.isImage)
                .accessibilityHidden(artist.imagePath == nil)
            LinearGradient(colors: [.clear, .clear, accent.opacity(0.35), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            // Reduce Transparency / Increase Contrast: darken the photo under the name.
            LegibilityScrim(opacity: 0.55)
            HStack(alignment: .bottom, spacing: 14) {
                Button {
                    if let first = data.topSongs.first {
                        model.player.play(trackIDs: data.topSongs.map(\.id), startingAt: first.id, context: .artist(artist.id, artist.name))
                    } else if let album = data.albums.last {
                        model.player.play(albumID: album.album.id)
                    }
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 20)).frame(width: 46, height: 46)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .help(data.topSongs.isEmpty ? "Play \(artist.name)’s first album" : "Play top songs")
                .accessibilityLabel(data.topSongs.isEmpty ? "Play \(artist.name)’s first album" : "Play top songs by \(artist.name)")
                .disabled(data.albums.isEmpty)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .accessibilityHeading()
                    if !artist.tagline.isEmpty {
                        Text(artist.tagline).font(.system(size: 14, weight: .medium)).opacity(0.85).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                FavoriteButton(isFavorite: artist.isFavorite) { model.toggleFavorite(artist: artist.id) }
                    .font(.system(size: 17))
                    .padding(10)
                    .glassEffect(.regular, in: .circle)
                NewReleaseButton(artist: artist)
                Button {
                    Task { await model.generateSimilar(to: artist) }
                } label: {
                    Label("More Like This", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .fixedSize()
                .help("Write new artists in the spirit of \(artist.name)")
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 24)
        }
        .frame(minHeight: 380)
        .clipped()
        .contextMenu { ArtistMenuItems(artist: artist) }
    }

    private func topSongs(_ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Top Songs", subtitle: data.unrecordedCount > 0 ? "From recorded songs · \(data.unrecordedCount) still to record" : nil)
                .padding(.horizontal, Metrics.pagePadding)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], spacing: 0) {
                ForEach(data.topSongs) { info in
                    TrackRow(info: info, showsArtwork: true, showsAlbum: true, list: data.topSongs)
                }
            }
            .padding(.horizontal, Metrics.pagePadding - 10)
        }
    }

    private func about(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About \(artist.name)").font(.system(size: 19, weight: .bold)).accessibilityHeading()
            HStack(alignment: .top, spacing: 32) {
                bio(artist)
                facts(artist)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private func bio(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(artist.bio)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(bioExpanded ? nil : 6)
                .textSelection(.enabled)
            if artist.bio.count > 400 {
                Button(bioExpanded ? "LESS" : "MORE") { withAnimation(.smooth) { bioExpanded.toggle() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityLabel(bioExpanded ? "Show less" : "Show more")
                    .accessibilityHint(bioExpanded ? "Collapses the biography" : "Expands the biography")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func facts(_ artist: Artist) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            if !artist.origin.isEmpty { fact("Hometown", artist.origin) }
            fact(artist.members.count > 1 ? "Formed" : "Active since", artist.disbandedYear.map { "\(artist.formedYear)–\($0)" } ?? String(artist.formedYear))
            if !artist.genres.isEmpty { fact("Genre", artist.genres.prefix(3).map(\.capitalized).joined(separator: ", ")) }
            if !artist.members.isEmpty { fact(artist.members.count > 1 ? "Members" : "Artist", artist.members.joined(separator: "\n")) }
        }
        .frame(width: 190, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value).font(.system(size: 12.5)).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Music-style artists list with the selected artist's page beside it.
struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    @State private var artists: [Artist] = []
    @State private var loaded = false
    @State private var filter = ""

    var body: some View {
        @Bindable var library = library
        Group {
            if artists.isEmpty && loaded {
                LibraryEmptyView(title: "No artists yet", systemImage: "music.microphone", message: "Artists appear here as your library is written.")
            } else {
                HStack(spacing: 0) {
                    List(selection: $library.selectedArtist) {
                        ForEach(visible) { artist in
                            HStack(spacing: 10) {
                                ArtworkView(source: .artist(artist), size: 34, circular: true, shadow: false)
                                Text(artist.name).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                if artist.isFavorite {
                                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                        .accessibilityLabel("Favorite")
                                }
                            }
                            .padding(.vertical, 1)
                            .accessibilityElement(children: .combine)
                            .tag(artist.id)
                            .contextMenu { ArtistMenuItems(artist: artist) }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        TextField("Filter Artists", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .padding(10)
                    }
                    .frame(width: 230)
                    Divider()
                    if let id = library.selectedArtist {
                        ArtistView(artistID: id).id(id)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .clipped()
                    } else {
                        ContentUnavailableView("Select an artist", systemImage: "music.microphone")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .observing(model.services.db) { db in try LibraryQuery.visibleArtists(db) } update: { list in
            artists = list
            loaded = true
            if library.selectedArtist == nil || !list.contains(where: { $0.id == library.selectedArtist }) {
                library.selectedArtist = list.first?.id
            }
        }
    }

    private var visible: [Artist] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }
}

/// Full-bleed portrait that fills its frame (ArtworkView is always square).
struct HeroImage: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    var fallback: [Color] = []
    @State private var image: NSImage?
    @State private var focus = FocalPoint.fallback

    var body: some View {
        let accent = Color(hex: artist.accentHex).map { [$0, $0.opacity(0.5)] }
        let palette = fallback.count >= 2 ? Array(fallback.prefix(2)) : nil
        // Without a portrait the album palette says more than the (often dark) accent.
        let colors = (artist.imagePath == nil ? palette ?? accent : accent ?? palette) ?? ArtworkView.seeded(artist.id)
        Rectangle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topTrailing) {
                if artist.imagePath == nil {
                    // No portrait yet: a big, quiet monogram.
                    Text(artist.name.split(separator: " ").filter { !["The", "A", "An", "&"].contains(String($0)) }.prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.system(size: 260, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.12))
                        .padding(.trailing, 40)
                        .padding(.top, 10)
                }
            }
            .overlay {
                if let image {
                    // Square portraits in a wide banner: keep the faces in frame.
                    FocusedFillImage(image: image, focus: focus)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: artist.imagePath) {
                image = nil
                guard let path = artist.imagePath else { return }
                let artwork = model.services.artwork
                let fullURL = artwork.url(for: path)
                // Only show the thumbnail early if we already know where to crop it.
                if let known = FocalPoint.cached(for: fullURL),
                   let thumb = ImageCache.shared.image(for: artwork.thumbnailURL(for: path)) {
                    focus = known
                    image = thumb
                }
                guard let full = await ImageCache.shared.load(fullURL) else { return }
                let point = await FocalPoint.find(in: full, for: fullURL)
                withAnimation(.easeOut(duration: 0.25)) {
                    focus = point
                    image = full
                }
            }
    }
}

/// "New Release": a format, a direction and an optional brief, then the artist's next record.
struct NewReleaseButton: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let artist: Artist
    @State private var showsBrief = false
    @State private var brief = ""
    /// nil lets the planner choose.
    @State private var format: AlbumKind?
    @State private var direction = ReleaseDirection.nextChapter

    var body: some View {
        let busy = library.releasing.contains(artist.id)
        Button { showsBrief = true } label: {
            if busy {
                Label { Text("Writing…") } icon: { ProgressView().controlSize(.small) }
            } else {
                Label("New Release", systemImage: "opticaldisc")
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .fixedSize()
        .disabled(busy)
        .help(busy ? "\(artist.name)’s next release is being written. It opens when it’s ready." : "Write \(artist.name)’s next release")
        .popover(isPresented: $showsBrief, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New release from \(artist.name)").font(.headline)
                Text("A new record with tracklist, liner notes and cover, shaped by their story so far. Takes a minute or two.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Format", selection: $format) {
                    Text("Auto").tag(AlbumKind?.none)
                    ForEach([AlbumKind.single, .ep, .album], id: \.self) { Text($0.label).tag(AlbumKind?.some($0)) }
                }
                .pickerStyle(.segmented)
                Picker("Direction", selection: $direction) {
                    ForEach(ReleaseDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Optional brief — “a stripped-back winter record”", text: $brief, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 3)
                    .onSubmit(start)
                HStack {
                    Spacer()
                    Button("Cancel") { showsBrief = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Write It", action: start)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }

    private func start() {
        showsBrief = false
        model.newRelease(from: artist, brief: brief, format: format, direction: direction, library: library)
        brief = ""
    }
}

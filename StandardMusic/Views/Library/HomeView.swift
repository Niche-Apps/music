import GRDB
import StandardKit
import SwiftUI

/// Album collections shown on Home; each can be opened as a "See All" page.
enum HomeShelf: String, CaseIterable {
    case recentlyPlayed, newInLibrary, madeForYou, somethingDifferent, favorites

    var title: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .newInLibrary: "New in Your Library"
        case .madeForYou: "Made for You"
        case .somethingDifferent: "Something Different"
        case .favorites: "Favorites"
        }
    }

    var subtitle: String? {
        switch self {
        case .madeForYou: "Right in your wheelhouse"
        case .somethingDifferent: "Wildcards, picked to stretch your taste"
        default: nil
        }
    }

    func albums(_ db: Database, limit: Int? = nil) throws -> [AlbumInfo] {
        try albums(from: LibraryQuery.albums().fetchAll(db), recentlyPlayed: Self.recentlyPlayedIDs(db), limit: limit)
    }

    static func recentlyPlayedIDs(_ db: Database) throws -> [ID] {
        try String.fetchAll(
            db,
            sql: """
                SELECT albumID FROM track WHERE lastPlayedAt IS NOT NULL
                GROUP BY albumID ORDER BY MAX(lastPlayedAt) DESC LIMIT 100
                """)
    }

    /// Builds the shelf from one in-memory list of albums (Home fetches the library once).
    func albums(from all: [AlbumInfo], recentlyPlayed: [ID], limit: Int? = nil) -> [AlbumInfo] {
        let result: [AlbumInfo]
        switch self {
        case .recentlyPlayed:
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            result = recentlyPlayed.compactMap { byID[$0] }
        case .newInLibrary:
            result = all.sorted { $0.album.createdAt > $1.album.createdAt }
        case .madeForYou, .somethingDifferent:
            let tier = self == .madeForYou ? TasteTier.core : .wildcard
            // Stable for a day, then reshuffled.
            let day = Int(Date().timeIntervalSince1970 / 86_400)
            result = all.filter { $0.artist.tier == tier }.sorted { Self.mix($0.id, day) < Self.mix($1.id, day) }
        case .favorites:
            result = all.filter(\.album.isFavorite).sorted { $0.album.title < $1.album.title }
        }
        return limit.map { Array(result.prefix($0)) } ?? result
    }

    private static func mix(_ id: String, _ day: Int) -> UInt64 {
        var h: UInt64 = 1_469_598_103_934_665_603 &+ UInt64(day)
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return h
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model

    struct Data: Equatable, Sendable {
        var fresh: [TrackInfo] = []
        var shelves: [HomeShelf: [AlbumInfo]] = [:]
        var genres: [(String, [AlbumInfo])] = []
        var albumCount = 0
        var pendingTracks = 0

        static func == (a: Data, b: Data) -> Bool {
            a.fresh == b.fresh && a.shelves == b.shelves && a.albumCount == b.albumCount
                && a.genres.map(\.0) == b.genres.map(\.0) && a.genres.map(\.1) == b.genres.map(\.1)
        }
    }

    @State private var data = Data()
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && data.albumCount == 0 {
                LibraryEmptyView(title: "Your library is empty", systemImage: "music.note.house", message: "Head to Create to write your first artists.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        PageHeader(title: "Home", subtitle: loaded ? greeting : " ")
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.top, 24)
                        LibraryBuildingBanner()
                            .padding(.horizontal, Metrics.pagePadding)
                        playlistRow
                            .padding(.horizontal, Metrics.pagePadding)
                        hero
                        ForEach(HomeShelf.allCases, id: \.self) { shelf in
                            if let albums = data.shelves[shelf], !albums.isEmpty {
                                Shelf(title: shelf.title, subtitle: shelf.subtitle, seeAll: { model.show(.shelf(shelf.rawValue)) }) {
                                    ForEach(albums) { AlbumCard(info: $0) }
                                }
                            }
                            if shelf == .madeForYou { genreShelves }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationTitle("Home")
        .observing(model.services.db, immediate: false) { db in
            var data = Data()
            let all = try LibraryQuery.albums().order(Column("releaseYear").desc).fetchAll(db)
            let recent = try HomeShelf.recentlyPlayedIDs(db)
            data.albumCount = all.count
            data.fresh = try AppDatabase.trackInfos().filter(Column("status") == TrackStatus.ready.rawValue)
                .order(Column("generatedAt").desc).limit(12).fetchAll(db)
            for shelf in HomeShelf.allCases { data.shelves[shelf] = shelf.albums(from: all, recentlyPlayed: recent, limit: 20) }
            let grouped = Dictionary(grouping: all) { $0.album.primaryGenre.capitalized }
            data.genres = grouped.filter { $0.value.count >= 3 }.sorted { $0.value.count > $1.value.count }
                .prefix(4).map { ($0.key, Array($0.value.prefix(20))) }
            return data
        } update: { value in
            data = value
            loaded = true
        }
    }

    private var playlistRow: some View {
        HStack(spacing: 12) {
            Button("Make Playlists") { Task { await model.organizePlaylists() } }
                .buttonStyle(.bordered)
                .disabled(model.libraryWork.phase == .working || model.libraryWork.phase == .waiting || data.albumCount == 0)
            Text("Groups albums you already have. Unchanged files are skipped. Free OpenRouter requests stay on free models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Unrecorded albums worth starting, best matches first.
    private var startHere: [AlbumInfo] {
        let recorded = Set(data.fresh.map(\.album.id))
        var seen = Set<ID>()
        return ((data.shelves[.madeForYou] ?? []) + (data.shelves[.newInLibrary] ?? []))
            .filter { !recorded.contains($0.id) && seen.insert($0.artist.id).inserted }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part). \(data.albumCount) album\(data.albumCount == 1 ? "" : "s") written just for you."
    }

    @ViewBuilder private var genreShelves: some View {
        ForEach(data.genres, id: \.0) { genre, albums in
            Shelf(title: genre, seeAll: { model.show(.genre(genre)) }) {
                ForEach(albums) { AlbumCard(info: $0) }
            }
        }
    }

    // MARK: Hero

    @ViewBuilder private var hero: some View {
        if let latest = data.fresh.first {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: "Fresh from the Studio", subtitle: "Songs recorded most recently")
                HStack(alignment: .top, spacing: 18) {
                    HeroCard(info: latest)
                    if data.fresh.count >= 4 {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 2) {
                            ForEach(data.fresh.dropFirst().prefix(8)) { info in
                                TrackRow(info: info, showsArtwork: true, showsArtist: true, list: data.fresh)
                            }
                        }
                    } else {
                        // A young library: pair the few recorded songs with albums to start next.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(data.fresh.dropFirst()) { info in
                                TrackRow(info: info, showsArtwork: true, showsArtist: true, list: data.fresh)
                            }
                            ReadyToRecordList(albums: Array(startHere.prefix(5 - data.fresh.count)))
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        } else if let active = model.recording.active {
            StudioHero(active: active)
                .padding(.horizontal, Metrics.pagePadding)
        } else if let pick = data.shelves[.madeForYou]?.first ?? data.shelves[.newInLibrary]?.first {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: "Start Here", subtitle: "Nothing’s recorded yet — press play and the studio records as you listen")
                FeaturedAlbumCard(info: pick)
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }
}

/// Albums that haven't been recorded yet, with a nudge to start one.
struct ReadyToRecordList: View {
    @Environment(AppModel.self) private var model
    let albums: [AlbumInfo]

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("READY WHEN YOU ARE")
                    .accessibilityLabel("Ready when you are")
                    .accessibilityHeading()
                    .font(.system(size: 10.5, weight: .bold)).tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                ForEach(albums) { info in
                    ReadyToRecordRow(info: info)
                }
                Text("Press play and the studio records each song as you listen. The first one takes a few minutes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
        }
    }
}

private struct ReadyToRecordRow: View {
    @Environment(AppModel.self) private var model
    let info: AlbumInfo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(source: .album(info.album), size: 38, cornerRadius: 4, shadow: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.album.title).font(.system(size: 13)).lineLimit(1)
                Text("\(info.artist.name) · \(info.album.kind.label) · \(info.album.trackCount) songs")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button { model.player.play(albumID: info.album.id) } label: {
                Label("Play", systemImage: "play.fill").font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .opacity(hovering ? 1 : 0.75)
            .help("Play — songs are recorded in order as you listen")
            .accessibilityLabel("Play \(info.album.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.show(.album(info.album.id)) }
        .contextMenu { AlbumMenuItems(info: info) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.album.title), \(info.artist.name), \(info.album.kind.label), \(info.album.trackCount) songs")
        .accessibilityValue("Not recorded yet")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the album")
        .accessibilityAction { model.show(.album(info.album.id)) }
        .accessibilityAction(named: "Play") { model.player.play(albumID: info.album.id) }
    }
}

/// Large card for the most recently recorded song.
struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo

    var body: some View {
        let colors = info.album.colors
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors.count >= 2 ? [colors[0], colors[1]] : ArtworkView.seeded(info.album.id), startPoint: .topLeading, endPoint: .bottomTrailing)
            if info.album.coverPath != nil {
                ArtworkView(source: .album(info.album), size: 200, cornerRadius: 8, highResolution: true)
                    .rotationEffect(.degrees(-4))
                    .offset(x: 150, y: -30)
                    .shadow(radius: 18)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            LegibilityScrim(opacity: 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text("JUST RECORDED").font(.system(size: 10, weight: .bold)).tracking(1).opacity(0.75)
                Text(info.track.title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                Text("\(info.artist.name) — \(info.album.title)").font(.system(size: 12)).opacity(0.85).lineLimit(1)
                if let at = info.track.generatedAt {
                    Text(at.formatted(.relative(presentation: .named))).font(.system(size: 11)).opacity(0.6)
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the album")
            .accessibilityAction { model.show(.album(info.album.id)) }
            Button { model.play(track: info) } label: {
                Image(systemName: "play.fill").font(.system(size: 16)).frame(width: 38, height: 38)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Play \(info.track.title)")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(16)
        }
        .frame(width: 320)
        .frame(minHeight: 250)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.show(.album(info.album.id)) }
        .contextMenu { TrackMenuItems(info: info) }
        .accessibilityElement(children: .contain)
    }
}

/// Wide card used when nothing is recorded yet.
struct FeaturedAlbumCard: View {
    @Environment(AppModel.self) private var model
    let info: AlbumInfo

    var body: some View {
        let colors = info.album.colors
        HStack(spacing: 24) {
            ArtworkView(source: .album(info.album), size: 190, cornerRadius: 8, highResolution: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(info.album.subtitleLine.uppercased()).font(.system(size: 10.5, weight: .bold)).opacity(0.7)
                    .accessibilityLabel(info.album.subtitleLine)
                Text(info.album.title).font(.system(size: 26, weight: .bold)).lineLimit(2)
                    .accessibilityHeading()
                Text(info.artist.name).font(.system(size: 15, weight: .medium)).opacity(0.85)
                Text(info.album.notes).font(.system(size: 12.5)).opacity(0.75).lineLimit(3).padding(.top, 4)
                Spacer(minLength: 8)
                Button { model.player.play(albumID: info.album.id) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityLabel("Play \(info.album.title)")
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minHeight: 234)
        .background {
            LinearGradient(colors: colors.count >= 2 ? [colors[0], colors[1]] : ArtworkView.seeded(info.album.id), startPoint: .leading, endPoint: .trailing)
                .overlay(Color.black.opacity(0.28))
                .overlay(LegibilityScrim(opacity: 0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.show(.album(info.album.id)) }
        .contextMenu { AlbumMenuItems(info: info) }
    }
}

/// Shown on Home while the very first song is being recorded.
struct StudioHero: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let active: RecordingQueue.Activity

    var body: some View {
        HStack(spacing: 18) {
            RecordingRing(fraction: active.fraction, lineWidth: 4)
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("IN THE STUDIO").font(.system(size: 10.5, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Text(active.title).font(.system(size: 20, weight: .bold))
                Text("\(active.artistName) · \(active.stageLabel)\(Format.remaining(active.remaining).map { " · \($0)" } ?? "")")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("In the studio, \(active.title) by \(active.artistName)")
            .accessibilityValue(Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining))
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Stop", systemImage: "stop.fill") { model.stopRecording() }
                .buttonStyle(.glass)
                .help("Stop recording (⌘.)")
            Button("Show Album") {
                library.reveal = active.trackID
                model.show(.album(active.albumID))
            }
            .buttonStyle(.glass)
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// "See All" page for a Home shelf.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var albums: [AlbumInfo] = []

    var body: some View {
        let shelf = HomeShelf(rawValue: key) ?? .newInLibrary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: shelf.title, subtitle: shelf.subtitle)
                AlbumGrid(albums: albums)
            }
            .padding(Metrics.pagePadding)
        }
        .navigationTitle(shelf.title)
        .observing(model.services.db, id: key) { db in try shelf.albums(db) } update: { albums = $0 }
    }
}

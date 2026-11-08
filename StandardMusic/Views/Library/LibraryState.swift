import AppKit
import GRDB
import StandardKit
import SwiftUI

/// UI state shared by the library screens: playlists (for menus), the song to reveal, and the
/// artist selected in the Artists list.
@MainActor
@Observable
final class LibraryState {
    var playlists: [Playlist] = []
    /// Track to scroll to and highlight on the next album page that shows it.
    var reveal: ID?
    var selectedArtist: ID?
    var favoritesTab = FavoritesTab.songs
    var renamingPlaylist: ID?
    /// Artists whose new release is being written right now.
    var releasing = Set<ID>()

    enum FavoritesTab: String, CaseIterable { case songs = "Songs", albums = "Albums", artists = "Artists" }
}

// MARK: - Queries

enum LibraryQuery {
    static let readyStatus = ItemStatus.ready.rawValue

    static func albums() -> QueryInterfaceRequest<AlbumInfo> {
        AppDatabase.albumInfos().filter(Column("status") == readyStatus)
    }

    /// Visible artists: anyone with at least one finished album.
    static func visibleArtists(_ db: Database) throws -> [Artist] {
        try Artist.fetchAll(
            db,
            sql: """
                SELECT * FROM artist WHERE id IN (SELECT artistID FROM album WHERE status = 'ready')
                ORDER BY sortName
                """)
    }

    static func tracks(albumIDs: [ID]) -> QueryInterfaceRequest<TrackInfo> {
        AppDatabase.trackInfos().filter(albumIDs.contains(Column("albumID")))
    }

    static func playlistTracks(_ db: Database, _ playlistID: ID) throws -> [PlaylistEntry] {
        let items = try PlaylistItem.filter(Column("playlistID") == playlistID).order(Column("position")).fetchAll(db)
        let infos = try AppDatabase.trackInfos().filter(keys: Set(items.map(\.trackID))).fetchAll(db)
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in byID[item.trackID].map { PlaylistEntry(position: item.position, info: $0) } }
    }
}

struct PlaylistEntry: Hashable, Identifiable, Sendable {
    var position: Int
    var info: TrackInfo
    var id: Int { position }
}

// MARK: - Playlist writes

extension AppDatabase {
    func createPlaylist(named name: String, trackIDs: [ID] = []) throws -> Playlist {
        let playlist = Playlist(name: name)
        try writer.write { db in
            try playlist.insert(db)
            for (i, id) in trackIDs.enumerated() {
                try PlaylistItem(playlistID: playlist.id, trackID: id, position: i).insert(db)
            }
        }
        return playlist
    }

    func renamePlaylist(_ id: ID, to name: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date(), id])
        }
    }

    func deletePlaylist(_ id: ID) throws {
        try writer.write { db in _ = try Playlist.deleteOne(db, key: id) }
    }

    func addToPlaylist(_ id: ID, trackIDs: [ID]) throws {
        try writer.write { db in
            var next = try Int.fetchOne(db, sql: "SELECT MAX(position) + 1 FROM playlistItem WHERE playlistID = ?", arguments: [id]) ?? 0
            for track in trackIDs {
                try PlaylistItem(playlistID: id, trackID: track, position: next).insert(db)
                next += 1
            }
            try db.execute(sql: "UPDATE playlist SET updatedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
    }

    /// Rewrites the playlist in the given order (positions are the primary key, so renumber all).
    func setPlaylistOrder(_ id: ID, trackIDs: [ID]) throws {
        try writer.write { db in
            let existing = try PlaylistItem.filter(Column("playlistID") == id).fetchAll(db)
            let addedAt = Dictionary(existing.map { ($0.trackID, $0.addedAt) }, uniquingKeysWith: { a, _ in a })
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistID = ?", arguments: [id])
            for (i, track) in trackIDs.enumerated() {
                var item = PlaylistItem(playlistID: id, trackID: track, position: i)
                item.addedAt = addedAt[track] ?? Date()
                try item.insert(db)
            }
            try db.execute(sql: "UPDATE playlist SET updatedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
    }
}

// MARK: - Actions

extension AppModel {
    /// Plays a recorded song in the context of its album. Unrecorded songs explain why they can't.
    func play(track info: TrackInfo, in list: [TrackInfo]? = nil, context: PlaybackContext? = nil) {
        guard info.track.isPlayable else {
            toast = "“\(info.track.title)” isn’t recorded yet — play the album to record it."
            return
        }
        if let list {
            let playable = list.filter { $0.track.isPlayable || $0.album.id == info.album.id }
            player.play(trackIDs: playable.map(\.id), startingAt: info.id, context: context ?? .songs("Songs"))
        } else {
            player.play(albumID: info.album.id, startingAt: info.id)
        }
    }

    func record(_ ids: [ID]) {
        guard !ids.isEmpty else { return }
        recording.request(ids)
        toast = ids.count == 1 ? "Added to the studio queue." : "\(ids.count) songs added to the studio queue."
    }

    func playNext(_ infos: [TrackInfo]) {
        player.playNext(infos.map(\.id))
        toast = infos.count == 1 ? "“\(infos[0].track.title)” will play next." : "\(infos.count) songs will play next."
    }

    func playLater(_ infos: [TrackInfo]) {
        player.playLater(infos.map(\.id))
        toast = infos.count == 1 ? "Added “\(infos[0].track.title)” to Up Next." : "Added \(infos.count) songs to Up Next."
    }

    func add(_ trackIDs: [ID], to playlist: Playlist) {
        try? services.db.addToPlaylist(playlist.id, trackIDs: trackIDs)
        toast = "Added \(trackIDs.count == 1 ? "1 song" : "\(trackIDs.count) songs") to “\(playlist.name)”."
    }

    @discardableResult
    func newPlaylist(with trackIDs: [ID] = []) -> Playlist? {
        let count = (try? services.db.reader.read { try Playlist.fetchCount($0) }) ?? 0
        return try? services.db.createPlaylist(named: count == 0 ? "New Playlist" : "New Playlist \(count + 1)", trackIDs: trackIDs)
    }

    func tracks(ofAlbum id: ID) -> [TrackInfo] {
        (try? services.db.reader.read { db in
            try AppDatabase.trackInfos().filter(Column("albumID") == id)
                .order(Column("discNumber"), Column("trackNumber")).fetchAll(db)
        }) ?? []
    }

    /// Writes a new album continuing the artist's story; the model navigates to it when done.
    func newRelease(
        from artist: Artist, brief: String? = nil, format: AlbumKind? = nil, direction: ReleaseDirection = .nextChapter,
        library: LibraryState
    ) {
        guard !library.releasing.contains(artist.id) else { return }
        library.releasing.insert(artist.id)
        let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await newRelease(from: artist, brief: brief?.isEmpty == false ? brief : nil, format: format, direction: direction)
            library.releasing.remove(artist.id)
        }
    }

    func revealCurrent(_ library: LibraryState) {
        guard let current = player.current else { return }
        library.reveal = current.id
        if path.last != .album(current.album.id) { show(.album(current.album.id)) }
    }

    func showInFinder(_ track: Track) {
        guard let path = track.audioPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Paths.resolve(path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Album {
    var colors: [Color] { palette.compactMap { Color(hex: $0) } }
    var subtitleLine: String {
        [primaryGenre.capitalized, String(releaseYear), kind == .album ? nil : kind.label].compactMap { $0 }.joined(separator: " · ")
    }
}

extension TrackInfo {
    var copyText: String { "\(track.title) — \(artist.name), \(album.title)" }
}

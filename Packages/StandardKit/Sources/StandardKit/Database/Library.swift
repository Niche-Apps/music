import Foundation
import GRDB

/// Album with its artist, the unit most screens display.
public struct AlbumInfo: Decodable, Sendable, Hashable, Identifiable, FetchableRecord {
    public var album: Album
    public var artist: Artist
    public var id: ID { album.id }
}

/// Track with its album and artist.
public struct TrackInfo: Decodable, Sendable, Hashable, Identifiable, FetchableRecord {
    public var track: Track
    public var album: Album
    public var artist: Artist
    public var id: ID { track.id }
}

// MARK: - Writes

extension AppDatabase {
    public func save(artist: Artist) throws {
        try writer.write { db in
            try artist.save(db)
            try Self.index(db, artist: artist)
        }
    }

    public func save(album: Album, tracks: [Track]? = nil) throws {
        try writer.write { db in
            try album.save(db)
            let artistName = try Artist.fetchOne(db, key: album.artistID)?.name ?? ""
            try Self.index(db, album: album, artistName: artistName)
            if let tracks {
                for track in tracks {
                    try track.save(db)
                    try Self.index(db, track: track, artistName: artistName, albumTitle: album.title)
                }
            }
        }
    }

    public func update(track: Track) throws {
        try writer.write { try track.update($0) }
    }

    /// Applies `change` to the latest stored copy of a track inside one transaction.
    @discardableResult
    public func modifyTrack(_ id: ID, _ change: @Sendable (inout Track) -> Void) throws -> Track? {
        try writer.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return nil }
            change(&track)
            try track.update(db)
            return track
        }
    }

    @discardableResult
    public func modifyArtist(_ id: ID, _ change: @Sendable (inout Artist) -> Void) throws -> Artist? {
        try writer.write { db in
            guard var artist = try Artist.fetchOne(db, key: id) else { return nil }
            change(&artist)
            try artist.update(db)
            try Self.index(db, artist: artist)
            return artist
        }
    }

    @discardableResult
    public func modifyAlbum(_ id: ID, _ change: @Sendable (inout Album) -> Void) throws -> Album? {
        try writer.write { db in
            guard var album = try Album.fetchOne(db, key: id) else { return nil }
            change(&album)
            try album.update(db)
            return album
        }
    }

    public func deleteArtist(_ id: ID) throws {
        try writer.write { db in
            let albumIDs = try String.fetchAll(db, sql: "SELECT id FROM album WHERE artistID = ?", arguments: [id])
            let trackIDs = try String.fetchAll(db, sql: "SELECT id FROM track WHERE artistID = ?", arguments: [id])
            for item in [id] + albumIDs + trackIDs {
                try db.execute(sql: "DELETE FROM searchIndex WHERE itemID = ?", arguments: [item])
            }
            _ = try Artist.deleteOne(db, key: id)
        }
    }

    public func recordPlay(_ event: PlayEvent) throws {
        try writer.write { db in
            var event = event
            try event.insert(db)
            try db.execute(
                sql: """
                    UPDATE track SET playCount = playCount + ?, skipCount = skipCount + ?, lastPlayedAt = ?
                    WHERE id = ?
                    """,
                arguments: [event.completed || event.secondsPlayed > 30 ? 1 : 0, event.skipped ? 1 : 0,
                    event.startedAt, event.trackID])
        }
    }

    /// Generation that was interrupted (app quit mid-song) goes back to pending.
    public func resetInterruptedGeneration() throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET status = 'pending' WHERE status = 'generating'")
        }
    }

    // MARK: Search index

    static func index(_ db: Database, artist: Artist) throws {
        try db.execute(sql: "DELETE FROM searchIndex WHERE itemID = ?", arguments: [artist.id])
        try db.execute(
            sql: "INSERT INTO searchIndex(kind, itemID, title, subtitle, keywords) VALUES (?, ?, ?, ?, ?)",
            arguments: [SearchKind.artist.rawValue, artist.id, artist.name, artist.primaryGenre,
                (artist.genres + artist.tags + [artist.origin]).joined(separator: " ")])
    }

    static func index(_ db: Database, album: Album, artistName: String) throws {
        try db.execute(sql: "DELETE FROM searchIndex WHERE itemID = ?", arguments: [album.id])
        try db.execute(
            sql: "INSERT INTO searchIndex(kind, itemID, title, subtitle, keywords) VALUES (?, ?, ?, ?, ?)",
            arguments: [SearchKind.album.rawValue, album.id, album.title, artistName,
                (album.genres + [String(album.releaseYear), album.label]).joined(separator: " ")])
    }

    static func index(_ db: Database, track: Track, artistName: String, albumTitle: String) throws {
        try db.execute(sql: "DELETE FROM searchIndex WHERE itemID = ?", arguments: [track.id])
        try db.execute(
            sql: "INSERT INTO searchIndex(kind, itemID, title, subtitle, keywords) VALUES (?, ?, ?, ?, ?)",
            arguments: [SearchKind.track.rawValue, track.id, track.title, "\(artistName) — \(albumTitle)",
                track.mood])
    }
}

// MARK: - Reads

extension AppDatabase {
    public static func albumInfos() -> QueryInterfaceRequest<AlbumInfo> {
        Album.including(required: Album.artist).asRequest(of: AlbumInfo.self)
    }

    public static func trackInfos() -> QueryInterfaceRequest<TrackInfo> {
        Track.including(required: Track.album).including(required: Track.artist).asRequest(of: TrackInfo.self)
    }

    public func search(_ text: String, limit: Int = 60) throws -> [SearchHit] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try reader.read { db in
            try SearchHit.fetchAll(
                db,
                sql: """
                    SELECT kind, itemID, title, subtitle FROM searchIndex
                    WHERE searchIndex MATCH ? ORDER BY bm25(searchIndex, 0, 0, 10.0, 3.0, 1.0) LIMIT ?
                    """,
                arguments: [pattern, limit])
        }
    }

    public func tracks(forAlbum albumID: ID) throws -> [Track] {
        try reader.read { db in
            try Track.filter(Column("albumID") == albumID)
                .order(Column("discNumber"), Column("trackNumber")).fetchAll(db)
        }
    }

    public func trackInfo(_ id: ID) throws -> TrackInfo? {
        try reader.read { try Self.trackInfos().filter(key: id).fetchOne($0) }
    }

    public func albumInfo(_ id: ID) throws -> AlbumInfo? {
        try reader.read { try Self.albumInfos().filter(key: id).fetchOne($0) }
    }

    public func artistCount(status: ItemStatus? = nil) throws -> Int {
        try reader.read { db in
            if let status { return try Artist.filter(Column("status") == status.rawValue).fetchCount(db) }
            return try Artist.fetchCount(db)
        }
    }
}

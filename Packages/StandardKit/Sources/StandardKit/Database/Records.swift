import Foundation
import GRDB

public typealias ID = String

public func newID() -> ID { UUID().uuidString.lowercased() }

/// Where an item sits relative to the listener's taste when it was generated.
public enum TasteTier: String, Codable, Sendable, CaseIterable {
    case core, adjacent, wildcard
}

public enum ItemStatus: String, Codable, Sendable {
    /// Concept only (name, genre, one-liner).
    case planned
    /// Text written (bio/soul, or tracklist for albums).
    case written
    /// Everything including artwork is done.
    case ready
    case failed
}

// MARK: - Artist

public struct Artist: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artist"

    public var id: ID
    public var name: String
    public var sortName: String
    public var primaryGenre: String
    public var genres: [String]
    /// Short tags used for similarity (scene, era, sound).
    public var tags: [String]
    public var origin: String
    public var formedYear: Int
    public var disbandedYear: Int?
    public var members: [String]
    /// One-line description shown under the name.
    public var tagline: String
    /// Encyclopedia-style biography shown in the app.
    public var bio: String
    /// Hidden: sonic identity, voice, influences and career arc. Drives all downstream generation.
    public var soul: String
    /// Hidden: the lead singer's fixed voice as music-model tags ("female alto vocal, smoky, breathy"),
    /// or "instrumental". Appended to every recording so the artist sounds like one person across albums.
    public var voice: String = ""
    /// Hidden: real artists this act resembles; used for taste matching only.
    public var touchstones: [String]
    public var tier: TasteTier
    public var plannedAlbumCount: Int
    public var imagePath: String?
    public var imagePrompt: String?
    /// Dominant color of the portrait as hex, used for page tints.
    public var accentHex: String?
    public var status: ItemStatus
    public var batchID: ID?
    public var isFavorite: Bool
    public var createdAt: Date

    public init(
        id: ID = newID(), name: String, primaryGenre: String, genres: [String], tags: [String] = [],
        origin: String = "", formedYear: Int, tagline: String = "", tier: TasteTier, plannedAlbumCount: Int,
        touchstones: [String] = [], batchID: ID? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = Artist.sortKey(for: name)
        self.primaryGenre = primaryGenre
        self.genres = genres
        self.tags = tags
        self.origin = origin
        self.formedYear = formedYear
        self.disbandedYear = nil
        self.members = []
        self.tagline = tagline
        self.bio = ""
        self.soul = ""
        self.touchstones = touchstones
        self.tier = tier
        self.plannedAlbumCount = plannedAlbumCount
        self.imagePath = nil
        self.imagePrompt = nil
        self.accentHex = nil
        self.status = .planned
        self.batchID = batchID
        self.isFavorite = false
        self.createdAt = Date()
    }

    public static func sortKey(for name: String) -> String {
        let lower = name.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) && lower.count > article.count {
            return String(lower.dropFirst(article.count))
        }
        return lower
    }

    public static let albums = hasMany(Album.self)
    public static let tracks = hasMany(Track.self)
}

// MARK: - Album

public enum AlbumKind: String, Codable, Sendable, CaseIterable {
    case album, ep, single, live, compilation

    public var label: String {
        switch self {
        case .album: "Album"
        case .ep: "EP"
        case .single: "Single"
        case .live: "Live Album"
        case .compilation: "Compilation"
        }
    }
}

public struct Album: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "album"

    public var id: ID
    public var artistID: ID
    public var title: String
    public var releaseYear: Int
    public var kind: AlbumKind
    public var label: String
    public var primaryGenre: String
    public var genres: [String]
    /// Liner notes / editorial blurb shown in the app.
    public var notes: String
    /// Hidden: concept, production, place in the artist's arc, per-song tone map.
    public var soul: String
    public var coverPrompt: String
    public var coverPath: String?
    /// Album page colors extracted from the cover (background, primary, secondary, tertiary text).
    public var palette: [String]
    public var trackCount: Int
    public var status: ItemStatus
    public var isFavorite: Bool
    public var createdAt: Date
    /// Set when this single belongs to a same-lyrics batch. Nil for every other album.
    public var batchID: ID? = nil

    public init(
        id: ID = newID(), artistID: ID, title: String, releaseYear: Int, kind: AlbumKind, label: String = "",
        primaryGenre: String, genres: [String], soul: String = "", coverPrompt: String = "", trackCount: Int
    ) {
        self.id = id
        self.artistID = artistID
        self.title = title
        self.releaseYear = releaseYear
        self.kind = kind
        self.label = label
        self.primaryGenre = primaryGenre
        self.genres = genres
        self.notes = ""
        self.soul = soul
        self.coverPrompt = coverPrompt
        self.coverPath = nil
        self.palette = []
        self.trackCount = trackCount
        self.status = .planned
        self.isFavorite = false
        self.createdAt = Date()
    }

    public static let artist = belongsTo(Artist.self)
    public static let tracks = hasMany(Track.self).order(Column("discNumber"), Column("trackNumber"))
}

// MARK: - Track

public enum TrackStatus: String, Codable, Sendable {
    /// Not recorded yet.
    case pending
    /// Audio is being generated right now.
    case generating
    case ready
    case failed
}

public struct Track: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "track"

    public var id: ID
    public var albumID: ID
    public var artistID: ID
    public var discNumber: Int
    public var trackNumber: Int
    public var title: String
    /// Hidden: what this song is, sonically and emotionally.
    public var details: String
    /// YuE style tags (genre, instruments, mood, vocal).
    public var styleTags: String
    /// Lyrics with section tags. Written just before recording.
    public var lyrics: String?
    public var vocal: String
    public var bpm: Int?
    public var mood: String
    public var isInstrumental: Bool
    /// Lyrics contain strong language or explicit themes (shown with an E).
    public var isExplicit: Bool = false
    /// Written by the listener (Create › Custom): their lyrics and style are recorded as given.
    public var isCustom: Bool = false
    /// The listener asked for vocals with no instruments. Recording keeps that in the style tags.
    /// The music engine only sees those tags; this is not a guarantee the model will obey.
    public var vocalOnly: Bool = false
    /// JSON `[StyleCue]` metadata for style references. Never audio, paths, or bookmarks.
    public var styleCues: String = "[]"
    public var seed: Int64
    public var status: TrackStatus
    public var audioPath: String?
    public var duration: Double?
    /// Integrated loudness (approx. LUFS) used for volume normalisation.
    public var loudness: Double?
    public var generatedAt: Date?
    public var generationSeconds: Double?
    public var isFavorite: Bool
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayedAt: Date?
    public var createdAt: Date

    public init(
        id: ID = newID(), albumID: ID, artistID: ID, discNumber: Int = 1, trackNumber: Int, title: String,
        details: String, styleTags: String, vocal: String, bpm: Int?, mood: String, isInstrumental: Bool = false
    ) {
        self.id = id
        self.albumID = albumID
        self.artistID = artistID
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.title = title
        self.details = details
        self.styleTags = styleTags
        self.lyrics = nil
        self.vocal = vocal
        self.bpm = bpm
        self.mood = mood
        self.isInstrumental = isInstrumental
        self.seed = Int64.random(in: 1 ... 2_000_000_000)
        self.status = .pending
        self.audioPath = nil
        self.duration = nil
        self.loudness = nil
        self.generatedAt = nil
        self.generationSeconds = nil
        self.isFavorite = false
        self.playCount = 0
        self.skipCount = 0
        self.lastPlayedAt = nil
        self.createdAt = Date()
    }

    public var isPlayable: Bool { status == .ready && audioPath != nil }

    public static let album = belongsTo(Album.self)
    public static let artist = belongsTo(Artist.self)
}

// MARK: - Listening history

public struct PlayEvent: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playEvent"

    public var id: Int64?
    public var trackID: ID
    public var startedAt: Date
    public var secondsPlayed: Double
    public var completed: Bool
    public var skipped: Bool

    public init(trackID: ID, startedAt: Date, secondsPlayed: Double, completed: Bool, skipped: Bool) {
        self.trackID = trackID
        self.startedAt = startedAt
        self.secondsPlayed = secondsPlayed
        self.completed = completed
        self.skipped = skipped
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Playlists

public struct Playlist: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "playlist"

    public var id: ID
    public var name: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: ID = newID(), name: String, notes: String = "") {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

public struct PlaylistItem: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "playlistItem"

    public var playlistID: ID
    public var trackID: ID
    public var position: Int
    public var addedAt: Date

    public init(playlistID: ID, trackID: ID, position: Int) {
        self.playlistID = playlistID
        self.trackID = trackID
        self.position = position
        self.addedAt = Date()
    }
}

// MARK: - Generation batches

public enum BatchKind: String, Codable, Sendable {
    /// The first library built after onboarding.
    case initialLibrary
    /// "More like this" from an artist/album.
    case similar
    /// Free-text request from the Create page.
    case prompt
    /// Taste-driven top-up ("Discover new artists").
    case discover
    /// New album for an existing artist.
    case newRelease
    /// The same custom lyrics, each song by a different artist.
    case customLyrics
}

public enum BatchStatus: String, Codable, Sendable {
    case planning, running, finished, failed, cancelled
}

public struct GenerationBatch: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "generationBatch"

    public var id: ID
    public var kind: BatchKind
    /// Human description ("Your library", "More like Velvet Antenna", ...).
    public var title: String
    /// JSON request payload (prompt, seed artist, counts).
    public var request: String
    public var status: BatchStatus
    public var targetArtists: Int
    public var error: String?
    public var createdAt: Date
    public var finishedAt: Date?

    public init(kind: BatchKind, title: String, request: String, targetArtists: Int) {
        self.id = newID()
        self.kind = kind
        self.title = title
        self.request = request
        self.status = .planning
        self.targetArtists = targetArtists
        self.error = nil
        self.createdAt = Date()
        self.finishedAt = nil
    }
}

// MARK: - Key/value settings stored with the library

public struct StoredValue: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "storedValue"
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - Search

public enum SearchKind: String, Codable, Sendable {
    case artist, album, track
}

public struct SearchHit: Codable, Sendable, Hashable, FetchableRecord {
    public var kind: SearchKind
    public var itemID: ID
    public var title: String
    public var subtitle: String
}

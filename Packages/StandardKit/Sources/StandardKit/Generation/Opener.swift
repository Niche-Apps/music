import Foundation
import GRDB

/// The "while you wait" song: one real track, in the listener's most likely favorite genre, written
/// and recorded ahead of everything else so there's something to hear while the first library builds.
///
/// The builder picks the artist as soon as the roster lands and writes that artist (and their lead
/// release) ahead of the queue; the app then picks a song from it and sends it to the front of the
/// studio. The choice is stored in the library so a relaunch mid-build never makes a second one.
public struct OpenerState: Codable, Sendable, Equatable {
    /// The genre the opener was chosen for.
    public var genre: String
    public var artistID: ID?
    /// The release written first for the opener (its track list arrives before the rest).
    public var albumID: ID?
    public var trackID: ID?

    public init(genre: String, artistID: ID? = nil, albumID: ID? = nil, trackID: ID? = nil) {
        self.genre = genre
        self.artistID = artistID
        self.albumID = albumID
        self.trackID = trackID
    }
}

public enum Opener {
    public static let storageKey = "openerSong"

    /// The genre the listener most likely loves: their refined core genres in order, nudged toward the
    /// ones the artists they liked actually play.
    public static func favoriteGenre(_ profile: TasteProfile) -> String? {
        let core = (profile.coreGenres.isEmpty ? profile.selectedGenres : profile.coreGenres)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !core.isEmpty else { return nil }
        let liked = profile.likedArtists.flatMap(\.genres)
        let scored = core.enumerated().map { i, genre in
            let likes = liked.count { overlap(genre, $0) > 0 }
            return (genre, Double(core.count - i) + 1.5 * Double(likes), i)
        }
        // Highest score; earlier (more central) genres win ties.
        return scored.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.2 > b.2 }?.0
    }

    /// How squarely an artist plays `genre`: 3 = primary genre, 2 = one of their genres,
    /// 1 = shares a distinctive word ("dream pop" ~ "cinematic dream pop"), 0 = unrelated.
    public static func match(_ artist: Artist, genre: String) -> Int {
        let g = normalise(genre)
        guard !g.isEmpty else { return 0 }
        if normalise(artist.primaryGenre) == g { return 3 }
        if artist.genres.contains(where: { normalise($0) == g }) { return 2 }
        if ([artist.primaryGenre] + artist.genres).contains(where: { overlap($0, genre) > 0 }) { return 1 }
        return 0
    }

    /// The artist to open with: a core-tier act in the favorite genre, earliest cast first.
    /// `artists` should be in roster order.
    public static func pickArtist(_ artists: [Artist], genre: String) -> Artist? {
        let usable = artists.enumerated().filter { $0.element.status != .failed }
        return usable.max { a, b in
            let ka = (a.element.tier == .core ? 1 : 0, match(a.element, genre: genre))
            let kb = (b.element.tier == .core ? 1 : 0, match(b.element, genre: genre))
            if ka != kb { return ka < kb }
            return a.offset > b.offset
        }?.element
    }

    /// The release to write first: a proper album if there is one (then an EP), earliest first.
    public static func leadAlbum(_ albums: [Album]) -> Album? {
        func rank(_ kind: AlbumKind) -> Int {
            switch kind {
            case .album: 0
            case .ep: 1
            case .single: 2
            case .live, .compilation: 3
            }
        }
        return albums.min { a, b in
            (rank(a.kind), a.releaseYear, a.createdAt) < (rank(b.kind), b.releaseYear, b.createdAt)
        }
    }

    static let introWords: Set<String> = ["intro", "introduction", "prelude", "overture", "interlude", "outro", "reprise"]

    /// The song to record: the opening track unless it's an instrumental or an intro piece, in which
    /// case the first proper song after it.
    public static func pickTrack(_ tracks: [Track]) -> Track? {
        let ordered = tracks.sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
        let isSong: (Track) -> Bool = { track in
            guard !track.isInstrumental else { return false }
            let words = Set(track.title.lowercased().split { !$0.isLetter }.map(String.init))
            return words.isDisjoint(with: introWords)
        }
        return ordered.first(where: isSong) ?? ordered.first
    }

    // MARK: Helpers

    static func normalise(_ s: String) -> String {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static let genericWords: Set<String> = ["music", "pop", "rock", "the", "and", "new", "style", "core"]

    /// Shared distinctive words between two genre names. "pop" and "rock" alone are too broad to count,
    /// unless one side is exactly that word.
    static func overlap(_ a: String, _ b: String) -> Int {
        let wa = Set(normalise(a).split(separator: " ").map(String.init))
        let wb = Set(normalise(b).split(separator: " ").map(String.init))
        if wa == wb, !wa.isEmpty { return wa.count }
        return wa.intersection(wb).subtracting(genericWords).count
    }
}

extension AppDatabase {
    public var openerState: OpenerState? { value(OpenerState.self, forKey: Opener.storageKey) }

    public func setOpenerState(_ state: OpenerState) throws {
        try setValue(state, forKey: Opener.storageKey)
    }

    /// Settles which song is the opener once one can be chosen and returns the current state.
    ///
    /// Keeps a chosen track while it exists. Otherwise picks one from the opener artist's lead release
    /// (or any of their written releases); if that artist couldn't be written, falls back to the
    /// best-matching artist that already has songs.
    @discardableResult
    public func resolveOpener() throws -> OpenerState? {
        guard var state = openerState else { return nil }
        let resolved: OpenerState = try writer.write { db in
            if let id = state.trackID, try Track.exists(db, key: id) { return state }
            state.trackID = nil
            // The builder hasn't cast the opener yet.
            guard let artistID = state.artistID else { return state }
            var artist = try Artist.fetchOne(db, key: artistID)
            if artist == nil || artist?.status == .failed {
                // The chosen artist couldn't be written: anyone in the library with written songs.
                let written = try Artist
                    .filter(sql: "status != 'failed' AND EXISTS (SELECT 1 FROM track t WHERE t.artistID = artist.id)")
                    .order(Column("createdAt")).fetchAll(db)
                guard let replacement = Opener.pickArtist(written, genre: state.genre) else { return state }
                artist = replacement
                state.artistID = replacement.id
                state.albumID = nil
            }
            guard let artist else { return state }
            let albums = try Album.filter(Column("artistID") == artist.id).fetchAll(db)
            let withTracks = try albums.filter { album in
                try Track.filter(Column("albumID") == album.id).fetchCount(db) > 0
            }
            let album = withTracks.first { $0.id == state.albumID } ?? Opener.leadAlbum(withTracks)
            guard let album else { return state }
            let tracks = try Track.filter(Column("albumID") == album.id).fetchAll(db)
            guard let track = Opener.pickTrack(tracks) else { return state }
            state.albumID = album.id
            state.trackID = track.id
            let raw = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            try StoredValue(key: Opener.storageKey, value: raw).save(db)
            return state
        }
        return resolved
    }
}

/// Everything the "while you wait" player shows, read in one go (for database observation).
public struct OpenerSong: Sendable, Equatable {
    public var state: OpenerState?
    public var artist: Artist?
    public var album: Album?
    public var track: Track?

    public static let none = OpenerSong()

    public init(state: OpenerState? = nil, artist: Artist? = nil, album: Album? = nil, track: Track? = nil) {
        self.state = state
        self.artist = artist
        self.album = album
        self.track = track
    }

    public static func fetch(_ db: Database) throws -> OpenerSong {
        guard let raw = try StoredValue.fetchOne(db, key: Opener.storageKey)?.value,
            let state = try? JSONDecoder().decode(OpenerState.self, from: Data(raw.utf8))
        else { return .none }
        let track = try state.trackID.flatMap { try Track.fetchOne(db, key: $0) }
        let artist = try (track?.artistID ?? state.artistID).flatMap { try Artist.fetchOne(db, key: $0) }
        let album = try (track?.albumID ?? state.albumID).flatMap { try Album.fetchOne(db, key: $0) }
        return OpenerSong(state: state, artist: artist, album: album, track: track)
    }
}

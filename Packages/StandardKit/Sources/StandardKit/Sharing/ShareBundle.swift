import Foundation
import GRDB
import OSLog

let shareLog = Logger(subsystem: "com.standardmusic", category: "sharing")

/// A `.standardalbum` file: one artist with one or more of their albums, ready to hand to another
/// Standard Music listener over AirDrop, Messages, Mail or a shared folder. No server involved.
///
/// On disk it is a zip archive:
///
///     manifest.json          ShareManifest (format version, artist, albums, tracks)
///     artwork/artist.jpg     the artist portrait, if any
///     artwork/<albumID>.jpg  each album cover, if any
///     audio/<trackID>.m4a    recordings, when the sender chose to include them
///
/// Everything needed to keep the artist alive travels with it: the hidden soul and voice (so new
/// albums and recordings on the recipient's Mac stay in character), and each song's lyrics, style
/// and seed (so unrecorded songs are recorded on the recipient's Mac just as they would have been
/// on the sender's). Listening history and favourites stay private and never leave the Mac.
public struct ShareManifest: Codable, Sendable {
    public static let currentFormat = 1
    public static let fileExtension = "standardalbum"

    public var format: Int
    public var exportedAt: Date
    /// The sender's first name, shown on the recipient's import sheet ("Shared by Justin").
    public var sharedBy: String?
    /// The music model the recordings were made with, so the recipient knows whether
    /// re-recording an unrecorded song will sound the same.
    public var engine: String?
    public var artist: SharedArtist
    public var albums: [SharedAlbum]

    public var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    public var recordedCount: Int { albums.reduce(0) { $0 + $1.tracks.filter { $0.audio != nil }.count } }
}

public struct SharedArtist: Codable, Sendable {
    public var id: ID
    public var name: String
    public var primaryGenre: String
    public var genres: [String]
    public var tags: [String]
    public var origin: String
    public var formedYear: Int
    public var disbandedYear: Int?
    public var members: [String]
    public var tagline: String
    public var bio: String
    public var soul: String
    public var voice: String
    public var touchstones: [String]
    public var tier: TasteTier
    public var plannedAlbumCount: Int
    public var imagePrompt: String?
    public var accentHex: String?
    /// Path inside the archive.
    public var image: String?
}

public struct SharedAlbum: Codable, Sendable {
    public var id: ID
    public var title: String
    public var releaseYear: Int
    public var kind: AlbumKind
    public var label: String
    public var primaryGenre: String
    public var genres: [String]
    public var notes: String
    public var soul: String
    public var coverPrompt: String
    public var palette: [String]
    public var cover: String?
    public var tracks: [SharedTrack]
}

public struct SharedTrack: Codable, Sendable {
    public var id: ID
    public var discNumber: Int
    public var trackNumber: Int
    public var title: String
    public var details: String
    public var styleTags: String
    public var lyrics: String?
    public var vocal: String
    public var bpm: Int?
    public var mood: String
    public var isInstrumental: Bool
    public var seed: Int64
    /// Path inside the archive, when the recording is included.
    public var audio: String?
    public var duration: Double?
    public var loudness: Double?
}

public enum ShareError: LocalizedError {
    case notFound
    case unreadable(String)
    case newerFormat(Int)
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "That album is no longer in your library."
        case .unreadable(let why): "This file isn’t a Standard Music share. \(why)"
        case .newerFormat: "This album was shared from a newer version of Standard Music. Update the app to open it."
        case .archiveFailed(let why): "Couldn’t package the album. \(why)"
        }
    }
}

/// What an import did, for the confirmation toast.
public struct ShareImportResult: Sendable, Equatable {
    public var artistID: ID
    public var artistName: String
    public var firstAlbumID: ID?
    public var albumsAdded: Int
    public var albumsUpdated: Int
    public var recordingsAdded: Int
    public var artistWasNew: Bool
}

/// Packs and unpacks `.standardalbum` files. Paths in the database are relative to `libraryRoot`
/// (audio) and `artwork.root` (images), matching how the app stores them.
public struct ShareBundler: Sendable {
    public let db: AppDatabase
    public let libraryRoot: URL
    public let artwork: ArtworkStore

    public init(db: AppDatabase, libraryRoot: URL, artwork: ArtworkStore) {
        self.db = db
        self.libraryRoot = libraryRoot
        self.artwork = artwork
    }

    // MARK: Export

    public struct ExportSummary: Sendable {
        public var recorded: Int
        public var total: Int
        /// Bytes of audio that "Include recordings" would add.
        public var audioBytes: Int64
    }

    /// Size and recorded-song count, for the share sheet's "include recordings" choice.
    /// `albumIDs` empty means every album by the artist.
    public func summary(artistID: ID, albumIDs: [ID]) throws -> ExportSummary {
        let tracks = try db.reader.read { db in
            albumIDs.isEmpty
                ? try Track.filter(Column("artistID") == artistID).fetchAll(db)
                : try Track.filter(albumIDs.contains(Column("albumID"))).fetchAll(db)
        }
        var bytes: Int64 = 0
        var recorded = 0
        for track in tracks where track.isPlayable {
            recorded += 1
            if let path = track.audioPath, let size = Self.size(of: resolveAudio(path)) { bytes += size }
        }
        return ExportSummary(recorded: recorded, total: tracks.count, audioBytes: bytes)
    }

    /// Writes `<Artist> – <Album>.standardalbum` into `directory` and returns its URL.
    /// `albumIDs` empty means every album by the artist.
    public func export(
        artistID: ID, albumIDs: [ID], includeRecordings: Bool, sharedBy: String?, engine: String?,
        to directory: URL
    ) throws -> URL {
        let (artist, albums, tracks) = try db.reader.read { db -> (Artist, [Album], [Track]) in
            guard let artist = try Artist.fetchOne(db, key: artistID) else { throw ShareError.notFound }
            var request = Album.filter(Column("artistID") == artistID)
            if !albumIDs.isEmpty { request = request.filter(albumIDs.contains(Column("id"))) }
            let albums = try request.order(Column("releaseYear"), Column("createdAt")).fetchAll(db)
            guard !albums.isEmpty else { throw ShareError.notFound }
            let tracks = try Track.filter(albums.map(\.id).contains(Column("albumID")))
                .order(Column("discNumber"), Column("trackNumber")).fetchAll(db)
            return (artist, albums, tracks)
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging.appending(path: "artwork"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appending(path: "audio"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func copyArtwork(_ relative: String?, as name: String) -> String? {
            guard let relative else { return nil }
            let source = artwork.url(for: relative)
            guard fm.fileExists(atPath: source.path) else { return nil }
            let inside = "artwork/\(name).jpg"
            return (try? fm.copyItem(at: source, to: staging.appending(path: inside))) != nil ? inside : nil
        }

        let sharedArtist = SharedArtist(
            id: artist.id, name: artist.name, primaryGenre: artist.primaryGenre, genres: artist.genres,
            tags: artist.tags, origin: artist.origin, formedYear: artist.formedYear,
            disbandedYear: artist.disbandedYear, members: artist.members, tagline: artist.tagline, bio: artist.bio,
            soul: artist.soul, voice: artist.voice, touchstones: artist.touchstones, tier: artist.tier,
            plannedAlbumCount: artist.plannedAlbumCount, imagePrompt: artist.imagePrompt,
            accentHex: artist.accentHex, image: copyArtwork(artist.imagePath, as: "artist"))

        let byAlbum = Dictionary(grouping: tracks, by: \.albumID)
        var sharedAlbums: [SharedAlbum] = []
        for album in albums {
            var sharedTracks: [SharedTrack] = []
            for track in byAlbum[album.id] ?? [] {
                var audio: String?
                if includeRecordings, track.isPlayable, let path = track.audioPath {
                    let source = resolveAudio(path)
                    let inside = "audio/\(track.id).m4a"
                    if fm.fileExists(atPath: source.path),
                        (try? fm.copyItem(at: source, to: staging.appending(path: inside))) != nil
                    {
                        audio = inside
                    }
                }
                sharedTracks.append(
                    SharedTrack(
                        id: track.id, discNumber: track.discNumber, trackNumber: track.trackNumber,
                        title: track.title, details: track.details, styleTags: track.styleTags, lyrics: track.lyrics,
                        vocal: track.vocal, bpm: track.bpm, mood: track.mood, isInstrumental: track.isInstrumental,
                        seed: track.seed, audio: audio, duration: audio == nil ? nil : track.duration,
                        loudness: audio == nil ? nil : track.loudness))
            }
            sharedAlbums.append(
                SharedAlbum(
                    id: album.id, title: album.title, releaseYear: album.releaseYear, kind: album.kind,
                    label: album.label, primaryGenre: album.primaryGenre, genres: album.genres, notes: album.notes,
                    soul: album.soul, coverPrompt: album.coverPrompt, palette: album.palette,
                    cover: copyArtwork(album.coverPath, as: album.id), tracks: sharedTracks))
        }

        let manifest = ShareManifest(
            format: ShareManifest.currentFormat, exportedAt: Date(), sharedBy: sharedBy, engine: engine,
            artist: sharedArtist, albums: sharedAlbums)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appending(path: "manifest.json"))

        let title = albums.count == 1 ? "\(artist.name) – \(albums[0].title)" : artist.name
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "\(Self.safeFileName(title)).\(ShareManifest.fileExtension)")
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        // Recordings are already AAC, so storing them uncompressed costs nothing and packs fast.
        try Self.ditto(["-c", "-k", "--norsrc", "--noextattr", "--zlibCompressionLevel", "1", staging.path, output.path])
        return output
    }

    // MARK: Import

    /// Reads a share file's manifest without touching the library (for the import preview).
    public static func preview(_ file: URL) throws -> (manifest: ShareManifest, folder: URL) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try ditto(["-x", "-k", file.path, folder.path])
        } catch {
            try? fm.removeItem(at: folder)
            throw ShareError.unreadable("It may be damaged or still downloading.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: folder.appending(path: "manifest.json"))
        } catch {
            try? fm.removeItem(at: folder)
            throw ShareError.unreadable("It has no manifest.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Read the version first so a newer format gets a helpful message rather than a decode error.
        struct Version: Decodable { var format: Int }
        if let version = try? decoder.decode(Version.self, from: data), version.format > ShareManifest.currentFormat {
            try? fm.removeItem(at: folder)
            throw ShareError.newerFormat(version.format)
        }
        do {
            return (try decoder.decode(ShareManifest.self, from: data), folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw ShareError.unreadable(error.localizedDescription)
        }
    }

    /// Adds a previewed share to the library. Importing the same album twice is safe: existing
    /// items keep the listener's own favourites and history, and only gain what they were missing
    /// (new albums, recordings for songs not yet recorded here, lyrics).
    public func importShare(_ manifest: ShareManifest, from folder: URL) throws -> ShareImportResult {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        let shared = manifest.artist

        // Files first, outside the transaction: copy artwork and recordings into the library.
        func inArchive(_ path: String?) -> URL? {
            guard let path, !path.contains("..") else { return nil }
            let url = folder.appending(path: path)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let artistImage = inArchive(shared.image).flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? artwork.save($0, kind: .artist, id: shared.id) }
        var covers: [ID: String] = [:]
        for album in manifest.albums {
            if let data = inArchive(album.cover).flatMap({ try? Data(contentsOf: $0) }),
                let path = try? artwork.save(data, kind: .album, id: album.id)
            {
                covers[album.id] = path
            }
        }
        let audioDir = libraryRoot.appending(path: "Audio", directoryHint: .isDirectory)
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        var audio: [ID: String] = [:]
        for track in manifest.albums.flatMap(\.tracks) {
            guard let source = inArchive(track.audio) else { continue }
            let relative = "Audio/\(track.id).m4a"
            let target = libraryRoot.appending(path: relative)
            if fm.fileExists(atPath: target.path) { continue }
            if (try? fm.copyItem(at: source, to: target)) != nil { audio[track.id] = relative }
        }

        return try db.writer.write { db in
            var artistWasNew = false
            var artist: Artist
            if let existing = try Artist.fetchOne(db, key: shared.id) {
                artist = existing
                if artist.imagePath == nil { artist.imagePath = artistImage }
                if artist.soul.isEmpty { artist.soul = shared.soul }
                if artist.voice.isEmpty { artist.voice = shared.voice }
            } else {
                artistWasNew = true
                artist = Artist(
                    id: shared.id, name: shared.name, primaryGenre: shared.primaryGenre, genres: shared.genres,
                    tags: shared.tags, origin: shared.origin, formedYear: shared.formedYear, tagline: shared.tagline,
                    tier: shared.tier, plannedAlbumCount: shared.plannedAlbumCount, touchstones: shared.touchstones)
                artist.disbandedYear = shared.disbandedYear
                artist.members = shared.members
                artist.bio = shared.bio
                artist.soul = shared.soul
                artist.voice = shared.voice
                artist.imagePrompt = shared.imagePrompt
                artist.accentHex = shared.accentHex
                artist.imagePath = artistImage
                artist.status = .ready
            }
            try artist.save(db)
            try AppDatabase.index(db, artist: artist)

            var added = 0
            var updated = 0
            var recordings = 0
            for sharedAlbum in manifest.albums {
                var album: Album
                if let existing = try Album.fetchOne(db, key: sharedAlbum.id) {
                    album = existing
                    if album.coverPath == nil, let cover = covers[album.id] { album.coverPath = cover }
                    updated += 1
                } else {
                    album = Album(
                        id: sharedAlbum.id, artistID: artist.id, title: sharedAlbum.title,
                        releaseYear: sharedAlbum.releaseYear, kind: sharedAlbum.kind, label: sharedAlbum.label,
                        primaryGenre: sharedAlbum.primaryGenre, genres: sharedAlbum.genres, soul: sharedAlbum.soul,
                        coverPrompt: sharedAlbum.coverPrompt, trackCount: sharedAlbum.tracks.count)
                    album.notes = sharedAlbum.notes
                    album.palette = sharedAlbum.palette
                    album.coverPath = covers[album.id]
                    album.status = .ready
                    added += 1
                }
                try album.save(db)
                try AppDatabase.index(db, album: album, artistName: artist.name)

                for shared in sharedAlbum.tracks {
                    var track: Track
                    if let existing = try Track.fetchOne(db, key: shared.id) {
                        track = existing
                    } else {
                        track = Track(
                            id: shared.id, albumID: album.id, artistID: artist.id, discNumber: shared.discNumber,
                            trackNumber: shared.trackNumber, title: shared.title, details: shared.details,
                            styleTags: shared.styleTags, vocal: shared.vocal, bpm: shared.bpm, mood: shared.mood,
                            isInstrumental: shared.isInstrumental)
                        track.seed = shared.seed
                    }
                    if track.lyrics == nil { track.lyrics = shared.lyrics }
                    if !track.isPlayable, let path = audio[track.id] {
                        track.status = .ready
                        track.audioPath = path
                        track.duration = shared.duration
                        track.loudness = shared.loudness
                        track.generatedAt = manifest.exportedAt
                        recordings += 1
                    } else if track.status == .failed || track.status == .generating {
                        track.status = .pending
                    }
                    try track.save(db)
                    try AppDatabase.index(db, track: track, artistName: artist.name, albumTitle: album.title)
                }
            }
            return ShareImportResult(
                artistID: artist.id, artistName: artist.name, firstAlbumID: manifest.albums.first?.id,
                albumsAdded: added, albumsUpdated: updated, recordingsAdded: recordings, artistWasNew: artistWasNew)
        }
    }

    // MARK: Helpers

    private func resolveAudio(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : libraryRoot.appending(path: relative)
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    /// `ditto` ships with every Mac and writes standard zip files that Finder, Mail and AirDrop understand.
    static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ShareError.archiveFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

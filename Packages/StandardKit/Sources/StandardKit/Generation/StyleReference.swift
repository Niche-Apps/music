import Foundation
import GRDB

/// What the listener picked, plus an optional local audio measurement.
///
/// `genres`, `styleTags`, `mood`, and `vocal` are metadata: library fields or file tags.
/// `audio` is a separate measurement of the waveform when a recording could be decoded.
/// Audio samples, paths, and bookmarks are never stored here and never sent to a model.
public struct StyleCue: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case libraryAlbum, librarySong, file, folder
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var genres: [String]
    public var styleTags: String
    public var mood: String
    public var vocal: String
    public var bpm: Int?
    public var isInstrumental: Bool
    /// A short factual note for the text model ("12 songs"). Never a music-model tag and never a file path.
    public var note: String
    /// Local DSP report. Nil means the audio was not measured. Missing on references saved before analysis existed.
    public var audio: AudioStyleReport?

    public init(
        id: String = newID(), kind: Kind, title: String, artistName: String = "", albumTitle: String = "",
        genres: [String] = [], styleTags: String = "", mood: String = "", vocal: String = "", bpm: Int? = nil,
        isInstrumental: Bool = false, note: String = "", audio: AudioStyleReport? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.genres = genres
        self.styleTags = styleTags
        self.mood = mood
        self.vocal = vocal
        self.bpm = bpm
        self.isInstrumental = isInstrumental
        self.note = note
        self.audio = audio
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, artistName, albumTitle, genres, styleTags, mood, vocal, bpm, isInstrumental, note, audio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        artistName = try container.decodeIfPresent(String.self, forKey: .artistName) ?? ""
        albumTitle = try container.decodeIfPresent(String.self, forKey: .albumTitle) ?? ""
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        styleTags = try container.decodeIfPresent(String.self, forKey: .styleTags) ?? ""
        mood = try container.decodeIfPresent(String.self, forKey: .mood) ?? ""
        vocal = try container.decodeIfPresent(String.self, forKey: .vocal) ?? ""
        bpm = try container.decodeIfPresent(Int.self, forKey: .bpm)
        isInstrumental = try container.decodeIfPresent(Bool.self, forKey: .isInstrumental) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        audio = try container.decodeIfPresent(AudioStyleReport.self, forKey: .audio)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(artistName, forKey: .artistName)
        try container.encode(albumTitle, forKey: .albumTitle)
        try container.encode(genres, forKey: .genres)
        try container.encode(styleTags, forKey: .styleTags)
        try container.encode(mood, forKey: .mood)
        try container.encode(vocal, forKey: .vocal)
        try container.encodeIfPresent(bpm, forKey: .bpm)
        try container.encode(isInstrumental, forKey: .isInstrumental)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(audio, forKey: .audio)
    }

    public var kindLabel: String {
        switch kind {
        case .libraryAlbum: "Album"
        case .librarySong: "Song"
        case .file: "File"
        case .folder: "Folder"
        }
    }

    public static func decode(_ raw: String) -> [StyleCue] {
        guard let data = raw.data(using: .utf8), let cues = try? JSONDecoder().decode([StyleCue].self, from: data) else { return [] }
        return cues
    }

    public static func encode(_ cues: [StyleCue]) -> String {
        guard let data = try? JSONEncoder().encode(cues) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Track {
    public var decodedStyleCues: [StyleCue] { StyleCue.decode(styleCues) }

    public mutating func storeStyleCues(_ cues: [StyleCue]) {
        styleCues = StyleCue.encode(cues)
    }
}

/// A style pick as the Create screen stores it. Library rows point at the index. File and folder
/// rows keep a security-scoped bookmark so the app can check the item is still readable later.
/// `bookmark` and `path` stay on this Mac; `cue` is the only form that may enter a prompt.
public struct StyleReference: Codable, Sendable, Hashable, Identifiable {
    public enum Availability: String, Codable, Sendable {
        case available, missing, permissionDenied
    }

    public var id: String
    public var cue: StyleCue
    public var libraryID: String?
    public var bookmark: Data?
    public var path: String?
    public var availability: Availability

    public init(
        id: String = newID(), cue: StyleCue, libraryID: String? = nil, bookmark: Data? = nil, path: String? = nil,
        availability: Availability = .available
    ) {
        self.id = id
        self.cue = cue
        self.libraryID = libraryID
        self.bookmark = bookmark
        self.path = path
        self.availability = availability
    }

    /// The cue sent to generation. Missing and unreadable picks contribute nothing.
    public var promptCue: StyleCue? { availability == .available ? cue : nil }

    public static func libraryAlbum(
        id: ID, title: String, artistName: String, genres: [String], styleTags: String, mood: String,
        isInstrumental: Bool
    ) -> StyleReference {
        StyleReference(
            cue: StyleCue(
                kind: .libraryAlbum, title: title, artistName: artistName, genres: genres, styleTags: styleTags,
                mood: mood, isInstrumental: isInstrumental),
            libraryID: id)
    }

    public static func librarySong(
        id: ID, title: String, artistName: String, albumTitle: String, genres: [String], styleTags: String,
        mood: String, vocal: String, bpm: Int?, isInstrumental: Bool
    ) -> StyleReference {
        StyleReference(
            cue: StyleCue(
                kind: .librarySong, title: title, artistName: artistName, albumTitle: albumTitle, genres: genres,
                styleTags: styleTags, mood: mood, vocal: vocal, bpm: bpm, isInstrumental: isInstrumental),
            libraryID: id)
    }
}

/// Why a local file or folder couldn't be used. `cancelled` means the open panel was dismissed
/// or a read was cancelled before it finished; the previous selection stays as it was.
public enum StyleAccessError: String, Error, Sendable, Equatable {
    case cancelled
    case missing
    case permissionDenied
    case unreadable
}

/// Tags read locally from a file. No audio samples.
public struct StyleFileMeta: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var genres: [String]

    public init(title: String, artist: String = "", album: String = "", genres: [String] = []) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genres = genres
    }
}

public enum StyleReferenceStore {
    public static let storageKey = "create.styleReferences"
    /// How many picks are written into one prompt. The rest stay saved and visible.
    public static let maxPromptCues = 8

    public static func load(_ db: AppDatabase) -> [StyleReference] {
        db.value([StyleReference].self, forKey: storageKey) ?? []
    }

    public static func save(_ db: AppDatabase, _ references: [StyleReference]) throws {
        try db.setValue(references, forKey: storageKey)
    }

    /// Re-reads library albums and songs. A deleted row becomes `.missing` and drops out of prompts.
    public static func refreshLibrary(_ references: [StyleReference], in db: AppDatabase) throws -> [StyleReference] {
        try db.reader.read { database in
            try references.map { reference in
                guard reference.cue.kind == .libraryAlbum || reference.cue.kind == .librarySong else { return reference }
                guard let libraryID = reference.libraryID else {
                    var missing = reference
                    missing.availability = .missing
                    return missing
                }
                if reference.cue.kind == .libraryAlbum {
                    guard let info = try AppDatabase.albumInfos().filter(key: libraryID).fetchOne(database) else {
                        var missing = reference
                        missing.availability = .missing
                        return missing
                    }
                    let tracks = try Track.filter(Column("albumID") == info.album.id)
                        .order(Column("trackNumber")).fetchAll(database)
                    var updated = reference
                    updated.availability = .available
                    updated.cue = Self.albumCue(info: info, tracks: tracks, id: reference.cue.id)
                    return updated
                }
                guard let info = try AppDatabase.trackInfos().filter(key: libraryID).fetchOne(database) else {
                    var missing = reference
                    missing.availability = .missing
                    return missing
                }
                var updated = reference
                updated.availability = .available
                updated.cue = Self.songCue(info: info, id: reference.cue.id)
                return updated
            }
        }
    }

    public static func albumCue(info: AlbumInfo, tracks: [Track], id: String) -> StyleCue {
        let tags = uniqueTags(tracks.map(\.styleTags)).prefix(6).joined(separator: ", ")
        let mood = tracks.first(where: { !$0.mood.isEmpty })?.mood ?? ""
        return StyleCue(
            id: id, kind: .libraryAlbum, title: info.album.title, artistName: info.artist.name,
            genres: info.album.genres.isEmpty ? [info.album.primaryGenre] : info.album.genres,
            styleTags: tags, mood: mood,
            isInstrumental: !tracks.isEmpty && tracks.allSatisfy(\.isInstrumental),
            note: tracks.isEmpty ? "" : "\(tracks.count) songs in the library")
    }

    public static func songCue(info: TrackInfo, id: String) -> StyleCue {
        StyleCue(
            id: id, kind: .librarySong, title: info.track.title, artistName: info.artist.name,
            albumTitle: info.album.title,
            genres: info.album.genres.isEmpty ? [info.album.primaryGenre] : info.album.genres,
            styleTags: info.track.styleTags, mood: info.track.mood, vocal: info.track.vocal, bpm: info.track.bpm,
            isInstrumental: info.track.isInstrumental)
    }

    static func uniqueTags(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            for tag in VocalOnly.split(line) where seen.insert(tag.lowercased()).inserted {
                out.append(tag)
            }
        }
        return out
    }

    /// Applies a file-system check. Library rows are left to `refreshLibrary`.
    public static func applyFileResult(_ reference: StyleReference, result: Result<StyleFileMeta, StyleAccessError>) -> StyleReference {
        guard reference.cue.kind == .file || reference.cue.kind == .folder else { return reference }
        var updated = reference
        switch result {
        case .success(let meta):
            updated.availability = .available
            if reference.cue.kind == .file {
                updated.cue.title = meta.title.isEmpty ? reference.cue.title : meta.title
                updated.cue.artistName = meta.artist
                updated.cue.albumTitle = meta.album
                updated.cue.genres = meta.genres
            }
        case .failure(.missing):
            updated.availability = .missing
        case .failure(.permissionDenied):
            updated.availability = .permissionDenied
        case .failure(.unreadable):
            updated.availability = .permissionDenied
        case .failure(.cancelled):
            break
        }
        return updated
    }

    /// Open-panel result. Cancel keeps the previous list; a finished pick is appended, skipping duplicates.
    public static func integrate(current: [StyleReference], panelAccepted: Bool, imported: [StyleReference]) -> [StyleReference] {
        guard panelAccepted else { return current }
        var combined = current
        for reference in imported where !combined.contains(where: { samePick($0, reference) }) {
            combined.append(reference)
        }
        return combined
    }

    static func samePick(_ lhs: StyleReference, _ rhs: StyleReference) -> Bool {
        if let left = lhs.libraryID, let right = rhs.libraryID, lhs.cue.kind == rhs.cue.kind {
            return left == right
        }
        if let left = lhs.path, let right = rhs.path, !left.isEmpty {
            return left == right
        }
        return false
    }
}

public enum StyleFolder {
    /// One cue for a folder of files whose tags were already read. Throws `CancellationError` before
    /// producing a cue when `isCancelled` fires, so a cancelled import does not replace the saved list.
    public static func summarize(folderName: String, files: [StyleFileMeta], limit: Int = 40, isCancelled: () throws -> Void = {}) throws -> StyleCue {
        try isCancelled()
        var artists: [String] = []
        var albums: [String] = []
        var genres: [String] = []
        var titles: [String] = []
        var seenArtists = Set<String>()
        var seenAlbums = Set<String>()
        var seenGenres = Set<String>()
        let capped = files.prefix(limit)
        for (index, file) in capped.enumerated() {
            if index % 8 == 0 { try isCancelled() }
            if !file.artist.isEmpty, seenArtists.insert(file.artist.lowercased()).inserted { artists.append(file.artist) }
            if !file.album.isEmpty, seenAlbums.insert(file.album.lowercased()).inserted { albums.append(file.album) }
            for genre in file.genres where seenGenres.insert(genre.lowercased()).inserted { genres.append(genre) }
            if !file.title.isEmpty, titles.count < 8 { titles.append(file.title) }
        }
        let extra = files.count > capped.count ? files.count - capped.count : 0
        var note = "\(files.count) audio file\(files.count == 1 ? "" : "s"), tags only"
        if !titles.isEmpty { note += ". Includes \(titles.joined(separator: ", "))" }
        if extra > 0 { note += " and \(extra) more" }
        return StyleCue(
            kind: .folder, title: folderName,
            artistName: artists.prefix(4).joined(separator: ", "),
            albumTitle: albums.prefix(4).joined(separator: ", "),
            genres: Array(genres.prefix(6)),
            note: note)
    }
}

/// Assembles the words the text models and the music engine actually see.
public enum StylePipeline {
    /// Listener text wins over the instrumental switch. "Acapella" means sung and unaccompanied,
    /// which contradicts "no vocals".
    public static func vocalOnly(styleText: String, instrumentalToggle: Bool) -> Bool {
        if VocalOnly.requests(styleText) { return true }
        _ = instrumentalToggle
        return false
    }

    public static func promptCues(_ cues: [StyleCue]) -> [StyleCue] {
        Array(cues.prefix(StyleReferenceStore.maxPromptCues))
    }

    /// Paragraph appended to a generation prompt. Empty when the listener didn't constrain anything,
    /// so ordinary songs keep the prompts they had. Never includes a path, a bookmark, or audio.
    public static func promptAddendum(vocalOnly: Bool, cues: [StyleCue]) -> String {
        var parts: [String] = []
        let usable = promptCues(cues)
        if !usable.isEmpty {
            let lines = usable.map { cue -> String in
                var bits = ["\(cue.kindLabel) \"\(cue.title)\""]
                if !cue.artistName.isEmpty { bits.append("by \(cue.artistName)") }
                if !cue.albumTitle.isEmpty, cue.albumTitle.caseInsensitiveCompare(cue.title) != .orderedSame {
                    bits.append("album \"\(cue.albumTitle)\"")
                }
                if !cue.genres.isEmpty { bits.append("genres \(cue.genres.joined(separator: ", "))") }
                if !vocalOnly, !cue.styleTags.isEmpty { bits.append("tags \(cue.styleTags)") }
                if !cue.mood.isEmpty, !vocalOnly || !VocalOnly.namesInstrument(cue.mood) {
                    bits.append("mood \(cue.mood)")
                }
                if !vocalOnly, !cue.vocal.isEmpty { bits.append("vocal \(cue.vocal)") }
                if !vocalOnly, cue.isInstrumental {
                    bits.append("the reference is marked instrumental; that is a cue, not an instruction to remove vocals")
                }
                if vocalOnly, cue.isInstrumental || VocalOnly.namesInstrument(cue.styleTags) {
                    bits.append("ignore this reference's instruments")
                }
                if !cue.note.isEmpty { bits.append(cue.note) }
                return "- " + bits.joined(separator: ". ")
            }
            let measured = usable.compactMap { cue -> String? in
                guard let audio = cue.audio, audio.status != .unavailable else { return nil }
                return "- \(cue.kindLabel) \"\(cue.title)\": \(audio.promptSentence(vocalOnly: vocalOnly))"
            }
            parts.append(
                """
                Style reference metadata (not audio): the listener picked these. Names, genres, moods and tags below come from the library or from file tags. \
                They are not the result of listening. Audio was not uploaded.
                \(lines.joined(separator: "\n"))
                """)
            if !measured.isEmpty {
                parts.append(
                    """
                    Measured audio (decoded and analyzed on this Mac; the recording was not uploaded). \
                    These are signal measurements and threshold labels. They do not identify instruments, vocals, key, or genre.
                    \(measured.joined(separator: "\n"))
                    """)
            }
        }
        if vocalOnly {
            parts.append(
                """
                Vocal-only constraint (listener, hard): they asked for a cappella — vocals only, no instruments. \
                Keep that in the tags you write. Do not name guitars, drums, bass, synths, beats or any other instrument, \
                and do not mark the song instrumental. If a style reference is instrumental or names instruments, ignore those cues. \
                This constraint overrides the genre instrument lists above. The music model only receives these tags as guidance \
                and is not guaranteed to omit every instrument, so the tags themselves must say a cappella, vocals only, no instruments, unaccompanied.
                """)
        }
        return parts.joined(separator: "\n\n")
    }

    public static func appending(_ prompt: String, vocalOnly: Bool, cues: [StyleCue]) -> String {
        let extra = promptAddendum(vocalOnly: vocalOnly, cues: cues)
        guard !extra.isEmpty else { return prompt }
        return prompt + "\n\n" + extra
    }

    /// Reference cues folded into the tag line. A vocal-only listener drops instrumental cues.
    /// A reference marked instrumental does not flip a sung song to instrumental.
    public static func mergeTags(base: String, cues: [StyleCue], vocalOnly: Bool, allowInstrumentalCue: Bool) -> String {
        var parts = VocalOnly.split(base)
        var seen = Set(parts.map { $0.lowercased() })
        var extra: [String] = []
        for cue in promptCues(cues) {
            extra.append(contentsOf: cue.genres)
            if vocalOnly {
                if !cue.mood.isEmpty { extra.append(cue.mood) }
                extra.append(contentsOf: cue.audio?.engineTags(vocalOnly: true) ?? [])
            } else {
                extra.append(contentsOf: VocalOnly.split(cue.styleTags).prefix(4))
                if !cue.mood.isEmpty { extra.append(cue.mood) }
                if cue.isInstrumental && allowInstrumentalCue { extra.append("instrumental") }
                extra.append(contentsOf: cue.audio?.engineTags(vocalOnly: false) ?? [])
            }
        }
        if vocalOnly { extra = extra.filter { !VocalOnly.namesInstrument($0) } }
        for tag in extra where !tag.isEmpty && seen.insert(tag.lowercased()).inserted && parts.count < 18 {
            parts.append(tag)
        }
        return parts.joined(separator: ", ")
    }
}

/// The style line and instrumental flag on an `EngineJob`. Every engine (the bundled YuE2 helper
/// and any program in Settings › Studio) receives this and nothing richer. Vocal-only is advisory
/// tags plus `isInstrumental == false`; it is not a separate render mode.
public enum RecordingStyle {
    public struct Prepared: Sendable, Equatable {
        public var style: String
        public var isInstrumental: Bool
        /// True when the listener's vocal-only constraint was applied. The engine is not required to obey it.
        public var vocalOnlyAdvisory: Bool
    }

    public static func prepare(
        tags: String, genres: [String], voice: String, isInstrumental: Bool, isCustom: Bool, vocalOnly: Bool,
        cues: [StyleCue]
    ) -> Prepared {
        let sung = isInstrumental && !vocalOnly
        let base = isCustom
            ? GenreSound.customRecordingTags(tags: tags)
            : GenreSound.recordingTags(tags: tags, genres: genres)
        let merged = StylePipeline.mergeTags(base: base, cues: cues, vocalOnly: vocalOnly, allowInstrumentalCue: sung)
        let scrubbed = vocalOnly ? VocalOnly.enforce(merged) : merged
        let style = Voice.recordingStyle(tags: scrubbed, voice: voice, isInstrumental: sung, vocalOnly: vocalOnly)
        return Prepared(style: style, isInstrumental: sung, vocalOnlyAdvisory: vocalOnly)
    }
}

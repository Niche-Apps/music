import Foundation
import GRDB

/// A song the listener writes themselves (Create › Custom): their lyrics and a style of music,
/// performed by one of their artists or by a new artist invented to fit the style.
public struct CustomSongRequest: Sendable, Hashable {
    /// The listener's lyrics. Ignored when `instrumental` is true.
    public var lyrics: String
    /// Style of music in the listener's words ("90s grunge, female vocals, heavy").
    public var style: String
    public var title: String?
    public var instrumental: Bool
    /// Perform as this artist; nil invents a new one that fits the style.
    public var artistID: ID?
    /// Albums or songs the listener picked as style references. Metadata only.
    public var references: [StyleCue]

    public init(lyrics: String, style: String, title: String? = nil, instrumental: Bool = false, artistID: ID? = nil, references: [StyleCue] = []) {
        self.lyrics = lyrics
        self.style = style
        self.title = title
        self.instrumental = instrumental
        self.artistID = artistID
        self.references = references
    }
}

extension LibraryBuilder {
    struct CustomPayload: Decodable, Sendable {
        struct NewArtist: Decodable, Sendable {
            var name: String
            var origin: String
            var formedYear: Int
            var tagline: String
            var bio: String
            var soul: String
            var members: [String]
            var imagePrompt: String
        }
        var title: String
        var primaryGenre: String
        var genres: [String]
        var styleTags: String
        var lyrics: String
        var mood: String
        var bpm: Int
        var vocal: String
        var details: String
        var label: String
        var notes: String
        var coverConcept: String
        var artist: NewArtist?
    }

    /// Writes a single for the listener's own song and returns its album id. The track keeps the
    /// listener's words; the studio records it on demand like any other song.
    public func createCustomSong(_ request: CustomSongRequest) async throws -> ID {
        let style = request.style.trimmingCharacters(in: .whitespacesAndNewlines)
        let vocalOnly = StylePipeline.vocalOnly(styleText: style, instrumentalToggle: request.instrumental)
        let instrumental = request.instrumental && !vocalOnly
        let cues = StylePipeline.promptCues(request.references)
        let lyrics = instrumental ? "" : request.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty || !lyrics.isEmpty || !cues.isEmpty else { throw ChatGPTError.failed("Add some lyrics or a style of music.") }
        var existing: Artist?
        if let id = request.artistID {
            existing = try await db.reader.read { try Artist.fetchOne($0, key: id) }
        }
        let year = Calendar.current.component(.year, from: Date())

        var fields: [String: JSON] = [
            "title": Schema.string(),
            "primaryGenre": Schema.string("The single most fitting genre name, lowercase (e.g. \"grunge\", \"electropop\")"),
            "genres": Schema.array(Schema.string(), min: 1, max: 4),
            "styleTags": Schema.string(),
            "lyrics": Schema.string(),
            "mood": Schema.string(),
            "bpm": Schema.integer(),
            "vocal": Schema.string("Lead vocal for this song, e.g. \"female lead\", \"male lead\", \"duet\", \"none\""),
            "details": Schema.string(),
            "label": Schema.string(),
            "notes": Schema.string(),
            "coverConcept": Schema.string(),
        ]
        if existing == nil {
            fields["artist"] = Schema.object([
                "name": Schema.string(),
                "origin": Schema.string("City, Country"),
                "formedYear": Schema.integer(),
                "tagline": Schema.string(),
                "bio": Schema.string(),
                "soul": Schema.string(),
                "members": Schema.array(Schema.string()),
                "imagePrompt": Schema.string(),
            ])
        }
        let performer = existing.map { a in
            "Performed by \(a.name) (\(a.primaryGenre), \(a.origin)). Artist soul: \(a.soul.prefix(600))"
        } ?? """
            Performed by a brand-new fictional artist you invent to fit this song: a memorable, original name \
            (never a real artist's), a hometown, a short believable bio (60–110 words), a private soul (sonic identity, \
            voice, influences; 60–120 words), members (empty for a solo act) and an imagePrompt: art direction for \
            their press photo (60–110 words) built on this direction, keeping its framing, look, setting, light and casting:
            \(PortraitDirection.assign(genres: [style], isGroup: nil))
            """
        let prompt = StylePipeline.appending("""
            The listener wrote their own song in the studio. Honor what they asked for exactly.
            Style of music (their words): \(style.isEmpty ? "(none given — infer it from the lyrics)" : style)
            Title: \(request.title?.isEmpty == false ? request.title! : "(none — choose a fitting one from the lyrics)")
            \(instrumental ? "It's an instrumental." : "Their lyrics:\n\(lyrics.isEmpty ? "(none)" : lyrics)")
            \(performer)

            Return:
            - lyrics: \(instrumental
                ? "section headers only, each followed by an empty line: [Intro], [Verse], [Chorus], [Verse], [Chorus], [Bridge], [Chorus], [Outro]."
                : "the listener's lyrics with every word kept exactly as written. Only add section headers on their own lines ([Intro], [Verse], [Pre-Chorus], [Chorus], [Bridge], [Outro]) where they're missing, keep any they wrote, and put a blank line between sections. If no lyrics were given, write a complete song in the style.")
            - \(vocalOnly ? VocalOnly.tagInstruction : "styleTags: the tag line for the music model, 8–12 short comma-separated tags (one to three words each): genre and subgenre first, then 3–5 defining instruments in plain words, then mood and a tempo word. Keep everything the listener asked for (genre, era, instruments, mood, vocal gender) as tags. No sentences, no production phrases.")
            - primaryGenre/genres: what this style is, for the library.
            - details: one or two sentences on what the song is, sonically and emotionally.
            - notes: liner notes for the single, 40–80 words, written like a music editor (don't mention the listener).
            - label: a fictional record label. coverConcept: specific art direction for the single's cover.
            """, vocalOnly: vocalOnly, cues: cues)
        let schema = Schema.object(fields)
        let p = try await textLimit.run {
            try await self.client.json(
                CustomPayload.self, schemaName: "custom_song", schema: schema,
                instructions: "You are a record producer and A&R turning a listener's own song into a release. Keep their words; be specific and consistent.",
                prompt: prompt, effort: "low")
        }

        var artist: Artist
        if let existing {
            artist = existing
        } else {
            let a = p.artist
            artist = Artist(
                name: a?.name ?? "Unknown Artist", primaryGenre: p.primaryGenre, genres: p.genres, tags: p.genres,
                origin: a?.origin ?? "", formedYear: a?.formedYear ?? year, tagline: a?.tagline ?? "", tier: .core,
                plannedAlbumCount: 1)
            artist.bio = a?.bio ?? ""
            artist.soul = a?.soul ?? p.details
            artist.members = a?.members ?? []
            artist.imagePrompt = a?.imagePrompt
            try db.save(artist: artist)
            try await paintPortrait(artist)
            artist = try db.modifyArtist(artist.id) { $0.status = .ready } ?? artist
        }

        let title = (request.title?.isEmpty == false ? request.title! : p.title).trimmingCharacters(in: .whitespacesAndNewlines)
        var album = Album(
            artistID: artist.id, title: title, releaseYear: year, kind: .single, label: p.label,
            primaryGenre: p.primaryGenre, genres: p.genres, soul: p.details, coverPrompt: p.coverConcept, trackCount: 1)
        album.notes = p.notes
        var track = Track(
            albumID: album.id, artistID: artist.id, trackNumber: 1, title: title, details: p.details,
            styleTags: vocalOnly ? VocalOnly.enforce(p.styleTags) : p.styleTags,
            vocal: instrumental ? "none" : p.vocal, bpm: p.bpm, mood: p.mood,
            isInstrumental: instrumental)
        track.vocalOnly = vocalOnly
        track.storeStyleCues(cues)
        track.lyrics = Self.customLyrics(p.lyrics, fallback: lyrics, instrumental: instrumental)
        track.isExplicit = ContentRating.containsExplicitLanguage(track.lyrics ?? "")
        track.isCustom = true
        try db.save(album: album, tracks: [track])
        try await paintCover(album, artist: artist, urgent: true)
        _ = try db.modifyAlbum(album.id) { $0.status = .ready }
        return album.id
    }

    /// The lyrics to record: the model's sectioned version when it kept the listener's words,
    /// otherwise the listener's own text with a header added if it has none.
    static func customLyrics(_ sectioned: String, fallback: String, instrumental: Bool) -> String {
        if instrumental {
            return "[Intro]\n\n[Verse]\n\n[Chorus]\n\n[Verse]\n\n[Chorus]\n\n[Bridge]\n\n[Chorus]\n\n[Outro]\n"
        }
        let words = { (s: String) in
            s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
                .joined(separator: " ").lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let cleaned = SongWriter.clean(sectioned)
        if fallback.isEmpty || words(cleaned) == words(fallback) { return cleaned }
        // The model changed the words: keep the listener's exactly.
        return fallback.contains("[") ? SongWriter.clean(fallback) : SongWriter.clean("[Verse]\n" + fallback)
    }
}

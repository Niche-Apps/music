import Foundation

/// Writes lyrics (and refines the style tag line) right before a song is recorded.
public struct SongWriter: Sendable {
    let client: ChatGPTClient
    let db: AppDatabase

    public init(client: ChatGPTClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    struct Payload: Decodable, Sendable {
        var lyrics: String
        var styleTags: String
    }

    /// Ensures the artist has a fixed voice and the track has lyrics; returns the updated track.
    public func prepare(trackID: ID) async throws -> Track {
        guard var info = try db.trackInfo(trackID) else { throw ChatGPTError.failed("Missing track") }
        if info.artist.voice.isEmpty { info.artist.voice = try await ensureVoice(info.artist) }
        if let lyrics = info.track.lyrics, !lyrics.isEmpty { return info.track }
        let siblings = try db.tracks(forAlbum: info.album.id)
        let previous = siblings.filter { $0.trackNumber < info.track.trackNumber }.compactMap { t -> String? in
            guard let lyrics = t.lyrics else { return nil }
            return "\"\(t.title)\": \(lyrics.split(separator: "\n").filter { !$0.hasPrefix("[") }.prefix(2).joined(separator: " / "))"
        }
        let schema = Schema.object([
            "lyrics": Schema.string(),
            "styleTags": Schema.string(),
        ])
        let prompt = """
            Artist: \(info.artist.name) (\(info.artist.primaryGenre), \(info.artist.origin))
            Artist soul: \(info.artist.soul)
            Album: "\(info.album.title)" (\(info.album.releaseYear)). Album soul: \(info.album.soul)
            Track \(info.track.trackNumber) of \(siblings.count): "\(info.track.title)"
            Song notes: \(info.track.details)
            Current style tags: \(info.track.styleTags)
            The singer's voice (fixed): \(info.artist.voice). Lead: \(info.track.vocal). Tempo: \(info.track.bpm.map { "\($0) BPM" } ?? "natural"). Mood: \(info.track.mood).
            \(previous.isEmpty ? "" : "Earlier songs on the record (avoid repeating their images): \(previous.joined(separator: "; "))")

            Write the lyrics as this artist would — their voice, era and idiom — for a complete song of about 2½–4 minutes.
            Format strictly:
            - Section headers on their own line, from: [Intro], [Verse], [Pre-Chorus], [Chorus], [Bridge], [Interlude], [Outro]. [Intro], [Interlude] and [Outro] may be followed by an empty line for instrumental passages.
            - A blank line between sections. 4–6 short singable lines per verse, a memorable repeated chorus that appears 2–3 times verbatim.
            - Typically: [Intro], [Verse], [Pre-Chorus], [Chorus], [Verse], [Chorus], [Bridge], [Chorus], [Outro]. Adapt to the genre (e.g. fewer words for ambient/electronic, longer verses for hip hop).
            - No notes, no chords, no performer names, no title line.
            - If the song notes describe an instrumental or wordless piece, write only a few wordless vocal lines (e.g. "Ooh, ooh" or "Ah") or leave sections empty — but keep the section headers so the arrangement has a shape.
            styleTags: the final tag line for the music model: 9–18 comma-separated words — language, genre, era/production feel, 3–5 instruments, mood, tempo word. Never describe the singer; their fixed voice is added automatically.
            """
        let p = try await client.json(
            Payload.self, schemaName: "song", schema: schema,
            instructions: "You are a gifted songwriter who writes in other artists' voices. Concrete images, natural rhyme, no clichés.",
            prompt: prompt, effort: "low")
        let lyrics = Self.clean(p.lyrics)
        let tags = p.styleTags.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.modifyTrack(trackID) {
            $0.lyrics = lyrics
            if !tags.isEmpty { $0.styleTags = tags }
        } ?? info.track
    }

    /// Gives an artist written before voices existed a permanent voice, derived from their soul and the
    /// vocals of songs already recorded. The first writer wins so concurrent songs agree.
    func ensureVoice(_ artist: Artist) async throws -> String {
        struct VoicePayload: Decodable, Sendable { var voice: String }
        let recorded = try await db.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT styleTags FROM track WHERE artistID = ? AND status = 'ready' LIMIT 3",
                arguments: [artist.id])
        }
        let prompt = """
            Artist: \(artist.name) (\(artist.primaryGenre), \(artist.origin)). Members: \(artist.members.joined(separator: "; "))
            Artist soul: \(artist.soul)
            \(recorded.isEmpty ? "" : "Tag lines of songs already recorded (keep the voice consistent with them): \(recorded.joined(separator: " | "))")

            \(Voice.fieldGuidance)
            """
        let p = try await client.json(
            VoicePayload.self, schemaName: "artist_voice", schema: Schema.object(["voice": Schema.string()]),
            instructions: "You are a vocal producer casting the permanent lead voice of an artist.", prompt: prompt,
            effort: "low")
        let voice = p.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return "" }
        return try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE artist SET voice = ? WHERE id = ? AND voice = ''", arguments: [voice, artist.id])
            return try String.fetchOne(db, sql: "SELECT voice FROM artist WHERE id = ?", arguments: [artist.id]) ?? voice
        }
    }

    /// Normalises section headers and spacing for the music model.
    static func clean(_ text: String) -> String {
        var out: [String] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let name = line[line.index(after: line.startIndex) ..< close].lowercased()
                let canonical =
                    name.contains("pre") ? "Pre-Chorus" : name.contains("chorus") || name.contains("hook") ? "Chorus"
                    : name.contains("verse") ? "Verse" : name.contains("bridge") ? "Bridge" : name.contains("intro") ? "Intro"
                    : name.contains("outro") || name.contains("end") ? "Outro" : "Interlude"
                line = "[\(canonical)]"
                if let last = out.last, !last.isEmpty { out.append("") }
            }
            if line.isEmpty, out.last?.isEmpty == true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

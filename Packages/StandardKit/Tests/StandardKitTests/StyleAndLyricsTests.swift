import Foundation
import Testing
@testable import StandardKit

@Suite struct VocalOnlyTests {
    @Test func synonymsMatch() {
        for text in [
            "acapella", "Acapella", "a cappella", "A Cappella", "a-cappella", "acappella",
            "no instruments", "no instrumentation", "without instruments", "without any instruments",
            "vocals only", "vocal only", "vocal-only", "voices only", "only vocals",
            "unaccompanied", "unaccompanied vocals", "singing only", "just vocals",
            "nothing but vocals", "she said no instruments",
        ] {
            #expect(VocalOnly.requests(text), "\(text)")
        }
    }

    @Test func negationsAndNearMissesDoNotMatch() {
        for text in [
            "not acapella", "no acapella", "not a cappella", "don't want acapella", "dont want a cappella",
            "not really acapella", "not no instruments", "without a cappella", "no, instruments",
            "with instruments", "instrumental", "not instrumental", "90s grunge, heavy guitars, female vocals",
            "lots of instrumentals",
        ] {
            #expect(!VocalOnly.requests(text), "\(text)")
        }
    }

    @Test func enforceDropsInstrumentsAndKeepsTheConstraint() {
        let tags = VocalOnly.enforce("electropop, synthesizer, drum machine, distorted guitar, bright, fast")
        #expect(tags.contains("a cappella"))
        #expect(tags.contains("vocals only"))
        #expect(tags.contains("no instruments"))
        #expect(tags.contains("unaccompanied"))
        #expect(tags.contains("electropop"))
        #expect(tags.contains("bright"))
        #expect(!tags.lowercased().contains("guitar"))
        #expect(!tags.lowercased().contains("drum"))
        #expect(!tags.lowercased().contains("synth"))
        #expect(VocalOnly.enforce(tags) == tags)
    }

    @Test func vocalOnlyVoiceKeepsAdvisoryTagsAndDropsInstrumentalVoice() {
        let style = Voice.recordingStyle(
            tags: "folk, a cappella, vocals only, no instruments, unaccompanied",
            voice: "instrumental", isInstrumental: true, vocalOnly: true)
        #expect(style.contains("vocals only"))
        #expect(style.hasSuffix("unaccompanied vocal"))
        #expect(!style.contains("instrumental"))
    }
}

@Suite struct StyleReferenceTests {
    func database() throws -> AppDatabase {
        let dir = FileManager.default.temporaryDirectory.appending(path: "style-\(UUID())")
        return try AppDatabase(url: dir.appending(path: "Library.sqlite"))
    }

    @Test func promptsUseMetadataAndNeverTheBookmarkOrPath() {
        var reference = StyleReference(
            cue: StyleCue(
                kind: .libraryAlbum, title: "Static Bloom", artistName: "The Glass Weather",
                genres: ["shoegaze"], styleTags: "distorted guitar, drums", mood: "hazy", isInstrumental: true),
            libraryID: "album-1", bookmark: Data("BEGIN_BOOKMARK_SECRET".utf8), path: "/Users/private/Library/secret-track.m4a")
        reference.availability = .available
        let prompt = StylePipeline.promptAddendum(vocalOnly: true, cues: [reference.promptCue].compactMap { $0 })
        #expect(prompt.contains("Static Bloom"))
        #expect(prompt.contains("Vocal-only constraint"))
        #expect(prompt.contains("ignore this reference's instruments"))
        #expect(!prompt.contains("BEGIN_BOOKMARK_SECRET"))
        #expect(!prompt.contains("secret-track"))
        #expect(!prompt.contains("distorted guitar"))
        let encoded = StyleCue.encode([reference.cue])
        #expect(!encoded.contains("BEGIN_BOOKMARK_SECRET"))
        #expect(!encoded.contains("secret-track"))
    }

    @Test func instrumentalReferenceDoesNotFlipASungSong() {
        let cue = StyleCue(
            kind: .librarySong, title: "Quiet Engines", artistName: "The Glass Weather", albumTitle: "Static Bloom",
            genres: ["shoegaze"], styleTags: "distorted guitar, live drums", mood: "hazy", isInstrumental: true)
        let plain = StylePipeline.mergeTags(base: "indie rock, warm", cues: [cue], vocalOnly: false, allowInstrumentalCue: false)
        #expect(plain.contains("distorted guitar"))
        #expect(!plain.contains("instrumental"))
        let vocal = RecordingStyle.prepare(
            tags: "electropop, synthesizer, drum machine, bright", genres: ["electropop"], voice: "female alto vocal, bright",
            isInstrumental: false, isCustom: false, vocalOnly: true, cues: [cue])
        #expect(!vocal.isInstrumental)
        #expect(vocal.vocalOnlyAdvisory)
        #expect(vocal.style.contains("a cappella"))
        #expect(vocal.style.contains("no instruments"))
        #expect(!vocal.style.lowercased().contains("guitar"))
        #expect(!vocal.style.lowercased().contains("drum"))
        #expect(!vocal.style.lowercased().contains("synth"))
        #expect(vocal.style.contains("female alto vocal, bright"))
    }

    @Test func cancelAndMissingAndPermissionStayOutOfThePrompt() throws {
        let db = try database()
        let kept = StyleReference(cue: StyleCue(kind: .file, title: "Kept"), path: "/tmp/kept.m4a")
        let imported = StyleReference(cue: StyleCue(kind: .file, title: "New"), path: "/tmp/new.m4a")
        #expect(StyleReferenceStore.integrate(current: [kept], panelAccepted: false, imported: [imported]) == [kept])
        #expect(StyleReferenceStore.integrate(current: [kept], panelAccepted: true, imported: [imported]).count == 2)

        let gone = StyleReference.librarySong(
            id: "missing-song", title: "Gone", artistName: "Nobody", albumTitle: "Nowhere", genres: ["pop"],
            styleTags: "guitar", mood: "sad", vocal: "female", bpm: 90, isInstrumental: false)
        let refreshed = try StyleReferenceStore.refreshLibrary([gone], in: db)
        #expect(refreshed[0].availability == .missing)
        #expect(refreshed[0].promptCue == nil)
        #expect(StylePipeline.promptAddendum(vocalOnly: false, cues: refreshed.compactMap(\.promptCue)).isEmpty)

        let denied = StyleReferenceStore.applyFileResult(kept, result: .failure(.permissionDenied))
        #expect(denied.availability == .permissionDenied)
        #expect(denied.promptCue == nil)

        #expect(throws: CancellationError.self) {
            _ = try StyleFolder.summarize(folderName: "Folder", files: [StyleFileMeta(title: "One")], isCancelled: { throw CancellationError() })
        }
    }

    @Test func referencesRoundTripWithTheBookmark() throws {
        let db = try database()
        let reference = StyleReference(
            cue: StyleCue(kind: .file, title: "Björk — Jóga", artistName: "Björk", albumTitle: "Homogenic", genres: ["electronic"]),
            bookmark: Data("bookmark-bytes".utf8), path: "/Users/private/Jóga.flac")
        try StyleReferenceStore.save(db, [reference])
        let loaded = StyleReferenceStore.load(db)
        #expect(loaded == [reference])
        #expect(loaded[0].bookmark == Data("bookmark-bytes".utf8))
    }

    @Test func newColumnsDefaultAndOldBatchRequestsStillDecode() throws {
        let db = try database()
        var artist = Artist(name: "The Glass Weather", primaryGenre: "shoegaze", genres: ["shoegaze"], formedYear: 1991, tier: .core, plannedAlbumCount: 1)
        try db.save(artist: artist)
        let album = Album(artistID: artist.id, title: "Static Bloom", releaseYear: 1994, kind: .album, primaryGenre: "shoegaze", genres: ["shoegaze"], trackCount: 1)
        let track = Track(albumID: album.id, artistID: artist.id, trackNumber: 1, title: "Halo Feedback", details: "", styleTags: "shoegaze", vocal: "female", bpm: 100, mood: "hazy")
        try db.save(album: album, tracks: [track])
        let stored = try #require(try db.reader.read { try Track.fetchOne($0, key: track.id) })
        #expect(stored.vocalOnly == false)
        #expect(stored.styleCues == "[]")

        let old = #"{"artistCount":4,"prompt":"a cappella folk","coreShare":0.6,"adjacentShare":0.3}"#
        let request = try JSONDecoder().decode(BuildRequest.self, from: Data(old.utf8))
        #expect(request.artistCount == 4)
        #expect(request.vocalOnly)
        #expect(request.styleCues.isEmpty)
        let again = try JSONDecoder().decode(BuildRequest.self, from: JSONEncoder().encode(request))
        #expect(again == request)
    }
}

@Suite struct LyricsLookupTests {
    @Test(arguments: [
        "Björk", "AC/DC", "Guns N' Roses", "A & B", "What?", "C#", "100%", "Say \"Hello\"", "星野 源", "🎤 Voices",
        "a/b", "line\nbreak", "tab\there", "null\u{0000}byte",
    ])
    func specialCharactersRoundTrip(field: String) throws {
        let outcome = LyricsLookup.webSearch(title: field, artist: "Artist & Co", album: "Album #1")
        guard case .webSearch(let url, let notice) = outcome else {
            Issue.record("expected a search for \(field)")
            return
        }
        let query = try #require(LyricsLookup.query(in: url))
        #expect(url.scheme == "https")
        #expect(url.host == "www.google.com")
        #expect(!query.contains("\n"))
        #expect(!query.contains("\u{0000}"))
        #expect(query.hasSuffix("lyrics"))
        #expect(query.contains("Artist & Co"))
        #expect(query.contains("Album #1"))
        #expect(notice.includedArtist && notice.includedAlbum)
        #expect(notice.message.contains("doesn’t download"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.count == 1)
        #expect(items[0].name == "q")
    }

    @Test func missingFieldsDoNotCrashOrInventASong() {
        #expect(LyricsLookup.lookUp(title: "  ", artist: "Björk", album: "Homogenic", localLyrics: nil) == .missingTitle)
        #expect(LyricsLookup.webSearch(title: "", artist: "", album: "") == .missingTitle)
        #expect(LyricsLookup.webSearch(title: "\n\t", artist: "X", album: "Y") == .missingTitle)
        guard case .webSearch(let url, let notice) = LyricsLookup.webSearch(title: "Hello", artist: " ", album: "") else {
            Issue.record("title-only search")
            return
        }
        #expect(LyricsLookup.query(in: url) == "\"Hello\" lyrics")
        #expect(!notice.includedArtist && !notice.includedAlbum)
        #expect(notice.message.contains("artist and album weren’t available"))
        guard case .webSearch(let withAlbum, let albumNotice) = LyricsLookup.webSearch(title: "Hello", artist: "", album: "Vespertine") else {
            Issue.record("album search")
            return
        }
        #expect(LyricsLookup.query(in: withAlbum) == "\"Hello\" \"Vespertine\" lyrics")
        #expect(!albumNotice.includedArtist && albumNotice.includedAlbum)
    }

    @Test func localLyricsWinAndTheSearchDoesNotCarryOtherFields() {
        #expect(LyricsLookup.lookUp(title: "Halo", artist: "Glass", album: "Bloom", localLyrics: "[Verse]\nOnly this") == .showLocal)
        #expect(!LyricsLookup.hasSingableLyrics("[Intro]\n\n[Verse]\n"))
        #expect(!LyricsLookup.hasSingableLyrics(nil))
        #expect(!LyricsLookup.hasSingableLyrics("   \n[Chorus]"))
        let cueSecret = "soul-text-should-not-appear styleTags-secret /Users/private/audio.m4a"
        guard case .webSearch(let url, _) = LyricsLookup.webSearch(title: "Halo", artist: "The Glass Weather", album: "Static Bloom") else {
            Issue.record("search")
            return
        }
        let query = LyricsLookup.query(in: url)
        #expect(query == "\"Halo\" \"The Glass Weather\" \"Static Bloom\" lyrics")
        #expect(query?.contains(cueSecret) == false)
        #expect(url.absoluteString.contains("audio.m4a") == false)
    }
}

@Suite struct StylePipelineProviderTests {
    final class Script: @unchecked Sendable {
        var bodies: [String]
        var requests: [URLRequest] = []
        init(_ bodies: [String]) { self.bodies = bodies }
        func take(_ request: URLRequest) -> (Int, Data) {
            requests.append(request)
            let body = bodies.isEmpty ? "{}" : bodies.removeFirst()
            return (200, Data(body.utf8))
        }
        func blob() -> String {
            requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        }
    }

    func jwt() -> String {
        func part(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let exp = Date().timeIntervalSince1970 + 86_400
        let claims: [String: Any] = [
            "exp": exp,
            "email": "test@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct_test", "chatgpt_plan_type": "plus"],
        ]
        return "\(part(["alg": "none"])).\(part(claims)).x"
    }

    func client(_ provider: AIProvider, script: Script) async throws -> ChatGPTClient {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gpt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if provider == .chatGPT {
            let token = jwt()
            let creds = try ChatGPTCredentials(idToken: token, accessToken: token, refreshToken: "refresh-token")
            try JSONEncoder().encode(creds).write(to: directory.appending(path: "chatgpt-auth.json"))
        }
        let auth = ChatGPTAuth(directory: directory)
        let openRouter: OpenRouterClient.Transport? = provider == .openRouter ? { request in
            let (status, data) = script.take(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, http)
        } : nil
        let chatGPT: ChatGPTClient.ResponseTransport? = provider == .chatGPT ? { script.take($0) } : nil
        let client = ChatGPTClient(auth: auth, openRouterTransport: openRouter, responseTransport: chatGPT)
        if provider == .openRouter {
            await client.configureOpenRouter(apiKey: "test-key", writing: "openrouter/free", fast: "openrouter/free", imageModel: nil)
        }
        return client
    }

    func sse(_ json: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": json])
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    func openRouterChat(_ json: String) -> String {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": json]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    func wrapped(_ provider: AIProvider, _ json: String) -> String {
        provider == .chatGPT ? sse(json) : openRouterChat(json)
    }

    /// A 1×1 PNG. The image call only needs bytes that decode; it does not have to be a real photo.
    var tinyImageJSON: String {
        #"{"data":[{"b64_json":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}]}"#
    }

    func jsonObject(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func builder(provider: AIProvider, script: Script) async throws -> (LibraryBuilder, AppDatabase) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lib-\(UUID())")
        let db = try AppDatabase(url: directory.appending(path: "Library.sqlite"))
        let client = try await client(provider, script: script)
        let artwork = ArtworkStore(root: directory.appending(path: "Artwork"))
        return (LibraryBuilder(db: db, client: client, catalog: nil, artwork: artwork), db)
    }

    func cue() -> StyleCue {
        StyleCue(
            kind: .libraryAlbum, title: "Static Bloom", artistName: "The Glass Weather", genres: ["shoegaze"],
            styleTags: "distorted guitar, drums", mood: "hazy", isInstrumental: true)
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func customSongSendsReferencesAndKeepsVocalOnly(provider: AIProvider) async throws {
        let custom = jsonObject([
            "title": "Voices", "primaryGenre": "electropop", "genres": ["electropop"],
            "styleTags": "electropop, synthesizer, drum machine, distorted guitar, bright",
            "lyrics": "[Verse]\nOnly voices\n\n[Chorus]\nOnly voices", "mood": "bright", "bpm": 120,
            "vocal": "female lead", "details": "Voices in an empty room.", "label": "North",
            "notes": "A short single sung with no band around it at all.", "coverConcept": "A white room.",
        ])
        let script = Script(provider == .chatGPT ? [wrapped(provider, custom), tinyImageJSON] : [wrapped(provider, custom)])
        let (builder, db) = try await builder(provider: provider, script: script)
        var artist = Artist(name: "North Room", primaryGenre: "electropop", genres: ["electropop"], formedYear: 2019, tier: .core, plannedAlbumCount: 1)
        artist.voice = "female alto vocal, bright"
        artist.status = .ready
        try db.save(artist: artist)
        let albumID = try await builder.createCustomSong(CustomSongRequest(
            lyrics: "", style: "acapella electropop", instrumental: true, artistID: artist.id, references: [cue()]))
        let track = try #require(try db.tracks(forAlbum: albumID).first)
        #expect(track.vocalOnly)
        #expect(!track.isInstrumental)
        #expect(track.styleTags.contains("a cappella"))
        #expect(!track.styleTags.lowercased().contains("guitar"))
        #expect(!track.styleTags.lowercased().contains("drum"))
        #expect(track.decodedStyleCues.first?.title == "Static Bloom")
        let blob = script.blob()
        #expect(blob.contains("Vocal-only constraint"))
        #expect(blob.contains("Static Bloom"))
        #expect(blob.contains("Style reference metadata"))
        #expect(!blob.contains("BEGIN_BOOKMARK_SECRET"))
        let prepared = RecordingStyle.prepare(
            tags: track.styleTags, genres: ["electropop"], voice: artist.voice, isInstrumental: track.isInstrumental,
            isCustom: track.isCustom, vocalOnly: track.vocalOnly, cues: track.decodedStyleCues)
        #expect(!prepared.isInstrumental)
        #expect(prepared.style.contains("no instruments"))
        #expect(!prepared.style.lowercased().contains("guitar"))
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func negatedAcapellaDoesNotStripInstruments(provider: AIProvider) async throws {
        let custom = jsonObject([
            "title": "Guitars", "primaryGenre": "rock", "genres": ["rock"],
            "styleTags": "rock, distorted guitar, live drums, loud",
            "lyrics": "[Verse]\nTurn it up", "mood": "loud", "bpm": 140, "vocal": "male lead",
            "details": "A loud rock song.", "label": "North", "notes": "Loud on purpose, with a full band.",
            "coverConcept": "A red stage.",
        ])
        let script = Script(provider == .chatGPT ? [wrapped(provider, custom), tinyImageJSON] : [wrapped(provider, custom)])
        let (builder, db) = try await builder(provider: provider, script: script)
        var artist = Artist(name: "North Room", primaryGenre: "rock", genres: ["rock"], formedYear: 2019, tier: .core, plannedAlbumCount: 1)
        artist.status = .ready
        try db.save(artist: artist)
        let albumID = try await builder.createCustomSong(CustomSongRequest(
            lyrics: "", style: "not acapella, distorted guitars", artistID: artist.id))
        let track = try #require(try db.tracks(forAlbum: albumID).first)
        #expect(!track.vocalOnly)
        #expect(track.styleTags.contains("distorted guitar"))
        #expect(!script.blob().contains("Vocal-only constraint"))
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func rewriteAndAlbumAndRosterKeepTheConstraint(provider: AIProvider) async throws {
        let song = jsonObject([
            "lyrics": "[Verse]\nOnly voices here\n\n[Chorus]\nOnly voices here",
            "styleTags": "metal, distorted guitar, drums, harsh", "explicit": false,
        ])
        let albumJSON = jsonObject([
            "notes": "Voices only, from the first note to the last.",
            "genres": ["folk"],
            "tracks": [[
                "title": "Unison", "details": "Voices.", "styleTags": "folk, acoustic guitar, soft drums, gentle",
                "vocal": "female", "bpm": 80, "mood": "gentle",
            ]],
        ])
        let roster = jsonObject([
            "artists": [[
                "name": "Choir North", "primaryGenre": "folk", "genres": ["folk", "a cappella"],
                "tags": ["voices", "choir", "unaccompanied"], "origin": "Oslo, Norway", "formedYear": 2012,
                "tagline": "Voices only", "albumCount": 1, "touchstones": ["A Real Choir", "Another Choir"],
            ]],
        ])
        let script = Script([wrapped(provider, song), wrapped(provider, albumJSON), wrapped(provider, roster)])
        let directory = FileManager.default.temporaryDirectory.appending(path: "pipe-\(UUID())")
        let db = try AppDatabase(url: directory.appending(path: "Library.sqlite"))
        let chat = try await client(provider, script: script)
        let library = LibraryBuilder(db: db, client: chat, catalog: nil, artwork: ArtworkStore(root: directory.appending(path: "Artwork")))
        var artist = Artist(name: "Choir North", primaryGenre: "folk", genres: ["folk"], formedYear: 2012, tier: .core, plannedAlbumCount: 1)
        artist.voice = "female alto vocal, clear"
        artist.soul = "Unaccompanied."
        artist.status = .written
        let batch = GenerationBatch(kind: .prompt, title: "acapella", request: String(decoding: try JSONEncoder().encode(BuildRequest(artistCount: 1, prompt: "acapella folk", styleCues: [cue()])), as: UTF8.self), targetArtists: 1)
        artist.batchID = batch.id
        try db.writer.write { try batch.insert($0) }
        try db.save(artist: artist)
        var album = Album(artistID: artist.id, title: "Static Bloom", releaseYear: 2020, kind: .album, primaryGenre: "folk", genres: ["folk"], soul: "Voices.", trackCount: 1)
        album.status = .planned
        var track = Track(albumID: album.id, artistID: artist.id, trackNumber: 1, title: "Voices", details: "Guitars were the model's idea.", styleTags: "folk, acoustic guitar", vocal: "female", bpm: 80, mood: "gentle")
        track.vocalOnly = true
        track.storeStyleCues([cue()])
        try db.save(album: album, tracks: [track])

        let rewritten = try await SongWriter(client: chat, db: db).prepare(trackID: track.id)
        #expect(rewritten.vocalOnly)
        #expect(rewritten.styleTags.contains("a cappella"))
        #expect(!rewritten.styleTags.lowercased().contains("guitar"))
        #expect(LyricsLookup.hasSingableLyrics(rewritten.lyrics))

        let written = try await library.writeAlbum(album, artist: artist)
        let albumTrack = try #require(try db.tracks(forAlbum: written.id).first)
        #expect(albumTrack.vocalOnly)
        #expect(albumTrack.styleTags.contains("no instruments"))
        #expect(!albumTrack.styleTags.lowercased().contains("guitar"))
        #expect(albumTrack.decodedStyleCues.first?.title == "Static Bloom")

        try await library.rosterChunk(
            [LibraryBuilder.Slot(tier: .core, genre: "folk")], batch: batch, profile: TasteProfile(),
            request: BuildRequest(artistCount: 1, prompt: "acapella folk", styleCues: [cue()]), seed: nil)
        let blob = script.blob()
        #expect(blob.contains("Vocal-only constraint"))
        #expect(blob.contains("Static Bloom"))
        #expect(!blob.contains("BEGIN_BOOKMARK"))
        let hosts = Set(script.requests.compactMap { $0.url?.host })
        #expect(hosts == (provider == .openRouter ? ["openrouter.ai"] : ["chatgpt.com"]))
    }
}

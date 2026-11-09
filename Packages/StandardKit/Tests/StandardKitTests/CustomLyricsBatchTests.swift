import Foundation
import Testing
@testable import StandardKit

@Suite struct CustomLyricsBatchPlannerTests {
    private func decide(_ ids: [ID], extra: Int, provider: AIProvider = .chatGPT, model: String? = nil) -> CustomLyricsBatchDecision {
        CustomLyricsBatchPlanner.decide(
            artistIDs: ids, newArtistCount: extra, provider: provider, openRouterModel: model, minutesPerRecording: 7)
    }

    @Test func duplicatesAreRemovedAndOrderIsKept() {
        let decision = decide(["a", "b", "a", "c", "b"], extra: 1)
        let selection = decision.selection
        #expect(selection?.artistIDs == ["a", "b", "c"])
        #expect(selection?.duplicatesRemoved == 2)
        #expect(selection?.newArtistCount == 1)
        #expect(selection?.songCount == 4)
        if case .needsConfirmation = decision {} else { Issue.record("4 songs should ask first") }
    }

    @Test func boundsAndConfirmation() {
        if case .ready(let selection, _) = decide(["a"], extra: 0) {
            #expect(selection.songCount == 1)
        } else { Issue.record("one song can start") }
        if case .ready(let selection, _) = decide([], extra: 3) {
            #expect(selection.songCount == 3)
        } else { Issue.record("three new artists can start") }
        if case .needsConfirmation(let selection, _) = decide([], extra: 4) {
            #expect(selection.songCount == CustomLyricsBatchPlanner.confirmFrom)
        } else { Issue.record("four songs should ask") }
        if case .invalid(let message) = decide([], extra: 0) {
            #expect(message.contains("at least one"))
        } else { Issue.record("empty batch is invalid") }
        if case .invalid = decide([], extra: 25) {} else { Issue.record("25 is over the maximum") }
        if case .ready(let selection, _) = decide(["a"], extra: -4) {
            #expect(selection.newArtistCount == 0)
            #expect(selection.songCount == 1)
        } else { Issue.record("a negative extra count is ignored") }
    }

    @Test func costNamesTheCurrentModelAndDoesNotSwitchToAPaidBackup() {
        let free = CustomLyricsBatchPlanner.cost(
            songCount: 4, provider: .openRouter, openRouterModel: nil, minutesPerRecording: 7)
        #expect(free.textIsFree)
        #expect(free.summary.contains("openrouter/free"))
        #expect(free.summary.contains("$0"))
        #expect(free.summary.contains("will not switch"))
        #expect(free.summary.contains("time only"))
        #expect(!free.summary.contains(OpenRouterCatalog.cheapBackupModel))

        let paid = CustomLyricsBatchPlanner.cost(
            songCount: 4, provider: .openRouter, openRouterModel: "google/gemini-2.5-flash-lite", minutesPerRecording: 7)
        #expect(!paid.textIsFree)
        #expect(paid.summary.contains("google/gemini-2.5-flash-lite"))
        #expect(paid.summary.contains("$10"))
        #expect(paid.summary.contains("will not change that model"))
        #expect(paid.summary.contains("time only"))

        let chat = CustomLyricsBatchPlanner.cost(songCount: 2, provider: .chatGPT, openRouterModel: nil, minutesPerRecording: 7)
        #expect(chat.summary.contains("ChatGPT"))
        #expect(chat.summary.contains("time only"))
        #expect(chat.summary.contains("does not turn on a paid OpenRouter model"))
        #expect(CustomLyricsBatchPlanner.isFreeOpenRouterModel("vendor/model:free"))
        #expect(!CustomLyricsBatchPlanner.isFreeOpenRouterModel("google/gemini-2.5-flash-lite"))
    }
}

@Suite struct CustomLyricsBatchProviderTests {
    final class Script: @unchecked Sendable {
        var bodies: [String]
        var requests: [URLRequest] = []
        var failAt: Int?
        var armStop: (@Sendable () -> Void)?
        init(_ bodies: [String]) { self.bodies = bodies }
        func take(_ request: URLRequest) -> (Int, Data) {
            requests.append(request)
            armStop?()
            if let failAt, requests.count == failAt {
                return (403, Data(#"{"error":{"message":"no"}}"#.utf8))
            }
            let body = bodies.isEmpty ? "{}" : bodies.removeFirst()
            return (200, Data(body.utf8))
        }
        func blob() -> String {
            requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        }
        var openRouterTransport: OpenRouterClient.Transport {
            { [self] request in
                let (status, data) = take(request)
                let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
                return (data, http)
            }
        }
        var chatGPTTransport: ChatGPTClient.ResponseTransport {
            { [self] request in take(request) }
        }
    }

    final class StopFlag: @unchecked Sendable {
        var stop = false
    }

    final class ProgressLog: @unchecked Sendable {
        var labels: [String] = []
        func add(_ progress: CustomLyricsBatchProgress) { labels.append(progress.label) }
    }

    func jwt() -> String {
        func part(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let exp = Date().timeIntervalSince1970 + 86_400
        let claims: [String: Any] = [
            "exp": exp, "email": "test@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct_test", "chatgpt_plan_type": "plus"],
        ]
        return "\(part(["alg": "none"])).\(part(claims)).x"
    }

    func client(_ provider: AIProvider, script: Script) async throws -> ChatGPTClient {
        let directory = FileManager.default.temporaryDirectory.appending(path: "batch-gpt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if provider == .chatGPT {
            let token = jwt()
            let creds = try ChatGPTCredentials(idToken: token, accessToken: token, refreshToken: "refresh-token")
            try JSONEncoder().encode(creds).write(to: directory.appending(path: "chatgpt-auth.json"))
        }
        let auth = ChatGPTAuth(directory: directory)
        let made = ChatGPTClient(
            auth: auth,
            openRouterTransport: provider == .openRouter ? script.openRouterTransport : nil,
            responseTransport: provider == .chatGPT ? script.chatGPTTransport : nil)
        if provider == .openRouter {
            await made.configureOpenRouter(apiKey: "test-key", writing: "openrouter/free", fast: "openrouter/free", imageModel: nil)
        }
        return made
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

    func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    var imageBody: String {
        #"{"data":[{"b64_json":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}]}"#
    }

    func song(styleTags: String, name: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "title": "Same Title", "primaryGenre": "folk", "genres": ["folk"], "styleTags": styleTags,
            "lyrics": "[Verse]\nOnly these words remain\n\n[Chorus]\nOnly these words remain",
            "mood": "hushed", "bpm": 80, "vocal": "female lead", "details": "Voices.",
            "label": "North", "notes": "A short single sung with the listener's own words.",
            "coverConcept": "A white room.",
        ]
        if let name {
            object["artist"] = [
                "name": name, "origin": "Oslo, Norway", "formedYear": 2012, "tagline": "Voices",
                "bio": "A singer.", "soul": "Unaccompanied.", "members": [String](), "imagePrompt": "A person.",
            ]
        }
        return object
    }

    func builder(_ provider: AIProvider, script: Script) async throws -> (LibraryBuilder, AppDatabase) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "batch-lib-\(UUID())")
        let db = try AppDatabase(url: directory.appending(path: "Library.sqlite"))
        let chat = try await client(provider, script: script)
        return (LibraryBuilder(db: db, client: chat, catalog: nil, artwork: ArtworkStore(root: directory.appending(path: "Artwork"))), db)
    }

    func saveArtist(_ db: AppDatabase, name: String, soul: String) throws -> Artist {
        var artist = Artist(name: name, primaryGenre: "rock", genres: ["rock"], formedYear: 1994, tier: .core, plannedAlbumCount: 1)
        artist.soul = soul
        artist.voice = "female alto vocal, clear"
        artist.status = .ready
        try db.save(artist: artist)
        return artist
    }

    func responses(_ provider: AIProvider, songs: [String], imagesPerSong: Int) -> [String] {
        var out: [String] = []
        for song in songs {
            out.append(wrapped(provider, song))
            if provider == .chatGPT {
                for _ in 0 ..< imagesPerSong { out.append(imageBody) }
            }
        }
        return out
    }

    static let bookmarkSecret = "BEGIN_BOOKMARK_SECRET_9f3a"
    static let pathSecret = "/Users/private/BEGIN_PATH_SECRET.wav"

    func sentCue() -> StyleCue {
        let measured = MeasuredAudioFeatures(
            sampleRate: 44_100, sourceDuration: 12, analyzedSeconds: 12, rmsDBFS: -18, peakDBFS: -3,
            crestDB: 15, silenceRatio: 0.01, spectralCentroidHz: 1800, spectralFlatness: 0.2,
            lowEnergy: 0.2, midEnergy: 0.6, highEnergy: 0.2, tempoBPM: nil, tempoConfidence: 0)
        let report = AudioStyleReport(
            algorithmVersion: 1, fingerprint: nil, status: .measured, measured: measured,
            inferred: InferredAudioDescriptors(words: ["darker", "noisy"], notes: ["threshold"]),
            confidence: 0.8, limitation: "Not instrument identification.", coverage: "One file.",
            samples: [AudioTrackSample(label: "Static Bloom", status: .measured, analyzedSeconds: 12, sourceDuration: 12)])
        let cue = StyleCue(
            kind: .libraryAlbum, title: "Static Bloom", artistName: "The Glass Weather", genres: ["shoegaze"],
            styleTags: "distorted guitar, drums", isInstrumental: true, audio: report)
        let reference = StyleReference(
            cue: cue, bookmark: Data(Self.bookmarkSecret.utf8), path: Self.pathSecret)
        #expect(reference.promptCue != nil)
        let encoded = StyleCue.encode([reference.promptCue].compactMap { $0 })
        #expect(!encoded.contains(Self.bookmarkSecret))
        #expect(!encoded.contains("BEGIN_PATH_SECRET"))
        return reference.promptCue ?? cue
    }

    func lyricBodies(_ script: Script) -> [String] {
        script.requests.compactMap { request in
            let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return text.contains("Only these words remain") ? text : nil
        }
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func eachArtistGetsTheSameLyricsAndKeepsVocalOnly(provider: AIProvider) async throws {
        let songs = [
            json(song(styleTags: "folk, distorted guitar, live drums, bright")),
            json(song(styleTags: "rock, electric guitar, drums, loud")),
        ]
        let script = Script(responses(provider, songs: songs, imagesPerSong: 1))
        let (builder, db) = try await builder(provider, script: script)
        let north = try saveArtist(db, name: "North Room", soul: "SOUL_NORTH")
        let south = try saveArtist(db, name: "South Room", soul: "SOUL_SOUTH")
        let log = ProgressLog()
        let plan = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "a cappella, folk", title: "Same Title", instrumental: true,
            references: [sentCue()], artistIDs: [north.id, north.id, south.id], newArtistCount: 0)
        let result = await builder.createCustomLyricsBatch(plan, onProgress: { log.add($0) })
        #expect(result.successes.count == 2)
        #expect(result.failures.isEmpty)
        #expect(!result.cancelled)
        #expect(log.labels == ["North Room", "South Room"])
        let texts = lyricBodies(script)
        #expect(texts.count == 2)
        #expect(texts[0].contains("North Room") && texts[0].contains("SOUL_NORTH"))
        #expect(texts[1].contains("South Room") && texts[1].contains("SOUL_SOUTH"))
        for text in texts {
            #expect(text.contains("Vocal-only constraint"))
            #expect(text.contains("Static Bloom"))
            #expect(text.contains("Spectral centroid"))
            #expect(text.contains("1800 Hz"))
            #expect(text.contains("darker"))
            #expect(!text.contains("noisy"))
            #expect(!text.contains("distorted guitar, drums"))
            #expect(text.contains("ignore this reference's instruments"))
            #expect(text.contains("Their lyrics"))
            #expect(!text.contains("It's an instrumental."))
            #expect(!text.contains(Self.bookmarkSecret))
            #expect(!text.contains("BEGIN_PATH_SECRET"))
            #expect(!text.contains("gemini-2.5-flash-lite"))
        }
        if provider == .openRouter {
            // JSONEncoder writes the model as "openrouter\/free", so a raw substring search for
            // "openrouter/free" misses the field the client actually sent. Decode it. This batch
            // is configured for that free router and procedural artwork: every call stays on
            // chat/completions, that model, and no image modalities.
            #expect(script.requests.count == texts.count)
            #expect(script.requests.count == 2)
            for request in script.requests {
                let raw = try #require(request.httpBody)
                let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
                let model = try #require(body["model"] as? String)
                #expect(model == OpenRouterCatalog.defaultModel)
                #expect(CustomLyricsBatchPlanner.isFreeOpenRouterModel(model))
                #expect(model != OpenRouterCatalog.cheapBackupModel)
                #expect(body["modalities"] == nil)
                #expect(request.url?.path.hasSuffix("chat/completions") == true)
            }
        } else {
            #expect(texts.allSatisfy { !$0.contains("openrouter/free") })
            #expect(script.requests.contains { $0.url?.path.contains("responses") == true })
            #expect(script.requests.contains { $0.url?.path.contains("images") == true })
        }
        let albums = try await db.reader.read { try Album.fetchAll($0) }
        #expect(albums.count == 2)
        #expect(Set(albums.compactMap(\.batchID)) == [result.batchID])
        let info = try #require(try db.albumInfo(albums[0].id))
        #expect(info.album.batchID == result.batchID)
        #expect(info.artist.batchID == nil)
        let storedBatch = try await db.reader.read { try GenerationBatch.fetchOne($0, key: result.batchID) }
        let batch = try #require(storedBatch)
        #expect(batch.kind == .customLyrics)
        #expect(batch.status == .finished)
        #expect(batch.request.contains("Only these words remain"))
        #expect(batch.request.contains(north.id) && batch.request.contains(south.id))
        #expect(!batch.request.contains(Self.bookmarkSecret))
        #expect(!batch.request.contains("BEGIN_PATH_SECRET"))
        let tracks = try await db.reader.read { try Track.fetchAll($0) }
        #expect(tracks.count == 2)
        #expect(Set(tracks.map(\.artistID)) == [north.id, south.id])
        let lyricWords = tracks.map { ($0.lyrics ?? "").lowercased().filter { $0.isLetter } }
        #expect(Set(lyricWords).count == 1)
        #expect(lyricWords.count == 2)
        #expect(lyricWords.allSatisfy { $0.contains("onlythesewordsremain") })
        for track in tracks {
            #expect(track.vocalOnly)
            #expect(!track.isInstrumental)
            #expect(track.isCustom)
            #expect(!track.styleTags.lowercased().contains("guitar"))
            #expect(!track.styleTags.lowercased().contains("drum"))
            #expect(track.styleTags.contains("a cappella"))
            #expect(!track.styleCues.contains(Self.bookmarkSecret))
            #expect(!track.styleCues.contains("BEGIN_PATH_SECRET"))
            #expect(track.styleCues.contains("Static Bloom"))
            let storedArtist = try await db.reader.read { try Artist.fetchOne($0, key: track.artistID) }
            let artist = try #require(storedArtist)
            let album = try #require(albums.first { $0.id == track.albumID })
            let genres = album.primaryGenre.isEmpty || album.primaryGenre == artist.primaryGenre
                ? [artist.primaryGenre] + artist.genres : [album.primaryGenre] + album.genres
            let prepared = RecordingStyle.prepare(
                tags: track.styleTags, genres: genres, voice: artist.voice, isInstrumental: track.isInstrumental,
                isCustom: track.isCustom, vocalOnly: track.vocalOnly, cues: track.decodedStyleCues)
            #expect(prepared.vocalOnlyAdvisory)
            #expect(!prepared.isInstrumental)
            #expect(prepared.style.contains("a cappella"))
            #expect(prepared.style.contains("vocals only"))
            #expect(prepared.style.contains("no instruments"))
            #expect(prepared.style.contains("unaccompanied"))
            #expect(prepared.style.contains("darker"))
            #expect(!prepared.style.contains("noisy"))
            #expect(!prepared.style.lowercased().contains("guitar"))
            #expect(!prepared.style.lowercased().contains("drum"))
            #expect(prepared.style.contains(artist.voice))
        }
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func newArtistsAreToldNotToReuseNames(provider: AIProvider) async throws {
        let songs = [json(song(styleTags: "indie rock, electric guitar", name: "Alpha Wave")), json(song(styleTags: "indie rock, bass guitar", name: "Beta Wave"))]
        let script = Script(responses(provider, songs: songs, imagesPerSong: 2))
        let (builder, db) = try await builder(provider, script: script)
        let plan = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "a cappella, indie", title: nil, instrumental: true,
            references: [], artistIDs: [], newArtistCount: 2)
        let result = await builder.createCustomLyricsBatch(plan)
        #expect(result.successes.map(\.artistName).sorted() == ["Alpha Wave", "Beta Wave"])
        let texts = lyricBodies(script)
        #expect(texts.count == 2)
        #expect(!texts[0].contains("Do not name the new artist"))
        #expect(texts[1].contains("Only these words remain"))
        #expect(texts[1].contains("Do not name the new artist any of these: Alpha Wave"))
        #expect(texts.allSatisfy { $0.contains("Vocal-only constraint") && !$0.contains("It's an instrumental.") })
        let ids = Set(result.successes.compactMap(\.artistID))
        #expect(ids.count == 2)
        let albums = try await db.reader.read { try Album.fetchAll($0) }
        #expect(Set(albums.compactMap(\.batchID)) == [result.batchID])
        let tracks = try await db.reader.read { try Track.fetchAll($0) }
        #expect(tracks.count == 2)
        for track in tracks {
            #expect(track.vocalOnly)
            #expect(!track.isInstrumental)
            #expect(!track.styleTags.lowercased().contains("guitar"))
            #expect(track.styleTags.contains("a cappella"))
            let prepared = RecordingStyle.prepare(
                tags: track.styleTags, genres: ["indie"], voice: "unaccompanied vocal", isInstrumental: track.isInstrumental,
                isCustom: track.isCustom, vocalOnly: track.vocalOnly, cues: track.decodedStyleCues)
            #expect(!prepared.isInstrumental)
            #expect(prepared.style.contains("a cappella"))
            #expect(!prepared.style.lowercased().contains("guitar"))
        }
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func oneFailureDoesNotCancelTheRest(provider: AIProvider) async throws {
        let script = Script(responses(provider, songs: [json(song(styleTags: "folk, guitar"))], imagesPerSong: 1))
        script.failAt = provider == .chatGPT ? 3 : 2
        let (builder, db) = try await builder(provider, script: script)
        let north = try saveArtist(db, name: "North Room", soul: "SOUL_NORTH")
        let south = try saveArtist(db, name: "South Room", soul: "SOUL_SOUTH")
        let plan = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "folk", title: "Same Title", instrumental: false,
            references: [], artistIDs: [north.id, south.id], newArtistCount: 0)
        let result = await builder.createCustomLyricsBatch(plan)
        #expect(result.successes.map(\.artistName) == ["North Room"])
        #expect(result.failures.map(\.artistName) == ["South Room"])
        #expect(result.failures.first?.error?.contains("403") == true)
        #expect(!result.cancelled)
        let storedBatch = try await db.reader.read { try GenerationBatch.fetchOne($0, key: result.batchID) }
        let batch = try #require(storedBatch)
        #expect(batch.status == .finished)
        let albumCount = try await db.reader.read { try Album.fetchCount($0) }
        #expect(albumCount == 1)
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func cancellationKeepsFinishedSongsAndSkipsTheRest(provider: AIProvider) async throws {
        let script = Script(responses(provider, songs: [json(song(styleTags: "folk, gentle"))], imagesPerSong: 1))
        let flag = StopFlag()
        script.armStop = { [flag] in flag.stop = true }
        let (builder, db) = try await builder(provider, script: script)
        let north = try saveArtist(db, name: "North Room", soul: "SOUL_NORTH")
        let south = try saveArtist(db, name: "South Room", soul: "SOUL_SOUTH")
        let plan = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "folk", title: "Same Title", instrumental: false,
            references: [], artistIDs: [north.id, south.id], newArtistCount: 0)
        let result = await builder.createCustomLyricsBatch(plan, shouldStop: { [flag] in flag.stop })
        #expect(result.cancelled)
        #expect(result.successes.map(\.artistName) == ["North Room"])
        #expect(!script.blob().contains("SOUL_SOUTH"))
        let storedBatch = try await db.reader.read { try GenerationBatch.fetchOne($0, key: result.batchID) }
        let batch = try #require(storedBatch)
        #expect(batch.status == .cancelled)
        let albumCount = try await db.reader.read { try Album.fetchCount($0) }
        #expect(albumCount == 1)
    }

    @Test(arguments: [AIProvider.chatGPT, AIProvider.openRouter])
    func aMissingArtistDoesNotStopTheNextSong(provider: AIProvider) async throws {
        let script = Script(responses(provider, songs: [json(song(styleTags: "folk, gentle"))], imagesPerSong: 1))
        let (builder, db) = try await builder(provider, script: script)
        let north = try saveArtist(db, name: "North Room", soul: "SOUL_NORTH")
        let plan = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "folk", title: "Same Title", instrumental: false,
            references: [], artistIDs: ["missing-artist", north.id], newArtistCount: 0)
        let result = await builder.createCustomLyricsBatch(plan)
        #expect(result.failures.map(\.artistName) == ["Unknown artist"])
        #expect(result.failures.first?.error?.contains("no longer in the library") == true)
        #expect(result.successes.map(\.artistName) == ["North Room"])
        #expect(!result.cancelled)
        #expect(lyricBodies(script).count == 1)
        #expect(lyricBodies(script)[0].contains("SOUL_NORTH"))
    }

    @Test func theBuilderRefusesAnEmptyOrOversizedBatchWithoutCallingAModel() async throws {
        let script = Script([])
        let (builder, db) = try await builder(.chatGPT, script: script)
        let empty = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "folk", title: nil, instrumental: false,
            references: [], artistIDs: [], newArtistCount: 0)
        let none = await builder.createCustomLyricsBatch(empty)
        #expect(none.successes.isEmpty)
        #expect(none.songs.first?.error?.contains("at least one") == true)
        let ids = (0 ..< 25).map { "artist-\($0)" }
        let huge = CustomLyricsBatchPlan(
            lyrics: "Only these words remain", style: "folk", title: nil, instrumental: false,
            references: [], artistIDs: ids, newArtistCount: 0)
        let refused = await builder.createCustomLyricsBatch(huge)
        #expect(refused.successes.isEmpty)
        #expect(refused.songs.first?.error?.contains("24") == true)
        #expect(script.requests.isEmpty)
        let statuses = try await db.reader.read { try GenerationBatch.fetchAll($0).map(\.status) }
        #expect(statuses.count == 2)
        #expect(statuses.allSatisfy { $0 == .failed })
    }

    @Test func customSongsAreNotResumedAsRosterAlbumsAndOldAlbumsStillLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "batch-resume-\(UUID())")
        let db = try AppDatabase(url: directory.appending(path: "Library.sqlite"))
        var artist = Artist(name: "North Room", primaryGenre: "rock", genres: ["rock"], formedYear: 1994, tier: .core, plannedAlbumCount: 1)
        artist.status = .ready
        try db.save(artist: artist)

        var roster = Album(artistID: artist.id, title: "Unfinished", releaseYear: 1999, kind: .album, primaryGenre: "rock", genres: ["rock"], trackCount: 1)
        let rosterTrack = Track(albumID: roster.id, artistID: artist.id, trackNumber: 1, title: "Draft", details: "", styleTags: "rock", vocal: "none", bpm: nil, mood: "x", isInstrumental: false)
        try db.save(album: roster, tracks: [rosterTrack])

        var custom = Album(artistID: artist.id, title: "Custom", releaseYear: 2020, kind: .single, primaryGenre: "folk", genres: ["folk"], trackCount: 1)
        custom.status = .planned
        var customTrack = Track(albumID: custom.id, artistID: artist.id, trackNumber: 1, title: "Custom", details: "", styleTags: "folk", vocal: "alto", bpm: 80, mood: "hushed", isInstrumental: false)
        customTrack.isCustom = true
        customTrack.vocalOnly = true
        try db.save(album: custom, tracks: [customTrack])

        var batched = Album(artistID: artist.id, title: "Batched", releaseYear: 2020, kind: .single, primaryGenre: "folk", genres: ["folk"], trackCount: 1)
        batched.batchID = "batch-kept"
        batched.status = .planned
        let batchedTrack = Track(albumID: batched.id, artistID: artist.id, trackNumber: 1, title: "Batched", details: "", styleTags: "folk", vocal: "alto", bpm: 80, mood: "hushed", isInstrumental: false)
        try db.save(album: batched, tracks: [batchedTrack])

        var finished = Album(artistID: artist.id, title: "Already There", releaseYear: 1998, kind: .album, primaryGenre: "rock", genres: ["rock"], trackCount: 1)
        finished.status = .ready
        let finishedTrack = Track(albumID: finished.id, artistID: artist.id, trackNumber: 1, title: "Old", details: "", styleTags: "rock", vocal: "none", bpm: nil, mood: "x", isInstrumental: false)
        try db.save(album: finished, tracks: [finishedTrack])

        let ids = try db.reader.read { try LibraryBuilder.releasesToFinish($0).map(\.id) }
        #expect(ids == [roster.id])
        let loadedOld = try #require(try db.reader.read { try Album.fetchOne($0, key: finished.id) })
        #expect(loadedOld.batchID == nil)
        let loadedBatch = try #require(try db.albumInfo(batched.id))
        #expect(loadedBatch.album.batchID == "batch-kept")
        #expect(loadedBatch.artist.batchID == nil)
        let loadedCustom = try #require(try db.reader.read { try Track.fetchOne($0, key: customTrack.id) })
        #expect(loadedCustom.isCustom)
        #expect(loadedCustom.vocalOnly)
    }
}

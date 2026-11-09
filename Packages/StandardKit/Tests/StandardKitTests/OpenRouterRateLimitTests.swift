import Foundation
import GRDB
import Testing
@testable import StandardKit

@Suite struct OpenRouterFreeChainTests {
    @Test func freeChainStaysFreeUntilAnExplicitPaidModelIsEnabled() {
        let off = OpenRouterFreeChain.order(
            starting: "openrouter/free", catalogFree: ["google/gemma-3-12b-it:free"],
            paid: OpenRouterPaidFallback(enabled: false, modelID: "openai/gpt-4o-mini"))
        #expect(off == ["openrouter/free", "meta-llama/llama-3.3-70b-instruct:free", "google/gemma-3-12b-it:free"])
        #expect(!off.contains("openai/gpt-4o-mini"))
        #expect(OpenRouterPaidFallback(enabled: true, modelID: "x/y:free").activeModelID == nil)
        #expect(OpenRouterPaidFallback.weeklyCapNote.contains("$10"))
        let on = OpenRouterPaidFallback(enabled: true, modelID: " openai/gpt-4o-mini ")
        #expect(on.activeModelID == "openai/gpt-4o-mini")
        let withPaid = OpenRouterFreeChain.order(starting: "openrouter/free", catalogFree: [], paid: on)
        #expect(withPaid.last == "openai/gpt-4o-mini")
        #expect(OpenRouterFreeChain.order(starting: "vendor/paid", catalogFree: ["openrouter/free"], paid: on) == ["vendor/paid"])
    }

    @Test func retryAfterIsHonoredAndCapped() {
        #expect(OpenRouterFreeChain.delay(status: 429, retryAfter: 2, attempt: 1) == 2)
        #expect(OpenRouterFreeChain.delay(status: 429, retryAfter: 600, attempt: 1) == OpenRouterFreeChain.retryAfterCap)
        #expect(OpenRouterFreeChain.delay(status: 503, retryAfter: nil, attempt: 1) == 2)
    }
}

@Suite struct OpenRouterTransportTests {
    final class Script: @unchecked Sendable {
        typealias Response = (Int, String, String?)
        let lock = NSLock()
        var responses: [Response]
        var requests: [URLRequest] = []
        var timeouts = 0
        init(_ responses: [Response]) { self.responses = responses }
        func take(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            lock.lock()
            requests.append(request)
            if timeouts > 0 {
                timeouts -= 1
                lock.unlock()
                throw URLError(.timedOut)
            }
            let next = responses.isEmpty ? nil : responses.removeFirst()
            lock.unlock()
            let (status, body, retry) = next ?? (500, "{}", nil as String?)
            var headers: [String: String] = [:]
            if let retry { headers["Retry-After"] = retry }
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), http)
        }
        func models() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return requests.compactMap { request in
                guard let data = request.httpBody, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return body["model"] as? String
            }
        }
    }

    func client(_ script: Script, model: String = "openrouter/free", paid: OpenRouterPaidFallback = .off, clock: ManualClock = ManualClock()) -> (OpenRouterClient, ManualClock) {
        let made = OpenRouterClient(apiKey: "k", transport: { try script.take($0) }, clock: clock, paidFallback: paid)
        return (made, clock)
    }

    @Test func retries429UsingRetryAfterThenSucceeds() async throws {
        let script = Script([
            (429, #"{"error":{"message":"slow down"}}"#, "2"),
            (200, chat(#"{"name":"A","age":1}"#), nil as String?),
        ])
        let clock = ManualClock()
        let (client, _) = client(script, model: "vendor/paid", clock: clock)
        let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "i", prompt: "p", model: "vendor/paid")
        #expect(try JSONDecoder().decode(Pet.self, from: data) == Pet(name: "A", age: 1))
        #expect(script.requests.count == 2)
        #expect(clock.slept == [2])
        #expect(script.requests.allSatisfy { $0.timeoutInterval == OpenRouterFreeChain.requestTimeout })
    }

    @Test func free429WalksTheFreeChainAndStopsBeforeAPaidModel() async {
        let limit: Script.Response = (429, #"{"error":{"message":"rate"}}"#, "0")
        let script = Script(Array(repeating: limit, count: OpenRouterFreeChain.builtIn.count * OpenRouterFreeChain.maxAttemptsPerModel))
        let (client, clock) = client(script)
        await #expect {
            _ = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "openrouter/free")
        } throws: { error in
            if case ChatGPTError.exhausted(let message) = error { return !message.isEmpty }
            return false
        }
        let models = script.models()
        #expect(models.count == OpenRouterFreeChain.builtIn.count * OpenRouterFreeChain.maxAttemptsPerModel)
        #expect(models.allSatisfy { OpenRouterCatalog.isFreeModel($0) })
        #expect(!models.contains("openai/gpt-4o-mini"))
        #expect(!models.contains(OpenRouterCatalog.cheapBackupModel))
        #expect(!clock.slept.isEmpty)
    }

    @Test func paidFallbackRunsOnlyAfterFreeModelsAreRateLimited() async throws {
        let limit: Script.Response = (429, #"{"error":{"message":"rate"}}"#, "1")
        var responses = Array(repeating: limit, count: OpenRouterFreeChain.builtIn.count * OpenRouterFreeChain.maxAttemptsPerModel)
        responses.append((200, chat(#"{"name":"Z","age":9}"#), nil as String?))
        let script = Script(responses)
        let paid = OpenRouterPaidFallback(enabled: true, modelID: "openai/gpt-4o-mini")
        let (client, _) = client(script, paid: paid)
        let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "openrouter/free")
        #expect(try JSONDecoder().decode(Pet.self, from: data).name == "Z")
        #expect(script.models().last == "openai/gpt-4o-mini")
        #expect(script.models().dropLast().allSatisfy { OpenRouterCatalog.isFreeModel($0) })
    }

    @Test func timeoutIsBoundedAndTriesTheNextFreeModel() async throws {
        let script = Script([(200, chat(#"{"name":"Rex","age":4}"#), nil as String?)])
        script.timeouts = OpenRouterFreeChain.maxAttemptsPerModel
        let (client, _) = client(script)
        let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "openrouter/free")
        #expect(try JSONDecoder().decode(Pet.self, from: data).name == "Rex")
        #expect(script.models().prefix(OpenRouterFreeChain.maxAttemptsPerModel).allSatisfy { $0 == "openrouter/free" })
        #expect(script.models().last == "meta-llama/llama-3.3-70b-instruct:free")
    }

    @Test func timeoutsSurfaceWhenEveryFreeModelHangs() async {
        let script = Script([])
        script.timeouts = 50
        let (client, _) = client(script, model: "vendor/paid")
        await #expect {
            _ = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "vendor/paid")
        } throws: { error in
            if case ChatGPTError.exhausted(let message) = error { return message.contains("timed out") }
            return false
        }
        #expect(script.requests.count == OpenRouterFreeChain.maxAttemptsPerModel)
    }

    @Test func nullContentUsesReasoningOnce() async throws {
        let body = #"{"choices":[{"message":{"content":null,"reasoning":"note {\"name\":\"R\",\"age\":2}"}}]}"#
        let script = Script([(200, body, nil as String?)])
        let (client, _) = client(script, model: "vendor/paid")
        let data = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "vendor/paid")
        #expect(try JSONDecoder().decode(Pet.self, from: data).name == "R")
        #expect(script.requests.count == 1)
        let raw = try #require(script.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func reasoningWithoutJSONDoesNotLoop() async {
        let body = #"{"choices":[{"message":{"content":null,"reasoning":"still thinking"}}]}"#
        let row: Script.Response = (200, body, nil as String?)
        let script = Script([row, row, row, row])
        let (client, _) = client(script, model: "vendor/paid")
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "vendor/paid")
        }
        #expect(script.requests.count == 2)
    }

    @Test func freeRequestsShareOnePace() async throws {
        let ok = (200, chat(#"{"name":"A","age":1}"#), nil as String?)
        let script = Script([ok, ok])
        let clock = ManualClock()
        let (client, _) = client(script, clock: clock)
        async let first = client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "openrouter/free")
        async let second = client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "openrouter/free")
        _ = try await (first, second)
        #expect(clock.slept.count == 1)
        #expect(abs((clock.slept.first ?? -1) - OpenRouterFreeChain.gap) < 0.0001)
    }

    @Test func waitingIsReportedInsteadOfStayingSilent() async throws {
        let script = Script([
            (429, #"{"error":{"message":"slow down"}}"#, "2"),
            (200, chat(#"{"name":"A","age":1}"#), nil as String?),
        ])
        let (client, _) = client(script, model: "vendor/paid")
        let log = StatusLog()
        await client.setActivityHandler { log.add($0) }
        _ = try await client.json(schemaName: "pet", schema: petSchema, instructions: "", prompt: "", model: "vendor/paid")
        #expect(log.values.contains { $0.phase == .waiting && $0.detail.contains("429") })
        #expect(log.values.contains { $0.detail.contains("2") })
    }
}

final class StatusLog: @unchecked Sendable {
    var values: [LibraryWorkStatus] = []
    func add(_ status: LibraryWorkStatus) { values.append(status) }
}

@Suite struct LibraryEnrichmentTests {
    @Test func albumsAreSplitAtTwentyFiveAndNotMixed() {
        let albumA = (0 ..< 30).map { EnrichmentTrack(id: "a\($0)", albumID: "A", albumTitle: "North", title: "T\($0)", artistName: "N") }
        let albumB = [EnrichmentTrack(id: "b0", albumID: "B", albumTitle: "South", title: "U", artistName: "S")]
        let batches = LibraryEnrichmentPlanner.batches(albumA + albumB)
        #expect(batches.map(\.count) == [25, 5, 1])
        #expect(batches[0].allSatisfy { $0.albumID == "A" })
        #expect(batches[1].map(\.id) == ["a25", "a26", "a27", "a28", "a29"])
        #expect(batches[2].map(\.id) == ["b0"])
        let skipped = LibraryEnrichmentPlanner.batches(albumA, include: ["a0"])
        #expect(skipped.map { $0.map(\.id) } == [["a0"]])
    }

    @Test func unchangedFilesAreSkipped() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scan-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = directory.appending(path: "kept.m4a")
        let changed = directory.appending(path: "changed.m4a")
        try Data("a".utf8).write(to: kept)
        try Data("a".utf8).write(to: changed)
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: kept.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: changed.path)
        let beforeKept = try #require(LibraryScan.stamp(key: "kept", url: kept))
        let beforeChanged = try #require(LibraryScan.stamp(key: "changed", url: changed))
        #expect(LibraryScan.needsWork(current: [beforeKept, beforeChanged], previous: [beforeKept, beforeChanged]).isEmpty)
        try Data("longer".utf8).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: baseline.addingTimeInterval(3600)], ofItemAtPath: changed.path)
        let after = try #require(LibraryScan.stamp(key: "changed", url: changed))
        #expect(LibraryScan.needsWork(current: [beforeKept, after], previous: [beforeKept, beforeChanged]) == ["changed"])
        #expect(beforeKept.byteCount == 1)
        #expect(after.byteCount == 6)
        try FileManager.default.setAttributes([.modificationDate: baseline.addingTimeInterval(7200)], ofItemAtPath: kept.path)
        let retimed = try #require(LibraryScan.stamp(key: "kept", url: kept))
        #expect(retimed.byteCount == beforeKept.byteCount)
        #expect(LibraryScan.needsWork(current: [retimed, beforeChanged], previous: [beforeKept, beforeChanged]) == ["kept"])
    }

    @Test func oneAlbumFailureDoesNotDropTheNextAndStatusShowsWhy() async throws {
        let first = EnrichmentTrack(id: "t1", albumID: "A", albumTitle: "North", title: "One", artistName: "N")
        let second = EnrichmentTrack(id: "t2", albumID: "B", albumTitle: "South", title: "Two", artistName: "S")
        let script = EnrichmentScript([
            (403, #"{"error":{"message":"no"}}"#),
            (200, chat(#"{"playlists":[{"name":"South Night","trackIDs":["t2"]}]}"#)),
        ])
        let client = try await openRouterClient(script)
        let log = StatusLog()
        let result = await LibraryEnrichment.enrich([first, second], client: client) { log.add($0) }
        #expect(result.failed == 1)
        #expect(result.completed == 1)
        #expect(result.playlists == [EnrichmentPlaylist(name: "South Night", trackIDs: ["t2"])])
        #expect(result.error?.contains("403") == true)
        #expect(log.values.contains { $0.phase == .failed && $0.detail.contains("403") && $0.total == 2 })
        #expect(log.values.last?.phase == .failed)
        #expect(log.values.last?.completed == 1)
        let bodies = script.bodies()
        #expect(bodies[0].contains("t1"))
        #expect(!bodies[0].contains("t2"))
        #expect(bodies[1].contains("t2"))
    }

    @Test func aLongAlbumIsTwoRequests() async throws {
        let tracks = (0 ..< 26).map { EnrichmentTrack(id: "id-\($0)", albumID: "A", albumTitle: "North", title: "T\($0)", artistName: "N") }
        let playlist = #"{"playlists":[{"name":"All","trackIDs":["id-0"]}]}"#
        let script = EnrichmentScript([(200, chat(playlist)), (200, chat(playlist))])
        let client = try await openRouterClient(script)
        let result = await LibraryEnrichment.enrich(tracks, client: client)
        #expect(result.completed == 26)
        #expect(result.failed == 0)
        let bodies = script.bodies()
        #expect(bodies.count == 2)
        #expect(bodies[0].contains("id-0") && bodies[0].contains("id-24") && !bodies[0].contains("id-25"))
        #expect(bodies[1].contains("id-25") && !bodies[1].contains("id-0"))
    }

    @Test func playlistsRoundTripThroughTheLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "enrich-\(UUID())")
        let db = try AppDatabase(url: directory.appending(path: "Library.sqlite"))
        var artist = Artist(name: "North", primaryGenre: "folk", genres: ["folk"], formedYear: 2001, tier: .core, plannedAlbumCount: 1)
        artist.status = .ready
        try db.save(artist: artist)
        let album = Album(artistID: artist.id, title: "North", releaseYear: 2001, kind: .album, primaryGenre: "folk", genres: ["folk"], trackCount: 1)
        let track = Track(albumID: album.id, artistID: artist.id, trackNumber: 1, title: "One", details: "", styleTags: "folk", vocal: "alto", bpm: 90, mood: "hushed")
        try db.save(album: album, tracks: [track])
        try LibraryEnrichment.store([EnrichmentPlaylist(name: "Night", trackIDs: [track.id]), EnrichmentPlaylist(name: "  ", trackIDs: [])], db: db)
        let stored = try db.reader.read { database -> (String, [String])? in
            guard let playlist = try Playlist.fetchOne(database) else { return nil }
            let items = try PlaylistItem.filter(Column("playlistID") == playlist.id).order(Column("position")).fetchAll(database)
            return (playlist.name, items.map(\.trackID))
        }
        let playlist = try #require(stored)
        #expect(playlist.0 == "Night")
        #expect(playlist.1 == [track.id])
    }
}

private final class EnrichmentScript: @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func take(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.isEmpty ? (500, "{}") : responses.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        return (Data(body.utf8), http)
    }
    func bodies() -> [String] {
        requests.compactMap { $0.httpBody }.map { String(decoding: $0, as: UTF8.self) }
    }
}

private func openRouterClient(_ script: EnrichmentScript) async throws -> ChatGPTClient {
    let directory = FileManager.default.temporaryDirectory.appending(path: "enrich-gpt-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let auth = ChatGPTAuth(directory: directory)
    let client = ChatGPTClient(auth: auth, openRouterTransport: { script.take($0) }, openRouterClock: ManualClock())
    await client.configureOpenRouter(apiKey: "k", writing: "openrouter/free", fast: "openrouter/free", imageModel: nil)
    return client
}

@Suite struct OpenRouterKeyFallbackTests {
    @Test func adHocFailureWritesAFileAndAMissingItemDoesNotInventOne() throws {
        #expect(OpenRouterKey.isAdHocKeychainFailure(errSecMissingEntitlement))
        #expect(OpenRouterKey.isAdHocKeychainFailure(errSecAuthFailed))
        #expect(!OpenRouterKey.isAdHocKeychainFailure(errSecItemNotFound))
        let root = FileManager.default.temporaryDirectory.appending(path: "key-\(UUID())", directoryHint: .isDirectory)
        let saved = OpenRouterKey.persist("sk-or-test", keychainWrite: { _ in errSecMissingEntitlement }, keychainDelete: { errSecSuccess }, root: root)
        #expect(saved)
        let loaded = OpenRouterKey.resolveStored(keychainRead: { (errSecItemNotFound, nil as String?) }, root: root)
        #expect(loaded == "sk-or-test")
        let cleared = OpenRouterKey.persist("", keychainWrite: { _ in errSecSuccess }, keychainDelete: { errSecSuccess }, root: root)
        #expect(cleared)
        #expect(OpenRouterKey.resolveStored(keychainRead: { (errSecItemNotFound, nil as String?) }, root: root) == nil)
        #expect(OpenRouterKey.persist("sk-or-live", keychainWrite: { _ in errSecSuccess }, keychainDelete: { errSecSuccess }, root: root))
        #expect(OpenRouterKey.resolveStored(keychainRead: { (errSecSuccess, "sk-or-live") }, root: root) == "sk-or-live")
    }
}

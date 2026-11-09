import Foundation
import GRDB

// MARK: - Clock

/// Time source for free-tier pacing. Tests advance this instead of sleeping.
public protocol OpenRouterClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async
}

public struct SystemOpenRouterClock: OpenRouterClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Records every sleep and moves `now` forward by the same amount. Does not wait.
public final class ManualClock: @unchecked Sendable, OpenRouterClock {
    public private(set) var time: Date
    public private(set) var slept: [Double] = []

    public init(time: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.time = time
    }

    public func now() -> Date { time }

    public func sleep(seconds: Double) async {
        let delay = max(0, seconds)
        slept.append(delay)
        time = time.addingTimeInterval(delay)
    }
}

// MARK: - Paid last resort

/// Off unless the listener turns it on and names a paid model. Free requests never select this.
public struct OpenRouterPaidFallback: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var modelID: String
    /// Shown next to the switch. The app does not meter the week; the listener does.
    public static let weeklyCapNote = "Paid models bill your OpenRouter account. Keep the week within about $10. This stays off until you turn it on and name a model."

    public init(enabled: Bool, modelID: String) {
        self.enabled = enabled
        self.modelID = modelID
    }

    public static let off = OpenRouterPaidFallback(enabled: false, modelID: "")

    /// A paid slug to try after every free model has failed. Nil when the switch is off or the slug is free.
    public var activeModelID: String? {
        guard enabled, let id = OpenRouterCatalog.normalizedModelID(modelID), !OpenRouterCatalog.isFreeModel(id) else { return nil }
        return id
    }
}

// MARK: - Free chain and limits

public enum OpenRouterFreeChain {
    /// Minimum gap between free-model requests, shared by every caller of one client.
    public static let gap: TimeInterval = 3.2
    /// Hung reasoning calls used to sit until the session timeout. Every OpenRouter request uses this.
    public static let requestTimeout: TimeInterval = 45
    /// Attempts per model, including the first. Then the next free model, or a surfaced failure.
    public static let maxAttemptsPerModel = 3
    /// A multi-hour Retry-After is honored up to this cap so a batch cannot stall overnight.
    public static let retryAfterCap: TimeInterval = 60
    /// Free text models tried after the listener's own free slug. No paid ids.
    public static let builtIn = [
        "openrouter/free",
        "meta-llama/llama-3.3-70b-instruct:free",
    ]

    public static func order(starting model: String, catalogFree: [String], paid: OpenRouterPaidFallback) -> [String] {
        guard OpenRouterCatalog.isFreeModel(model) else { return [model] }
        var seen = Set<String>()
        var out: [String] = []
        func add(_ raw: String) {
            guard let id = OpenRouterCatalog.normalizedModelID(raw), OpenRouterCatalog.isFreeModel(id) else { return }
            if seen.insert(id.lowercased()).inserted { out.append(id) }
        }
        add(model)
        for id in builtIn { add(id) }
        for id in catalogFree { add(id) }
        if let paidID = paid.activeModelID, seen.insert(paidID.lowercased()).inserted { out.append(paidID) }
        return out
    }

    public static func delay(status: Int, retryAfter: TimeInterval?, attempt: Int) -> TimeInterval {
        let header = retryAfter.map { min(max(0, $0), retryAfterCap) }
        if status == 429 { return header ?? min(pow(2, Double(attempt)), retryAfterCap) }
        return header ?? min(pow(2, Double(attempt)), retryAfterCap)
    }
}

// MARK: - Live status

public struct LibraryWorkStatus: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle, working, waiting, failed, finished
    }

    public var phase: Phase
    public var step: String
    public var completed: Int
    public var total: Int
    public var detail: String

    public init(phase: Phase, step: String, completed: Int, total: Int, detail: String) {
        self.phase = phase
        self.step = step
        self.completed = completed
        self.total = total
        self.detail = detail
    }

    public static let idle = LibraryWorkStatus(phase: .idle, step: "", completed: 0, total: 0, detail: "")

    public var progressLabel: String {
        guard total > 0 else { return step }
        return "\(step) \(completed)/\(total)"
    }
}

// MARK: - Incremental file scan

public struct LibraryFileStamp: Sendable, Equatable, Codable {
    public var key: String
    public var byteCount: Int
    public var modifiedAt: TimeInterval

    public init(key: String, byteCount: Int, modifiedAt: TimeInterval) {
        self.key = key
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public enum LibraryScan {
    /// Size and modification time only. The file's bytes are not read.
    public static func stamp(key: String, url: URL) -> LibraryFileStamp? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate else { return nil }
        return LibraryFileStamp(key: key, byteCount: size, modifiedAt: modified.timeIntervalSince1970)
    }

    /// Keys whose file appeared, grew, shrank, or was rewritten. Unchanged stamps are omitted.
    public static func needsWork(current: [LibraryFileStamp], previous: [LibraryFileStamp]) -> Set<String> {
        let prior = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = Set<String>()
        for stamp in current {
            guard let old = prior[stamp.key] else {
                changed.insert(stamp.key)
                continue
            }
            if old.byteCount != stamp.byteCount || old.modifiedAt != stamp.modifiedAt { changed.insert(stamp.key) }
        }
        return changed
    }
}

// MARK: - Album batches

public struct EnrichmentTrack: Sendable, Equatable, Identifiable {
    public var id: ID
    public var albumID: ID
    public var albumTitle: String
    public var title: String
    public var artistName: String

    public init(id: ID, albumID: ID, albumTitle: String, title: String, artistName: String) {
        self.id = id
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.title = title
        self.artistName = artistName
    }
}

public struct EnrichmentPlaylist: Sendable, Equatable {
    public var name: String
    public var trackIDs: [ID]

    public init(name: String, trackIDs: [ID]) {
        self.name = name
        self.trackIDs = trackIDs
    }
}

public struct LibraryWorkResult: Sendable, Equatable {
    public var playlists: [EnrichmentPlaylist]
    public var enrichedIDs: [ID]
    public var completed: Int
    public var failed: Int
    public var error: String?

    public init(playlists: [EnrichmentPlaylist], enrichedIDs: [ID], completed: Int, failed: Int, error: String?) {
        self.playlists = playlists
        self.enrichedIDs = enrichedIDs
        self.completed = completed
        self.failed = failed
        self.error = error
    }
}

public enum LibraryEnrichmentPlanner {
    public static let tracksPerRequest = 25

    /// One request per album chunk. Albums are not mixed, and a long album is split at 25 tracks.
    public static func batches(_ tracks: [EnrichmentTrack], include: Set<ID>? = nil) -> [[EnrichmentTrack]] {
        var grouped: [ID: [EnrichmentTrack]] = [:]
        var order: [ID] = []
        for track in tracks {
            if let include, !include.contains(track.id) { continue }
            if grouped[track.albumID] == nil { order.append(track.albumID) }
            grouped[track.albumID, default: []].append(track)
        }
        var out: [[EnrichmentTrack]] = []
        for album in order {
            let rows = grouped[album] ?? []
            var index = 0
            while index < rows.count {
                let end = min(index + tracksPerRequest, rows.count)
                out.append(Array(rows[index ..< end]))
                index = end
            }
        }
        return out
    }
}

public enum LibraryEnrichment {
    private static func ignore(_ status: LibraryWorkStatus) {}

    struct Payload: Decodable, Sendable {
        struct Playlist: Decodable, Sendable {
            var name: String
            var trackIDs: [String]
        }
        var playlists: [Playlist]
    }

    public static func enrich(
        _ tracks: [EnrichmentTrack], include: Set<ID>? = nil, client: ChatGPTClient,
        onStatus: (@Sendable (LibraryWorkStatus) -> Void)? = nil
    ) async -> LibraryWorkResult {
        let report = onStatus ?? Self.ignore
        let batches = LibraryEnrichmentPlanner.batches(tracks, include: include)
        let total = batches.reduce(0) { $0 + $1.count }
        if total == 0 {
            report(LibraryWorkStatus(phase: .finished, step: "Playlists", completed: 0, total: 0, detail: "Library files are unchanged."))
            return LibraryWorkResult(playlists: [], enrichedIDs: [], completed: 0, failed: 0, error: nil)
        }
        var playlists: [EnrichmentPlaylist] = []
        var enriched: [ID] = []
        var completed = 0
        var failed = 0
        var failure: String?
        report(LibraryWorkStatus(phase: .working, step: "Playlists", completed: 0, total: total, detail: "Reading albums"))
        for batch in batches {
            let title = batch.first?.albumTitle ?? "Album"
            report(LibraryWorkStatus(
                phase: .working, step: "Playlists", completed: completed, total: total, detail: "\(title) · \(batch.count) tracks"))
            do {
                let found = try await request(batch, client: client)
                playlists.append(contentsOf: found)
                enriched.append(contentsOf: batch.map(\.id))
                completed += batch.count
                report(LibraryWorkStatus(phase: .working, step: "Playlists", completed: completed, total: total, detail: title))
            } catch {
                failed += batch.count
                let reason = error.localizedDescription
                failure = reason
                report(LibraryWorkStatus(phase: .failed, step: "Playlists", completed: completed, total: total, detail: reason))
            }
        }
        let phase: LibraryWorkStatus.Phase = failed > 0 ? .failed : .finished
        let detail = failure ?? "\(playlists.count) playlist\(playlists.count == 1 ? "" : "s")"
        report(LibraryWorkStatus(phase: phase, step: "Playlists", completed: completed, total: total, detail: detail))
        return LibraryWorkResult(playlists: playlists, enrichedIDs: enriched, completed: completed, failed: failed, error: failure)
    }

    public static func store(_ drafts: [EnrichmentPlaylist], db: AppDatabase) throws {
        try db.writer.write { database in
            for draft in drafts {
                let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = draft.trackIDs.filter { !$0.isEmpty }
                guard !name.isEmpty, !ids.isEmpty else { continue }
                let playlist = Playlist(name: name)
                try playlist.insert(database)
                for (index, id) in ids.enumerated() {
                    try PlaylistItem(playlistID: playlist.id, trackID: id, position: index).insert(database)
                }
            }
        }
    }

    private static func request(_ batch: [EnrichmentTrack], client: ChatGPTClient) async throws -> [EnrichmentPlaylist] {
        let allowed = Set(batch.map(\.id))
        let lines = batch.map { "- \($0.id) · \($0.title) · \($0.artistName)" }.joined(separator: "\n")
        let album = batch.first?.albumTitle ?? "Album"
        let schema = Schema.object([
            "playlists": Schema.array(Schema.object([
                "name": Schema.string("A short playlist name"),
                "trackIDs": Schema.array(Schema.string(), min: 1, max: LibraryEnrichmentPlanner.tracksPerRequest),
            ]), min: 0, max: 4),
        ])
        let payload = try await client.json(
            Payload.self, schemaName: "library_playlists", schema: schema,
            instructions: "You group songs the listener already has into a few playlists. Use only the ids you are given.",
            prompt: """
            Album "\(album)". These tracks share that album. Suggest up to 4 playlists. \
            Every trackID must be copied from the list. Do not invent ids.
            \(lines)
            """,
            effort: "low")
        return payload.playlists.compactMap { playlist in
            let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = playlist.trackIDs.filter { allowed.contains($0) }
            guard !name.isEmpty, !ids.isEmpty else { return nil }
            return EnrichmentPlaylist(name: name, trackIDs: ids)
        }
    }
}

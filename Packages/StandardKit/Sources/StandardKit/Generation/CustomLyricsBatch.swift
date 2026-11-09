import Foundation
import GRDB

/// How many same-lyrics songs to write, and whether the listener should confirm first.
///
/// Artists come from the indexed library (finished artists already stored on this Mac), plus an
/// optional count of new fictional artists. The onboarding catalog of real artists is not a source,
/// and a library build that is still writing its roster is not either: those artists have no finished
/// record to perform in.
public enum CustomLyricsBatchPlanner {
    /// Ask before starting. Each song is a text request plus a local recording.
    public static let confirmFrom = 4
    /// Hard stop. The stepper and this check both use it.
    public static let maximum = 24

    public static func decide(
        artistIDs: [ID], newArtistCount: Int, provider: AIProvider, openRouterModel: String?, minutesPerRecording: Double
    ) -> CustomLyricsBatchDecision {
        var seen = Set<ID>()
        var unique: [ID] = []
        var duplicates = 0
        for id in artistIDs {
            if seen.insert(id).inserted { unique.append(id) } else { duplicates += 1 }
        }
        let extra = max(0, newArtistCount)
        let count = unique.count + extra
        let selection = CustomLyricsSelection(artistIDs: unique, newArtistCount: extra, duplicatesRemoved: duplicates)
        if count < 1 {
            return .invalid("Pick at least one artist, or ask for a new one.")
        }
        if count > maximum {
            return .invalid("\(maximum) songs is the maximum for one batch. This would be \(count).")
        }
        let cost = Self.cost(
            songCount: count, provider: provider, openRouterModel: openRouterModel, minutesPerRecording: minutesPerRecording)
        if count >= confirmFrom { return .needsConfirmation(selection, cost) }
        return .ready(selection, cost)
    }

    /// Describes the cost of the batch without changing which model is selected.
    /// OpenRouter stays on the listener's current model. `openrouter/free` is the free default.
    /// A paid slug is billed by OpenRouter; this app does not switch to a different paid model.
    /// Recording is local and costs time only.
    public static func cost(
        songCount: Int, provider: AIProvider, openRouterModel: String?, minutesPerRecording: Double
    ) -> CustomLyricsBatchCost {
        let minutes = max(1, minutesPerRecording)
        let minuteText = "\(Int(minutes.rounded()))"
        let recording = "Each song then records on this Mac, one at a time, about \(minuteText) minutes. That cost is time only."
        switch provider {
        case .chatGPT:
            return CustomLyricsBatchCost(
                songCount: songCount, textIsFree: false, minutesPerSong: minutes,
                summary: "\(songCount) songs keep the same lyrics. Each one is a ChatGPT text request on your subscription. \(recording) Artwork stays on your current setting. This does not turn on a paid OpenRouter model.")
        case .openRouter:
            let model = (openRouterModel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? OpenRouterCatalog.defaultModel
            if isFreeOpenRouterModel(model) {
                return CustomLyricsBatchCost(
                    songCount: songCount, textIsFree: true, minutesPerSong: minutes,
                    summary: "\(songCount) songs keep the same lyrics. Text uses \(model), which is free ($0). This app will not switch that to a paid model. \(recording) Covers stay on your current artwork setting. The OpenRouter default is procedural art at $0.")
            }
            return CustomLyricsBatchCost(
                songCount: songCount, textIsFree: false, minutesPerSong: minutes,
                summary: "\(songCount) songs keep the same lyrics. Text uses \(model), a paid OpenRouter model billed to your account. This app will not change that model. If you pay for text, keep the week within about $10. \(recording)")
        }
    }

    public static func isFreeOpenRouterModel(_ model: String) -> Bool {
        OpenRouterCatalog.isFreeModel(model)
    }
}

public struct CustomLyricsSelection: Sendable, Equatable {
    public var artistIDs: [ID]
    public var newArtistCount: Int
    public var duplicatesRemoved: Int
    public var songCount: Int { artistIDs.count + newArtistCount }

    public init(artistIDs: [ID], newArtistCount: Int, duplicatesRemoved: Int) {
        self.artistIDs = artistIDs
        self.newArtistCount = newArtistCount
        self.duplicatesRemoved = duplicatesRemoved
    }
}

public struct CustomLyricsBatchCost: Sendable, Equatable {
    public var songCount: Int
    public var textIsFree: Bool
    public var minutesPerSong: Double
    public var summary: String

    public init(songCount: Int, textIsFree: Bool, minutesPerSong: Double, summary: String) {
        self.songCount = songCount
        self.textIsFree = textIsFree
        self.minutesPerSong = minutesPerSong
        self.summary = summary
    }
}

public enum CustomLyricsBatchDecision: Sendable, Equatable {
    case invalid(String)
    case ready(CustomLyricsSelection, CustomLyricsBatchCost)
    case needsConfirmation(CustomLyricsSelection, CustomLyricsBatchCost)

    public var selection: CustomLyricsSelection? {
        switch self {
        case .invalid: nil
        case .ready(let selection, _), .needsConfirmation(let selection, _): selection
        }
    }

    public var cost: CustomLyricsBatchCost? {
        switch self {
        case .invalid: nil
        case .ready(_, let cost), .needsConfirmation(_, let cost): cost
        }
    }
}

public struct CustomLyricsBatchPlan: Sendable, Equatable {
    public var lyrics: String
    public var style: String
    public var title: String?
    public var instrumental: Bool
    public var references: [StyleCue]
    public var artistIDs: [ID]
    public var newArtistCount: Int

    public init(
        lyrics: String, style: String, title: String?, instrumental: Bool, references: [StyleCue], artistIDs: [ID],
        newArtistCount: Int
    ) {
        self.lyrics = lyrics
        self.style = style
        self.title = title
        self.instrumental = instrumental
        self.references = references
        self.artistIDs = artistIDs
        self.newArtistCount = newArtistCount
    }

    public var songCount: Int { artistIDs.count + max(0, newArtistCount) }
}

public struct CustomLyricsBatchProgress: Sendable, Equatable {
    public var index: Int
    public var total: Int
    public var label: String

    public init(index: Int, total: Int, label: String) {
        self.index = index
        self.total = total
        self.label = label
    }
}

public struct CustomLyricsSongOutcome: Sendable, Equatable {
    public var artistID: ID?
    public var artistName: String
    public var albumID: ID?
    public var trackID: ID?
    public var error: String?

    public init(artistID: ID?, artistName: String, albumID: ID?, trackID: ID?, error: String?) {
        self.artistID = artistID
        self.artistName = artistName
        self.albumID = albumID
        self.trackID = trackID
        self.error = error
    }

    public var succeeded: Bool { trackID != nil && error == nil }
}

public struct CustomLyricsBatchResult: Sendable, Equatable {
    public var batchID: ID
    public var songs: [CustomLyricsSongOutcome]
    public var cancelled: Bool

    public init(batchID: ID, songs: [CustomLyricsSongOutcome], cancelled: Bool) {
        self.batchID = batchID
        self.songs = songs
        self.cancelled = cancelled
    }

    public var successes: [CustomLyricsSongOutcome] { songs.filter(\.succeeded) }
    public var failures: [CustomLyricsSongOutcome] { songs.filter { $0.error != nil } }
}

extension LibraryBuilder {
    /// Writes one single per artist, all with the same lyrics. One failed artist does not stop the rest.
    /// `shouldStop` is checked between songs. Already written songs are kept.
    public func createCustomLyricsBatch(
        _ plan: CustomLyricsBatchPlan,
        shouldStop: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (CustomLyricsBatchProgress) -> Void)? = nil
    ) async -> CustomLyricsBatchResult {
        let stop = shouldStop ?? { Task.isCancelled }
        let progress = onProgress ?? { _ in }
        var seen = Set<ID>()
        let artistIDs = plan.artistIDs.filter { seen.insert($0).inserted }
        let extra = max(0, plan.newArtistCount)
        let total = artistIDs.count + extra
        let stored = String(decoding: (try? JSONEncoder().encode(StoredBatch(
            lyrics: plan.lyrics, style: plan.style, title: plan.title, instrumental: plan.instrumental,
            artistIDs: artistIDs, newArtistCount: extra, vocalOnly: VocalOnly.requests(plan.style)
        ))) ?? Data("{}".utf8), as: UTF8.self)
        let batch = GenerationBatch(
            kind: .customLyrics, title: "Same lyrics · \(total) artist\(total == 1 ? "" : "s")",
            request: stored, targetArtists: total)
        if let inserted = try? await db.writer.write({ db -> GenerationBatch in
            var batch = batch
            batch.status = .running
            try batch.insert(db)
            return batch
        }) {
            return await runBatch(inserted, plan: plan, artistIDs: artistIDs, extra: extra, stop: stop, progress: progress)
        }
        return CustomLyricsBatchResult(batchID: batch.id, songs: [
            CustomLyricsSongOutcome(artistID: nil, artistName: "", albumID: nil, trackID: nil, error: "Couldn’t save the batch."),
        ], cancelled: false)
    }

    private func runBatch(
        _ batch: GenerationBatch, plan: CustomLyricsBatchPlan, artistIDs: [ID], extra: Int,
        stop: @Sendable () -> Bool, progress: @Sendable (CustomLyricsBatchProgress) -> Void
    ) async -> CustomLyricsBatchResult {
        let total = artistIDs.count + extra
        var songs: [CustomLyricsSongOutcome] = []
        var avoid: [String] = []
        var cancelled = false
        if total < 1 || total > CustomLyricsBatchPlanner.maximum {
            let message = total < 1 ? "Pick at least one artist." : "\(CustomLyricsBatchPlanner.maximum) songs is the maximum."
            songs.append(CustomLyricsSongOutcome(artistID: nil, artistName: "", albumID: nil, trackID: nil, error: message))
        } else {
            for id in artistIDs {
                if stop() || Task.isCancelled { cancelled = true; break }
                let name = (try? await db.reader.read { try Artist.fetchOne($0, key: id)?.name }) ?? "Unknown artist"
                progress(CustomLyricsBatchProgress(index: songs.count + 1, total: total, label: name))
                let outcome = await writeOne(plan: plan, artistID: id, artistName: name, avoid: avoid, batchID: batch.id)
                if outcome.error == "Cancelled" { cancelled = true }
                if outcome.succeeded { avoid.append(outcome.artistName) }
                songs.append(outcome)
                if cancelled { break }
            }
            if !cancelled {
                for _ in 0 ..< extra {
                    if stop() || Task.isCancelled { cancelled = true; break }
                    progress(CustomLyricsBatchProgress(index: songs.count + 1, total: total, label: "A new artist"))
                    let outcome = await writeOne(
                        plan: plan, artistID: nil, artistName: "A new artist", avoid: avoid, batchID: batch.id)
                    if outcome.error == "Cancelled" { cancelled = true }
                    if outcome.succeeded { avoid.append(outcome.artistName) }
                    songs.append(outcome)
                    if cancelled { break }
                }
            }
        }
        let status: BatchStatus = cancelled ? .cancelled : (songs.contains(where: \.succeeded) ? .finished : .failed)
        let error = songs.compactMap(\.error).prefix(4).joined(separator: " ")
        _ = try? await db.writer.write { db in
            try db.execute(
                sql: "UPDATE generationBatch SET status = ?, error = ?, finishedAt = ? WHERE id = ?",
                arguments: [status.rawValue, error.isEmpty ? nil : String(error.prefix(500)), Date(), batch.id])
        }
        return CustomLyricsBatchResult(batchID: batch.id, songs: songs, cancelled: cancelled)
    }

    private func writeOne(
        plan: CustomLyricsBatchPlan, artistID: ID?, artistName: String, avoid: [String], batchID: ID
    ) async -> CustomLyricsSongOutcome {
        let request = CustomSongRequest(
            lyrics: plan.lyrics, style: plan.style, title: plan.title, instrumental: plan.instrumental, artistID: artistID,
            references: plan.references, avoidArtistNames: avoid, batchID: batchID)
        do {
            let albumID = try await createCustomSong(request)
            _ = try db.modifyAlbum(albumID) { $0.batchID = batchID }
            let trackID = try await db.reader.read { try Track.filter(Column("albumID") == albumID).fetchOne($0)?.id }
            let name = try await db.reader.read { db -> String in
                if let artistID, let artist = try Artist.fetchOne(db, key: artistID) { return artist.name }
                if let album = try Album.fetchOne(db, key: albumID), let artist = try Artist.fetchOne(db, key: album.artistID) {
                    return artist.name
                }
                return artistName
            }
            let resolvedArtist = try await db.reader.read { try Album.fetchOne($0, key: albumID)?.artistID }
            return CustomLyricsSongOutcome(
                artistID: resolvedArtist ?? artistID, artistName: name, albumID: albumID, trackID: trackID, error: nil)
        } catch is CancellationError {
            return CustomLyricsSongOutcome(artistID: artistID, artistName: artistName, albumID: nil, trackID: nil, error: "Cancelled")
        } catch {
            return CustomLyricsSongOutcome(
                artistID: artistID, artistName: artistName, albumID: nil, trackID: nil, error: error.localizedDescription)
        }
    }
}

private struct StoredBatch: Encodable {
    var lyrics: String
    var style: String
    var title: String?
    var instrumental: Bool
    var artistIDs: [ID]
    var newArtistCount: Int
    var vocalOnly: Bool
}

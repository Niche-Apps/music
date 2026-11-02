import EngineProtocol
import Foundation
import Observation
import OSLog
import StandardKit
import UserNotifications

let recordLog = Logger(subsystem: "com.standardmusic", category: "recording")

/// Decides which song the engine records next and tracks progress for the UI.
///
/// Demand comes from three places, in priority order: what the player needs now (current track and
/// the next few in the queue), songs the listener explicitly asked to record, and optional idle
/// prefetching. One song records at a time; lyrics for the next one are written in parallel.
@MainActor
@Observable
final class RecordingQueue {
    enum Phase: Equatable {
        case writingLyrics
        case waitingForModel
        case recording(EngineProgress)
    }

    struct Activity: Equatable {
        var trackID: ID
        var title: String
        var artistName: String
        var albumID: ID
        var phase: Phase
        var startedAt: Date

        var fraction: Double {
            if case .recording(let p) = phase { return p.overall }
            return 0
        }

        /// Seconds remaining, extrapolated from progress so far.
        var remaining: TimeInterval? {
            guard case .recording(let p) = phase, p.overall > 0.04 else { return nil }
            return max(0, p.elapsed / p.overall - p.elapsed)
        }

        var stageLabel: String {
            switch phase {
            case .writingLyrics: "Writing lyrics"
            case .waitingForModel: "Setting up the studio"
            case .recording(let p):
                switch p.stage {
                case "loading": "Warming up"
                case "planning": "Writing the score"
                case "composing": "Laying down the tracks"
                case "rendering": "Mixing"
                case "mastering", "encoding": "Mastering"
                default: "Recording"
                }
            }
        }
    }

    private let services: Services
    private(set) var active: Activity?
    /// Track ids the player needs, in order (current first).
    private(set) var playbackDemand: [ID] = []
    /// Explicit "record this" requests, in order.
    private(set) var requested: [ID] = []
    private(set) var failures: [ID: String] = [:]
    /// Lifetime stats for estimating durations.
    private(set) var averageSecondsPerSong: Double = 420
    var modelDirectory: () -> URL? = { nil }
    var onTrackReady: ((ID) -> Void)?
    var onTrackFailed: ((ID, String) -> Void)?
    var onActivityChange: (() -> Void)?

    private var worker: Task<Void, Never>?
    private var lyricsTasks: [ID: Task<Void, Never>] = [:]
    private var cancelledByPreemption = Set<ID>()

    init(services: Services) {
        self.services = services
        if let avg = UserDefaults.standard.object(forKey: "averageSecondsPerSong") as? Double { averageSecondsPerSong = avg }
    }

    // MARK: Demand

    func setPlaybackDemand(_ ids: [ID]) {
        guard ids != playbackDemand else { return }
        playbackDemand = ids
        preemptIfNeeded()
        pump()
    }

    /// Queue songs to record (e.g. "Record Album").
    func request(_ ids: [ID]) {
        for id in ids where !requested.contains(id) { requested.append(id) }
        pump()
    }

    func cancelRequest(_ ids: [ID]) {
        requested.removeAll { ids.contains($0) }
        if let active, ids.contains(active.trackID), !playbackDemand.contains(active.trackID) {
            Task { await services.engine.cancel(jobID: active.trackID) }
        }
    }

    /// Lets songs that failed earlier be tried again (the listener explicitly asked to play them).
    func clearFailures(_ ids: [ID]) {
        var changed = false
        for id in ids where failures[id] != nil {
            failures[id] = nil
            _ = try? services.db.modifyTrack(id) { $0.status = .pending }
            changed = true
        }
        if changed { pump() }
    }

    func retry(_ id: ID) {
        failures[id] = nil
        _ = try? services.db.modifyTrack(id) { $0.status = .pending }
        pump()
    }

    /// Re-evaluates idle work (e.g. after Background Recording is switched on).
    func kick() { pump() }

    func isQueued(_ id: ID) -> Bool { playbackDemand.contains(id) || requested.contains(id) }

    /// Position in line (0 = recording now) or nil.
    func position(of id: ID) -> Int? {
        if active?.trackID == id { return 0 }
        let order = orderedDemand()
        return order.firstIndex(of: id).map { $0 + (active == nil ? 0 : 1) }
    }

    private func orderedDemand() -> [ID] {
        var seen = Set<ID>()
        return (playbackDemand + requested).filter { $0 != active?.trackID && seen.insert($0).inserted }
    }

    // MARK: Scheduling

    private func preemptIfNeeded() {
        guard let active, let first = playbackDemand.first, first != active.trackID else { return }
        // The listener is waiting on something else. Drop the current job unless it's nearly done
        // or still needed soon.
        let neededSoon = playbackDemand.prefix(2).contains(active.trackID)
        if !neededSoon, active.fraction < 0.6 {
            recordLog.info("Preempting \(active.title) for a song the listener is waiting on")
            cancelledByPreemption.insert(active.trackID)
            Task { await services.engine.cancel(jobID: active.trackID) }
        }
    }

    static let warmStartAlbums = 6

    /// When idle (and enabled in Settings), records the opening song of albums the listener is likely
    /// to reach for — favourites first, then their core taste — so Play starts instantly.
    private func idleCandidate() -> ID? {
        let failed = Array(failures.keys)
        return try? services.db.reader.read { db in
            // Warm start: make sure a handful of albums can start instantly even with background
            // recording off (this mostly happens while the library is still being written).
            let warm = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT albumID) FROM track WHERE status = 'ready'") ?? 0
            guard warm < Self.warmStartAlbums || UserDefaults.standard.bool(forKey: Pref.backgroundRecording) else { return nil }
            return try String.fetchOne(
                db,
                sql: """
                    SELECT t.id FROM track t
                    JOIN album al ON al.id = t.albumID JOIN artist ar ON ar.id = t.artistID
                    WHERE t.status = 'pending' AND al.status = 'ready'
                      AND NOT EXISTS (SELECT 1 FROM track r WHERE r.albumID = al.id AND r.status = 'ready')
                      AND t.trackNumber = 1 AND t.id NOT IN (\(failed.map { "'\($0)'" }.joined(separator: ",")))
                    ORDER BY al.isFavorite DESC, ar.isFavorite DESC, (ar.tier = 'core') DESC, RANDOM()
                    LIMIT 1
                    """)
        }
    }

    private func nextCandidate() -> ID? {
        let db = services.db
        for id in orderedDemand() where failures[id] == nil {
            guard let track = try? db.reader.read({ try Track.fetchOne($0, key: id) }) else {
                requested.removeAll { $0 == id }
                continue
            }
            if track.isPlayable {
                requested.removeAll { $0 == id }
                continue
            }
            return id
        }
        return idleCandidate()
    }

    private func pump() {
        guard worker == nil, let next = nextCandidate() else {
            prepareLyricsAhead()
            return
        }
        worker = Task { [weak self] in
            await self?.record(next)
            guard let self else { return }
            self.worker = nil
            self.pump()
        }
        prepareLyricsAhead()
    }

    /// Writes lyrics for the next couple of songs while the current one records.
    private func prepareLyricsAhead() {
        for id in orderedDemand().prefix(2) where lyricsTasks[id] == nil {
            guard let track = try? services.db.reader.read({ try Track.fetchOne($0, key: id) }),
                track.lyrics == nil
            else { continue }
            let writer = services.songWriter
            lyricsTasks[id] = Task { [weak self] in
                _ = try? await writer.prepare(trackID: id)
                self?.lyricsTasks[id] = nil
            }
        }
    }

    private func record(_ id: ID) async {
        let db = services.db
        guard let info = try? db.trackInfo(id) else { return }
        var activity = Activity(
            trackID: id, title: info.track.title, artistName: info.artist.name, albumID: info.album.id,
            phase: .writingLyrics, startedAt: Date())
        setActive(activity)
        defer { setActive(nil) }
        do {
            // 1. Lyrics
            if let pending = lyricsTasks[id] { await pending.value }
            let track = try await services.songWriter.prepare(trackID: id)
            guard let lyrics = track.lyrics else { throw EngineError.failed("No lyrics were written.") }
            if cancelledByPreemption.contains(id) { throw EngineError.cancelled }

            // 2. Model
            var modelDir = modelDirectory()
            while modelDir == nil {
                activity.phase = .waitingForModel
                setActive(activity)
                try await Task.sleep(for: .seconds(2))
                if cancelledByPreemption.contains(id) { throw EngineError.cancelled }
                modelDir = modelDirectory()
            }

            // 3. Record
            _ = try db.modifyTrack(id) { $0.status = .generating }
            let output = Paths.audioFile(for: id)
            let voice = (try? await db.reader.read { db in
                try String.fetchOne(db, sql: "SELECT voice FROM artist WHERE id = ?", arguments: [track.artistID])
            }) ?? ""
            let style = Voice.recordingStyle(tags: track.styleTags, voice: voice, isInstrumental: track.isInstrumental)
            let maxSeconds = 60 * max(1, UserDefaults.standard.double(forKey: Pref.maxSongMinutes))
            let job = EngineJob(
                id: id, style: style, lyrics: lyrics, planning: ScorePlanningPref.current.rawValue,
                seed: UInt64(track.seed), steps: GenerationQuality.current.steps,
                maxSemanticTokens: Int(25 * maxSeconds), outputPath: output.path, title: track.title,
                artist: info.artist.name, voice: voice, isInstrumental: track.isInstrumental, maxSeconds: maxSeconds)
            activity.phase = .recording(EngineProgress(stage: "loading", stageFraction: 0, overall: 0, estimatedSongSeconds: nil, elapsed: 0))
            setActive(activity)
            let result = try await services.engine.render(job, modelDirectory: modelDir!) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.active?.trackID == id else { return }
                    self.active?.phase = .recording(progress)
                    self.onActivityChange?()
                }
            }
            _ = try db.modifyTrack(id) {
                $0.status = .ready
                $0.audioPath = Paths.relativeAudioPath(for: id)
                $0.duration = result.duration
                $0.loudness = result.loudness
                $0.generatedAt = Date()
                $0.generationSeconds = result.seconds
            }
            averageSecondsPerSong = averageSecondsPerSong * 0.7 + result.seconds * 0.3
            UserDefaults.standard.set(averageSecondsPerSong, forKey: "averageSecondsPerSong")
            requested.removeAll { $0 == id }
            recordLog.info("Recorded \(info.track.title) in \(Int(result.seconds))s")
            onTrackReady?(id)
            notifyIfNeeded(info)
        } catch EngineError.cancelled {
            _ = try? db.modifyTrack(id) { $0.status = .pending }
            cancelledByPreemption.remove(id)
            await services.engine.clearCancel(jobID: id)
        } catch is CancellationError {
            _ = try? db.modifyTrack(id) { $0.status = .pending }
        } catch {
            recordLog.error("Recording \(info.track.title) failed: \(error.localizedDescription)")
            failures[id] = error.localizedDescription
            _ = try? db.modifyTrack(id) { $0.status = .failed }
            // Clear the finished job first so the player's reaction can't "preempt" it after the fact.
            setActive(nil)
            onTrackFailed?(id, error.localizedDescription)
            // A crash usually means memory pressure; give the system a moment.
            if case EngineError.crashed = error { try? await Task.sleep(for: .seconds(3)) }
        }
    }

    private func setActive(_ activity: Activity?) {
        active = activity
        onActivityChange?()
    }

    private func notifyIfNeeded(_ info: TrackInfo) {
        guard UserDefaults.standard.bool(forKey: Pref.notifyWhenReady), !NSAppIsActive() else { return }
        let content = UNMutableNotificationContent()
        content.title = info.track.title
        content.subtitle = "\(info.artist.name) — \(info.album.title)"
        content.body = "Fresh from the studio."
        if let cover = info.album.coverPath {
            let url = services.artwork.thumbnailURL(for: cover)
            let copy = FileManager.default.temporaryDirectory.appending(path: "\(info.track.id).jpg")
            try? FileManager.default.removeItem(at: copy)
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil,
                let attachment = try? UNNotificationAttachment(identifier: "cover", url: copy)
            {
                content.attachments = [attachment]
            }
        }
        let request = UNNotificationRequest(identifier: info.track.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

import AppKit

@MainActor
func NSAppIsActive() -> Bool { NSApplication.shared.isActive }

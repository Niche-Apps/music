import AppKit
import Foundation
import GRDB
import MediaPlayer
import Observation
import StandardKit

/// Where the current queue came from ("Playing from …").
enum PlaybackContext: Equatable, Codable {
    case album(ID, String)
    case artist(ID, String)
    case playlist(ID, String)
    case songs(String)

    var label: String {
        switch self {
        case .album(_, let t): t
        case .artist(_, let n): n
        case .playlist(_, let n): n
        case .songs(let t): t
        }
    }
}

/// The queue and transport. Songs that aren't recorded yet are still queued; when playback reaches
/// one, the player waits while the studio records it, then starts automatically.
@MainActor
@Observable
final class PlayerModel {
    enum State: Equatable { case idle, playing, paused, waiting }
    enum RepeatMode: String, CaseIterable, Codable { case off, all, one }

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let trackID: ID
        var isAutoplay = false
    }

    private(set) var queue: [Entry] = []
    private(set) var index: Int?
    private(set) var current: TrackInfo?
    private(set) var state: State = .idle
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var context: PlaybackContext?
    private(set) var level: Float = 0
    var shuffle = false { didSet { if shuffle != oldValue { applyShuffle() } } }
    var repeatMode: RepeatMode = .off
    var autoplay: Bool {
        get { UserDefaults.standard.bool(forKey: Pref.autoplay) }
        set {
            UserDefaults.standard.set(newValue, forKey: Pref.autoplay)
            if !newValue {
                let cut = index ?? -1
                queue = queue.enumerated().filter { !($0.element.isAutoplay && $0.offset > cut) }.map(\.element)
            }
            refreshDemand()
        }
    }
    var volume: Float = Float(UserDefaults.standard.double(forKey: Pref.volume)) {
        didSet {
            output.volume = volume
            UserDefaults.standard.set(Double(volume), forKey: Pref.volume)
        }
    }

    private let services: Services
    private let recording: RecordingQueue
    private let output = AudioOutput()
    private var unshuffled: [Entry] = []
    private var ticker: Timer?
    private var playStartedAt: Date?
    private var playedSeconds: Double = 0
    private var observation: AnyDatabaseCancellable?
    private let nowPlaying = NowPlayingBridge()

    init(services: Services, recording: RecordingQueue) {
        self.services = services
        self.recording = recording
        output.volume = volume
        output.onFinished = { [weak self] in self?.trackFinished() }
        output.onLevel = { [weak self] level in self?.level = level }
        recording.onTrackReady = { [weak self] id in self?.trackBecameReady(id) }
        recording.onTrackFailed = { [weak self] id, message in self?.trackFailed(id, message: message) }
        nowPlaying.install(player: self)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSession(cleanExit: true) }
        }
    }

    // MARK: Session

    /// Everything needed to pick up where the listener left off, saved in the library as it changes.
    /// After a crash `wasActive` is still set, so playback resumes on its own; a normal quit clears it.
    struct Session: Codable {
        struct SavedEntry: Codable {
            var trackID: ID
            var isAutoplay: Bool
        }
        var entries: [SavedEntry]
        var index: Int
        var time: Double
        var wasActive: Bool
        var context: PlaybackContext?
        var shuffle: Bool
        var repeatMode: RepeatMode
    }

    static let sessionKey = "playbackSession"
    private var restoring = false

    func persistSession(cleanExit: Bool = false) {
        guard !restoring else { return }
        guard let index, !queue.isEmpty else {
            try? services.db.setValue(Optional<Session>.none, forKey: Self.sessionKey)
            return
        }
        let session = Session(
            entries: queue.map { .init(trackID: $0.trackID, isAutoplay: $0.isAutoplay) }, index: index,
            time: state == .waiting ? 0 : time, wasActive: !cleanExit && (state == .playing || state == .waiting),
            context: context, shuffle: shuffle, repeatMode: repeatMode)
        try? services.db.setValue(session, forKey: Self.sessionKey)
    }

    /// Rebuilds the queue saved by the last run. Resumes playing if the app didn't quit normally.
    func restoreSession() {
        guard index == nil, let saved = services.db.value(Session.self, forKey: Self.sessionKey) else { return }
        let ids = saved.entries.map(\.trackID)
        let existing = Set(
            (try? services.db.reader.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM track WHERE id IN (\(ids.map { "'\($0)'" }.joined(separator: ",")))")
            }) ?? [])
        var entries: [Entry] = []
        var start = 0
        for (i, e) in saved.entries.enumerated() where existing.contains(e.trackID) {
            if i <= saved.index { start = entries.count }
            entries.append(Entry(trackID: e.trackID, isAutoplay: e.isAutoplay))
        }
        guard !entries.isEmpty else { return }
        restoring = true
        defer { restoring = false }
        context = saved.context
        repeatMode = saved.repeatMode
        shuffleSilently(saved.shuffle)
        queue = entries
        unshuffled = entries
        load(index: start, autoPlay: false)
        if state == .paused, saved.time > 0 {
            output.seek(to: min(saved.time, max(0, duration - 1)))
            time = output.currentTime
        }
        if saved.wasActive {
            if state == .paused { resume() }
        } else if state == .waiting {
            // Quit while waiting for a recording: don't start recording until asked.
            output.stop()
            state = .idle
            refreshDemand()
        }
        updateNowPlaying()
    }

    // MARK: Derived

    var currentEntry: Entry? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }

    var upNext: [Entry] {
        guard let index else { return queue }
        return Array(queue.dropFirst(index + 1))
    }

    var history: [Entry] {
        guard let index else { return [] }
        return Array(queue.prefix(index))
    }

    var isPlaying: Bool { state == .playing }
    var isWaiting: Bool { state == .waiting }

    private func isAfterCurrent(_ entry: Entry) -> Bool {
        guard let index, let i = queue.firstIndex(of: entry) else { return true }
        return i > index
    }

    // MARK: Starting playback

    /// Plays an album from the top (or from `trackID`). Unrecorded songs record in order.
    func play(albumID: ID, startingAt trackID: ID? = nil, shuffled: Bool = false) {
        guard let info = try? services.db.albumInfo(albumID),
            let tracks = try? services.db.tracks(forAlbum: albumID), !tracks.isEmpty
        else { return }
        play(
            trackIDs: tracks.map(\.id), startingAt: trackID, context: .album(albumID, info.album.title),
            shuffled: shuffled)
    }

    func play(trackIDs: [ID], startingAt trackID: ID? = nil, context: PlaybackContext, shuffled: Bool = false) {
        guard !trackIDs.isEmpty else { return }
        logCurrentPlay(skipped: true)
        self.context = context
        var entries = trackIDs.map { Entry(trackID: $0) }
        unshuffled = entries
        recording.clearFailures(trackIDs)
        var start = trackID.flatMap { id in entries.firstIndex { $0.trackID == id } } ?? 0
        if shuffled {
            let first = entries.remove(at: trackID == nil ? Int.random(in: 0 ..< entries.count) : start)
            entries.shuffle()
            entries.insert(first, at: 0)
            start = 0
        }
        shuffleSilently(shuffled)
        queue = entries
        load(index: start, autoPlay: true)
    }

    func playNext(_ trackIDs: [ID]) {
        let entries = trackIDs.map { Entry(trackID: $0) }
        guard let index else {
            play(trackIDs: trackIDs, context: .songs("Queue"))
            return
        }
        queue.insert(contentsOf: entries, at: index + 1)
        unshuffled.append(contentsOf: entries)
        refreshDemand()
    }

    func playLater(_ trackIDs: [ID]) {
        let entries = trackIDs.map { Entry(trackID: $0) }
        guard index != nil else {
            play(trackIDs: trackIDs, context: .songs("Queue"))
            return
        }
        let firstAutoplay = queue.indices.first { queue[$0].isAutoplay && isAfterCurrent(queue[$0]) } ?? queue.endIndex
        queue.insert(contentsOf: entries, at: firstAutoplay)
        unshuffled.append(contentsOf: entries)
        refreshDemand()
    }

    func jump(to entry: Entry) {
        guard let i = queue.firstIndex(of: entry) else { return }
        logCurrentPlay(skipped: true)
        load(index: i, autoPlay: true)
    }

    func remove(_ entry: Entry) {
        guard let i = queue.firstIndex(of: entry), i != index else { return }
        queue.remove(at: i)
        if let idx = index, i < idx { index = idx - 1 }
        refreshDemand()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        guard let index else { return }
        // Offsets are relative to Up Next.
        var upcoming = Array(queue.dropFirst(index + 1))
        upcoming.move(fromOffsets: fromOffsets, toOffset: toOffset)
        queue = Array(queue.prefix(index + 1)) + upcoming
        refreshDemand()
    }

    func clearUpNext() {
        guard let index else { return }
        queue = Array(queue.prefix(index + 1))
        refreshDemand()
    }

    // MARK: Transport

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .waiting: break
        case .idle:
            if index != nil { load(index: index!, autoPlay: true) }
        }
    }

    func pause() {
        guard state == .playing else { return }
        output.pause()
        state = .paused
        accumulatePlayTime()
        stopTicker()
        updateNowPlaying()
        persistSession()
    }

    func resume() {
        guard state == .paused else { return }
        output.play()
        state = .playing
        playStartedAt = Date()
        startTicker()
        updateNowPlaying()
        persistSession()
    }

    func next() {
        guard let index else { return }
        logCurrentPlay(skipped: state == .playing && time < duration - 5)
        if index + 1 < queue.count {
            load(index: index + 1, autoPlay: true)
        } else if appendAutoplayAlbum() {
            load(index: index + 1, autoPlay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            load(index: 0, autoPlay: true)
        } else {
            stop()
        }
    }

    func previous() {
        guard let index else { return }
        if time > 3 || index == 0 {
            seek(to: 0)
            return
        }
        logCurrentPlay(skipped: true)
        load(index: index - 1, autoPlay: true)
    }

    func seek(to seconds: Double) {
        guard state != .waiting, current != nil else { return }
        output.seek(to: max(0, min(seconds, duration)))
        time = output.currentTime
        updateNowPlaying()
    }

    func stop() {
        logCurrentPlay(skipped: false)
        output.stop()
        state = .idle
        time = 0
        stopTicker()
        refreshDemand()
        updateNowPlaying()
    }

    // MARK: Loading

    private func load(index newIndex: Int, autoPlay: Bool) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        let entry = queue[newIndex]
        current = try? services.db.trackInfo(entry.trackID)
        observeCurrent(entry.trackID)
        playedSeconds = 0
        playStartedAt = nil
        guard let info = current else {
            // The track was deleted: move on to the next one that still exists, without recursing.
            queue.remove(at: newIndex)
            if queue.indices.contains(newIndex) {
                load(index: newIndex, autoPlay: autoPlay)
            } else {
                index = queue.isEmpty ? nil : queue.count - 1
                stop()
            }
            return
        }
        if info.track.isPlayable, let path = info.track.audioPath {
            do {
                try output.load(Paths.resolve(path))
                applyGain(info.track)
                duration = output.duration
                time = 0
                if autoPlay {
                    output.play()
                    state = .playing
                    playStartedAt = Date()
                    startTicker()
                } else {
                    state = .paused
                }
            } catch {
                // The file is gone or damaged: send it back to the studio.
                _ = try? services.db.modifyTrack(info.track.id) {
                    $0.status = .pending
                    $0.audioPath = nil
                }
                waitForRecording(info)
            }
        } else {
            waitForRecording(info)
        }
        refreshDemand()
        updateNowPlaying()
    }

    private func waitForRecording(_ info: TrackInfo) {
        output.stop()
        state = .waiting
        time = 0
        duration = info.track.duration ?? 0
        stopTicker()
    }

    /// Shown by the app when playback has to skip something.
    var onNotice: ((String) -> Void)?

    /// The studio couldn't record the song we're waiting on: skip ahead instead of waiting forever.
    private func trackFailed(_ id: ID, message: String) {
        guard let current, current.track.id == id, state == .waiting, let index else {
            refreshDemand()
            return
        }
        onNotice?("Couldn't record “\(current.track.title)” — skipping ahead. You can retry it from the album.")
        if index + 1 < queue.count || appendAutoplayAlbum() {
            load(index: index + 1, autoPlay: true)
        } else {
            stop()
        }
    }

    private func trackBecameReady(_ id: ID) {
        if let current, current.track.id == id {
            self.current = try? services.db.trackInfo(id)
            if state == .waiting, let index { load(index: index, autoPlay: true) }
        }
        refreshDemand()
    }

    private func trackFinished() {
        logCurrentPlay(skipped: false)
        if repeatMode == .one, let index {
            load(index: index, autoPlay: true)
            return
        }
        guard let index else { return }
        if index + 1 < queue.count || appendAutoplayAlbum() {
            load(index: index + 1, autoPlay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            load(index: 0, autoPlay: true)
        } else {
            state = .idle
            stopTicker()
            time = duration
            updateNowPlaying()
            refreshDemand()
        }
    }

    private func applyGain(_ track: Track) {
        guard UserDefaults.standard.bool(forKey: Pref.normalizeVolume), let loudness = track.loudness else {
            output.gainDB = 0
            return
        }
        output.gainDB = Float(max(-10, min(6, -14 - loudness)))
    }

    /// Keeps `current` fresh (favourite toggles, lyrics written, recording finished).
    private func observeCurrent(_ id: ID) {
        observation = ValueObservation.tracking { db in try AppDatabase.trackInfos().filter(key: id).fetchOne(db) }
            .start(in: services.db.reader, scheduling: .immediate, onError: { _ in }) { [weak self] info in
                guard let self, let info, self.current?.track.id == info.track.id else { return }
                self.current = info
            }
    }

    // MARK: Recording demand

    /// Tells the studio which songs we'll need next: the current one if unrecorded, then the next few.
    func refreshDemand() {
        defer { persistSession() }
        let lookahead = max(1, UserDefaults.standard.integer(forKey: Pref.lookahead))
        if let index, autoplay, queue.count - index - 1 < lookahead { _ = appendAutoplayAlbum() }
        guard let index, state != .idle else {
            recording.setPlaybackDemand([])
            return
        }
        let ids = queue[index...].map(\.trackID)
        let ready = Set(
            (try? services.db.reader.read { db in
                try String.fetchAll(
                    db, sql: "SELECT id FROM track WHERE status = 'ready' AND id IN (\(ids.map { "'\($0)'" }.joined(separator: ",")))")
            }) ?? [])
        let needed = ids.filter { !ready.contains($0) }.prefix(lookahead + 1)
        recording.setPlaybackDemand(Array(needed))
    }

    @discardableResult
    private func appendAutoplayAlbum() -> Bool {
        guard autoplay, repeatMode == .off, let seed = currentEntry.flatMap({ e in try? services.db.trackInfo(e.trackID) })
        else { return false }
        let queuedAlbums = Set(queue.compactMap { e in try? services.db.reader.read { db in try String.fetchOne(db, sql: "SELECT albumID FROM track WHERE id = ?", arguments: [e.trackID]) } })
        guard let album = AutoplayPicker(db: services.db).nextAlbum(after: seed, excluding: queuedAlbums),
            let tracks = try? services.db.tracks(forAlbum: album.id), !tracks.isEmpty
        else { return false }
        queue.append(contentsOf: tracks.map { Entry(trackID: $0.id, isAutoplay: true) })
        return true
    }

    // MARK: Shuffle

    private var shuffling = false

    private func shuffleSilently(_ value: Bool) {
        shuffling = true
        shuffle = value
        shuffling = false
    }

    private func applyShuffle() {
        guard !shuffling, let index else { return }
        let current = queue[index]
        if shuffle {
            unshuffled = queue
            var rest = queue.enumerated().filter { $0.offset > index && !$0.element.isAutoplay }.map(\.element)
            rest.shuffle()
            queue = Array(queue.prefix(index + 1)) + rest + queue.filter { $0.isAutoplay && isAfterCurrent($0) }
        } else if !unshuffled.isEmpty {
            // Restore the original order for what's still queued; anything added since keeps its place at the end.
            let upcoming = Array(queue.dropFirst(index + 1))
            let upcomingIDs = Set(upcoming.map(\.id))
            let originalIDs = Set(unshuffled.map(\.id))
            let restored = unshuffled.filter { upcomingIDs.contains($0.id) } + upcoming.filter { !originalIDs.contains($0.id) }
            queue = Array(queue.prefix(index + 1)) + restored
        }
        self.index = queue.firstIndex(of: current)
        refreshDemand()
    }

    // MARK: Listening history

    private func accumulatePlayTime() {
        if let start = playStartedAt { playedSeconds += Date().timeIntervalSince(start) }
        playStartedAt = nil
    }

    private func logCurrentPlay(skipped: Bool) {
        accumulatePlayTime()
        guard let current, playedSeconds > 2 else { return }
        let completed = !skipped && duration > 0
        try? services.db.recordPlay(
            PlayEvent(trackID: current.track.id, startedAt: Date().addingTimeInterval(-playedSeconds),
                secondsPlayed: playedSeconds, completed: completed, skipped: skipped && playedSeconds < 30))
        playedSeconds = 0
    }

    // MARK: Ticker & Now Playing

    private var tick = 0

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = self.output.currentTime
                self.tick += 1
                if self.tick % 20 == 0 { self.persistSession() }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        if state != .playing { level = 0 }
    }

    private func updateNowPlaying() {
        nowPlaying.update(
            info: current, state: state, time: time, duration: duration,
            artwork: current?.album.coverPath.map { services.artwork.url(for: $0) })
    }
}

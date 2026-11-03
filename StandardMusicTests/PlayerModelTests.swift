import Foundation
import StandardKit
import Testing
@testable import Standard_Music

/// Player behavior against a real library in the throwaway `SM_HOME` set by the test scheme.
/// No one is signed in to ChatGPT there, so every recording attempt fails at the lyrics step, which
/// is exactly the failure path the player has to survive.
@MainActor
@Suite(.serialized)
struct PlayerModelTests {
    let services: Services
    let recording: RecordingQueue
    let player: PlayerModel

    init() throws {
        // Never run against someone's real library.
        try #require(ProcessInfo.processInfo.environment["SM_HOME"] != nil, "Run through the StandardMusic test scheme")
        Pref.register()
        services = try Services()
        recording = RecordingQueue(services: services)
        player = PlayerModel(services: services, recording: recording)
    }

    /// One ready (but unrecorded) album with `tracks` songs.
    func seedAlbum(tracks count: Int, genre: String = "shoegaze") throws -> (Album, [Track]) {
        var artist = Artist(
            name: "Test Artist \(UUID().uuidString.prefix(8))", primaryGenre: genre, genres: [genre], formedYear: 1991,
            tier: .core, plannedAlbumCount: 1)
        artist.status = .ready
        try services.db.save(artist: artist)
        var album = Album(
            artistID: artist.id, title: "Test Album \(UUID().uuidString.prefix(8))", releaseYear: 1993, kind: .album,
            primaryGenre: genre, genres: [genre], trackCount: count)
        album.status = .ready
        let tracks = (1 ... count).map {
            Track(
                albumID: album.id, artistID: artist.id, trackNumber: $0, title: "Song \($0)", details: "",
                styleTags: "English, \(genre)", vocal: "female", bpm: 100, mood: "hazy")
        }
        try services.db.save(album: album, tracks: tracks)
        return (album, tracks)
    }

    /// Runs `body` with the given preferences, then puts the listener's own settings back
    /// (hosted tests share the app's defaults domain).
    func withDefaults(_ values: [String: Any], _ body: () async throws -> Void) async rethrows {
        let saved = values.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        try await body()
    }

    func withAutoplay(_ value: Bool, _ body: () async throws -> Void) async rethrows {
        try await withDefaults([Pref.autoplay: value], body)
    }

    /// Marks a track as recorded without a real file (enough for demand, which only reads status).
    func markReady(_ id: ID) throws {
        try services.db.modifyTrack(id) {
            $0.status = .ready
            $0.audioPath = "Audio/missing-\(id).m4a"
        }
    }

    func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Autoplay off (regression: exclusivity crash in the setter)

    @Test func turningAutoplayOffDropsUpcomingAutoplayAlbums() async throws {
        try await withAutoplay(true) {
            let (album, tracks) = try seedAlbum(tracks: 2)
            _ = try seedAlbum(tracks: 3)  // something for autoplay to pick
            player.play(albumID: album.id)
            // Near the end of a short album, the player has already lined up a similar one.
            try #require(player.queue.contains { $0.isAutoplay })

            player.autoplay = false  // used to crash: removeAll read `queue` while mutating it

            #expect(player.queue.map(\.trackID) == tracks.map(\.id))
            #expect(!player.queue.contains { $0.isAutoplay })
            #expect(player.index == 0)
        }
    }

    @Test func turningAutoplayOffKeepsTheCurrentAndEarlierAutoplaySongs() async throws {
        try await withAutoplay(true) {
            let (album, _) = try seedAlbum(tracks: 1)
            _ = try seedAlbum(tracks: 2)
            _ = try seedAlbum(tracks: 2)
            player.play(albumID: album.id)
            let firstAutoplay = try #require(player.queue.first { $0.isAutoplay })
            player.jump(to: firstAutoplay)  // now playing from an autoplay album
            let current = try #require(player.currentEntry)
            let before = player.queue.prefix(through: try #require(player.index))

            player.autoplay = false

            #expect(player.currentEntry == current)
            #expect(Array(player.queue.prefix(through: try #require(player.index))) == Array(before))
            #expect(!player.upNext.contains { $0.isAutoplay })
        }
    }

    // MARK: Recording failures (regression: player stuck waiting forever)

    @Test func playerSkipsPastASongThatFailsToRecord() async throws {
        try await withAutoplay(false) {
            let (album, tracks) = try seedAlbum(tracks: 2)
            player.play(albumID: album.id)
            #expect(player.state == .waiting)
            #expect(player.currentEntry?.trackID == tracks[0].id)

            // Song 1 fails → the player moves on to song 2, which fails too → the album is over.
            try await eventually { player.state == .idle }

            #expect(player.state == .idle)
            #expect(player.index == 1)
            #expect(recording.failures[tracks[0].id] != nil)
            #expect(recording.failures[tracks[1].id] != nil)
        }
    }

    @Test func aFailureOnAnotherSongDoesNotMoveThePlayer() async throws {
        try await withAutoplay(false) {
            let (_, otherTracks) = try seedAlbum(tracks: 1)
            recording.request([otherTracks[0].id])  // "Record Album" on something else
            let (album, tracks) = try seedAlbum(tracks: 1)
            player.play(albumID: album.id)

            try await eventually { recording.failures[otherTracks[0].id] != nil && recording.failures[tracks[0].id] != nil }

            // The listener's song failed too, so it ends; the unrelated failure must not have skipped anything.
            #expect(recording.failures[otherTracks[0].id] != nil)
            #expect(player.queue.map(\.trackID) == tracks.map(\.id))
            #expect(player.currentEntry?.trackID == tracks[0].id)
        }
    }

    @Test func playingAnAlbumAgainRetriesSongsThatFailedEarlier() async throws {
        try await withAutoplay(false) {
            let (album, tracks) = try seedAlbum(tracks: 1)
            player.play(albumID: album.id)
            try await eventually { recording.failures[tracks[0].id] != nil }
            try #require(recording.failures[tracks[0].id] != nil)
            #expect(try services.db.trackInfo(tracks[0].id)?.track.status == .failed)

            player.play(albumID: album.id)

            // Cleared synchronously and sent back to the studio, so the player waits instead of giving up.
            #expect(recording.failures[tracks[0].id] == nil)
            #expect(player.state == .waiting)
            #expect(recording.isQueued(tracks[0].id))
        }
    }

    // MARK: Queue order

    @Test func playNextGoesRightAfterTheCurrentSong() async throws {
        try await withAutoplay(false) {
            let (album, tracks) = try seedAlbum(tracks: 3)
            let (_, extra) = try seedAlbum(tracks: 2)
            player.play(albumID: album.id)

            player.playNext(extra.map(\.id))

            #expect(player.queue.map(\.trackID) == [tracks[0].id] + extra.map(\.id) + tracks[1...].map(\.id))
            #expect(player.index == 0)
        }
    }

    @Test func playLaterGoesBeforeAutoplayAlbums() async throws {
        try await withAutoplay(true) {
            let (album, tracks) = try seedAlbum(tracks: 2)
            _ = try seedAlbum(tracks: 2)
            let (_, extra) = try seedAlbum(tracks: 1)
            player.play(albumID: album.id)
            try #require(player.queue.contains { $0.isAutoplay })

            player.playLater(extra.map(\.id))

            let ids = player.queue.map(\.trackID)
            #expect(Array(ids.prefix(3)) == tracks.map(\.id) + [extra[0].id])
            #expect(!player.queue[3...].contains { !$0.isAutoplay })
            #expect(!player.queue[..<3].contains { $0.isAutoplay })
        }
    }

    @Test func shuffledPlayStartsWithTheChosenSong() async throws {
        try await withAutoplay(false) {
            let (album, tracks) = try seedAlbum(tracks: 6)

            player.play(albumID: album.id, startingAt: tracks[3].id, shuffled: true)

            #expect(player.shuffle)
            #expect(player.index == 0)
            #expect(player.currentEntry?.trackID == tracks[3].id)
            #expect(Set(player.queue.map(\.trackID)) == Set(tracks.map(\.id)))
            #expect(player.queue.count == tracks.count)
        }
    }

    // MARK: Shuffle restore

    @Test func shuffleOffRestoresAlbumOrder() async throws {
        try await withAutoplay(false) {
            let (album, tracks) = try seedAlbum(tracks: 8)
            player.play(albumID: album.id)
            let current = try #require(player.currentEntry)

            player.shuffle = true
            #expect(player.currentEntry == current)
            #expect(Set(player.upNext.map(\.trackID)) == Set(tracks[1...].map(\.id)))

            player.shuffle = false
            #expect(player.currentEntry == current)
            #expect(player.queue.map(\.trackID) == tracks.map(\.id))
        }
    }

    @Test func shuffleOffKeepsRemovalsAndAdditions() async throws {
        try await withAutoplay(false) {
            let (album, tracks) = try seedAlbum(tracks: 6)
            let (_, extra) = try seedAlbum(tracks: 1)
            player.play(albumID: album.id)
            player.shuffle = true

            let removed = try #require(player.upNext.first { $0.trackID == tracks[2].id })
            player.remove(removed)
            player.playLater(extra.map(\.id))
            player.shuffle = false

            // Original order for what's left, the removed song stays gone, the addition stays queued.
            let expected = tracks.map(\.id).filter { $0 != tracks[2].id } + [extra[0].id]
            #expect(player.queue.map(\.trackID) == expected)
        }
    }

    // MARK: Recording demand

    @Test func demandIsTheCurrentSongThenTheNextUnrecordedOnes() async throws {
        try await withDefaults([Pref.autoplay: false, Pref.lookahead: 2]) {
            let (album, tracks) = try seedAlbum(tracks: 6)
            try markReady(tracks[1].id)

            player.play(albumID: album.id)

            // Current (unrecorded) first, the recorded song 2 skipped, then lookahead (2) more.
            #expect(recording.playbackDemand == [tracks[0].id, tracks[2].id, tracks[3].id])
        }
    }

    @Test func demandFollowsQueueChanges() async throws {
        try await withDefaults([Pref.autoplay: false, Pref.lookahead: 1]) {
            let (album, tracks) = try seedAlbum(tracks: 4)
            let (_, extra) = try seedAlbum(tracks: 1)
            player.play(albumID: album.id)
            #expect(recording.playbackDemand == [tracks[0].id, tracks[1].id])

            player.playNext(extra.map(\.id))
            #expect(recording.playbackDemand == [tracks[0].id, extra[0].id])

            player.stop()
            #expect(recording.playbackDemand.isEmpty)
        }
    }

    @Test func autoplayPicksTheMostSimilarAlbum() throws {
        let genre = "zydeco-\(UUID().uuidString.prefix(6))"
        let (seed, seedTracks) = try seedAlbum(tracks: 2, genre: genre)
        let (similar, _) = try seedAlbum(tracks: 2, genre: genre)
        _ = try seedAlbum(tracks: 2, genre: "death metal")
        let info = try #require(try services.db.trackInfo(seedTracks[0].id))
        let picked = AutoplayPicker(db: services.db).nextAlbum(after: info, excluding: [])
        #expect(picked?.id == similar.id)
        #expect(picked?.id != seed.id)
    }
}

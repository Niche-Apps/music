import Foundation
import GRDB
import Testing
@testable import StandardKit

@Suite struct OpenerTests {
    func artist(_ name: String, _ genre: String, genres: [String] = [], tier: TasteTier = .core) -> Artist {
        Artist(name: name, primaryGenre: genre, genres: genres.isEmpty ? [genre] : genres, formedYear: 2000, tier: tier, plannedAlbumCount: 2)
    }

    func track(_ number: Int, _ title: String, album: ID = "a", instrumental: Bool = false) -> Track {
        Track(albumID: album, artistID: "x", trackNumber: number, title: title, details: "", styleTags: "", vocal: "female",
              bpm: 100, mood: "", isInstrumental: instrumental)
    }

    // MARK: Genre

    @Test func favouriteGenreIsTheFirstCoreGenre() {
        var taste = TasteProfile()
        taste.coreGenres = ["shoegaze", "dream pop", "post-punk"]
        #expect(Opener.favoriteGenre(taste) == "shoegaze")
    }

    @Test func likedArtistsPullTheFavouriteGenre() {
        var taste = TasteProfile()
        taste.coreGenres = ["shoegaze", "dream pop", "post-punk"]
        taste.likedArtists = [
            SeedArtist(catalogID: nil, name: "A", genres: ["post-punk revival"]),
            SeedArtist(catalogID: nil, name: "B", genres: ["post-punk"]),
        ]
        #expect(Opener.favoriteGenre(taste) == "post-punk")
    }

    @Test func fallsBackToSelectedGenres() {
        var taste = TasteProfile()
        #expect(Opener.favoriteGenre(taste) == nil)
        taste.selectedGenres = ["Jazz"]
        #expect(Opener.favoriteGenre(taste) == "Jazz")
    }

    // MARK: Artist

    @Test func picksTheCoreArtistInTheFavouriteGenre() {
        let roster = [
            artist("Wild One", "dream pop", tier: .wildcard),
            artist("Near", "indie rock", tier: .adjacent),
            artist("Loose Fit", "cinematic dream pop"),
            artist("Exact", "dream pop"),
            artist("Also Exact", "dream pop"),
        ]
        #expect(Opener.pickArtist(roster, genre: "Dream Pop")?.name == "Exact")
    }

    @Test func broadWordsAloneDontCountAsAMatch() {
        #expect(Opener.match(artist("X", "pop punk"), genre: "synth pop") == 0)
        #expect(Opener.match(artist("Y", "cinematic dream pop"), genre: "dream pop") == 1)
        #expect(Opener.match(artist("Z", "folk", genres: ["folk", "dream pop"]), genre: "dream pop") == 2)
        #expect(Opener.match(artist("W", "pop"), genre: "pop") == 3)
    }

    @Test func skipsFailedArtistsAndStillPicksSomeone() {
        var failed = artist("Gone", "techno")
        failed.status = .failed
        let roster = [failed, artist("Other", "house", tier: .adjacent), artist("Core", "ambient")]
        #expect(Opener.pickArtist(roster, genre: "techno")?.name == "Core")
        #expect(Opener.pickArtist([failed], genre: "techno") == nil)
    }

    // MARK: Release and song

    @Test func leadAlbumPrefersTheDebutFullLength() {
        let single = Album(artistID: "x", title: "S", releaseYear: 1990, kind: .single, primaryGenre: "", genres: [], trackCount: 1)
        let second = Album(artistID: "x", title: "B", releaseYear: 1996, kind: .album, primaryGenre: "", genres: [], trackCount: 10)
        let debut = Album(artistID: "x", title: "A", releaseYear: 1993, kind: .album, primaryGenre: "", genres: [], trackCount: 10)
        #expect(Opener.leadAlbum([single, second, debut])?.title == "A")
        #expect(Opener.leadAlbum([single])?.title == "S")
    }

    @Test func pickTrackSkipsIntrosAndInstrumentals() {
        let tracks = [track(3, "Third"), track(1, "Intro"), track(2, "Glass Hymn", instrumental: true), track(4, "Fourth")]
        #expect(Opener.pickTrack(tracks)?.title == "Third")
        #expect(Opener.pickTrack([track(1, "Halo Feedback"), track(2, "Two")])?.title == "Halo Feedback")
        // Nothing but intros: still play something.
        #expect(Opener.pickTrack([track(2, "Reprise"), track(1, "Prelude")])?.title == "Prelude")
    }

    // MARK: Persistence

    func makeLibrary() throws -> AppDatabase {
        try AppDatabase(url: FileManager.default.temporaryDirectory.appending(path: "sk-\(UUID())/Library.sqlite"))
    }

    @Test func resolvesOnceTracksAreWrittenAndKeepsTheChoice() throws {
        let db = try makeLibrary()
        let star = artist("Static Choir", "shoegaze")
        try db.save(artist: star)
        try db.setOpenerState(OpenerState(genre: "shoegaze", artistID: star.id))
        // Dossier written, no songs yet.
        #expect(try db.resolveOpener()?.trackID == nil)

        let album = Album(artistID: star.id, title: "Bloom", releaseYear: 1993, kind: .album, primaryGenre: "shoegaze", genres: [], trackCount: 2)
        let tracks = [
            Track(albumID: album.id, artistID: star.id, trackNumber: 1, title: "Intro", details: "", styleTags: "", vocal: "female", bpm: 90, mood: ""),
            Track(albumID: album.id, artistID: star.id, trackNumber: 2, title: "Halo", details: "", styleTags: "", vocal: "female", bpm: 90, mood: ""),
        ]
        try db.save(album: album, tracks: tracks)
        let resolved = try db.resolveOpener()
        #expect(resolved?.trackID == tracks[1].id)
        #expect(resolved?.albumID == album.id)
        // A relaunch reads back the same song.
        #expect(try db.resolveOpener() == resolved)
        #expect(db.openerState == resolved)
    }

    @Test func fallsBackWhenTheOpenerArtistFails() throws {
        let db = try makeLibrary()
        var gone = artist("Gone", "shoegaze")
        gone.status = .failed
        let backup = artist("Backup", "shoegaze")
        try db.save(artist: gone)
        try db.save(artist: backup)
        try db.setOpenerState(OpenerState(genre: "shoegaze", artistID: gone.id))
        #expect(try db.resolveOpener()?.trackID == nil)

        let album = Album(artistID: backup.id, title: "Bloom", releaseYear: 1993, kind: .album, primaryGenre: "shoegaze", genres: [], trackCount: 1)
        let song = Track(albumID: album.id, artistID: backup.id, trackNumber: 1, title: "Halo", details: "", styleTags: "", vocal: "female", bpm: 90, mood: "")
        try db.save(album: album, tracks: [song])
        let resolved = try db.resolveOpener()
        #expect(resolved?.artistID == backup.id)
        #expect(resolved?.trackID == song.id)
    }

    @Test func nothingToResolveBeforeTheBuilderChooses() throws {
        let db = try makeLibrary()
        #expect(try db.resolveOpener() == nil)
        try db.setOpenerState(OpenerState(genre: "jazz"))
        #expect(try db.resolveOpener() == OpenerState(genre: "jazz"))
    }

    @Test func urgentWaitersJumpTheLine() async {
        let gate = AsyncSemaphore(1)
        await gate.wait()
        let order = OrderLog()
        let normal = Task { await gate.wait(); await order.add("normal"); await gate.signal() }
        try? await Task.sleep(for: .milliseconds(50))
        let urgent = Task { await gate.wait(first: true); await order.add("urgent"); await gate.signal() }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.signal()
        await normal.value
        await urgent.value
        #expect(await order.items == ["urgent", "normal"])
    }
}

actor OrderLog {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

@Suite struct OpenerSongTests {
    @Test func snapshotFollowsTheChosenTrack() throws {
        let db = try AppDatabase(url: FileManager.default.temporaryDirectory.appending(path: "sk-\(UUID())/Library.sqlite"))
        #expect(try db.reader.read(OpenerSong.fetch) == .none)
        let artist = Artist(name: "Static Choir", primaryGenre: "shoegaze", genres: ["shoegaze"], formedYear: 1991, tier: .core, plannedAlbumCount: 1)
        try db.save(artist: artist)
        try db.setOpenerState(OpenerState(genre: "shoegaze", artistID: artist.id))
        var song = try db.reader.read(OpenerSong.fetch)
        #expect(song.artist?.id == artist.id)
        #expect(song.track == nil)
        let album = Album(artistID: artist.id, title: "Bloom", releaseYear: 1993, kind: .album, primaryGenre: "shoegaze", genres: [], trackCount: 1)
        let track = Track(albumID: album.id, artistID: artist.id, trackNumber: 1, title: "Halo", details: "", styleTags: "", vocal: "female", bpm: 90, mood: "")
        try db.save(album: album, tracks: [track])
        try db.resolveOpener()
        song = try db.reader.read(OpenerSong.fetch)
        #expect(song.track?.id == track.id)
        #expect(song.album?.id == album.id)
    }
}

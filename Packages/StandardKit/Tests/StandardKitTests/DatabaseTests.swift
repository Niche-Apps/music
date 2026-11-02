import Foundation
import GRDB
import Testing
@testable import StandardKit

@Suite struct DatabaseTests {
    func makeLibrary() throws -> (AppDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sk-\(UUID())")
        let db = try AppDatabase(url: dir.appending(path: "Library.sqlite"))
        return (db, dir)
    }

    func seed(_ db: AppDatabase) throws -> (Artist, Album, [Track]) {
        var artist = Artist(name: "The Glass Weather", primaryGenre: "shoegaze", genres: ["shoegaze", "dream pop"], formedYear: 1991, tier: .core, plannedAlbumCount: 1)
        artist.status = .ready
        try db.save(artist: artist)
        let album = Album(artistID: artist.id, title: "Static Bloom", releaseYear: 1993, kind: .album, primaryGenre: "shoegaze", genres: ["shoegaze"], trackCount: 2)
        let tracks = (1 ... 2).map {
            Track(albumID: album.id, artistID: artist.id, trackNumber: $0, title: $0 == 1 ? "Halo Feedback" : "Quiet Engines", details: "", styleTags: "English, shoegaze", vocal: "female", bpm: 100, mood: "hazy")
        }
        try db.save(album: album, tracks: tracks)
        return (artist, album, tracks)
    }

    @Test func searchFindsArtistsAlbumsAndTracks() throws {
        let (db, _) = try makeLibrary()
        _ = try seed(db)
        #expect(try db.search("glass").first?.kind == .artist)
        #expect(try db.search("static bl").first?.kind == .album)
        #expect(try db.search("quiet eng").first?.title == "Quiet Engines")
        #expect(try db.search("dream").contains { $0.kind == .artist })
    }

    @Test func deletingArtistCascadesAndCleansSearch() throws {
        let (db, _) = try makeLibrary()
        let (artist, _, _) = try seed(db)
        try db.deleteArtist(artist.id)
        #expect(try db.reader.read { try Track.fetchCount($0) } == 0)
        #expect(try db.search("halo").isEmpty)
    }

    @Test func playsAreCounted() throws {
        let (db, _) = try makeLibrary()
        let (_, _, tracks) = try seed(db)
        try db.recordPlay(PlayEvent(trackID: tracks[0].id, startedAt: Date(), secondsPlayed: 200, completed: true, skipped: false))
        #expect(try db.reader.read { try Track.fetchOne($0, key: tracks[0].id) }?.playCount == 1)
    }

    @Test func corruptLibraryIsRestoredFromBackup() throws {
        let (db, dir) = try makeLibrary()
        _ = try seed(db)
        db.backupIfNeeded(interval: 0)
        let url = db.url
        try db.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        try db.writer.close()
        // Scribble over the middle of the file.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 8192))
        try handle.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let reopened = try AppDatabase(url: url)
        #expect(reopened.recoveredFromBackup != nil)
        #expect(try reopened.reader.read { try Artist.fetchCount($0) } == 1)
        let damaged = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("Damaged-") }
        #expect(damaged.count == 1)
    }

    @Test func backupsRotate() throws {
        let (db, dir) = try makeLibrary()
        _ = try seed(db)
        for _ in 0 ..< 4 {
            db.backupIfNeeded(interval: 0, keep: 2)
            Thread.sleep(forTimeInterval: 1.1)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "Backups").path)
            .filter { $0.hasSuffix(".sqlite") }
        #expect(backups.count == 2)
    }
}

@Suite struct SongWriterTests {
    @Test func normalisesSectionHeaders() {
        let raw = "[VERSE 1]\nLine one\n\n\n[Chorus x2]\nHook\n[pre chorus]\nRise\n[Hook]\nAgain"
        let cleaned = SongWriter.clean(raw)
        #expect(cleaned == "[Verse]\nLine one\n\n[Chorus]\nHook\n\n[Pre-Chorus]\nRise\n\n[Chorus]\nAgain")
    }
}

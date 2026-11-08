import Foundation
import GRDB
import Testing
@testable import StandardKit

/// New releases used to be dated the year after the artist's last one, landing in the future (#6).
@Suite struct ReleaseYearTests {
    @Test func futureReleasesComeBackToThisYear() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "years-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Library.sqlite")
        let year = LibraryBuilder.currentYear
        do {
            let db = try AppDatabase(url: url)
            let artist = Artist(name: "Darnell Quenby", primaryGenre: "soul", genres: [], formedYear: 2001, tier: .core, plannedAlbumCount: 2)
            try db.save(artist: artist)
            try db.save(album: Album(artistID: artist.id, title: "Half a Beat Too Soon", releaseYear: year + 1, kind: .single, primaryGenre: "soul", genres: [], soul: "", trackCount: 1), tracks: [])
            try db.save(album: Album(artistID: artist.id, title: "Early", releaseYear: 2004, kind: .album, primaryGenre: "soul", genres: [], soul: "", trackCount: 1), tracks: [])
            // As if the library predates the fix.
            try db.writer.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6-no-future-releases'") }
        }
        let db = try AppDatabase(url: url)
        let years = try db.reader.read { try Album.order(Column("title")).fetchAll($0).map(\.releaseYear) }
        #expect(years == [2004, year])
    }
}

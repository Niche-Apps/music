import Foundation
import GRDB
import Testing
@testable import StandardKit

@Suite struct ShareBundleTests {
    struct Library {
        let db: AppDatabase
        let root: URL
        var bundler: ShareBundler { ShareBundler(db: db, libraryRoot: root, artwork: ArtworkStore(root: root.appending(path: "Artwork"))) }
    }

    func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-test-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Audio"), withIntermediateDirectories: true)
        return Library(db: try AppDatabase(url: root.appending(path: "Library.sqlite")), root: root)
    }

    /// One artist, two albums of two songs; the first song of album one is recorded.
    func seed(_ lib: Library) throws -> (Artist, [Album], [Track]) {
        var artist = Artist(name: "The Lacquer Picnic", primaryGenre: "chamber pop", genres: ["chamber pop"], formedYear: 1997, tier: .core, plannedAlbumCount: 2)
        artist.soul = "secret soul"
        artist.voice = "male falsetto vocal, nasal"
        artist.status = .ready
        artist.isFavorite = true
        artist.imagePath = try ArtworkStore(root: lib.root.appending(path: "Artwork")).save(Data(repeating: 1, count: 64), kind: .artist, id: artist.id)
        try lib.db.save(artist: artist)
        var albums: [Album] = []
        var all: [Track] = []
        for (n, title) in ["Good China", "Second Helpings"].enumerated() {
            var album = Album(artistID: artist.id, title: title, releaseYear: 1999 + n, kind: .album, primaryGenre: "chamber pop", genres: [], soul: "album soul \(n)", trackCount: 2)
            album.status = .ready
            var tracks = (1 ... 2).map {
                Track(albumID: album.id, artistID: artist.id, trackNumber: $0, title: "\(title) \($0)", details: "private", styleTags: "chamber pop", vocal: "male", bpm: 90, mood: "wry")
            }
            tracks[0].lyrics = "[Verse]\nla la"
            if n == 0 {
                try Data("fake aac".utf8).write(to: lib.root.appending(path: "Audio/\(tracks[0].id).m4a"))
                tracks[0].status = .ready
                tracks[0].audioPath = "Audio/\(tracks[0].id).m4a"
                tracks[0].duration = 200
                tracks[0].playCount = 9
            }
            try lib.db.save(album: album, tracks: tracks)
            albums.append(album)
            all += tracks
        }
        return (artist, albums, all)
    }

    @Test func albumRoundTripsWithRecordingsAndSoul() throws {
        let sender = try makeLibrary()
        let (artist, albums, tracks) = try seed(sender)
        let outbox = sender.root.appending(path: "Outbox")
        let file = try sender.bundler.export(
            artistID: artist.id, albumIDs: [albums[0].id], includeRecordings: true, sharedBy: "Justin", engine: "YuE2 8-bit", to: outbox)
        #expect(file.lastPathComponent == "The Lacquer Picnic – Good China.standardalbum")

        let (manifest, folder) = try ShareBundler.preview(file)
        #expect(manifest.albums.count == 1)
        #expect(manifest.trackCount == 2)
        #expect(manifest.recordedCount == 1)
        #expect(manifest.sharedBy == "Justin")

        let recipient = try makeLibrary()
        let result = try recipient.bundler.importShare(manifest, from: folder)
        #expect(result.artistWasNew)
        #expect(result.albumsAdded == 1)
        #expect(result.recordingsAdded == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let imported = try #require(try recipient.db.reader.read { try Artist.fetchOne($0, key: artist.id) })
        #expect(imported.soul == "secret soul")
        #expect(imported.voice == "male falsetto vocal, nasal")
        #expect(imported.isFavorite == false)  // the sender's favourites stay private
        #expect(imported.imagePath != nil)
        let recorded = try #require(try recipient.db.reader.read { try Track.fetchOne($0, key: tracks[0].id) })
        #expect(recorded.isPlayable)
        #expect(recorded.playCount == 0)
        #expect(recorded.seed == tracks[0].seed)
        #expect(try Data(contentsOf: recipient.root.appending(path: recorded.audioPath!)) == Data("fake aac".utf8))
        let unrecorded = try #require(try recipient.db.reader.read { try Track.fetchOne($0, key: tracks[1].id) })
        #expect(unrecorded.status == .pending)
        #expect(try recipient.db.search("lacquer").first?.kind == .artist)
    }

    @Test func recipeOnlyShareIsTinyAndLeavesSongsToRecord() throws {
        let sender = try makeLibrary()
        let (artist, _, _) = try seed(sender)
        let file = try sender.bundler.export(
            artistID: artist.id, albumIDs: [], includeRecordings: false, sharedBy: nil, engine: nil,
            to: sender.root.appending(path: "Outbox"))
        let (manifest, folder) = try ShareBundler.preview(file)
        #expect(manifest.albums.count == 2)
        #expect(manifest.recordedCount == 0)
        let recipient = try makeLibrary()
        let result = try recipient.bundler.importShare(manifest, from: folder)
        #expect(result.recordingsAdded == 0)
        #expect(try recipient.db.reader.read { try Track.filter(Column("status") == "pending").fetchCount($0) } == 4)
    }

    @Test func reimportingKeepsLocalStateAndAddsOnlyWhatIsMissing() throws {
        let sender = try makeLibrary()
        let (artist, albums, tracks) = try seed(sender)
        let outbox = sender.root.appending(path: "Outbox")

        // First the recipe, then the same album again with its recording.
        let recipient = try makeLibrary()
        let first = try ShareBundler.preview(try sender.bundler.export(
            artistID: artist.id, albumIDs: [albums[0].id], includeRecordings: false, sharedBy: nil, engine: nil, to: outbox))
        _ = try recipient.bundler.importShare(first.manifest, from: first.folder)
        _ = try recipient.db.modifyArtist(artist.id) { $0.isFavorite = true }

        let second = try ShareBundler.preview(try sender.bundler.export(
            artistID: artist.id, albumIDs: [], includeRecordings: true, sharedBy: nil, engine: nil, to: outbox))
        let result = try recipient.bundler.importShare(second.manifest, from: second.folder)
        #expect(!result.artistWasNew)
        #expect(result.albumsAdded == 1)
        #expect(result.albumsUpdated == 1)
        #expect(result.recordingsAdded == 1)
        #expect(try recipient.db.reader.read { try Artist.fetchCount($0) } == 1)
        #expect(try recipient.db.reader.read { try Track.fetchCount($0) } == 4)
        #expect(try recipient.db.reader.read { try Artist.fetchOne($0, key: artist.id) }?.isFavorite == true)
        #expect(try recipient.db.reader.read { try Track.fetchOne($0, key: tracks[0].id) }?.isPlayable == true)
    }

    @Test func rejectsFilesThatAreNotShares() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notashare-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "x.standardalbum")
        try Data("hello".utf8).write(to: file)
        #expect(throws: ShareError.self) { try ShareBundler.preview(file) }
    }
}

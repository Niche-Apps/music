import AVFoundation
import Foundation
import Testing
@testable import StandardKit

@Suite struct AudioExportTests {
    /// Half a second of AAC, like a real recording.
    static func writeAAC(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        for c in 0 ..< 2 {
            for i in 0 ..< 24_000 { buffer.floatChannelData![c][i] = sin(Float(i) * 0.05) * 0.2 }
        }
        try file.write(from: buffer)
    }

    @Test func exportsAnArtistAlbumTrackFolderWithTags() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "export-test-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Audio"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(url: root.appending(path: "Library.sqlite"))
        let artwork = ArtworkStore(root: root.appending(path: "Artwork"))
        let bundler = ShareBundler(db: db, libraryRoot: root, artwork: artwork)

        var artist = Artist(name: "Glass/Harbor", primaryGenre: "dream pop", genres: [], formedYear: 2001, tier: .core, plannedAlbumCount: 1)
        artist.status = .ready
        try db.save(artist: artist)
        var album = Album(artistID: artist.id, title: "Low Tide", releaseYear: 2003, kind: .album, primaryGenre: "dream pop", genres: [], soul: "", trackCount: 3)
        album.status = .ready
        var tracks = (1 ... 3).map {
            Track(albumID: album.id, artistID: artist.id, trackNumber: $0, title: ["Salt", "Undertow", "Unrecorded"][$0 - 1],
                  details: "", styleTags: "", vocal: "", bpm: 90, mood: "")
        }
        for i in 0 ..< 2 {
            try Self.writeAAC(to: root.appending(path: "Audio/\(tracks[i].id).m4a"))
            tracks[i].status = .ready
            tracks[i].audioPath = "Audio/\(tracks[i].id).m4a"
        }
        tracks[0].lyrics = "[Verse]\nfolded light"
        try db.save(album: album, tracks: tracks)

        let out = root.appending(path: "Export")
        let first = try await bundler.exportAudio(to: out)
        #expect(first == AudioExportResult(exported: 2, skipped: 0, failed: 0))

        let folder = out.appending(path: "Glass-Harbor/Low Tide")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["01 Salt.m4a", "02 Undertow.m4a"])

        let asset = AVURLAsset(url: folder.appending(path: "01 Salt.m4a"))
        let metadata = try await asset.load(.metadata)
        func string(_ id: AVMetadataIdentifier) async throws -> String? {
            try await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first?.load(.stringValue)
        }
        #expect(try await string(.iTunesMetadataSongName) == "Salt")
        #expect(try await string(.iTunesMetadataArtist) == "Glass/Harbor")
        #expect(try await string(.iTunesMetadataAlbum) == "Low Tide")
        #expect(try await string(.iTunesMetadataReleaseDate) == "2003")
        #expect(try await string(.iTunesMetadataLyrics) == "[Verse]\nfolded light")
        let number = try await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataTrackNumber)
            .first?.load(.dataValue)
        #expect(number.map { [UInt8]($0) } == [0, 0, 0, 1, 0, 3, 0, 0])
        #expect(try await asset.load(.duration).seconds > 0.4)

        // Again: nothing new to write.
        let second = try await bundler.exportAudio(to: out)
        #expect(second == AudioExportResult(exported: 0, skipped: 2, failed: 0))
    }
}

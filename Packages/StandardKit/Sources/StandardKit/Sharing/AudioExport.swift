import AVFoundation
import Foundation
import GRDB

/// What an audio export did.
public struct AudioExportResult: Sendable, Equatable {
    /// Songs written this time.
    public var exported = 0
    /// Songs already in the folder from an earlier export, left untouched.
    public var skipped = 0
    /// Songs that couldn't be written.
    public var failed = 0
}

extension ShareBundler {
    /// Copies recorded songs into `directory` as a conventional music folder, for Finder, other players
    /// and backups. The library's own storage is untouched:
    ///
    ///     <Artist>/<Album>/01 <Title>.m4a      (multi-disc albums: 1-01 <Title>.m4a)
    ///
    /// Each file is tagged with title, artist, album, track and disc number, year, genre, lyrics and the
    /// cover. Files already present are skipped, so exporting again only adds what's new.
    /// `artistIDs`/`albumIDs` empty means everything.
    public func exportAudio(
        artistIDs: [ID] = [], albumIDs: [ID] = [], to directory: URL,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> AudioExportResult {
        let (artists, albums, tracks) = try await db.reader.read { db -> ([ID: Artist], [Album], [Track]) in
            var albumRequest = Album.all()
            if !artistIDs.isEmpty { albumRequest = albumRequest.filter(artistIDs.contains(Column("artistID"))) }
            if !albumIDs.isEmpty { albumRequest = albumRequest.filter(albumIDs.contains(Column("id"))) }
            let albums = try albumRequest.order(Column("releaseYear"), Column("createdAt")).fetchAll(db)
            let tracks = try Track
                .filter(albums.map(\.id).contains(Column("albumID")))
                .filter(Column("status") == TrackStatus.ready.rawValue && Column("audioPath") != nil)
                .order(Column("discNumber"), Column("trackNumber")).fetchAll(db)
            let artists = try Artist.filter(Set(albums.map(\.artistID)).contains(Column("id"))).fetchAll(db)
            return (Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) }), albums, tracks)
        }

        let fm = FileManager.default
        let byAlbum = Dictionary(grouping: tracks, by: \.albumID)
        var folders = Set<String>()
        var result = AudioExportResult()
        var done = 0
        for album in albums {
            guard let artist = artists[album.artistID], let songs = byAlbum[album.id], !songs.isEmpty else { continue }
            // Two releases with the same title by one artist get the year to tell them apart.
            let artistFolder = Self.folderName(artist.name, fallback: "Unknown Artist")
            var albumFolder = Self.folderName(album.title, fallback: "Untitled")
            if folders.contains("\(artistFolder)/\(albumFolder)") { albumFolder += " (\(album.releaseYear))" }
            folders.insert("\(artistFolder)/\(albumFolder)")
            let folder = directory.appending(path: artistFolder, directoryHint: .isDirectory)
                .appending(path: albumFolder, directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            let cover = album.coverPath.flatMap { try? Data(contentsOf: artwork.url(for: $0)) }
            let discs = Set(songs.map(\.discNumber)).count
            // "3 of 12" counts the whole release, recorded or not; a multi-disc total is left out.
            let total = discs > 1 ? 0 : album.trackCount
            for track in songs {
                defer {
                    done += 1
                    progress(done, tracks.count)
                }
                let number = String(format: "%02d", track.trackNumber)
                let name = (discs > 1 ? "\(track.discNumber)-\(number)" : number) + " "
                    + Self.folderName(track.title, fallback: "Track \(track.trackNumber)")
                let target = folder.appending(path: name + ".m4a")
                if fm.fileExists(atPath: target.path) {
                    result.skipped += 1
                    continue
                }
                guard let path = track.audioPath else { continue }
                let source = path.hasPrefix("/") ? URL(fileURLWithPath: path) : libraryRoot.appending(path: path)
                let tags = Self.tags(track: track, album: album, artist: artist, trackCount: total, cover: cover)
                do {
                    try await Self.writeTagged(source, to: target, metadata: tags)
                    result.exported += 1
                } catch {
                    try? fm.removeItem(at: target)
                    result.failed += 1
                }
            }
        }
        return result
    }

    static func folderName(_ name: String, fallback: String) -> String {
        // A leading dot would hide the file in Finder.
        var cleaned = safeFileName(name)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? fallback : cleaned
    }

    static func tags(track: Track, album: Album, artist: Artist, trackCount: Int, cover: Data?) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, type: CFString? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            if let type { item.dataType = type as String }
            return item
        }
        /// iTunes number pairs ("3 of 12"): two reserved bytes, the number, the total, two reserved bytes.
        func pair(_ number: Int, of total: Int) -> NSData {
            let bytes: [UInt8] = [0, 0, UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF),
                                  UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF), 0, 0]
            return Data(bytes) as NSData
        }
        var items = [
            item(.iTunesMetadataSongName, track.title as NSString),
            item(.iTunesMetadataArtist, artist.name as NSString),
            item(.iTunesMetadataAlbumArtist, artist.name as NSString),
            item(.iTunesMetadataAlbum, album.title as NSString),
            item(.iTunesMetadataReleaseDate, String(album.releaseYear) as NSString),
            item(.iTunesMetadataUserGenre, album.primaryGenre as NSString),
            item(.iTunesMetadataTrackNumber, pair(track.trackNumber, of: trackCount), type: kCMMetadataBaseDataType_RawData),
            item(.iTunesMetadataDiscNumber, pair(track.discNumber, of: 0), type: kCMMetadataBaseDataType_RawData),
        ]
        if let lyrics = track.lyrics, !lyrics.isEmpty { items.append(item(.iTunesMetadataLyrics, lyrics as NSString)) }
        if let cover { items.append(item(.iTunesMetadataCoverArt, cover as NSData, type: kCMMetadataBaseDataType_JPEG)) }
        return items
    }

    /// Re-wraps the recording without re-encoding and adds the tags.
    static func writeTagged(_ source: URL, to target: URL, metadata: [AVMetadataItem]) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.metadata = metadata
        try await session.export(to: target, as: .m4a)
    }
}

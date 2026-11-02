import AppKit
import Foundation
import StandardKit

/// An album (or a whole artist) the listener is about to share.
struct ShareRequest: Identifiable {
    let id = UUID()
    var artist: Artist
    /// Empty means every album by the artist.
    var albums: [Album]

    var title: String { albums.count == 1 ? albums[0].title : artist.name }
    var albumIDs: [ID] { albums.map(\.id) }
}

/// A received `.standardalbum`, unpacked and waiting for "Add to Library".
struct PendingImport: Identifiable {
    let id = UUID()
    var manifest: ShareManifest
    /// The unpacked archive; deleted after import or cancel.
    var folder: URL

    var artistImage: URL? { manifest.artist.image.map { folder.appending(path: $0) } }
    func cover(_ album: SharedAlbum) -> URL? { album.cover.map { folder.appending(path: $0) } }
}

extension AppModel {
    func share(album info: AlbumInfo) {
        shareRequest = ShareRequest(artist: info.artist, albums: [info.album])
    }

    func share(artist: Artist) {
        shareRequest = ShareRequest(artist: artist, albums: [])
    }

    /// The sender's first name, shown to the recipient.
    var shareSenderName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }

    // MARK: Receiving

    /// Opens a `.standardalbum` from Finder, a drop or File › Import. Waits for the library if needed.
    func openShareFile(_ url: URL) {
        guard phase == .library else {
            queuedShareFiles.append(url)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let (manifest, folder) = try await Task.detached(priority: .userInitiated) {
                    try ShareBundler.preview(url)
                }.value
                if let previous = pendingImport { try? FileManager.default.removeItem(at: previous.folder) }
                pendingImport = PendingImport(manifest: manifest, folder: folder)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    func openQueuedShares() {
        let files = queuedShareFiles
        queuedShareFiles = []
        // One import sheet at a time; the last file opened wins, like Finder's double-click.
        if let last = files.last { openShareFile(last) }
    }

    func confirmImport(_ pending: PendingImport) {
        pendingImport = nil
        let sharing = services.sharing
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try sharing.importShare(pending.manifest, from: pending.folder)
                }.value
                toast = Self.importMessage(result)
                if let album = result.firstAlbumID, pending.manifest.albums.count == 1 {
                    show(.album(album))
                } else {
                    show(.artist(result.artistID))
                }
                recording.kick()
            } catch {
                toast = "Couldn’t add \(pending.manifest.artist.name): \(error.localizedDescription)"
            }
        }
    }

    func cancelImport() {
        if let pending = pendingImport { try? FileManager.default.removeItem(at: pending.folder) }
        pendingImport = nil
    }

    static func importMessage(_ r: ShareImportResult) -> String {
        if r.albumsAdded == 0 {
            return r.recordingsAdded > 0
                ? "Added \(r.recordingsAdded) recording\(r.recordingsAdded == 1 ? "" : "s") to \(r.artistName)"
                : "\(r.artistName) was already in your library"
        }
        let albums = r.albumsAdded == 1 ? "an album" : "\(r.albumsAdded) albums"
        return r.artistWasNew ? "Added \(r.artistName) to your library" : "Added \(albums) by \(r.artistName)"
    }
}

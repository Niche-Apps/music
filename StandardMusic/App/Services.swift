import Foundation
import StandardKit

/// Locations of everything the app stores.
enum Paths {
    /// `SM_HOME` points the app at another data directory (development, screenshots).
    static let support: URL = {
        let url = ProcessInfo.processInfo.environment["SM_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "StandardMusic", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let library = support.appending(path: "Library", directoryHint: .isDirectory)
    static let database = library.appending(path: "Library.sqlite")
    static let artwork = library.appending(path: "Artwork", directoryHint: .isDirectory)
    static let audio = library.appending(path: "Audio", directoryHint: .isDirectory)
    /// Models are shared across data directories; they're large and immutable.
    static let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "StandardMusic/Models", directoryHint: .isDirectory)

    static func audioFile(for trackID: ID) -> URL { audio.appending(path: "\(trackID).m4a") }
    static func relativeAudioPath(for trackID: ID) -> String { "Audio/\(trackID).m4a" }
    static func resolve(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : library.appending(path: relative)
    }

    static var catalog: URL? { Bundle.main.url(forResource: "catalog", withExtension: "sqlite") }

    static var engine: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/StandardMusicEngine")
    }
}

/// Long-lived service objects shared by the whole app.
@MainActor
final class Services {
    let db: AppDatabase
    let auth: ChatGPTAuth
    let client: ChatGPTClient
    let catalog: Catalog?
    let artwork: ArtworkStore
    let builder: LibraryBuilder
    let engine: EngineClient
    let models: ModelStore
    let songWriter: SongWriter
    let sharing: ShareBundler

    init() throws {
        if UserDefaults.standard.bool(forKey: Pref.eraseLibraryOnLaunch) {
            UserDefaults.standard.removeObject(forKey: Pref.eraseLibraryOnLaunch)
            try? FileManager.default.trashItem(at: Paths.library, resultingItemURL: nil)
        }
        try FileManager.default.createDirectory(at: Paths.audio, withIntermediateDirectories: true)
        db = try AppDatabase(url: Paths.database)
        auth = ChatGPTAuth(directory: Paths.support)
        client = ChatGPTClient(auth: auth)
        catalog = Paths.catalog.flatMap { try? Catalog(url: $0) }
        artwork = ArtworkStore(root: Paths.artwork)
        builder = LibraryBuilder(db: db, client: client, catalog: catalog, artwork: artwork)
        engine = EngineClient(executableURL: Paths.engine)
        models = ModelStore(root: Paths.models)
        songWriter = SongWriter(client: client, db: db)
        sharing = ShareBundler(db: db, libraryRoot: Paths.library, artwork: artwork)
    }
}

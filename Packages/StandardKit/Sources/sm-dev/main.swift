import Foundation
import EngineProtocol
import GRDB
import StandardKit

// Developer harness: exercises the ChatGPT-backed builder against a scratch library.
//   sm-dev build <dir> <count> [prompt]
//   sm-dev lyrics <dir> <trackID>
//   sm-dev models <dir>
//   sm-dev image <dir> <out.jpg> <prompt>
//   sm-dev roster <dir> <count> <genre, genre, …>   (an even spread of artists across those genres)
//   sm-dev write <dir> <trackID>                     (lyrics, as the app writes them before recording)
//   sm-dev take <dir> <trackID> <engine> [maxSeconds] (records exactly like the app's RecordingQueue)

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let auth = ChatGPTAuth(directory: dir)
if await auth.credentials == nil { _ = try await auth.importCodexLogin() }
let client = ChatGPTClient(auth: auth)
let db = try AppDatabase(url: dir.appending(path: "Library.sqlite"))
let catalogURL = URL(fileURLWithPath: "/Users/justinschroeder/Projects/StandardMusic/StandardMusic/Resources/catalog.sqlite")
let catalog = FileManager.default.fileExists(atPath: catalogURL.path) ? try? Catalog(url: catalogURL) : nil

switch args[1] {
case "models":
    for m in try await client.availableModels() { print(m.id, "|", m.displayName, "|", m.description) }
case "build":
    var profile = TasteProfile()
    profile.selectedGenres = ["Indie", "Electronic"]
    profile.likedArtists = [SeedArtist(catalogID: nil, name: "Beach House", genres: ["Dream pop"]), SeedArtist(catalogID: nil, name: "Bon Iver", genres: ["Indie folk"])]
    profile.coreGenres = ["dream pop", "indie folk", "chillwave"]
    profile.adjacentGenres = ["shoegaze", "ambient pop"]
    profile.summary = "You love hazy, reverb-soaked melodies and intimate falsetto."
    try db.setValue(profile, forKey: TasteProfile.storageKey)
    let builder = LibraryBuilder(db: db, client: client, catalog: catalog, artwork: ArtworkStore(root: dir.appending(path: "Artwork")))
    let start = Date()
    await builder.observe { s in print("[\(Int(Date().timeIntervalSince(start)))s] \(s.phase.rawValue) \(s.artistsReady)/\(s.artistsTotal) — \(s.activity)") }
    try await builder.start(kind: .prompt, title: "test", request: BuildRequest(artistCount: Int(args[3]) ?? 2, prompt: args.count > 4 ? args[4] : nil))
    while true {
        try await Task.sleep(for: .seconds(2))
        let s = await builder.currentStatus
        if s.phase == .finished || s.phase == .failed { print(s); break }
    }
    let artists = try await db.reader.read { try Artist.fetchAll($0) }
    for a in artists {
        print("\n== \(a.name) (\(a.primaryGenre), \(a.origin), \(a.formedYear)) [\(a.status)] — \(a.tagline)\n\(a.bio)\nSOUL: \(a.soul)")
        let albums = try await db.reader.read { try Album.filter(Column("artistID") == a.id).fetchAll($0) }
        for al in albums {
            print("  -- \(al.releaseYear) \(al.title) [\(al.kind.rawValue)] palette \(al.palette) cover \(al.coverPath ?? "nil")\n  NOTES: \(al.notes)")
            for t in try db.tracks(forAlbum: al.id) { print("     \(t.trackNumber). \(t.title) — \(t.styleTags)") }
        }
    }
case "roster":
    // An eclectic listener: every listed genre is "core", spread evenly across the roster.
    let genres = args[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    var profile = TasteProfile()
    profile.selectedGenres = genres
    profile.coreGenres = genres
    profile.summary = "You listen to everything, as long as it sounds unmistakably like itself: each genre played the way its best records sound."
    try db.setValue(profile, forKey: TasteProfile.storageKey)
    let builder = LibraryBuilder(db: db, client: client, catalog: catalog, artwork: ArtworkStore(root: dir.appending(path: "Artwork")))
    let start = Date()
    await builder.observe { s in print("[\(Int(Date().timeIntervalSince(start)))s] \(s.phase.rawValue) \(s.artistsReady)/\(s.artistsTotal) — \(s.activity)") }
    try await builder.start(kind: .initialLibrary, title: "Roster", request: BuildRequest(artistCount: Int(args[3]) ?? genres.count, coreShare: 1, adjacentShare: 0))
    while true {
        try await Task.sleep(for: .seconds(5))
        let s = await builder.currentStatus
        if s.phase == .finished || s.phase == .failed { print(s); break }
    }
case "custom":
    // sm-dev custom <dir> <style> <lyrics file or -> [artistID]
    let lyrics = args[4] == "-" ? "" : try String(contentsOfFile: args[4], encoding: .utf8)
    let builder = LibraryBuilder(db: db, client: client, catalog: catalog, artwork: ArtworkStore(root: dir.appending(path: "Artwork")))
    let albumID = try await builder.createCustomSong(CustomSongRequest(
        lyrics: lyrics, style: args[3], instrumental: lyrics.isEmpty, artistID: args.count > 5 ? args[5] : nil))
    let info = try db.albumInfo(albumID)!
    let track = try db.tracks(forAlbum: albumID)[0]
    print("ARTIST: \(info.artist.name) (\(info.artist.primaryGenre), \(info.artist.origin)) portrait \(info.artist.imagePath ?? "nil")")
    print("SINGLE: \(info.album.title) [\(info.album.primaryGenre)] cover \(info.album.coverPath ?? "nil")")
    print("TAGS: \(track.styleTags)")
    print("RECORDING TAGS: \(GenreSound.customRecordingTags(tags: track.styleTags))")
    print("LYRICS:\n\(track.lyrics ?? "")")
case "portrait":
    // sm-dev portrait <dir> <artistID>   (a fresh art direction and photo; prints the concept)
    let builder = LibraryBuilder(db: db, client: client, catalog: catalog, artwork: ArtworkStore(root: dir.appending(path: "Artwork")))
    try await builder.reimaginePortrait(artistID: args[3])
    let a = try await db.reader.read { try Artist.fetchOne($0, key: args[3]) }!
    print("\(a.name): \(a.imagePath ?? "")\n\(a.imagePrompt ?? "")")
case "draft":
    print(try await SongWriter(client: client, db: db).draft(style: args[3], about: args.count > 4 ? args[4] : ""))
case "write":
    let t = try await SongWriter(client: client, db: db).prepare(trackID: args[3])
    print(t.styleTags); print(t.lyrics ?? "")
case "take":
    // Mirrors RecordingQueue.record: genre-first tags, the artist's voice, default quality and planning.
    let id = args[3]
    let info = try db.trackInfo(id)!
    let track = try await SongWriter(client: client, db: db).prepare(trackID: id)
    let voice = try await db.reader.read { db in
        try String.fetchOne(db, sql: "SELECT voice FROM artist WHERE id = ?", arguments: [track.artistID])
    } ?? ""
    let genreTags = GenreSound.recordingTags(tags: track.styleTags, genres: [info.artist.primaryGenre] + info.artist.genres)
    let style = Voice.recordingStyle(tags: genreTags, voice: voice, isInstrumental: track.isInstrumental)
    let maxSeconds = args.count > 5 ? Double(args[5]) ?? 330 : 330
    let audioDir = dir.appending(path: "Audio")
    try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    let out = audioDir.appending(path: "\(id).m4a")
    print("STYLE: \(style)")
    let job = EngineJob(
        id: id, style: style, lyrics: track.lyrics ?? "", planning: "full", seed: UInt64(track.seed), steps: 16,
        maxSemanticTokens: Int(25 * maxSeconds), outputPath: out.path, title: track.title, artist: info.artist.name,
        voice: voice, isInstrumental: track.isInstrumental, maxSeconds: maxSeconds)
    let engine = EngineClient(executableURL: URL(fileURLWithPath: args[4]))
    let model = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/StandardMusic/Models/YuE2-3B-MLX-8bit")
    let start = Date()
    final class Stage: @unchecked Sendable { var name = "" }
    let stage = Stage()
    let result = try await engine.render(job, modelDirectory: model) { p in
        if p.stage != stage.name { print("[\(Int(Date().timeIntervalSince(start)))s] \(p.stage) \(Int(p.overall * 100))%"); stage.name = p.stage }
    }
    _ = try db.modifyTrack(id) {
        $0.status = .ready
        $0.audioPath = "Audio/\(id).m4a"
        $0.duration = result.duration
        $0.loudness = result.loudness
        $0.generatedAt = Date()
        $0.generationSeconds = result.seconds
    }
    print("RECORDED \(info.artist.name) — \(track.title) in \(Int(result.seconds))s, \(Int(result.duration))s long")
case "lyrics":
    let writer = SongWriter(client: client, db: db)
    let t = try await writer.prepare(trackID: args[3])
    print(t.styleTags); print(t.lyrics ?? "")
case "record":
    let info = try db.trackInfo(args[3])!
    let engine = EngineClient(executableURL: URL(fileURLWithPath: args[4]))
    let out = dir.appending(path: "\(args[3]).m4a")
    let job = EngineJob(id: args[3], style: info.track.styleTags, lyrics: info.track.lyrics ?? "", planning: "full", seed: UInt64(info.track.seed), steps: Int(args[5]) ?? 16, maxSemanticTokens: 25 * 330, outputPath: out.path)
    let start = Date()
    final class Box: @unchecked Sendable { var stage = "" }
    let box = Box()
    let model = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/StandardMusic/Models/YuE2-3B-MLX-8bit")
    let result = try await engine.render(job, modelDirectory: model) { p in
        if p.stage != box.stage { print("[\(Int(Date().timeIntervalSince(start)))s] \(p.stage) overall \(Int(p.overall * 100))% est \(Int(p.estimatedSongSeconds ?? 0))s"); box.stage = p.stage }
    }
    print(result)
case "image":
    let data = try await client.image(prompt: args[4], quality: args.count > 5 ? args[5] : "high")
    try data.write(to: URL(fileURLWithPath: args[3]))
    print("wrote \(args[3])")
case "download":
    let store = ModelStore(root: dir)
    let start = Date()
    _ = try await store.install(.int4) { p in
        print(String(format: "%.0fs %.1f/%.1f MB %.1f MB/s", Date().timeIntervalSince(start), Double(p.receivedBytes) / 1e6, Double(p.totalBytes) / 1e6, p.bytesPerSecond / 1e6))
    }
default:
    print("?")
}

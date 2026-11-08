import Foundation
import GRDB
import OSLog

let dbLog = Logger(subsystem: "com.standardmusic", category: "database")

/// The listener's library: a single SQLite file in WAL mode with full fsync, verified at launch,
/// with rotating online backups. Everything else in the app reads and writes through this type.
public final class AppDatabase: Sendable {
    public let writer: DatabasePool
    public let url: URL
    /// Set when the library had to be restored from a backup at launch.
    public let recoveredFromBackup: Date?
    /// Set when the library was damaged and no healthy backup existed; the damaged copy is kept aside.
    public let resetAfterDamage: Bool

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var recovered: Date?
        var reset = false
        if FileManager.default.fileExists(atPath: url.path), !Self.passesIntegrityCheck(url) {
            recovered = try Self.restoreLatestBackup(for: url)
            reset = recovered == nil
        }
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "Library"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        writer = try DatabasePool(path: url.path, configuration: config)
        recoveredFromBackup = recovered
        resetAfterDamage = reset
        try Self.migrator.migrate(writer)
    }

    /// In-memory database for previews and tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(url: FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID()).sqlite"))
    }

    public var reader: DatabaseReader { writer }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "generationBatch") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("request", .text).notNull()
                t.column("status", .text).notNull()
                t.column("targetArtists", .integer).notNull()
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            try db.create(table: "artist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sortName", .text).notNull().indexed()
                t.column("primaryGenre", .text).notNull().indexed()
                t.column("genres", .text).notNull()
                t.column("tags", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("formedYear", .integer).notNull()
                t.column("disbandedYear", .integer)
                t.column("members", .text).notNull()
                t.column("tagline", .text).notNull()
                t.column("bio", .text).notNull()
                t.column("soul", .text).notNull()
                t.column("touchstones", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("plannedAlbumCount", .integer).notNull()
                t.column("imagePath", .text)
                t.column("imagePrompt", .text)
                t.column("accentHex", .text)
                t.column("status", .text).notNull().indexed()
                t.column("batchID", .text).references("generationBatch", onDelete: .setNull)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "album") { t in
                t.primaryKey("id", .text)
                t.column("artistID", .text).notNull().indexed().references("artist", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("releaseYear", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull()
                t.column("primaryGenre", .text).notNull().indexed()
                t.column("genres", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("soul", .text).notNull()
                t.column("coverPrompt", .text).notNull()
                t.column("coverPath", .text)
                t.column("palette", .text).notNull()
                t.column("trackCount", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().indexed()
            }
            try db.create(table: "track") { t in
                t.primaryKey("id", .text)
                t.column("albumID", .text).notNull().indexed().references("album", onDelete: .cascade)
                t.column("artistID", .text).notNull().indexed().references("artist", onDelete: .cascade)
                t.column("discNumber", .integer).notNull()
                t.column("trackNumber", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("details", .text).notNull()
                t.column("styleTags", .text).notNull()
                t.column("lyrics", .text)
                t.column("vocal", .text).notNull()
                t.column("bpm", .integer)
                t.column("mood", .text).notNull()
                t.column("isInstrumental", .boolean).notNull()
                t.column("seed", .integer).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("audioPath", .text)
                t.column("duration", .double)
                t.column("loudness", .double)
                t.column("generatedAt", .datetime).indexed()
                t.column("generationSeconds", .double)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("skipCount", .integer).notNull().defaults(to: 0)
                t.column("lastPlayedAt", .datetime).indexed()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "playEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .text).notNull().indexed().references("track", onDelete: .cascade)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("secondsPlayed", .double).notNull()
                t.column("completed", .boolean).notNull()
                t.column("skipped", .boolean).notNull()
            }
            try db.create(table: "playlist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "playlistItem") { t in
                t.column("playlistID", .text).notNull().references("playlist", onDelete: .cascade)
                t.column("trackID", .text).notNull().references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["playlistID", "position"])
            }
            try db.create(table: "storedValue") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(virtualTable: "searchIndex", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("kind").notIndexed()
                t.column("itemID").notIndexed()
                t.column("title")
                t.column("subtitle")
                t.column("keywords")
            }
        }
        m.registerMigration("v2-artist-voice") { db in
            try db.alter(table: "artist") { t in
                t.add(column: "voice", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v3-genre-true-voices") { db in
            // Early voices were cast with the listener's taste in mind, so most came out soft and
            // intimate whatever the genre. Re-cast (lazily, by SongWriter) every artist who hasn't
            // recorded anything yet; recorded artists keep theirs so they still sound like themselves.
            try db.execute(sql: """
                UPDATE artist SET voice = ''
                WHERE voice != 'instrumental'
                  AND NOT EXISTS (SELECT 1 FROM track WHERE track.artistID = artist.id AND track.status = 'ready')
                """)
        }
        m.registerMigration("v4-explicit") { db in
            try db.alter(table: "track") { t in
                t.add(column: "isExplicit", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v5-custom-songs") { db in
            try db.alter(table: "track") { t in
                t.add(column: "isCustom", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v6-no-future-releases") { db in
            // New releases used to be dated the year after the artist's last one (#6).
            try db.execute(
                sql: "UPDATE album SET releaseYear = ? WHERE releaseYear > ?",
                arguments: [LibraryBuilder.currentYear, LibraryBuilder.currentYear])
        }
        return m
    }

    // MARK: Integrity & backups

    /// False only for real damage (a failed quick_check, or SQLite reporting corruption). Transient
    /// problems such as a busy file don't count — the normal open will surface those.
    static func passesIntegrityCheck(_ url: URL) -> Bool {
        do {
            var config = Configuration()
            config.busyMode = .timeout(10)
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            defer { try? queue.close() }
            let result = try queue.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
            return result == "ok"
        } catch let error as DatabaseError where [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(error.resultCode) {
            dbLog.error("Library is damaged: \(error.localizedDescription)")
            return false
        } catch {
            dbLog.error("Integrity check couldn't run: \(error.localizedDescription)")
            return true
        }
    }

    static func backupDirectory(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    }

    /// Moves a damaged library aside and puts the newest healthy backup in its place.
    static func restoreLatestBackup(for url: URL) throws -> Date? {
        let fm = FileManager.default
        let quarantine = url.deletingLastPathComponent().appending(path: "Damaged-\(Int(Date().timeIntervalSince1970))")
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: file.path) {
                try fm.moveItem(at: file, to: quarantine.appending(path: file.lastPathComponent))
            }
        }
        let backups = (try? fm.contentsOfDirectory(
            at: backupDirectory(for: url), includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for backup in backups where passesIntegrityCheck(backup) {
            try fm.copyItem(at: backup, to: url)
            dbLog.notice("Restored library from \(backup.lastPathComponent)")
            return (try? backup.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return nil
    }

    /// Writes a consistent online snapshot if the newest one is older than `interval`. Keeps `keep` snapshots.
    public func backupIfNeeded(interval: TimeInterval = 6 * 3600, keep: Int = 7) {
        let fm = FileManager.default
        let dir = Self.backupDirectory(for: url)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            if let newest = existing.first,
                let date = try newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                Date().timeIntervalSince(date) < interval
            {
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let target = dir.appending(path: "Library-\(formatter.string(from: Date())).sqlite")
            let partial = target.appendingPathExtension("partial")
            let destination = try DatabaseQueue(path: partial.path)
            try writer.backup(to: destination)
            try destination.close()
            try fm.moveItem(at: partial, to: target)
            for old in existing.dropFirst(keep - 1) { try? fm.removeItem(at: old) }
        } catch {
            dbLog.error("Backup failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Stored values

extension AppDatabase {
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let raw = try? reader.read({ try StoredValue.fetchOne($0, key: key) })?.value else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(raw.utf8))
    }

    public func setValue<T: Encodable>(_ value: T, forKey key: String) throws {
        let raw = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try writer.write { try StoredValue(key: key, value: raw).save($0) }
    }
}

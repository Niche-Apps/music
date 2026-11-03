import Foundation
import GRDB
import StandardKit

/// Chooses what plays after an album ends: something close in sound and era, nudged toward the
/// listener's favorites and songs that are already recorded (so music keeps flowing).
struct AutoplayPicker {
    let db: AppDatabase

    func nextAlbum(after seed: TrackInfo, excluding: Set<ID>) -> Album? {
        guard let candidates = try? db.reader.read({ db in
            try AppDatabase.albumInfos().filter(Column("status") == ItemStatus.ready.rawValue).fetchAll(db)
        }) else { return nil }
        let readyCounts: [ID: Int] = (try? db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT albumID, COUNT(*) AS n FROM track WHERE status = 'ready' GROUP BY albumID")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["albumID"] as String, $0["n"] as Int) })
        }) ?? [:]
        let recent: Set<ID> = Set((try? db.reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT t.albumID FROM playEvent p JOIN track t ON t.id = p.trackID
                    ORDER BY p.startedAt DESC LIMIT 12
                    """)
        }) ?? [])
        let seedTags = Set((seed.artist.genres + seed.artist.tags + seed.album.genres).map { $0.lowercased() })
        func score(_ c: AlbumInfo) -> Double {
            let tags = Set((c.artist.genres + c.artist.tags + c.album.genres).map { $0.lowercased() })
            let overlap = Double(seedTags.intersection(tags).count) / Double(max(1, seedTags.union(tags).count))
            var s = overlap * 4
            if c.artist.id == seed.artist.id { s += 1.2 }
            if c.album.primaryGenre.lowercased() == seed.album.primaryGenre.lowercased() { s += 1 }
            s -= Double(abs(c.album.releaseYear - seed.album.releaseYear)) / 25
            if c.album.isFavorite || c.artist.isFavorite { s += 0.8 }
            if (readyCounts[c.album.id] ?? 0) > 0 { s += 0.9 }
            if recent.contains(c.album.id) { s -= 2 }
            return s + Double.random(in: 0 ... 0.6)
        }
        return candidates
            .filter { $0.album.id != seed.album.id && !excluding.contains($0.album.id) }
            .max { score($0) < score($1) }?.album
    }
}

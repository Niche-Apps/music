import Foundation
import GRDB

/// A real-world artist from the bundled catalog (used only to learn the listener's taste).
public struct CatalogArtist: Codable, Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var name: String
    public var fans: Int
    public var pictureURL: URL?
    public var pictureSmallURL: URL?
    public var genres: [String]
    public var primaryGenre: String
    public var popularityRank: Int

    enum CodingKeys: String, CodingKey {
        case id, name, fans, pictureURL = "picture_url", pictureSmallURL = "picture_small_url", genres
        case primaryGenre = "primary_genre", popularityRank = "popularity_rank"
    }

    public init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        fans = row["fans"] ?? 0
        pictureURL = (row["picture_url"] as String?).flatMap(URL.init(string:))
        pictureSmallURL = (row["picture_small_url"] as String?).flatMap(URL.init(string:))
        let rawGenres: String = row["genres"] ?? "[]"
        genres = (try? JSONDecoder().decode([String].self, from: Data(rawGenres.utf8))) ?? []
        primaryGenre = row["primary_genre"] ?? genres.first ?? ""
        popularityRank = row["popularity_rank"] ?? 0
    }
}

public struct CatalogAlbum: Codable, Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var artistID: Int64
    public var title: String
    public var year: Int?
    public var coverURL: URL?
    public var coverSmallURL: URL?
    public var genre: String?

    public init(row: Row) throws {
        id = row["id"]
        artistID = row["artist_id"]
        title = row["title"]
        year = row["year"]
        coverURL = (row["cover_url"] as String?).flatMap(URL.init(string:))
        coverSmallURL = (row["cover_small_url"] as String?).flatMap(URL.init(string:))
        genre = row["genre"]
    }
}

public struct CatalogGenre: Sendable, Hashable, Identifiable {
    public var name: String
    public var artistCount: Int
    /// A few strong artists for the genre's collage.
    public var featured: [CatalogArtist]
    public var id: String { name }
}

/// Read-only access to the bundled `catalog.sqlite` of real artists.
public final class Catalog: Sendable {
    private let queue: DatabaseQueue

    public init(url: URL) throws {
        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(path: url.path, configuration: config)
    }

    public func genres(minimumArtists: Int = 25) throws -> [CatalogGenre] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT primary_genre AS name, COUNT(*) AS n FROM artists
                    WHERE primary_genre IS NOT NULL AND primary_genre != ''
                    GROUP BY primary_genre HAVING n >= ? ORDER BY n DESC
                    """, arguments: [minimumArtists])
            return try rows.map { row in
                let name: String = row["name"]
                let featured = try CatalogArtist.fetchAll(
                    db, sql: "SELECT * FROM artists WHERE primary_genre = ? ORDER BY fans DESC LIMIT 4",
                    arguments: [name])
                return CatalogGenre(name: name, artistCount: row["n"], featured: featured)
            }
        }
    }

    /// Style-level buckets (e.g. "Indie Rock", "K-Pop") matched on primary genre or the `genres` array.
    public func styleGenres(_ styles: [String], minimumArtists: Int = 25, featured: Int = 4) throws -> [CatalogGenre] {
        try queue.read { db in
            try styles.compactMap { style in
                let match = "primary_genre = ? OR genres LIKE ?"
                let args: StatementArguments = [style, "%\"\(style)\"%"]
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artists WHERE \(match)", arguments: args) ?? 0
                guard count >= minimumArtists else { return nil }
                let top = try CatalogArtist.fetchAll(
                    db, sql: "SELECT * FROM artists WHERE \(match) ORDER BY fans DESC LIMIT ?", arguments: args + [featured])
                return CatalogGenre(name: style, artistCount: count, featured: top)
            }
        }
    }

    /// Popular artists whose genres intersect `genres`, interleaved so each genre is represented.
    public func topArtists(genres: [String], perGenre: Int, excluding: Set<Int64> = []) throws -> [CatalogArtist] {
        try queue.read { db in
            var lists: [[CatalogArtist]] = []
            for genre in genres {
                let artists = try CatalogArtist.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM artists WHERE primary_genre = ? OR genres LIKE ?
                        ORDER BY (primary_genre = ?) DESC, fans DESC LIMIT ?
                        """,
                    arguments: [genre, "%\"\(genre)\"%", genre, perGenre * 3])
                lists.append(Array(artists.filter { !excluding.contains($0.id) }.prefix(perGenre)))
            }
            var seen = Set<Int64>()
            var out: [CatalogArtist] = []
            for i in 0 ..< (lists.map(\.count).max() ?? 0) {
                for list in lists where i < list.count && seen.insert(list[i].id).inserted {
                    out.append(list[i])
                }
            }
            return out
        }
    }

    public func related(to id: Int64, limit: Int = 12) throws -> [CatalogArtist] {
        try queue.read { db in
            try CatalogArtist.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM related r JOIN artists a ON a.id = r.related_id
                    WHERE r.artist_id = ? ORDER BY r.rank LIMIT ?
                    """, arguments: [id, limit])
        }
    }

    /// Artists related to any of `ids` but not in it, ranked by how many of them point there.
    public func neighbors(of ids: Set<Int64>, limit: Int) throws -> [CatalogArtist] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        return try queue.read { db in
            try CatalogArtist.fetchAll(
                db,
                sql: """
                    SELECT a.*, COUNT(*) AS votes FROM related r JOIN artists a ON a.id = r.related_id
                    WHERE r.artist_id IN (\(list)) AND r.related_id NOT IN (\(list))
                    GROUP BY a.id ORDER BY votes DESC, a.fans DESC LIMIT ?
                    """, arguments: [limit])
        }
    }

    public func artists(ids: [Int64]) throws -> [CatalogArtist] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        let found = try queue.read { db in
            try CatalogArtist.fetchAll(db, sql: "SELECT * FROM artists WHERE id IN (\(list))")
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    public func albums(artistID: Int64, limit: Int = 5) throws -> [CatalogAlbum] {
        try queue.read { db in
            try CatalogAlbum.fetchAll(
                db, sql: "SELECT * FROM albums WHERE artist_id = ? ORDER BY fans DESC LIMIT ?",
                arguments: [artistID, limit])
        }
    }

    public func albums(ids: [Int64]) throws -> [CatalogAlbum] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        let found = try queue.read { db in
            try CatalogAlbum.fetchAll(db, sql: "SELECT * FROM albums WHERE id IN (\(list))")
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    public func search(_ text: String, limit: Int = 30) throws -> [CatalogArtist] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try queue.read { db in
            try CatalogArtist.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM artists_fts f JOIN artists a ON a.id = f.rowid
                    WHERE artists_fts MATCH ? ORDER BY a.fans DESC LIMIT ?
                    """, arguments: [pattern, limit])
        }
    }

    /// True when `name` belongs to a real artist (case/diacritic-insensitive exact match).
    public func isRealArtistName(_ name: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        let candidates = (try? search(name, limit: 10)) ?? []
        return candidates.contains {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        }
    }
}

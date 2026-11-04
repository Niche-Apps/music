import Foundation

/// Searches Deezer's public, keyless API for artists the bundled catalog doesn't carry. The catalog
/// is capped per genre (about 5,000 artists), so plenty of well-loved mid-size bands miss the cut;
/// onboarding falls back to this so any real artist can be found by name.
public enum LiveArtistSearch {
    struct Response: Decodable {
        struct Artist: Decodable {
            var id: Int64
            var name: String
            var nb_fan: Int?
            var picture_xl: String?
            var picture_medium: String?
        }
        var data: [Artist]
    }

    /// Real artists matching `text`, most fans first. Artists without a photo or with very few fans
    /// (duplicates, tribute acts, uploads) are dropped. Returns [] on any network error.
    public static func search(_ text: String, limit: Int = 12, session: URLSession = .shared) async -> [CatalogArtist] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, var url = URLComponents(string: "https://api.deezer.com/search/artist") else { return [] }
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "25")]
        guard let requestURL = url.url else { return [] }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 6
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return [] }
        return artists(from: decoded, limit: limit)
    }

    static func artists(from response: Response, limit: Int) -> [CatalogArtist] {
        response.data
            .filter { ($0.nb_fan ?? 0) >= 500 && hasPhoto($0.picture_xl) }
            .sorted { ($0.nb_fan ?? 0) > ($1.nb_fan ?? 0) }
            .prefix(limit)
            .map { a in
                CatalogArtist(
                    id: a.id, name: a.name, fans: a.nb_fan ?? 0,
                    pictureURL: a.picture_xl.flatMap(URL.init(string:)),
                    pictureSmallURL: (a.picture_medium ?? a.picture_xl).flatMap(URL.init(string:)),
                    genres: [], primaryGenre: "", popularityRank: 0)
            }
    }

    /// Deezer's placeholder pictures have an empty hash: `/images/artist//1000x1000-…`.
    static func hasPhoto(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        return !url.contains("/images/artist//")
    }

    /// Catalog results first, then live ones the catalog doesn't already have (by Deezer id or name).
    public static func merge(_ local: [CatalogArtist], _ live: [CatalogArtist], limit: Int = 12) -> [CatalogArtist] {
        var ids = Set(local.map(\.id))
        var names = Set(local.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })
        var out = local
        for a in live where out.count < limit {
            let name = a.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard ids.insert(a.id).inserted, names.insert(name).inserted else { continue }
            out.append(a)
        }
        return out
    }
}

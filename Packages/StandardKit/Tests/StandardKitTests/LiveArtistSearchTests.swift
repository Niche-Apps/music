import Foundation
import Testing
@testable import StandardKit

@Suite struct LiveArtistSearchTests {
    let json = """
    {"data":[
      {"id":173740,"name":"Manchester Orchestra","nb_fan":42995,"picture_xl":"https://cdn-images.dzcdn.net/images/artist/e49d/1000x1000.jpg","picture_medium":"https://cdn-images.dzcdn.net/images/artist/e49d/250x250.jpg"},
      {"id":415162752,"name":"Manchester Orchestra","nb_fan":0,"picture_xl":"https://cdn-images.dzcdn.net/images/artist//1000x1000-000000.jpg"},
      {"id":7916594,"name":"Manchester Symphony Orchestra","nb_fan":33,"picture_xl":"https://cdn-images.dzcdn.net/images/artist/69c0/1000x1000.jpg"}
    ]}
    """

    @Test func keepsRealArtistsDropsPlaceholdersAndTinyUploads() throws {
        let response = try JSONDecoder().decode(LiveArtistSearch.Response.self, from: Data(json.utf8))
        let found = LiveArtistSearch.artists(from: response, limit: 12)
        #expect(found.map(\.name) == ["Manchester Orchestra"])
        #expect(found.first?.id == 173740)
        #expect(found.first?.pictureSmallURL?.absoluteString.hasSuffix("250x250.jpg") == true)
    }

    @Test func mergeKeepsCatalogFirstAndSkipsDuplicates() {
        func artist(_ id: Int64, _ name: String) -> CatalogArtist {
            CatalogArtist(id: id, name: name, fans: 1, pictureURL: nil, pictureSmallURL: nil, genres: [], primaryGenre: "", popularityRank: 0)
        }
        let merged = LiveArtistSearch.merge([artist(1, "Bon Iver")], [artist(1, "Bon Iver"), artist(9, "bon ivér"), artist(2, "Manchester Orchestra")])
        #expect(merged.map(\.id) == [1, 2])
    }
}

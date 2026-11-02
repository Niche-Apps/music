import Foundation
import Testing
@testable import StandardKit

@Suite struct GenerationTests {
    @Test func voiceReplacesSingerTags() {
        let style = Voice.recordingStyle(
            tags: "English, dream pop, 1990s, reverb guitar, warm husky male vocal, slow",
            voice: "female alto vocal, smoky, intimate", isInstrumental: false)
        #expect(style == "English, dream pop, 1990s, reverb guitar, slow, female alto vocal, smoky, intimate")
    }

    @Test func instrumentalsGetNoVoice() {
        let tags = "ambient, synth pads, breathy vocal, calm"
        #expect(Voice.recordingStyle(tags: tags, voice: "male tenor vocal", isInstrumental: true) == "ambient, synth pads, calm, instrumental")
        #expect(Voice.recordingStyle(tags: tags, voice: "instrumental", isInstrumental: false) == "ambient, synth pads, calm, instrumental")
    }

    @Test func missingVoiceLeavesTagsAlone() {
        #expect(Voice.recordingStyle(tags: "rock, male vocal", voice: "", isInstrumental: false) == "rock, male vocal")
    }

    @Test func coverApproachesAreDistinctPerArtist() {
        let picked = CoverDirection.assign(count: 8, genres: ["shoegaze", "dream pop"], seed: 42)
        #expect(picked.count == 8)
        #expect(Set(picked).count == 8)
        // Even past the size of the catalogue, every release gets an approach.
        #expect(CoverDirection.assign(count: 30, genres: ["metal"], seed: 7).count == 30)
    }
}

@Suite struct TasteTests {
    @Test func favouritesReachGenerationPrompts() {
        var taste = TasteProfile()
        taste.coreGenres = ["shoegaze"]
        taste.signals = [
            ListeningSignal(kind: .favoriteTrack, artistName: "Velvet Static", genres: ["dream pop"], styleTags: "reverb guitar, hazy", title: "Glass Rain"),
            ListeningSignal(kind: .skip, artistName: "Loud Men", genres: ["metal"], styleTags: "", title: "Skipped Song"),
        ]
        let context = taste.promptContext
        #expect(context.contains("Glass Rain by Velvet Static [reverb guitar, hazy]"))
        #expect(!context.contains("Skipped Song"))
    }
}

@Suite struct GenreGroupTests {
    /// The primary genres of a real 110-artist library.
    static let library: [String: Int] = ["acoustic folk-pop": 24, "acoustic pop": 5, "acoustic rock": 3, "acoustic singer-songwriter": 19, "acoustic singer-songwriter pop": 8, "acoustic sophisti-pop": 2, "adult alternative": 1, "alternative pop": 4, "alternative pop rock": 1, "alternative rock": 1, "anthemic pop rock": 33, "arena rock": 80, "argentine acoustic folk-pop": 1, "art rock": 1, "cinematic dream pop": 16, "french piano pop rock": 3, "french piano rock": 1, "heartland rock": 2, "indie pop": 12, "italian acoustic singer-songwriter": 1, "italian arena rock": 1, "italian rock": 1, "jangle pop": 3, "melodic alternative pop": 42, "melodic alternative rock": 23, "norwegian acoustic folk-pop": 2, "piano pop": 3, "piano pop rock": 11, "piano rock": 33, "piano-driven pop rock": 9, "piano-led alternative pop": 1, "pop rock francophone": 1, "pop rock française": 1, "portuguese acoustic folk-pop": 6, "portuguese pop rock": 4, "progressive rock": 1, "roots rock": 1, "soft rock": 1, "sophisti-pop": 45, "spanish-language pop rock": 2, "swedish alternative pop": 1, "symphonic rock": 1, "theatrical arena rock": 1, "theatrical rock": 1,]

    @Test func nearDuplicatesShareAShelf() {
        let map = GenreGroups.make(Self.library)
        #expect(map["piano-driven pop rock"] == map["piano rock"])
        #expect(map["portuguese acoustic folk-pop"] == map["acoustic folk-pop"])
        #expect(map["acoustic singer-songwriter pop"] == map["acoustic singer-songwriter"])
        #expect(map["sophisti-pop"] == "Sophisti-Pop")
        #expect(map["arena rock"] != map["sophisti-pop"])
        let shelves = Set(map.values)
        print("shelves:", shelves.count, shelves.sorted())
        #expect(shelves.count <= 20)
        #expect(shelves.count >= 6)
    }
}

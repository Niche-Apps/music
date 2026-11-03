import Foundation

/// Assigns each release a distinct visual approach before its cover is art-directed. Left alone, the
/// writer drifts towards one tasteful look (muted still lifes on paper); real record shelves mix band
/// photos, typography, illustration, snapshots and more, in proportions that depend on the genre.
public enum CoverDirection {
    struct Approach {
        let brief: String
        /// Genre keywords that make this approach more likely, with the weight they add.
        let affinity: [String]
        let base: Double
    }

    static let approaches: [Approach] = [
        Approach(brief: "a posed photograph of the artist or band, looking at the camera, styled for the era", affinity: ["rock", "pop", "punk", "soul", "country", "r&b", "indie", "metal", "folk", "hip hop", "rap"], base: 1.2),
        Approach(brief: "a close-up portrait of the lead artist's face, dramatic lighting, the image fills the whole sleeve", affinity: ["pop", "r&b", "soul", "singer-songwriter", "jazz", "hip hop", "rap", "neo-soul"], base: 1.0),
        Approach(brief: "a candid 35mm snapshot with on-camera flash — party, backstage, car or kitchen — grainy and immediate", affinity: ["indie", "punk", "garage", "lo-fi", "emo", "hip hop", "bedroom"], base: 0.8),
        Approach(brief: "a live concert photograph: stage lights, haze, motion, the crowd or the band mid-performance", affinity: ["rock", "metal", "punk", "jazz", "live"], base: 0.5),
        Approach(brief: "bold typographic design: the artist name and title set large in a striking typeface on flat color, no photo", affinity: ["electronic", "techno", "post-punk", "minimal", "house", "experimental", "krautrock"], base: 0.8),
        Approach(brief: "a classic jazz-label layout: a high-contrast photograph cropped into a grid with strong sans-serif type and one bold color", affinity: ["jazz", "bossa", "soul", "funk"], base: 0.4),
        Approach(brief: "a vivid painting (oil, acrylic or gouache) with visible brushwork", affinity: ["folk", "psychedelic", "prog", "indie", "americana", "art rock"], base: 0.8),
        Approach(brief: "a detailed illustration — ink, airbrush, comic or anime style — full of character", affinity: ["metal", "psychedelic", "city pop", "hip hop", "funk", "synthwave", "prog", "stoner"], base: 0.7),
        Approach(brief: "a surreal photomontage: two incongruous photographs combined seamlessly into one impossible image", affinity: ["psychedelic", "art rock", "trip-hop", "alternative", "dream pop"], base: 0.7),
        Approach(brief: "an abstract composition — color fields, geometric shapes or generative patterns — with no figurative imagery", affinity: ["electronic", "ambient", "techno", "idm", "post-rock", "minimal", "jazz"], base: 0.7),
        Approach(brief: "a glossy 3D render or CGI object with reflective materials, studio lit against a clean backdrop", affinity: ["electronic", "hyperpop", "pop", "future", "edm", "synth"], base: 0.5),
        Approach(brief: "a wide landscape or place photograph — a road, a coastline, a city at night — with the people small or absent", affinity: ["country", "americana", "post-rock", "ambient", "shoegaze", "folk", "indie"], base: 0.8),
        Approach(brief: "a DIY photocopied collage: cut-up photos, hand-lettering, tape and xerox grain", affinity: ["punk", "hardcore", "riot grrrl", "zine", "noise", "lo-fi", "garage"], base: 0.5),
        Approach(brief: "a high-fashion studio shoot: styled outfit, seamless colored backdrop, magazine-cover polish", affinity: ["pop", "r&b", "dance", "disco", "k-pop", "house"], base: 0.7),
        Approach(brief: "a single striking object photographed on a plain color background, centered and graphic", affinity: ["indie", "alternative", "pop", "electronic"], base: 0.6),
        Approach(brief: "a found-photo aesthetic: an old family photograph or vintage postcard, faded color, white border", affinity: ["folk", "indie", "americana", "lo-fi", "singer-songwriter", "slowcore"], base: 0.4),
        Approach(brief: "a moody black-and-white documentary photograph with deep blacks and film grain", affinity: ["jazz", "blues", "post-punk", "folk", "hip hop", "goth"], base: 0.7),
        Approach(brief: "a neon-lit night scene with saturated color, rain or reflections, cinematic", affinity: ["synthwave", "city pop", "r&b", "electronic", "trip-hop", "phonk"], base: 0.5),
        Approach(brief: "a hand-drawn logo or emblem as the centerpiece — intricate lettering or a band crest", affinity: ["metal", "black metal", "doom", "hardcore", "stoner"], base: 0.4),
        Approach(brief: "a bright, playful pop-art graphic with flat colors, halftone dots and big shapes", affinity: ["pop", "bubblegum", "power pop", "ska", "disco", "funk"], base: 0.5),
    ]

    /// Distinct approaches for `count` releases, chosen at random with genre weighting.
    public static func assign(count: Int, genres: [String], seed: UInt64 = .random(in: 0 ... .max)) -> [String] {
        let haystack = genres.joined(separator: " ").lowercased()
        var generator = SplitMix(seed: seed)
        var pool = approaches.map { a -> (String, Double) in
            let bonus = a.affinity.filter { haystack.contains($0) }.isEmpty ? 0 : 1.6
            return (a.brief, a.base + bonus)
        }
        var picked: [String] = []
        while picked.count < count {
            if pool.isEmpty { pool = approaches.map { ($0.brief, $0.base) } }
            let total = pool.reduce(0) { $0 + $1.1 }
            var roll = Double(generator.next() % 1_000_000) / 1_000_000 * total
            let index = pool.firstIndex { roll -= $0.1; return roll <= 0 } ?? pool.count - 1
            picked.append(pool.remove(at: index).0)
        }
        return picked
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

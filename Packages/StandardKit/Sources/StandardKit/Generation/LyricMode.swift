import Foundation

/// Gives each song a lyrical register before it's written. Left alone, the writer turns every song
/// into a tidy short story told through household objects (the kettle, the bus fare, the coat on
/// the chair) that says exactly what it means. Real records are mostly not like that: lyrics are
/// fragments, sounds, private references and images that never quite resolve, and the ambiguity is
/// a large part of why a song keeps pulling you back.
public enum LyricMode {
    struct Mode {
        let name: String
        let brief: String
        /// Genre keywords that make this mode more likely.
        let affinity: [String]
        let base: Double
    }

    static let modes: [Mode] = [
        Mode(
            name: "impressionistic",
            brief: """
                Impressionistic and oblique. Lines are fragments and images that never add up to a \
                story the listener could retell. Jump between scenes and times without transitions. \
                Use pronouns (you, he, they) whose referents are never made clear. Half-overheard \
                quotes from someone unnamed. The feeling is unmistakable; what actually happened is not.
                """,
            affinity: ["indie", "folk", "alternative", "art rock", "slowcore", "chamber", "post-rock", "singer-songwriter", "experimental"],
            base: 2.0),
        Mode(
            name: "sound-first",
            brief: """
                Sound first, sense second. Choose words for their vowels, consonants and how they sit \
                in the mouth on the melody. Coined phrases and odd collisions of words that feel \
                meaningful but resist paraphrase ("salt hour", "borrowed weather"). Puns, near-homophones, \
                lines that could be misheard as something else. Grammar may bend or break.
                """,
            affinity: ["dream pop", "shoegaze", "electronic", "psychedelic", "trip-hop", "ambient", "neo-soul", "art pop", "indie"],
            base: 1.6),
        Mode(
            name: "mantra",
            brief: """
                Mantra. Very few words. A handful of short phrases repeated and slightly varied, so \
                that each return shifts their meaning. Verses can be two or three lines. Leave long \
                stretches for the music; the repetition is the point.
                """,
            affinity: ["electronic", "house", "techno", "ambient", "krautrock", "minimal", "dance", "gospel", "drone", "disco"],
            base: 0.9),
        Mode(
            name: "dream logic",
            brief: """
                Dream logic. Impossible or surreal images stated plainly, as if they were ordinary. \
                Things transform mid-line. A strange internal consistency, never explained or winked at.
                """,
            affinity: ["psychedelic", "prog", "art rock", "dream pop", "freak folk", "alternative", "glam"],
            base: 1.1),
        Mode(
            name: "private confession",
            brief: """
                Private confession. Intensely personal, but written as if to someone who already \
                knows the whole story, so the listener only gets the edges: names, places and in-jokes \
                that are never explained, sentences that stop before the point. Raw emotion, \
                withheld facts.
                """,
            affinity: ["emo", "singer-songwriter", "indie", "r&b", "folk", "slowcore", "hip hop", "soul"],
            base: 1.4),
        Mode(
            name: "extended metaphor",
            brief: """
                One extended metaphor or allegory that runs through the whole song and is never \
                named or decoded. The listener should be able to read it two or three different ways.
                """,
            affinity: ["folk", "rock", "metal", "americana", "prog", "gospel", "blues"],
            base: 0.9),
        Mode(
            name: "plain-spoken",
            brief: """
                Plain-spoken and direct: conversational, punchy declarations and a hook that says one \
                feeling simply. Avoid inventories of objects; one sharp detail is plenty.
                """,
            affinity: ["pop", "punk", "soul", "r&b", "power pop", "garage", "funk", "rock and roll", "country", "dance"],
            base: 1.0),
        Mode(
            name: "story",
            brief: """
                A story, told elliptically: characters and a situation, but skip the connecting \
                scenes and leave the ending unresolved. Show only the two or three moments that \
                matter, and never state the moral.
                """,
            affinity: ["country", "americana", "folk", "hip hop", "rap", "bluegrass", "heartland"],
            base: 0.7),
    ]

    /// The register for one song, stable for a given album and track number so retries agree.
    /// Neighboring tracks on an album get different registers.
    public static func brief(albumID: String, trackNumber: Int, trackCount: Int, genres: [String]) -> String {
        let count = max(trackCount, trackNumber, 1)
        let picks = assign(count: count, genres: genres, seed: stableHash(albumID))
        let mode = picks[max(trackNumber - 1, 0) % picks.count]
        return mode.brief
    }

    static func assign(count: Int, genres: [String], seed: UInt64) -> [Mode] {
        let haystack = genres.joined(separator: " ").lowercased()
        var generator = CoverDirection.SplitMix(seed: seed)
        let weighted = modes.map { m -> (Mode, Double) in
            (m, m.base + (m.affinity.contains { haystack.contains($0) } ? 1.2 : 0))
        }
        var picked: [Mode] = []
        while picked.count < count {
            // Draw without immediate repeats; modes can recur across a long album.
            let pool = weighted.filter { $0.0.name != picked.last?.name }
            let total = pool.reduce(0) { $0 + $1.1 }
            var roll = Double(generator.next() % 1_000_000) / 1_000_000 * total
            let mode = pool.first { roll -= $0.1; return roll <= 0 }?.0 ?? pool[pool.count - 1].0
            picked.append(mode)
        }
        return picked
    }

    /// FNV-1a: String.hashValue changes every launch.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}

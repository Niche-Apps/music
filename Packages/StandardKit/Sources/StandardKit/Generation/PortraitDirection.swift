import Foundation

/// Gives each artist's press photo its own framing, look, setting, light and casting before the writer
/// art-directs it. Left alone, every band becomes four young people standing in a row in a car park at
/// dusk and every singer a slim model posing in black; real artist photos are far more varied.
public enum PortraitDirection {
    struct Option {
        let text: String
        let affinity: [String]
        let base: Double
        var groupOnly = false
        var soloOnly = false
    }

    static let framings: [Option] = [
        Option(text: "a tight close-up: one face fills the frame, cropped hard", affinity: ["r&b", "soul", "pop", "singer-songwriter", "hip hop", "rap"], base: 1.0, soloOnly: true),
        Option(text: "a tight close-up of the singer alone, the rest of the band out of frame or a blurred shoulder", affinity: ["indie", "rock", "pop"], base: 0.5, groupOnly: true),
        Option(text: "a wide environmental shot: the people are small in a big, specific place", affinity: ["folk", "country", "americana", "post-rock", "ambient", "shoegaze"], base: 1.0),
        Option(text: "a candid frame caught mid-moment — laughing, talking, walking, eating — nobody posing for the camera", affinity: ["indie", "punk", "garage", "hip hop", "emo"], base: 1.1),
        Option(text: "shot from directly overhead or a steep high angle", affinity: ["electronic", "pop", "hyperpop"], base: 0.6),
        Option(text: "a low angle looking up, sky or ceiling behind them", affinity: ["metal", "hip hop", "rap", "rock"], base: 0.6),
        Option(text: "a profile or a back turned: looking away from the camera, face half-seen", affinity: ["ambient", "electronic", "folk", "dream pop", "slowcore"], base: 0.7),
        Option(text: "partly obscured: in deep shadow, behind wet or dirty glass, through smoke or haze, or blurred by motion", affinity: ["trip-hop", "shoegaze", "goth", "post-punk", "techno"], base: 0.7),
        Option(text: "a reflection in a mirror, shop window or puddle, the photographer's framing deliberate", affinity: ["indie", "art rock", "jazz"], base: 0.4),
        Option(text: "live on stage or in rehearsal, instruments in hand, mid-performance, sweat and movement", affinity: ["rock", "metal", "punk", "jazz", "blues", "hardcore", "funk"], base: 0.9),
        Option(text: "seated or lying down — sprawled on a couch, a floor, grass or a car hood", affinity: ["indie", "r&b", "lo-fi", "bedroom"], base: 0.8),
        Option(text: "a formal, posed publicity still against a plain backdrop, like an old record-label promo photo", affinity: ["soul", "jazz", "country", "disco", "funk", "k-pop"], base: 0.7),
        Option(text: "a half-length portrait at a slight angle, one hand doing something (a cigarette, a drink, a guitar neck, a jacket collar)", affinity: ["rock", "blues", "country", "r&b"], base: 0.8, soloOnly: true),
    ]

    static let looks: [Option] = [
        Option(text: "color 35mm film in natural light, real grain", affinity: ["indie", "folk", "rock"], base: 1.0),
        Option(text: "high-contrast black-and-white film with deep blacks", affinity: ["jazz", "post-punk", "blues", "hip hop", "goth"], base: 0.9),
        Option(text: "harsh direct on-camera flash at night, a snapshot look with hard shadows", affinity: ["punk", "garage", "hip hop", "indie", "hyperpop"], base: 0.9),
        Option(text: "instant-film look: soft focus, shifted color, slightly faded", affinity: ["lo-fi", "bedroom", "dream pop"], base: 0.5),
        Option(text: "saturated slide-film color, rich reds and deep blue skies", affinity: ["soul", "funk", "country", "surf", "reggae"], base: 0.8),
        Option(text: "crisp, bright modern digital photography with clean color", affinity: ["pop", "k-pop", "edm", "electropop"], base: 0.8),
        Option(text: "cinematic colored-gel lighting — magenta, cyan, deep red", affinity: ["r&b", "synthwave", "electronic", "trip-hop"], base: 0.6),
        Option(text: "warm tungsten indoor light, homey and amber", affinity: ["folk", "singer-songwriter", "soul", "americana"], base: 0.7),
        Option(text: "overexposed, sun-bleached daylight with blown highlights", affinity: ["surf", "indie", "reggae", "chillwave"], base: 0.6),
        Option(text: "grainy disposable-camera photo with slightly crooked framing", affinity: ["emo", "punk", "lo-fi", "indie"], base: 0.5),
        Option(text: "medium-format studio photo with a soft key light and a bold solid-color seamless backdrop", affinity: ["pop", "r&b", "k-pop", "dance", "hip hop"], base: 0.7),
        Option(text: "a painted or illustrated portrait instead of a photo (gouache, oil or ink), with visible brushwork", affinity: ["psychedelic", "folk", "prog", "lo-fi"], base: 0.25),
    ]

    static let settings: [Option] = [
        Option(text: "somewhere domestic and lived-in, with real clutter", affinity: ["folk", "indie", "bedroom", "r&b", "singer-songwriter"], base: 1.0),
        Option(text: "out in open nature, far from any city", affinity: ["folk", "country", "americana", "post-rock", "black metal"], base: 1.0),
        Option(text: "in or on a vehicle", affinity: ["hip hop", "country", "punk", "rock"], base: 0.7),
        Option(text: "an ordinary working place with its own light and signage (shop, diner, laundromat, garage, barbershop, factory floor)", affinity: ["punk", "indie", "hip hop", "soul"], base: 0.9),
        Option(text: "a rehearsal room, recording studio or backstage corridor", affinity: ["rock", "jazz", "metal", "funk"], base: 0.7),
        Option(text: "no setting at all: a plain studio backdrop", affinity: ["pop", "r&b", "electronic", "k-pop"], base: 0.7),
        Option(text: "a busy street or market in daylight, other people around them", affinity: ["hip hop", "reggae", "afrobeats", "indie", "latin"], base: 0.8),
        Option(text: "a strange, specific place nobody photographs bands in", affinity: ["art rock", "experimental", "indie", "electronic"], base: 0.8),
        Option(text: "a nightclub, party or crowded room", affinity: ["house", "techno", "disco", "dance", "r&b"], base: 0.6),
        Option(text: "water: a beach, a pool, a river or the rain", affinity: ["surf", "dream pop", "chillwave", "reggae"], base: 0.6),
    ]

    static let lights: [Option] = [
        Option(text: "harsh midday sun", affinity: [], base: 1.0),
        Option(text: "flat overcast daylight", affinity: [], base: 0.9),
        Option(text: "low golden-hour sun", affinity: [], base: 0.8),
        Option(text: "night, lit by whatever is there (streetlight, neon, headlights, a phone screen)", affinity: [], base: 0.8),
        Option(text: "indoor fluorescent or practical lamps", affinity: [], base: 0.8),
        Option(text: "early morning, pale and cold", affinity: [], base: 0.5),
    ]

    static let castings: [String] = [
        "They're older than you'd expect for the scene, lined faces, comfortable in themselves.",
        "Mixed ages and builds; nobody looks like a model.",
        "Very young, a little awkward, dressed in whatever they own.",
        "Styled boldly in strong color and pattern, not black.",
        "Dressed plainly, like they came straight from work.",
        "Distinctive faces and hair; each person reads as a specific individual.",
        "Unfussy and ordinary-looking; the charisma is in the attitude, not the styling.",
        "Theatrical styling: costume pieces, makeup or a signature look.",
    ]

    /// A short art-direction brief for one artist's portrait. `isGroup` nil when the lineup isn't
    /// written yet (the brief then covers both).
    public static func assign(genres: [String], isGroup: Bool?, seed: UInt64 = .random(in: 0 ... .max)) -> String {
        let haystack = genres.joined(separator: " ").lowercased()
        var generator = CoverDirection.SplitMix(seed: seed)
        func pick(_ options: [Option]) -> String {
            let pool = options.filter { o in
                switch isGroup {
                case true?: !o.soloOnly
                case false?: !o.groupOnly
                case nil: !o.soloOnly && !o.groupOnly
                }
            }
                .map { o in (o.text, o.base + (o.affinity.contains { haystack.contains($0) } ? 1.2 : 0)) }
            let total = pool.reduce(0) { $0 + $1.1 }
            var roll = Double(generator.next() % 1_000_000) / 1_000_000 * total
            return pool.first { roll -= $0.1; return roll <= 0 }?.0 ?? pool[pool.count - 1].0
        }
        let framing = pick(framings)
        let look = pick(looks)
        let setting = pick(settings)
        let staged = setting.contains("backdrop") || look.contains("studio") || framing.contains("on stage")
        let light = staged ? "studio or stage lighting that suits the look" : pick(lights)
        let casting = castings[Int(generator.next() % UInt64(castings.count))]
        let arrangement = isGroup != false
            ? " \(isGroup == nil ? "If it's a group: never" : "Never") a straight standing lineup: arrange them unevenly (some sitting, someone cut off by the frame, one sharp and the others soft, or spread across the space)."
            : ""

        return """
            Framing: \(framing).\(arrangement)
            Look: \(look).
            Setting: \(setting). Pick one concrete place and name it.
            Light: \(light).
            Casting: \(casting)
            Avoid the stock band photo: no car parks, rooftops, underpasses or concrete walls at dusk, no all-black wardrobe, no everyone staring into the lens with the same expression.
            """
    }
}

extension LibraryBuilder {
    /// Art-directs and paints a fresh press photo for an existing artist (a new direction each time).
    public func reimaginePortrait(artistID: ID) async throws {
        struct Concept: Decodable, Sendable { var portraitConcept: String }
        guard var artist = try await db.reader.read({ try Artist.fetchOne($0, key: artistID) }) else {
            throw ChatGPTError.failed("Unknown artist")
        }
        let prompt = """
            Art-direct a new press photo for this fictional artist.
            \(artist.name) (\(artist.primaryGenre), \(artist.origin), from \(artist.formedYear)). \(artist.tagline)
            Members: \(artist.members.isEmpty ? "solo artist" : artist.members.joined(separator: "; "))
            Soul: \(artist.soul.prefix(700))

            portraitConcept: 60–110 words, built on this direction (keep its framing, look, setting, light and casting; \
            make each concrete and specific to this artist, their era and scene). Describe the people as individuals: \
            age, build, hair, clothes with real color, expression. Fictional people only. No text.
            \(PortraitDirection.assign(genres: [artist.primaryGenre] + artist.genres + artist.tags, isGroup: artist.members.count > 1))
            """
        let c = try await textLimit.run {
            try await self.client.json(
                Concept.self, schemaName: "portrait", schema: Schema.object(["portraitConcept": Schema.string()]),
                instructions: "You are a photo editor at a music magazine with a restless eye.", prompt: prompt, effort: "low")
        }
        artist = try db.modifyArtist(artistID) { $0.imagePrompt = c.portraitConcept } ?? artist
        try await paintPortrait(artist)
    }
}

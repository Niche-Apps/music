import Foundation

/// What each genre actually sounds like on record. The writer otherwise drifts every artist toward
/// the listener's own taste (an indie-folk listener gets "intimate, tactile" electropop with nylon
/// guitar), and the music model only hears the tags, so an electropop song tagged like a folk song
/// comes out as a folk song. These references keep each genre's defining sound in the prompts.
public enum GenreSound {
    struct Reference {
        /// Lowercased keywords matched against an artist's genres; the first entry is the label.
        let keys: [String]
        let instruments: String
        let production: String
        let vocals: String
        /// Things the genre almost never has, which the writer tends to add anyway.
        let avoid: String
    }

    // Ordered most specific first: "electropop" must match before "pop", "folk rock" before "rock".
    static let references: [Reference] = [
        Reference(keys: ["electropop", "electro-pop", "electro pop", "synth-pop", "synthpop", "synth pop", "dance-pop", "dance pop", "hyperpop"],
                  instruments: "analog and digital synthesizers, synth bass, drum machine, programmed claps, arpeggiators, vocoder or vocal chops",
                  production: "glossy, compressed, sidechained, bright, quantized beats, big polished chorus",
                  vocals: "processed or layered lead, auto-tune or doubled vocals, hooky and confident, bright",
                  avoid: "acoustic guitar, nylon guitar, upright piano, felt piano, brushed drums, room tone, folk instruments"),
        Reference(keys: ["synthwave", "retrowave", "outrun"],
                  instruments: "analog polysynths, gated reverb drums, synth bass arpeggio, electric guitar lead, saxophone",
                  production: "1980s retro, neon, wide chorus effects, punchy, reverb-heavy",
                  vocals: "emotive, reverb-drenched, soaring",
                  avoid: "acoustic instruments, lo-fi room sound"),
        Reference(keys: ["house", "deep house", "disco house"],
                  instruments: "four-on-the-floor kick, open hi-hats, synth stabs, piano chords, deep bass, claps",
                  production: "club mix, groovy, sidechained, long builds, polished",
                  vocals: "soulful diva hooks or chopped vocal samples",
                  avoid: "acoustic guitar, live room drums, folk instruments"),
        Reference(keys: ["techno", "trance", "edm", "drum and bass", "dnb", "dubstep", "electro", "electronic dance", "rave"],
                  instruments: "drum machine, synth bass, sequenced synths, risers, heavy kick",
                  production: "club-loud, driving, hypnotic, sidechained, high energy",
                  vocals: "sparse chopped vocals or short repeated hooks",
                  avoid: "acoustic guitar, piano ballad, folk instruments"),
        Reference(keys: ["arena rock", "stadium rock", "glam metal", "hair metal", "aor", "hard rock"],
                  instruments: "distorted electric guitars, power chords, big guitar solo, bass guitar, huge drums, keyboards or synth pads",
                  production: "stadium-sized, loud, wide, big reverb on drums, anthemic, polished 80s rock mix",
                  vocals: "powerful belted lead, high-register, gang vocal chorus, soaring",
                  avoid: "harmonium, nylon guitar, spoon or found-object percussion, intimate room recording, whispered vocals"),
        Reference(keys: ["metal", "metalcore", "thrash", "doom", "black metal", "death metal", "sludge"],
                  instruments: "heavily distorted downtuned guitars, double-kick drums, bass guitar, riffs",
                  production: "crushing, loud, aggressive, tight, heavy",
                  vocals: "screamed, growled or soaring clean metal vocals",
                  avoid: "acoustic folk instruments, soft piano, gentle"),
        Reference(keys: ["punk", "hardcore", "pop-punk", "pop punk", "garage rock", "garage"],
                  instruments: "fast distorted electric guitars, bass guitar, loud drums",
                  production: "raw, fast, loud, energetic, short",
                  vocals: "shouted, snotty, urgent, gang vocals",
                  avoid: "strings, harmonium, gentle, polished ballad"),
        Reference(keys: ["shoegaze", "noise pop", "dream pop"],
                  instruments: "washed-out reverb guitars, fuzz pedals, synth pads, bass, steady drums",
                  production: "hazy, layered walls of sound, reverb-soaked, dreamy",
                  vocals: "airy, buried in the mix, ethereal",
                  avoid: "dry close-mic sound, folk instruments"),
        Reference(keys: ["post-punk", "post punk", "new wave", "darkwave", "coldwave", "goth"],
                  instruments: "chorus-drenched guitar, prominent melodic bass, drum machine or tight drums, synths",
                  production: "cold, angular, driving, reverb, 1980s",
                  vocals: "deadpan, baritone or detached, dramatic",
                  avoid: "folk instruments, warm acoustic sound"),
        Reference(keys: ["hip hop", "hip-hop", "rap", "trap", "drill", "boom bap"],
                  instruments: "programmed drums, 808 bass, samples, hi-hat rolls, synth or sampled loops",
                  production: "hard-hitting, punchy low end, modern mix",
                  vocals: "rapped verses, rhythmic flow, hooky chorus",
                  avoid: "acoustic folk guitar, harmonium, brushed drums"),
        Reference(keys: ["r&b", "rnb", "neo-soul", "neo soul", "contemporary r&b"],
                  instruments: "smooth keys, rhodes, deep bass, programmed or live groove drums, lush pads",
                  production: "silky, polished, warm low end, groove-forward",
                  vocals: "smooth, melismatic, layered harmonies",
                  avoid: "folk instruments, distorted guitars"),
        Reference(keys: ["soul", "motown", "funk", "disco"],
                  instruments: "horn section, bass guitar groove, rhythm guitar, organ or electric piano, live drums, strings",
                  production: "groovy, warm analog, tight band, danceable",
                  vocals: "powerful soulful lead, backing vocal harmonies",
                  avoid: "folk instruments, ambient haze"),
        Reference(keys: ["k-pop", "kpop", "j-pop", "jpop", "city pop", "bubblegum", "teen pop"],
                  instruments: "synthesizers, slap or synth bass, punchy drums, bright guitars, polished hooks",
                  production: "glossy, highly polished, dynamic sections, bright",
                  vocals: "bright, layered group or lead vocals, catchy",
                  avoid: "lo-fi, folk instruments, room tone"),
        Reference(keys: ["country", "americana", "bluegrass", "honky-tonk", "outlaw"],
                  instruments: "steel guitar, telecaster twang, fiddle, acoustic guitar, banjo, bass, drums",
                  production: "Nashville or roots, warm, clear",
                  vocals: "twangy, storytelling, heartfelt",
                  avoid: "synthesizers, drum machine"),
        Reference(keys: ["jazz", "bebop", "swing", "bossa nova", "bossa"],
                  instruments: "upright bass, ride cymbal, piano, saxophone or trumpet, brushes, nylon guitar for bossa",
                  production: "live, acoustic, warm, small-group",
                  vocals: "jazz phrasing, smoky, scat",
                  avoid: "distorted guitar, drum machine, synths"),
        Reference(keys: ["reggae", "dub", "dancehall", "ska"],
                  instruments: "offbeat skank guitar, heavy bass, one-drop drums, organ bubble, horns",
                  production: "deep bass, echo and delay, laid-back",
                  vocals: "patois-inflected, rhythmic",
                  avoid: "folk instruments, stadium rock"),
        Reference(keys: ["latin", "reggaeton", "salsa", "cumbia", "bachata"],
                  instruments: "dembow or clave rhythm, percussion, bass, brass or synths, guitar",
                  production: "danceable, rhythmic, bright",
                  vocals: "passionate, rhythmic",
                  avoid: "folk harmonium, ambient"),
        Reference(keys: ["ambient", "drone", "new age"],
                  instruments: "synth pads, textures, field recordings, slow evolving tones",
                  production: "spacious, floating, slow, atmospheric",
                  vocals: "wordless or sparse",
                  avoid: "loud drums, guitar solos"),
        Reference(keys: ["trip-hop", "trip hop", "downtempo", "chillwave", "lo-fi hip hop"],
                  instruments: "breakbeat drums, deep bass, samples, rhodes, turntable scratches, strings",
                  production: "moody, dusty, slow groove",
                  vocals: "sultry, detached",
                  avoid: "stadium rock, bluegrass"),
        Reference(keys: ["indie rock", "alternative rock", "alt rock", "grunge", "britpop", "post-grunge"],
                  instruments: "electric guitars, bass guitar, live drums, occasional keys",
                  production: "band in a room, guitar-driven, energetic",
                  vocals: "expressive, earnest or sneering",
                  avoid: "harmonium, chamber strings on every song"),
        Reference(keys: ["folk rock", "folk-rock"],
                  instruments: "acoustic and electric guitars, bass, drums, harmonica, organ",
                  production: "warm, live band",
                  vocals: "earnest, harmonies",
                  avoid: "drum machine, synth bass"),
        Reference(keys: ["folk", "singer-songwriter", "chamber folk", "acoustic"],
                  instruments: "acoustic guitar, piano, strings, light percussion",
                  production: "intimate, warm, natural",
                  vocals: "close, conversational",
                  avoid: "heavy distortion, club beats"),
        Reference(keys: ["pop"],
                  instruments: "synthesizers, punchy drums, bass, guitars or piano supporting a big hook",
                  production: "polished radio-ready mix, big chorus",
                  vocals: "confident, catchy, upfront",
                  avoid: "lo-fi room tone, folk instruments"),
        Reference(keys: ["rock"],
                  instruments: "electric guitars, bass guitar, drums, solos",
                  production: "loud, driving band mix",
                  vocals: "strong, gritty",
                  avoid: "harmonium, felt piano"),
    ]

    /// The reference for an artist's genres (primary genre first), or nil for genres not covered.
    static func reference(for genres: [String]) -> Reference? {
        let lowered = genres.map { $0.lowercased() }
        for genre in lowered {
            if let hit = references.first(where: { ref in ref.keys.contains { genre.contains($0) } }) { return hit }
        }
        return nil
    }

    /// A prompt paragraph describing the genre's real sound, or "" when nothing matches.
    public static func guide(for genres: [String]) -> String {
        guard let r = reference(for: genres) else { return "" }
        let name = genres.first ?? r.keys[0]
        return """
            What \(name) sounds like on real records (stay true to it, whatever the listener's other tastes): \
            instruments: \(r.instruments). Production: \(r.production). Vocals: \(r.vocals). \
            Rarely has: \(r.avoid).
            """
    }
}

extension GenreSound {
    /// Last line of defence before the music model: removes tags the genre rarely has (felt piano on
    /// an electropop song) and adds the genre's signature production when none of it is present.
    public static func enforce(tags: String, genres: [String]) -> String {
        guard let r = reference(for: genres) else { return tags }
        let avoid = r.avoid.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var kept = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { tag in
            let lower = tag.lowercased()
            return !tag.isEmpty && !avoid.contains { !$0.isEmpty && lower.contains($0) }
        }
        let signature = r.production.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let lowerKept = kept.map { $0.lowercased() }
        if !signature.contains(where: { s in lowerKept.contains { $0.contains(s.lowercased()) } }) {
            // After the genre and language, before the instruments.
            kept.insert(contentsOf: signature.prefix(2), at: min(2, kept.count))
        }
        let instruments = r.instruments.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let hasInstrument = instruments.contains { inst in
            let core = inst.split(separator: " ").last.map(String.init) ?? inst
            return lowerKept.contains { $0.contains(core) }
        }
        if !hasInstrument, let first = instruments.first { kept.insert(first, at: min(4, kept.count)) }
        return kept.joined(separator: ", ")
    }
}

import Foundation

/// Clean and explicit lyrics. Explicit songs are only written when the listener allows them, and
/// even then they stay a minority: a rate that depends on the genre (common in hip hop, rare in
/// folk), never more than about a third of songs.
public enum ContentRating {
    /// UserDefaults key for "explicit lyrics are OK" (set during onboarding and in Settings).
    public static let allowExplicitKey = "allowExplicit"

    public static var allowsExplicit: Bool { UserDefaults.standard.bool(forKey: allowExplicitKey) }

    /// Share of an artist's songs that may be explicit, by genre.
    static func rate(for genres: [String]) -> Double {
        let g = genres.joined(separator: " ").lowercased()
        func has(_ keys: [String]) -> Bool { keys.contains { g.contains($0) } }
        if has(["hip hop", "hip-hop", "rap", "trap", "drill", "grime", "horrorcore"]) { return 0.3 }
        if has(["punk", "hardcore", "metal", "grunge", "garage", "emo", "reggaeton", "dancehall"]) { return 0.15 }
        if has(["rock", "indie", "alternative", "r&b", "rnb", "electro", "pop", "soul", "funk", "house"]) { return 0.08 }
        if has(["gospel", "christian", "children", "kids", "lullaby", "classical", "ambient", "new age"]) { return 0 }
        return 0.04
    }

    /// Whether this song is one of the few that may be explicit. Stable per track so a retry agrees.
    public static func mayBeExplicit(trackID: String, genres: [String], isInstrumental: Bool) -> Bool {
        guard allowsExplicit, !isInstrumental else { return false }
        let roll = Double(LyricMode.stableHash("explicit:" + trackID) % 10_000) / 10_000
        return roll < rate(for: genres)
    }

    /// Strong anywhere inside a word ("bullshit", "motherfucker").
    static let strongRoots = ["fuck", "shit", "cunt", "nigga", "nigger"]
    /// Strong only as whole words, since they hide inside innocent ones ("Dickens", "cocktail").
    static let strongWords: Set<String> = [
        "dick", "dicks", "cock", "cocks", "pussy", "bitch", "bitches", "bitchin", "asshole", "assholes",
        "bastard", "bastards", "whore", "whores", "slut", "sluts",
    ]

    /// True when the lyrics contain strong language, whatever the writer claims.
    public static func containsExplicitLanguage(_ lyrics: String) -> Bool {
        lyrics.lowercased().split { !$0.isLetter }.contains { word in
            strongWords.contains(String(word)) || strongRoots.contains { word.contains($0) }
        }
    }
}

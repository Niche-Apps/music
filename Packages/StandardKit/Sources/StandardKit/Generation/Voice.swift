import Foundation

/// Keeps an artist sounding like the same singer on every recording. YuE2 can't take reference audio,
/// so the voice is pinned in text: song tags never describe the vocalist, and the artist's fixed voice
/// line is appended verbatim to every style prompt.
public enum Voice {
    public static let instrumental = "instrumental"

    /// Words that describe a singer rather than a song. Tags containing them are dropped in favour of
    /// the artist's own voice line.
    static let singerWords = [
        "vocal", "voice", "singer", "sung", "male", "female", "falsetto", "baritone", "tenor", "alto", "soprano",
        "mezzo", "croon", "rasp", "husky", "breathy",
    ]

    /// The tag line sent to the music model.
    public static func recordingStyle(tags: String, voice: String, isInstrumental: Bool) -> String {
        let voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return tags }
        let kept = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { tag in
                let lower = tag.lowercased()
                return !tag.isEmpty && !singerWords.contains { lower.contains($0) }
            }
        if isInstrumental || voice.lowercased() == instrumental {
            return (kept + ["instrumental"]).joined(separator: ", ")
        }
        return (kept + [voice]).joined(separator: ", ")
    }

    /// Prompt guidance for the `voice` field when writing an artist.
    static let fieldGuidance = """
        voice (private): the lead singer's permanent voice as 4–8 comma-separated music-tag words — gender, register, timbre and delivery, idiomatic to the genre: an arena rock singer belts ("male tenor vocal, powerful, high belting, raspy"), an electropop singer is bright and polished ("female soprano vocal, bright, glossy, auto-tuned"), a rapper raps ("male vocal, rapped, punchy flow"), a folk singer may be close and warm. Don't default to soft, breathy or intimate. This exact line is used for every song they ever record, so describe the person, not a song. Use "instrumental" for instrumental acts.
        """
}

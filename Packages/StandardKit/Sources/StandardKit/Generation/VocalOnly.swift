import Foundation

/// The listener's explicit request for vocals with no instruments ("acapella", "a cappella",
/// "no instruments", and the same idea in nearby words).
///
/// This is a constraint on the words we send. YuE2 and every custom engine only receive a style
/// tag line; nothing in this app can force the model to leave every instrument out. Callers must
/// say that the tags are guidance.
public enum VocalOnly {
    /// Tags appended when the constraint applies. Short, so the music model can actually follow them.
    public static let advisoryTags = ["a cappella", "vocals only", "no instruments", "unaccompanied"]

    /// Replaces the usual "name 3–5 instruments" instruction. The model is told the tags are guidance.
    public static let tagInstruction = """
        styleTags: 6–10 short comma-separated tags of one to three words: the genre first, then mood and a tempo word. \
        Do not name any instrument, drum, bass, synth, beat, or the word instrumental. Include these tags: a cappella, vocals only, no instruments, unaccompanied. \
        The music model only hears these tags and is not guaranteed to leave every instrument out, so the tags must say it plainly.
        """

    /// True when `text` asks for vocals with no instruments, and a negation isn't sitting on that phrase.
    /// "not acapella", "no acapella", "don't want a cappella" and "not no instruments" are not matches.
    /// "not instrumental" is not a match either: that asks for singing, not for an empty band.
    public static func requests(_ text: String) -> Bool {
        let tokens = tokenize(text)
        for index in tokens.indices {
            guard case .word = tokens[index] else { continue }
            for phrase in phrases where matches(phrase, in: tokens, at: index) {
                if !negated(tokens, before: index) { return true }
            }
        }
        return false
    }

    /// Drops instrument tags and appends the advisory line. Idempotent.
    public static func enforce(_ tags: String) -> String {
        var kept: [String] = []
        var seen = Set<String>()
        for tag in split(tags) where !namesInstrument(tag) {
            if seen.insert(tag.lowercased()).inserted { kept.append(tag) }
        }
        for tag in advisoryTags where seen.insert(tag).inserted {
            kept.append(tag)
        }
        return kept.joined(separator: ", ")
    }

    /// A tag that names a way of playing or an instrument. Advisory vocal-only tags are never instruments.
    public static func namesInstrument(_ tag: String) -> Bool {
        let normalized = normalize(tag)
        if isProtected(normalized) { return false }
        let words = wordTokens(normalized)
        let joined = words.joined(separator: " ")
        if instrumentPhrases.contains(where: { joined.contains($0) }) { return true }
        if words.contains(where: { instrumentWords.contains($0) }) { return true }
        return false
    }

    /// Tags the singer-word filter must not throw away ("vocals only" contains "vocal").
    public static func isProtected(_ tag: String) -> Bool {
        let normalized = normalize(tag)
        return protected.contains(normalized)
    }

    // MARK: Matching

    enum Token: Equatable {
        case word(String)
        case barrier
    }

    /// Phrase token lists, longest first so "a cappella" wins over a stray fragment.
    static let phrases: [[String]] = [
        ["nothing", "but", "the", "vocals"],
        ["nothing", "but", "the", "voices"],
        ["vocals", "and", "nothing", "else"],
        ["voices", "and", "nothing", "else"],
        ["no", "musical", "instruments"],
        ["without", "any", "instruments"],
        ["without", "instrumentation"],
        ["no", "instrumentation"],
        ["unaccompanied", "vocals"],
        ["unaccompanied", "voices"],
        ["unaccompanied", "voice"],
        ["nothing", "but", "vocals"],
        ["nothing", "but", "voices"],
        ["just", "the", "vocals"],
        ["just", "the", "voices"],
        ["without", "instruments"],
        ["no", "instruments"],
        ["a", "cappella"],
        ["a", "capella"],
        ["vocals", "only"],
        ["vocal", "only"],
        ["voices", "only"],
        ["voice", "only"],
        ["only", "vocals"],
        ["only", "voices"],
        ["only", "voice"],
        ["just", "vocals"],
        ["just", "voices"],
        ["singing", "only"],
        ["bare", "vocals"],
        ["bare", "voices"],
        ["bare", "voice"],
        ["acappella"],
        ["acapella"],
        ["unaccompanied"],
    ]

    static let negators: Set<String> = [
        "not", "no", "never", "without", "dont", "don't", "isnt", "isn't", "wasnt", "wasn't",
        "avoid", "except", "minus", "non", "arent", "aren't", "wont", "won't", "cannot", "can't",
    ]

    /// Words that can sit between a negator and the phrase ("don't want acapella", "not really a cappella").
    static let fillers: Set<String> = [
        "a", "an", "the", "any", "some", "just", "really", "very", "want", "wants", "wanted", "do", "to",
        "be", "of", "for", "please", "actually", "quite", "kinda", "kind", "so", "too", "all", "my", "your",
        "their", "this", "that", "it", "its", "it's", "quite",
    ]

    static let protected: Set<String> = [
        "a cappella", "a capella", "acappella", "acapella", "vocals only", "vocal only", "voices only",
        "voice only", "only vocals", "only voices", "only voice", "no instruments", "no instrumentation",
        "without instruments", "without instrumentation", "unaccompanied", "unaccompanied vocal",
        "unaccompanied vocals", "unaccompanied voices", "unaccompanied voice", "singing only",
        "bare vocals", "bare voices", "bare voice", "just vocals", "just voices",
    ]

    static let instrumentPhrases = [
        "drum machine", "hi hat", "synth bass", "electric guitar", "acoustic guitar", "power chord",
        "power chords", "four on the floor", "double kick",
    ]

    static let instrumentWords: Set<String> = [
        "guitar", "guitars", "bass", "drum", "drums", "piano", "synth", "synths", "synthesizer", "synthesizers",
        "keyboard", "keyboards", "organ", "violin", "fiddle", "horn", "horns", "brass", "sax", "saxophone",
        "trumpet", "banjo", "harmonica", "string", "strings", "percussion", "kick", "hihat", "snare", "cymbal",
        "cymbals", "rhodes", "pad", "pads", "riff", "riffs", "instrumental", "instrument", "instruments",
        "orchestra", "orchestral", "cello", "flute", "clarinet", "harp", "ukulele", "mandolin", "tambourine",
        "shaker", "sampler", "sample", "samples", "turntable", "vocoder", "arpeggiator", "808", "chord",
        "chords", "distorted", "conga", "bongo", "timbale", "dembow",         "beat", "beats", "backbeat", "acoustic", "electric",
    ]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        func flush() {
            let cleaned = normalize(word)
            if !cleaned.isEmpty { tokens.append(.word(cleaned)) }
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’" || character == "‘" {
                word.append(character == "’" || character == "‘" ? "'" : character)
            } else if character == "-" || character == "_" || character == "/" {
                // "a-cappella" and "vocal-only" are the same phrases with a space.
                flush()
            } else if character.isWhitespace {
                flush()
            } else {
                // Commas and other punctuation break a phrase, so "no, instruments" is not "no instruments".
                flush()
                if tokens.last != .barrier { tokens.append(.barrier) }
            }
        }
        flush()
        return tokens
    }

    static func matches(_ phrase: [String], in tokens: [Token], at start: Int) -> Bool {
        var cursor = start
        for (offset, expected) in phrase.enumerated() {
            guard cursor < tokens.count, case .word(let word) = tokens[cursor] else { return false }
            let actual = (offset == phrase.count - 1) ? word.trimmingPlural : word
            let wanted = expected.trimmingPlural
            guard actual == wanted || actual == expected else { return false }
            cursor += 1
        }
        return true
    }

    /// A negator in the few words before the phrase, not counting fillers. A content word stops the lookback,
    /// so "she said no instruments" still matches while "not no instruments" does not.
    static func negated(_ tokens: [Token], before index: Int) -> Bool {
        var seen = 0
        var cursor = index - 1
        while cursor >= 0 && seen < 4 {
            switch tokens[cursor] {
            case .barrier:
                cursor -= 1
            case .word(let word):
                if negators.contains(word) { return true }
                if fillers.contains(word) {
                    seen += 1
                    cursor -= 1
                    continue
                }
                return false
            }
        }
        return false
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    static func wordTokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public static func split(_ tags: String) -> [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private extension String {
    /// "acapellas" matches the phrase "acapella". Only a trailing s, and not on tiny words ("as").
    var trimmingPlural: String {
        guard count > 4, hasSuffix("s"), !hasSuffix("ss") else { return self }
        return String(dropLast())
    }
}

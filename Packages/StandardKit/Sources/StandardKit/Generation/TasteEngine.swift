import Foundation
import OSLog

let tasteLog = Logger(subsystem: "com.standardmusic", category: "taste")

/// Runs the adaptive part of onboarding: picks the next question with ChatGPT (from real catalog
/// candidates so every question has real artwork) and condenses the answers into a `TasteProfile`.
public struct TasteEngine: Sendable {
    let client: ChatGPTClient
    let catalog: Catalog?

    public init(client: ChatGPTClient, catalog: Catalog?) {
        self.client = client
        self.catalog = catalog
    }

    // MARK: Questions

    struct Candidates {
        var artists: [CatalogArtist]
        var albums: [(CatalogAlbum, CatalogArtist)]
    }

    func candidates(for profile: TasteProfile, asked: [TasteQuestion]) -> Candidates {
        let liked = Set(profile.likedArtists.compactMap(\.catalogID))
        let shown = Set(asked.flatMap(\.artistIDs))
        var exclude = liked.union(shown).union(profile.dislikedArtists.compactMap(\.catalogID))
        var artists: [CatalogArtist] = []
        func add(_ list: [CatalogArtist], _ count: Int) {
            for a in list where !exclude.contains(a.id) && artists.count < 60 {
                artists.append(a)
                exclude.insert(a.id)
                if artists.filter({ list.contains($0) }).count >= count { break }
            }
        }
        add((try? catalog?.neighbors(of: liked, limit: 40)) ?? [], 16)
        let allGenres = ((try? catalog?.genres()) ?? []).map(\.name)
        let unselected = allGenres.filter { !profile.selectedGenres.contains($0) }
        add((try? catalog?.topArtists(genres: profile.selectedGenres, perGenre: 6, excluding: exclude)) ?? [], 10)
        add((try? catalog?.topArtists(genres: Array(unselected.shuffled().prefix(5)), perGenre: 2, excluding: exclude)) ?? [], 8)
        var albums: [(CatalogAlbum, CatalogArtist)] = []
        let albumSources = Array((profile.likedArtists.compactMap(\.catalogID).shuffled().prefix(6))) + artists.prefix(10).map(\.id)
        let artistByID = Dictionary(
            ((try? catalog?.artists(ids: albumSources)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in albumSources {
            guard let artist = artistByID[id], let album = (try? catalog?.albums(artistID: id, limit: 3))?.randomElement()
            else { continue }
            if !asked.contains(where: { $0.albumIDs.contains(album.id) }) { albums.append((album, artist)) }
        }
        return Candidates(artists: artists, albums: albums)
    }

    struct QuestionPayload: Decodable, Sendable {
        var kind: String
        var title: String
        var subtitle: String
        var artistIDs: [Int]
        var albumIDs: [Int]
        var leftLabel: String
        var rightLabel: String
    }

    public func nextQuestion(profile: TasteProfile, asked: [TasteQuestion], remaining: Int) async -> TasteQuestion {
        let pool = candidates(for: profile, asked: asked)
        let artistLines = pool.artists.map { "\($0.id): \($0.name) (\($0.genres.prefix(3).joined(separator: ", ")))" }
        let albumLines = pool.albums.map { "\($0.0.id): \"\($0.0.title)\" by \($0.1.name)\($0.0.year.map { " (\($0))" } ?? "")" }
        let askedLines = asked.map { "- [\($0.kind.rawValue)] \($0.title)" }
        let answers = profile.answers.map { "- \($0.question) → \($0.answer)" }
        // Rotate kinds so the quiz feels varied; ChatGPT chooses the content.
        let rotation: [TasteQuestion.Kind] = [.thisOrThat, .pickAlbum, .multiPick, .spectrum, .thisOrThat, .pickAlbum]
        var kind = rotation[asked.count % rotation.count]
        if kind == .pickAlbum, pool.albums.count < 4 { kind = .thisOrThat }
        if kind == .multiPick, pool.artists.count < 6 { kind = .spectrum }
        let schema = Schema.object([
            "kind": Schema.enumeration([kind.rawValue]),
            "title": Schema.string("The question, max 60 characters, warm and playful"),
            "subtitle": Schema.string("One short supporting line, max 80 characters"),
            "artistIDs": Schema.array(Schema.integer()),
            "albumIDs": Schema.array(Schema.integer()),
            "leftLabel": Schema.string(),
            "rightLabel": Schema.string(),
        ])
        let prompt = """
            We're getting to know a new listener. Choose the single most informative next question.
            \(remaining) question(s) remain after this one.

            What we know:
            Genres they picked: \(profile.selectedGenres.joined(separator: ", "))
            Artists they love: \(profile.likedArtists.map(\.name).joined(separator: ", "))
            Answers so far:
            \(answers.isEmpty ? "(none)" : answers.joined(separator: "\n"))

            Questions already asked (don't repeat their angle):
            \(askedLines.isEmpty ? "(none)" : askedLines.joined(separator: "\n"))

            Candidate artists (id: name (genres)):
            \(artistLines.joined(separator: "\n"))

            Candidate albums (id: title by artist):
            \(albumLines.joined(separator: "\n"))

            Question kinds:
            - thisOrThat: exactly 2 artistIDs that contrast along one dimension you want to learn (e.g. polished vs raw, vintage vs modern). Title like "Which one's more you?"
            - pickAlbum: exactly 4 albumIDs; "Which one are you putting on first?" — spread across moods/eras.
            - multiPick: exactly 6 artistIDs to probe an adjacent scene; "Any of these?"
            - spectrum: a slider between two sonic poles (leftLabel/rightLabel, each ≤ 24 chars), e.g. "Stripped back" ↔ "Big and lush", "Words first" ↔ "Groove first", "Comfort zone" ↔ "Surprise me". No ids.
            This question must be of kind: \(kind.rawValue). Only use ids from the candidate lists. Leave unused fields empty ("" or []).
            """
        do {
            let payload = try await client.json(
                QuestionPayload.self, schemaName: "taste_question", schema: schema,
                instructions:
                    "You are the music-loving onboarding host of a beautiful music app. You're curious, concise and never cheesy.",
                prompt: prompt, quality: .fast, retries: 1)
            if let question = validate(payload, pool: pool) { return question }
        } catch {
            tasteLog.error("Question generation failed: \(error.localizedDescription)")
        }
        return fallbackQuestion(pool: pool, asked: asked, preferred: kind)
    }

    func validate(_ p: QuestionPayload, pool: Candidates) -> TasteQuestion? {
        guard let kind = TasteQuestion.Kind(rawValue: p.kind) else { return nil }
        let artistIDs = Set(pool.artists.map(\.id))
        let albumIDs = Set(pool.albums.map(\.0.id))
        let artists = p.artistIDs.map(Int64.init).filter(artistIDs.contains)
        let albums = p.albumIDs.map(Int64.init).filter(albumIDs.contains)
        switch kind {
        case .thisOrThat where artists.count >= 2:
            return TasteQuestion(kind: kind, title: p.title, subtitle: p.subtitle, artistIDs: Array(artists.prefix(2)))
        case .pickAlbum where albums.count >= 4:
            return TasteQuestion(kind: kind, title: p.title, subtitle: p.subtitle, albumIDs: Array(albums.prefix(4)))
        case .multiPick where artists.count >= 4:
            return TasteQuestion(kind: kind, title: p.title, subtitle: p.subtitle, artistIDs: Array(artists.prefix(6)))
        case .spectrum where !p.leftLabel.isEmpty && !p.rightLabel.isEmpty:
            return TasteQuestion(
                kind: kind, title: p.title, subtitle: p.subtitle, leftLabel: String(p.leftLabel.prefix(28)),
                rightLabel: String(p.rightLabel.prefix(28)))
        default:
            return nil
        }
    }

    func fallbackQuestion(pool: Candidates, asked: [TasteQuestion], preferred: TasteQuestion.Kind? = nil) -> TasteQuestion {
        var used = Set(asked.map(\.kind))
        if let preferred { used = Set(TasteQuestion.Kind.allCases).subtracting([preferred]) }
        if !used.contains(.pickAlbum), pool.albums.count >= 4 {
            return TasteQuestion(
                kind: .pickAlbum, title: "Which one are you putting on first?", subtitle: "Go with your gut.",
                albumIDs: pool.albums.prefix(4).map(\.0.id))
        }
        if !used.contains(.multiPick), pool.artists.count >= 6 {
            return TasteQuestion(
                kind: .multiPick, title: "Any of these?", subtitle: "Tap everyone you'd happily hear today.",
                artistIDs: pool.artists.prefix(6).map(\.id))
        }
        if pool.artists.count >= 2, asked.filter({ $0.kind == .thisOrThat }).count < 2 {
            let pair = [pool.artists[0], pool.artists[min(pool.artists.count - 1, 7)]]
            return TasteQuestion(
                kind: .thisOrThat, title: "Which one's more you?", subtitle: "No wrong answers.",
                artistIDs: pair.map(\.id))
        }
        let poles = [
            ("Stripped back", "Big and lush"), ("Comfort zone", "Surprise me"), ("Words first", "Groove first"),
            ("Vintage warmth", "Modern sheen"),
        ]
        let pick = poles.first { pole in !asked.contains { $0.leftLabel == pole.0 } } ?? poles[0]
        return TasteQuestion(
            kind: .spectrum, title: "Where do you land?", subtitle: "Drag to wherever feels right.",
            leftLabel: pick.0, rightLabel: pick.1)
    }

    // MARK: Profile

    struct ProfilePayload: Decodable, Sendable {
        var headline: String
        var summary: String
        var coreGenres: [String]
        var adjacentGenres: [String]
        var wildcardGenres: [String]
        var descriptors: [String]
        var eras: [String]
    }

    /// Condenses onboarding (and later, favorites) into the profile used for generation.
    public func refine(_ profile: TasteProfile) async throws -> TasteProfile {
        let schema = Schema.object([
            "headline": Schema.string("≤ 70 characters, evocative, second person not required"),
            "summary": Schema.string("2–3 sentences addressed to the listener (\"You…\"), specific and flattering but honest"),
            "coreGenres": Schema.array(Schema.string(), min: 3, max: 6),
            "adjacentGenres": Schema.array(Schema.string(), min: 4, max: 8),
            "wildcardGenres": Schema.array(Schema.string(), min: 2, max: 4),
            "descriptors": Schema.array(Schema.string(), min: 4, max: 10),
            "eras": Schema.array(Schema.string(), min: 1, max: 4),
        ])
        let prompt = """
            Build a listener profile from what they told us.

            \(profile.promptContext)
            Genres they picked: \(profile.selectedGenres.joined(separator: ", "))
            Their answers:
            \(profile.answers.map { "- \($0.question) → \($0.answer)" }.joined(separator: "\n"))

            Genres should be specific, music-journalist style (e.g. "dream pop", "UK garage", "outlaw country", "spiritual jazz"), not broad buckets.
            Core = the heart of their taste. Adjacent = neighboring styles they'd likely enjoy. Wildcard = a tasteful stretch they haven't mentioned.
            Descriptors are sonic qualities (e.g. "warm analog production", "breathy female vocals", "odd time signatures").
            """
        let p = try await client.json(
            ProfilePayload.self, schemaName: "taste_profile", schema: schema,
            instructions: "You are a perceptive music critic who profiles listeners' taste.", prompt: prompt)
        var out = profile
        out.headline = p.headline
        out.summary = p.summary
        out.coreGenres = p.coreGenres
        out.adjacentGenres = p.adjacentGenres
        out.wildcardGenres = p.wildcardGenres
        out.descriptors = p.descriptors
        out.eras = p.eras
        out.updatedAt = Date()
        return out
    }
}

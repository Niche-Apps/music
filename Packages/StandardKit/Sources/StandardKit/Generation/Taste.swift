import Foundation

/// A real artist the listener reacted to during onboarding.
public struct SeedArtist: Codable, Sendable, Hashable {
    public var catalogID: Int64?
    public var name: String
    public var genres: [String]

    public init(catalogID: Int64?, name: String, genres: [String]) {
        self.catalogID = catalogID
        self.name = name
        self.genres = genres
    }

    public init(_ artist: CatalogArtist) {
        self.init(catalogID: artist.id, name: artist.name, genres: artist.genres)
    }
}

public struct TasteAnswer: Codable, Sendable, Hashable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// A signal from listening inside the app (favorite, many plays, skip).
public struct ListeningSignal: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case favoriteTrack, favoriteAlbum, favoriteArtist, unfavorite, skip }
    public var kind: Kind
    public var artistName: String
    public var genres: [String]
    public var styleTags: String
    public var title: String
    public var date: Date

    public init(kind: Kind, artistName: String, genres: [String], styleTags: String, title: String) {
        self.kind = kind
        self.artistName = artistName
        self.genres = genres
        self.styleTags = styleTags
        self.title = title
        self.date = Date()
    }
}

public struct TasteProfile: Codable, Sendable, Hashable {
    public var selectedGenres: [String] = []
    public var likedArtists: [SeedArtist] = []
    public var dislikedArtists: [SeedArtist] = []
    public var answers: [TasteAnswer] = []
    /// Free-text extras ("more female vocals", "no country").
    public var notes: String = ""
    /// Short, shareable line ("Late-night synth melancholy with a soft spot for jangly guitars").
    public var headline: String = ""
    /// A paragraph describing the listener, addressed to them.
    public var summary: String = ""
    public var coreGenres: [String] = []
    public var adjacentGenres: [String] = []
    public var wildcardGenres: [String] = []
    public var descriptors: [String] = []
    public var eras: [String] = []
    public var signals: [ListeningSignal] = []
    public var updatedAt = Date()

    public init() {}

    public static let storageKey = "tasteProfile"

    /// Compact description used inside generation prompts.
    public var promptContext: String {
        var lines: [String] = []
        if !summary.isEmpty { lines.append("Listener profile: \(summary)") }
        if !likedArtists.isEmpty { lines.append("Real artists they love: \(likedArtists.map(\.name).joined(separator: ", "))") }
        if !dislikedArtists.isEmpty {
            lines.append("Real artists they're less into: \(dislikedArtists.map(\.name).joined(separator: ", "))")
        }
        if !coreGenres.isEmpty { lines.append("Core genres: \(coreGenres.joined(separator: ", "))") }
        if !adjacentGenres.isEmpty { lines.append("Adjacent genres: \(adjacentGenres.joined(separator: ", "))") }
        if !descriptors.isEmpty { lines.append("Sonic preferences: \(descriptors.joined(separator: ", "))") }
        if !eras.isEmpty { lines.append("Favorite eras: \(eras.joined(separator: ", "))") }
        if !notes.isEmpty { lines.append("In their own words: \(notes)") }
        let loved = signals.filter { $0.kind != .skip && $0.kind != .unfavorite }.suffix(25)
        if !loved.isEmpty {
            lines.append(
                "Songs/artists they've favorited in this app: "
                    + loved.map { "\($0.title) by \($0.artistName) [\($0.styleTags.isEmpty ? $0.genres.joined(separator: ", ") : $0.styleTags)]" }
                    .joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Onboarding questions

public struct TasteQuestion: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Two artists head to head.
        case thisOrThat
        /// Pick the album you'd put on first, out of four.
        case pickAlbum
        /// Tap any you like out of six artists.
        case multiPick
        /// A slider between two sonic poles.
        case spectrum
    }

    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var artistIDs: [Int64]
    public var albumIDs: [Int64]
    public var leftLabel: String
    public var rightLabel: String

    enum CodingKeys: String, CodingKey { case kind, title, subtitle, artistIDs, albumIDs, leftLabel, rightLabel }

    public init(
        kind: Kind, title: String, subtitle: String, artistIDs: [Int64] = [], albumIDs: [Int64] = [],
        leftLabel: String = "", rightLabel: String = ""
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artistIDs = artistIDs
        self.albumIDs = albumIDs
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
    }
}

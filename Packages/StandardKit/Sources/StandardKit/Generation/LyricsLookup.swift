import Foundation

/// How "Look Up Lyrics" behaves.
///
/// Songs written in this library already store their lyrics on the track. Those are shown first.
/// There is no licensed lyrics catalog wired up, so a song with no local lyrics is not filled in
/// from the network. The app opens a web search for the title and artist (and the album, when it
/// has one) and leaves the results in the browser. It does not download, scrape, or display those
/// lyrics, and it does not upload audio.
public enum LyricsLookup {
    public struct Notice: Equatable, Sendable {
        /// Honest description of what the app did. It never claims the lyrics are now in the library.
        public var message: String
        public var includedArtist: Bool
        public var includedAlbum: Bool
    }

    public enum Outcome: Equatable, Sendable {
        /// The track already has singable lyrics. Show those. Do not open a browser.
        case showLocal
        /// No local lyrics. `url` is a search page, not a lyrics document.
        case webSearch(URL, Notice)
        /// Nothing to search for. Do not build a URL.
        case missingTitle
    }

    /// True when `lyrics` contains a sung line, not only section headers like "[Verse]".
    public static func hasSingableLyrics(_ lyrics: String?) -> Bool {
        guard let lyrics else { return false }
        for raw in lyrics.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { continue }
            return true
        }
        return false
    }

    /// Local lyrics win. Otherwise the same search as `webSearch`.
    public static func lookUp(title: String, artist: String, album: String, localLyrics: String?) -> Outcome {
        if hasSingableLyrics(localLyrics) { return .showLocal }
        return webSearch(title: title, artist: artist, album: album)
    }

    /// A browser search for this title and artist. Album is included when it is non-empty so two
    /// songs with the same name can be told apart in the results. The results page is the
    /// disambiguation; this function does not pick a match or fetch lyrics.
    public static func webSearch(title: String, artist: String, album: String) -> Outcome {
        let title = clean(title)
        guard !title.isEmpty else { return .missingTitle }
        let artist = clean(artist)
        let album = clean(album)
        var terms = ["\"\(quoted(title))\""]
        if !artist.isEmpty { terms.append("\"\(quoted(artist))\"") }
        if !album.isEmpty { terms.append("\"\(quoted(album))\"") }
        terms.append("lyrics")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: terms.joined(separator: " "))]
        guard let url = components.url else { return .missingTitle }
        let message: String
        if artist.isEmpty && album.isEmpty {
            message = "Opened a web search for “\(title)”. The artist and album weren’t available, so the results may be the wrong song. Standard Music doesn’t download those lyrics."
        } else if artist.isEmpty {
            message = "Opened a web search for “\(title)” from “\(album)”. The artist wasn’t available. If several results appear, pick the right one in the browser. Standard Music doesn’t download those lyrics."
        } else if album.isEmpty {
            message = "Opened a web search for “\(title)” by \(artist). The album wasn’t available. If several songs share this name, pick the right one in the browser. Standard Music doesn’t download those lyrics."
        } else {
            message = "Opened a web search for “\(title)” by \(artist), from “\(album)”. If more than one song matches, pick it in the browser. Standard Music doesn’t download those lyrics."
        }
        return .webSearch(url, Notice(message: message, includedArtist: !artist.isEmpty, includedAlbum: !album.isEmpty))
    }

    /// The decoded search query, for tests. Nil when the URL isn't a search we built.
    public static func query(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
    }

    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Straight quotes would close the phrase we wrap the field in.
    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }
}

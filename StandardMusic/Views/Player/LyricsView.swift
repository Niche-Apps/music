import StandardKit
import SwiftUI

/// Inspector: lyrics for the current song, with section markers ("[Chorus]") styled as headers.
struct LyricsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let info = model.player.current {
                if info.track.isInstrumental {
                    placeholder("Instrumental", "pianokeys", "“\(info.track.title)” has no vocals. Just listen.")
                } else if let lyrics = info.track.lyrics, !lyrics.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.track.title).font(.system(size: 15, weight: .bold)).accessibilityHeading()
                            Text(info.artist.name).font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.bottom, 14)
                            ForEach(Array(Self.parse(lyrics).enumerated()), id: \.offset) { _, line in
                                switch line {
                                case .section(let name):
                                    Text(name.uppercased())
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .tracking(0.8)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 14)
                                        .padding(.bottom, 2)
                                        .accessibilityLabel(name)
                                        .accessibilityHeading()
                                case .text(let text):
                                    Text(text)
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(.primary.opacity(0.85))
                                case .gap:
                                    Spacer().frame(height: 8)
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                    .id(info.id)
                } else {
                    let recording = model.recording.active?.trackID == info.id
                    VStack(spacing: 16) {
                        placeholder(
                            "Lyrics aren’t written yet", "pencil.and.scribble",
                            recording ? "The songwriter is working on them now." : "They’re written just before the song is recorded.")
                        LookUpLyricsButton(info: info)
                    }
                }
            } else {
                placeholder("Lyrics", "quote.bubble", "Lyrics for the song that’s playing appear here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ title: String, _ symbol: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }

    enum Line { case section(String), text(String), gap }

    static func parse(_ lyrics: String) -> [Line] {
        var lines: [Line] = []
        for raw in lyrics.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if case .text = lines.last { lines.append(.gap) }
            } else if line.hasPrefix("["), line.hasSuffix("]") {
                lines.append(.section(String(line.dropFirst().dropLast())))
            } else {
                lines.append(.text(line))
            }
        }
        // Drop headers with no lines under them ("[Intro]" on an instrumental opening).
        return lines.enumerated().filter { i, line in
            guard case .section = line else { return true }
            if i + 1 < lines.count, case .text = lines[i + 1] { return true }
            return false
        }.map(\.element)
    }
}

/// Opens lyrics saved on the song, or a web search when there are none.
struct LookUpLyricsButton: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo
    var prominent = false

    var body: some View {
        VStack(spacing: 6) {
            if prominent {
                Button("Look Up Lyrics", systemImage: "quote.bubble") { model.lookUpLyrics(info) }
                    .buttonStyle(.borderedProminent)
                    .help("Shows lyrics saved with this song, or opens a web search for the title and artist.")
            } else {
                Button("Look Up Lyrics", systemImage: "quote.bubble") { model.lookUpLyrics(info) }
                    .buttonStyle(.bordered)
                    .help("Shows lyrics saved with this song, or opens a web search for the title and artist.")
            }
            if LyricsLookup.hasSingableLyrics(info.track.lyrics) {
                Button("Search the Web for Lyrics…") { model.searchWebForLyrics(info) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else {
                Text("Web results stay in your browser. This app doesn’t download them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

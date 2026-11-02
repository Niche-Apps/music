import StandardKit
import SwiftUI

struct QuestionStep: View {
    @Bindable var flow: OnboardingFlow
    let index: Int

    var body: some View {
        Group {
            if let question = flow.questions[index] {
                QuestionContent(flow: flow, index: index, question: question)
                    .transition(.blurReplace)
            } else {
                QuestionSkeleton()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.45), value: flow.questions[index]?.id)
    }
}

/// Real artwork for a question, resolved from the catalog.
private struct QuestionMaterial {
    var artists: [CatalogArtist] = []
    var albums: [(album: CatalogAlbum, artist: CatalogArtist?)] = []
    var loaded = false
}

private struct QuestionContent: View {
    @Bindable var flow: OnboardingFlow
    let index: Int
    let question: TasteQuestion
    @State private var material = QuestionMaterial()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            StepHeading(title: question.title, subtitle: question.subtitle)
                .padding(.bottom, 34)
            Group {
                if material.loaded {
                    switch question.kind {
                    case .thisOrThat: ThisOrThat(flow: flow, index: index, question: question, artists: material.artists)
                    case .pickAlbum: PickAlbum(flow: flow, index: index, question: question, albums: material.albums)
                    case .multiPick: MultiPick(flow: flow, index: index, question: question, artists: material.artists)
                    case .spectrum: SpectrumQuestion(flow: flow, index: index, question: question)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(height: 300)
                        .accessibilityLabel("Loading")
                }
            }
            Spacer(minLength: 16)
            Text("Question \(index + 1) of \(OnboardingFlow.questionCount)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 40)
        .task(id: question.id) { await load() }
    }

    private func load() async {
        guard let catalog = flow.catalog else {
            material.loaded = true
            return
        }
        let artistIDs = question.artistIDs
        let albumIDs = question.albumIDs
        let result = await Task.detached(priority: .userInitiated) { () -> QuestionMaterial in
            let artists = (try? catalog.artists(ids: artistIDs)) ?? []
            let albums = (try? catalog.albums(ids: albumIDs)) ?? []
            let owners = (try? catalog.artists(ids: albums.map(\.artistID))) ?? []
            let byID = Dictionary(owners.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return QuestionMaterial(artists: artists, albums: albums.map { ($0, byID[$0.artistID]) }, loaded: true)
        }.value
        withAnimation(.smooth) { material = result }
    }
}

// MARK: - This or that

private struct ThisOrThat: View {
    @Bindable var flow: OnboardingFlow
    let index: Int
    let question: TasteQuestion
    let artists: [CatalogArtist]

    var body: some View {
        let pair = Array(artists.prefix(2))
        let answered = flow.answers[index]
        let previous = answered?.selection ?? []
        VStack(spacing: 26) {
            HStack(spacing: 0) {
                ForEach(Array(pair.enumerated()), id: \.element.id) { i, artist in
                    if i == 1 {
                        Text("or")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 70)
                            .accessibilityHidden(true)
                    }
                    PortraitChoice(artist: artist, selected: previous == [artist.id] || previous.count == 2) {
                        choose([artist], over: pair.filter { $0.id != artist.id }, pair: pair)
                    }
                    .help(i == 0 ? "\(artist.name) (←)" : "\(artist.name) (→)")
                }
            }
            HStack(spacing: 12) {
                Button { choose(pair, over: [], pair: pair) } label: { Text("Both").foregroundStyle(.white).frame(minWidth: 70) }
                    .accessibilityAddTraits(previous.count == 2 ? .isSelected : [])
                    .help("Both (B)")
                Button { choose([], over: pair, pair: pair) } label: { Text("Neither").foregroundStyle(.white).frame(minWidth: 70) }
                    .accessibilityAddTraits(answered != nil && previous.isEmpty ? .isSelected : [])
                    .help("Neither (N)")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        // Keyboard: ← / → pick a side, B for both, N for neither.
        .background {
            if pair.count == 2 {
                KeyboardShortcutHandler(key: .leftArrow) { choose([pair[0]], over: [pair[1]], pair: pair) }
                KeyboardShortcutHandler(key: .rightArrow) { choose([pair[1]], over: [pair[0]], pair: pair) }
                KeyboardShortcutHandler(key: "b") { choose(pair, over: [], pair: pair) }
                KeyboardShortcutHandler(key: "n") { choose([], over: pair, pair: pair) }
            }
        }
    }

    private func choose(_ picked: [CatalogArtist], over others: [CatalogArtist], pair: [CatalogArtist]) {
        let names = pair.map(\.name)
        let text: String
        var disliked: [CatalogArtist] = []
        switch picked.count {
        case 2: text = "Likes both \(names.joined(separator: " and "))"
        case 1: text = "Picked \(picked[0].name) over \(others.first?.name ?? "the other")"
        default:
            text = "Neither \(names.joined(separator: " nor ")) appeals"
            disliked = pair
        }
        flow.record(
            .init(
                answer: TasteAnswer(question: "\(question.title) (\(names.joined(separator: " vs ")))", answer: text),
                liked: picked, disliked: disliked, selection: Set(picked.map(\.id))), for: index)
    }
}

private struct PortraitChoice: View {
    let artist: CatalogArtist
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ArtworkView(source: .url(artist.pictureURL ?? artist.pictureSmallURL), size: 230, circular: true, highResolution: true)
                    .overlay(Circle().strokeBorder(selected ? Color.pink : .white.opacity(hovering ? 0.5 : 0), lineWidth: 3))
                    .shadow(color: .black.opacity(0.4), radius: hovering ? 26 : 14, y: 10)
                    .scaleEffect(hovering ? 1.04 : 1)
                VStack(spacing: 3) {
                    Text(artist.name).font(.system(size: 18, weight: .semibold))
                    Text(artist.genres.prefix(2).joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
            }
            .frame(width: 260)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.22), value: hovering)
        .accessibilityLabel([artist.name, artist.genres.prefix(2).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityChoice(selected: selected)
    }
}

// MARK: - Pick an album

private struct PickAlbum: View {
    @Bindable var flow: OnboardingFlow
    let index: Int
    let question: TasteQuestion
    let albums: [(album: CatalogAlbum, artist: CatalogArtist?)]

    var body: some View {
        let previous = flow.answers[index]?.selection ?? []
        HStack(alignment: .top, spacing: 24) {
            ForEach(Array(albums.enumerated()), id: \.element.album.id) { i, item in
                AlbumChoice(album: item.album, artist: item.artist, selected: previous.contains(item.album.id)) {
                    choose(item)
                }
                .help("\(item.album.title) (\(i + 1))")
                // Keyboard: number keys pick an album.
                .background {
                    if i < 9 { KeyboardShortcutHandler(key: KeyEquivalent(Character("\(i + 1)"))) { choose(item) } }
                }
            }
        }
    }

    private func choose(_ item: (album: CatalogAlbum, artist: CatalogArtist?)) {
        let describe: ((album: CatalogAlbum, artist: CatalogArtist?)) -> String = {
            "“\($0.album.title)” by \($0.artist?.name ?? "unknown")\($0.album.year.map { " (\($0))" } ?? "")"
        }
        let others = albums.filter { $0.album.id != item.album.id }.map(describe)
        flow.record(
            .init(
                answer: TasteAnswer(
                    question: question.title,
                    answer: "Would put on \(describe(item)) first, over \(others.joined(separator: ", "))"),
                liked: item.artist.map { [$0] } ?? [], selection: [item.album.id]), for: index)
    }
}

private struct AlbumChoice: View {
    let album: CatalogAlbum
    let artist: CatalogArtist?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkView(source: .url(album.coverURL ?? album.coverSmallURL), size: 190, cornerRadius: 10, highResolution: true)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.pink : .clear, lineWidth: 3)
                    )
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular, in: .circle)
                            .opacity(hovering ? 1 : 0)
                            .scaleEffect(hovering ? 1 : 0.7)
                    }
                    .shadow(color: .black.opacity(0.45), radius: hovering ? 22 : 12, y: 10)
                    .offset(y: hovering ? -4 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 13.5, weight: .semibold))
                    Text([artist?.name, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
            }
            .frame(width: 190)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.22), value: hovering)
        .accessibilityLabel(Spoken.albumCover(album.title, by: artist?.name) + (album.year.map { ", \($0)" } ?? ""))
        .accessibilityChoice(selected: selected)
    }
}

// MARK: - Multi pick

private struct MultiPick: View {
    @Bindable var flow: OnboardingFlow
    let index: Int
    let question: TasteQuestion
    let artists: [CatalogArtist]
    @State private var picked: Set<Int64> = []

    var body: some View {
        VStack(spacing: 34) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 26), count: 3), spacing: 22) {
                ForEach(Array(artists.prefix(6).enumerated()), id: \.element.id) { i, artist in
                    let selected = picked.contains(artist.id)
                    Button {
                        toggle(artist)
                    } label: {
                        VStack(spacing: 8) {
                            ArtworkView(source: .url(artist.pictureSmallURL ?? artist.pictureURL), size: 116, circular: true)
                                .overlay(Circle().strokeBorder(selected ? Color.pink : .clear, lineWidth: 3))
                                .overlay(alignment: .bottomTrailing) {
                                    if selected { SelectionCheck().offset(x: -2, y: -2) }
                                }
                                .scaleEffect(selected ? 1.08 : 1)
                            Text(artist.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(width: 150)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(artist.name) (\(i + 1))")
                    .accessibilityLabel(artist.name)
                    .accessibilityChoice(selected: selected)
                    // Keyboard: number keys toggle an artist.
                    .background { KeyboardShortcutHandler(key: KeyEquivalent(Character("\(i + 1)"))) { toggle(artist) } }
                }
            }
            Button(picked.isEmpty ? "None of these" : "Continue") { submit() }
                .buttonStyle(.onboardingPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { picked = flow.answers[index]?.selection ?? [] }
    }

    private func toggle(_ artist: CatalogArtist) {
        withAnimation(.spring(duration: 0.35, bounce: 0.45)) {
            if picked.contains(artist.id) { picked.remove(artist.id) } else { picked.insert(artist.id) }
        }
    }

    private func submit() {
        let yes = artists.filter { picked.contains($0.id) }
        let no = artists.filter { !picked.contains($0.id) }
        let text =
            yes.isEmpty
            ? "None of these: \(no.map(\.name).joined(separator: ", "))"
            : "Likes \(yes.map(\.name).joined(separator: ", "))"
                + (no.isEmpty ? "" : "; passed on \(no.map(\.name).joined(separator: ", "))")
        flow.record(
            .init(
                answer: TasteAnswer(question: question.title, answer: text), liked: yes,
                disliked: yes.isEmpty ? no : [], selection: picked), for: index)
    }
}

// MARK: - Spectrum

private struct SpectrumQuestion: View {
    @Bindable var flow: OnboardingFlow
    let index: Int
    let question: TasteQuestion
    @State private var value = 0.5

    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 0) {
                pole(question.leftLabel, weight: 1 - value, alignment: .leading)
                pole(question.rightLabel, weight: value, alignment: .trailing)
            }
            .frame(width: 560)
            .accessibilityHidden(true)
            Slider(value: $value, in: 0 ... 1)
                .tint(.pink)
                .frame(width: 560)
                .focused($sliderFocused)
                .accessibilityLabel("\(question.leftLabel) to \(question.rightLabel)")
                .accessibilityValue(spokenLean)
                .help("Use ← and → to move the slider")
            Button("Continue") { submit() }
                .buttonStyle(.onboardingPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            value = flow.answers[index]?.spectrum ?? 0.5
            sliderFocused = true
        }
        // Keyboard: ← / → move the slider even when it doesn't have focus.
        .background {
            if !sliderFocused {
                KeyboardShortcutHandler(key: .leftArrow) { withAnimation(.smooth(duration: 0.15)) { value = max(0, value - 0.1) } }
                KeyboardShortcutHandler(key: .rightArrow) { withAnimation(.smooth(duration: 0.15)) { value = min(1, value + 0.1) } }
            }
        }
    }

    @FocusState private var sliderFocused: Bool

    private var spokenLean: String {
        switch value {
        case ..<0.2: "Strongly \(question.leftLabel)"
        case ..<0.4: "Leans \(question.leftLabel)"
        case ..<0.6: "Right in the middle"
        case ..<0.8: "Leans \(question.rightLabel)"
        default: "Strongly \(question.rightLabel)"
        }
    }

    private func pole(_ label: String, weight: Double, alignment: Alignment) -> some View {
        Text(label)
            .font(.system(size: 22 + 8 * weight, weight: .bold))
            .foregroundStyle(.white.opacity(0.35 + 0.65 * weight))
            .frame(maxWidth: .infinity, alignment: alignment)
            .animation(.smooth(duration: 0.15), value: weight)
    }

    private func submit() {
        let lean: String
        switch value {
        case ..<0.2: lean = "Strongly \(question.leftLabel)"
        case ..<0.4: lean = "Leans \(question.leftLabel)"
        case ..<0.6: lean = "Right in the middle"
        case ..<0.8: lean = "Leans \(question.rightLabel)"
        default: lean = "Strongly \(question.rightLabel)"
        }
        let percent = Int((value * 100).rounded())
        flow.record(
            .init(
                answer: TasteAnswer(
                    question: "\(question.title) (\(question.leftLabel) ↔ \(question.rightLabel))",
                    answer: "\(lean) — \(percent)% of the way toward \(question.rightLabel)"),
                spectrum: value), for: index)
    }
}

// MARK: - ShimmerBlock

private struct QuestionSkeleton: View {
    @State private var line = 0
    private let lines = ["Thinking about what to ask next…", "Listening to your picks…", "Digging through the crates…"]

    var body: some View {
        VStack(spacing: 34) {
            VStack(spacing: 12) {
                ShimmerBlock(cornerRadius: 8).frame(width: 380, height: 30)
                ShimmerBlock(cornerRadius: 6).frame(width: 260, height: 16)
            }
            HStack(spacing: 70) {
                ShimmerBlock(cornerRadius: 115).frame(width: 230, height: 230)
                ShimmerBlock(cornerRadius: 115).frame(width: 230, height: 230)
            }
            Text(lines[line % lines.count])
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .contentTransition(.opacity)
                .id(line)
                .transition(.opacity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking about what to ask next")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.smooth) { line += 1 }
            }
        }
    }
}

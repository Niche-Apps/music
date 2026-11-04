import GRDB
import StandardKit
import SwiftUI

/// Generate more music: from a prompt, a blind "discover", or "more like" an artist you love.
struct CreateView: View {
    @Environment(AppModel.self) private var model

    struct Batch: Equatable, Identifiable, Sendable {
        var batch: GenerationBatch
        var ready: [Artist]
        var id: ID { batch.id }
    }

    struct Data: Equatable, Sendable {
        var batches: [Batch] = []
        var artists: [Artist] = []
    }

    @State private var prompt = ""
    @State private var count = 4
    @State private var data = Data()
    @State private var likeQuery = ""
    @State private var submitting = false
    @AppStorage("createMode") private var mode = Mode.simple
    @FocusState private var promptFocused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case simple, custom
        var id: String { rawValue }
        var title: String { self == .simple ? "Simple" : "Custom" }
    }

    static let suggestions = [
        "Late-night jazz from a fictional 1960s Lisbon",
        "Dream pop recorded in a lighthouse",
        "Afrobeat bands that only play weddings",
        "Synthwave for driving through rain",
        "Folk songs from a mining town",
        "90s Tokyo city pop",
        "Gospel choirs meets drum and bass",
        "Desert blues, cassette only",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                PageHeader(title: "Create", subtitle: "Write new artists into your library, or bring your own lyrics and a style and hear them sung.")
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("Create mode")
                if mode == .simple { promptCard } else { CustomSongCard(artists: data.artists) }
                NewReleaseCard(artists: data.artists)
                HStack(alignment: .top, spacing: 18) {
                    discoverCard
                    moreLikeCard
                }
                batches
            }
            .padding(Metrics.pagePadding)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Create")
        .observing(model.services.db) { db in
            let batches = try GenerationBatch.order(Column("createdAt").desc).limit(20).fetchAll(db)
            let ids = batches.map(\.id)
            let ready = try Artist.filter(ids.contains(Column("batchID")) && Column("status") == ItemStatus.ready.rawValue)
                .order(Column("createdAt")).fetchAll(db)
            return Data(
                batches: batches.map { b in Batch(batch: b, ready: ready.filter { $0.batchID == b.id }) },
                artists: try LibraryQuery.visibleArtists(db))
        } update: { data = $0 }
    }

    // MARK: Prompt

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe what you want to hear").font(.system(size: 15, weight: .semibold)).accessibilityHeading()
            TextField("Describe a sound, a scene, an era…", text: $prompt, axis: .vertical)
                .accessibilityLabel("Describe what you want to hear")
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(2 ... 4)
                .focused($promptFocused)
                .padding(14)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(promptFocused ? Color.accentColor.opacity(0.6) : .primary.opacity(0.1)))
                .onSubmit(submitPrompt)
            FlowLayout(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button(s) {
                        prompt = s
                        promptFocused = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityHint("Uses this as the description")
                }
            }
            HStack {
                Stepper(value: $count, in: 1 ... 12) {
                    Text("\(count) artist\(count == 1 ? "" : "s")").monospacedDigit()
                }
                .fixedSize()
                .accessibilityLabel("Number of artists")
                .accessibilityValue("\(count)")
                Text("Usually 2–4 minutes per artist").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: submitPrompt) {
                    Label("Create", systemImage: "sparkles").frame(minWidth: 80)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func submitPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !submitting else { return }
        submitting = true
        Task {
            await model.generateArtists(prompt: text, count: count)
            prompt = ""
            submitting = false
        }
    }

    // MARK: Discover & More like

    private var discoverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "dice").font(.system(size: 22)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text("Discover new artists for me").font(.system(size: 15, weight: .semibold)).accessibilityHeading()
            Text("No brief. Picked from your taste, with a few surprises.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button {
                Task { await model.generateArtists(prompt: nil, count: count) }
            } label: {
                Label("Surprise Me", systemImage: "sparkles")
            }
            .buttonStyle(.glass)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var moreLikeCard: some View {
        let q = likeQuery.trimmingCharacters(in: .whitespaces)
        let matches = (q.isEmpty ? data.artists.filter(\.isFavorite) + data.artists.filter { !$0.isFavorite } : data.artists.filter { $0.name.localizedCaseInsensitiveContains(q) })
            .prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 22)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text("More like…").font(.system(size: 15, weight: .semibold)).accessibilityHeading()
            TextField("Find an artist", text: $likeQuery)
                .textFieldStyle(.roundedBorder)
            if data.artists.isEmpty {
                Text("Your artists will be listed here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(matches)) { artist in
                Button {
                    Task { await model.generateSimilar(to: artist) }
                } label: {
                    HStack(spacing: 8) {
                        ArtworkView(source: .artist(artist), size: 22, circular: true, shadow: false)
                        Text(artist.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Write four artists in the spirit of \(artist.name)")
                .accessibilityLabel("More like \(artist.name)")
                .accessibilityHint("Writes four artists in the spirit of \(artist.name)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    // MARK: Batches

    @ViewBuilder private var batches: some View {
        if !data.batches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Creations").font(.system(size: 19, weight: .bold)).accessibilityHeading()
                ForEach(data.batches) { batch in
                    BatchRow(batch: batch)
                    Divider()
                }
            }
        }
    }
}

/// Pick an artist (favorites first), optionally add a brief, and write their next album.
struct NewReleaseCard: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    let artists: [Artist]
    @State private var selected: ID?
    @State private var brief = ""

    var body: some View {
        let ordered = artists.filter(\.isFavorite) + artists.filter { !$0.isFavorite }
        let artist = ordered.first { $0.id == selected } ?? ordered.first
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "opticaldisc").font(.system(size: 18)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New music from artists you love").font(.system(size: 15, weight: .semibold)).accessibilityHeading()
                    Text("A new album that continues their story, with tracklist, liner notes and cover.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            if ordered.isEmpty {
                Text("Your artists will appear here once your library has some.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(ordered.prefix(24)) { a in
                            let isSelected = a.id == artist?.id
                            let busy = library.releasing.contains(a.id)
                            Button { selected = a.id } label: {
                                VStack(spacing: 6) {
                                    ArtworkView(source: .artist(a), size: 60, circular: true, shadow: false)
                                        .overlay {
                                            Circle().stroke(Color.accentColor, lineWidth: isSelected ? 2.5 : 0).padding(-3)
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            if busy { ProgressView().controlSize(.mini).padding(3).glassEffect(.regular, in: .circle) }
                                            else if a.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor).padding(4).glassEffect(.regular, in: .circle) }
                                        }
                                    Text(a.name).font(.system(size: 11)).lineLimit(1).frame(width: 72)
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(busy ? "\(a.name)’s next album is being written" : a.name)
                            .accessibilityLabel(a.isFavorite ? "\(a.name), Favorite" : a.name)
                            .accessibilityValue(busy ? "Next album is being written" : "")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                }
                .scrollIndicators(.never)
                if let artist {
                    HStack(spacing: 10) {
                        TextField("Optional brief for \(artist.name) — “their late-career acoustic record”", text: $brief)
                            .accessibilityLabel("Optional brief for \(artist.name)")
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { start(artist) }
                        Button { start(artist) } label: {
                            if library.releasing.contains(artist.id) {
                                Label { Text("Writing…") } icon: { ProgressView().controlSize(.small) }
                            } else {
                                Label("New Release", systemImage: "opticaldisc")
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(library.releasing.contains(artist.id))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func start(_ artist: Artist) {
        model.newRelease(from: artist, brief: brief, library: library)
        brief = ""
    }
}

struct BatchRow: View {
    @Environment(AppModel.self) private var model
    let batch: CreateView.Batch

    var body: some View {
        let b = batch.batch
        let live = model.buildStatus.batchID == b.id ? model.buildStatus : nil
        let total = max(1, live?.artistsTotal ?? b.targetArtists)
        let ready = live?.artistsReady ?? batch.ready.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon(b)).foregroundStyle(color(b)).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(detail(b, live: live, ready: ready, total: total))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(b.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            if b.status == .running || b.status == .planning {
                ProgressView(value: Double(ready), total: Double(total)).controlSize(.small).padding(.leading, 26)
                    .accessibilityLabel("Progress for \(b.title)")
                    .accessibilityValue("\(ready) of \(total) artists ready")
            }
            if !batch.ready.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(batch.ready) { artist in
                            ArtistCard(artist: artist, size: 64)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.leading, 26)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ b: GenerationBatch) -> String {
        switch b.status {
        case .planning, .running: "sparkles"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func color(_ b: GenerationBatch) -> Color {
        switch b.status {
        case .planning, .running: .accentColor
        case .finished: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }

    private func detail(_ b: GenerationBatch, live: BuildStatus?, ready: Int, total: Int) -> String {
        switch b.status {
        case .planning: return "Planning the lineup…"
        case .running:
            let activity = live?.activity ?? ""
            return "\(ready) of \(total) artists ready" + (activity.isEmpty ? "" : " · \(activity)")
        case .finished: return "\(ready) new artist\(ready == 1 ? "" : "s")"
        case .failed: return b.error ?? "Stopped with an error."
        case .cancelled: return "Cancelled"
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}

/// Create › Custom: the listener's own lyrics (or ones written for them) and a style of music,
/// performed by one of their artists or by a new artist invented for the song.
struct CustomSongCard: View {
    @Environment(AppModel.self) private var model
    let artists: [Artist]
    @State private var lyrics = ""
    @State private var style = ""
    @State private var title = ""
    @State private var instrumental = false
    @State private var performer: ID?
    @State private var drafting = false
    @State private var submitting = false
    @FocusState private var focus: Field?

    enum Field { case lyrics, style, title }

    static let styleChips = [
        "pop", "indie rock", "hip hop", "r&b", "electropop", "country", "metal", "jazz", "lo-fi", "synthwave",
        "female vocals", "male vocals", "upbeat", "melancholic", "acoustic", "808 bass", "80s", "orchestral",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Lyrics").font(.system(size: 15, weight: .semibold)).accessibilityHeading()
                    Spacer()
                    Toggle("Instrumental", isOn: $instrumental).toggleStyle(.switch).controlSize(.small)
                    Button {
                        draft()
                    } label: {
                        if drafting { Label { Text("Writing…") } icon: { ProgressView().controlSize(.small) } }
                        else { Label("Write Lyrics for Me", systemImage: "sparkles") }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(drafting || instrumental)
                    .help("Writes a song in the style below (and about the title, if you give one). Edit it before you create.")
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $lyrics)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .lyrics)
                        .disabled(instrumental)
                        .accessibilityLabel("Lyrics")
                    if lyrics.isEmpty {
                        Text(instrumental ? "No vocals: just the style below." : "[Verse]\nWrite your own lyrics, paste some in, or let Standard Music write them.\n\n[Chorus]\n…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .padding(.leading, 5).padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .frame(height: 220)
                .opacity(instrumental ? 0.45 : 1)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(focus == .lyrics ? Color.accentColor.opacity(0.6) : .primary.opacity(0.1)))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Style of music").font(.system(size: 15, weight: .semibold)).accessibilityHeading()
                TextField("Genres, instruments, mood, era, vocals — “90s grunge, heavy guitars, female vocals”", text: $style, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1 ... 3)
                    .focused($focus, equals: .style)
                    .padding(12)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(focus == .style ? Color.accentColor.opacity(0.6) : .primary.opacity(0.1)))
                    .accessibilityLabel("Style of music")
                FlowLayout(spacing: 6) {
                    ForEach(Self.styleChips, id: \.self) { chip in
                        Button("+ \(chip)") { add(chip) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .accessibilityLabel("Add \(chip) to the style")
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title").font(.system(size: 13, weight: .semibold))
                    TextField("Optional", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .title)
                        .accessibilityLabel("Title, optional")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Performed by").font(.system(size: 13, weight: .semibold))
                    Picker("Performed by", selection: $performer) {
                        Text("A new artist for this song").tag(ID?.none)
                        if !artists.isEmpty { Divider() }
                        ForEach(artists.filter(\.isFavorite) + artists.filter { !$0.isFavorite }) { a in
                            Text(a.name).tag(Optional(a.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                Spacer()
                Button(action: create) {
                    if submitting { Label { Text("Creating…") } icon: { ProgressView().controlSize(.small) } }
                    else { Label("Create", systemImage: "sparkles").frame(minWidth: 80) }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate || submitting)
            }
            Text(performer == nil
                ? "A new artist is invented to fit the style, with a photo, a story and a cover for your single. It starts recording right away."
                : "Your single gets its own cover and starts recording right away, in that artist’s voice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var canCreate: Bool {
        !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!instrumental && !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func add(_ chip: String) {
        let current = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.localizedCaseInsensitiveContains(chip) else { return }
        style = current.isEmpty ? chip : current + ", " + chip
    }

    private func draft() {
        drafting = true
        Task {
            if let text = await model.draftLyrics(style: style, about: title) { lyrics = text }
            drafting = false
        }
    }

    private func create() {
        guard canCreate, !submitting else { return }
        submitting = true
        let request = CustomSongRequest(
            lyrics: lyrics, style: style, title: title.isEmpty ? nil : title, instrumental: instrumental, artistID: performer)
        Task {
            if await model.createCustomSong(request) {
                lyrics = ""
                title = ""
            }
            submitting = false
        }
    }
}

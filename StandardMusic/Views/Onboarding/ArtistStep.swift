import StandardKit
import SwiftUI

struct ArtistStep: View {
    @Bindable var flow: OnboardingFlow
    @State private var query = ""
    @State private var results: [CatalogArtist] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    StepHeading(
                        title: "Choose some artists you love",
                        subtitle: "Tap the ones you’d play on repeat. We’ll suggest more as you go.")
                        .padding(.top, 26)
                    searchField
                    if !results.isEmpty { searchResults }
                    if flow.cloud.isEmpty {
                        loadingCloud
                    } else {
                        BubbleLayout(spacing: 14) {
                            ForEach(flow.cloud) { artist in
                                ArtistBubble(artist: artist, selected: flow.isLiked(artist)) {
                                    flow.toggle(artist: artist)
                                }
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: 1040)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)

            StepFooter(
                hint: flow.liked.count >= OnboardingFlow.minimumArtists
                    ? "\(flow.liked.count) artists picked"
                    : "Pick \(OnboardingFlow.minimumArtists - flow.liked.count) more",
                action: "Continue", enabled: flow.liked.count >= OnboardingFlow.minimumArtists,
                returnKey: !searchFocused || query.isEmpty
            ) {
                flow.advance()
            } accessory: {
                LikedStrip(artists: flow.liked)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await flow.search(query)
            withAnimation(.smooth(duration: 0.25)) { results = found }
        }
        .task(id: flow.liked.count) {
            // Start thinking about the first question once the picks settle.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            flow.prefetchFirstQuestion()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55)).accessibilityHidden(true)
            TextField("Search for an artist", text: $query)
                .accessibilityLabel("Search for an artist")
                .accessibilityHint("Press Return to add the first result")
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let first = results.first { add(first) }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .frame(width: 380)
        .frame(minHeight: 40)
        .background(.white.opacity(0.06), in: .capsule)
        .glassEffect(.regular, in: .capsule)
    }

    private var searchResults: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(results) { artist in
                    Button {
                        add(artist)
                    } label: {
                        HStack(spacing: 8) {
                            ArtworkView(source: .url(artist.pictureSmallURL), size: 28, circular: true, shadow: false)
                            Text(artist.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Image(systemName: flow.isLiked(artist) ? "checkmark" : "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(flow.isLiked(artist) ? Color.pink : .white.opacity(0.6))
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(flow.isLiked(artist) ? artist.name : "Add \(artist.name)")
                    .accessibilityChoice(selected: flow.isLiked(artist))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: 900)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var loadingCloud: some View {
        BubbleLayout(spacing: 14) {
            ForEach(0 ..< 18, id: \.self) { i in
                ShimmerBlock(cornerRadius: 60)
                    .frame(width: i % 3 == 0 ? 116 : 100, height: i % 3 == 0 ? 116 : 100)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: 1040)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading artists")
    }

    private func add(_ artist: CatalogArtist) {
        if !flow.isLiked(artist) { flow.toggle(artist: artist) }
        query = ""
        results = []
    }
}

private struct ArtistBubble: View {
    let artist: CatalogArtist
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size: CGFloat = selected ? 128 : 104
        Button(action: action) {
            VStack(spacing: 8) {
                ArtworkView(source: .url(artist.pictureSmallURL ?? artist.pictureURL), size: size, circular: true)
                    .overlay {
                        Circle().strokeBorder(selected ? Color.pink : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selected { SelectionCheck(size: 28).offset(x: -4, y: -4) }
                    }
                    .scaleEffect(hovering && !selected ? 1.05 : 1)
                Text(artist.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                    .lineLimit(1)
                    .frame(width: 128)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .accessibilityLabel(artist.name)
        .accessibilityChoice(selected: selected)
    }
}

/// Small overlapping portraits of what's been picked, shown beside Continue.
private struct LikedStrip: View {
    let artists: [CatalogArtist]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(artists.suffix(6)) { artist in
                ArtworkView(source: .url(artist.pictureSmallURL), size: 30, circular: true, shadow: false)
                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 2))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.4), value: artists.map(\.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(artists.isEmpty ? "" : "Picked: " + artists.map(\.name).joined(separator: ", "))
        .accessibilityHidden(artists.isEmpty)
    }
}

/// Packs bubbles into centered rows with a gentle stagger, like a loose cloud.
struct BubbleLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let rows = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for (offset, index) in row.items.enumerated() {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Alternate items sit a little lower so the cloud doesn't read as a grid.
                let stagger: CGFloat = offset.isMultiple(of: 2) ? 0 : 18
                let y = bounds.minY + row.y + (row.height - 18 - size.height) / 2 + stagger
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var y: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                current.y = y
                y += current.height + spacing
                rows.append(current)
                current = Row()
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height + 18)
            current.items.append(index)
        }
        if !current.items.isEmpty {
            current.y = y
            rows.append(current)
        }
        return rows
    }
}

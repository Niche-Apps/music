import StandardKit
import SwiftUI

struct GenreStep: View {
    @Bindable var flow: OnboardingFlow

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 30) {
                    StepHeading(title: "What do you love to listen to?", subtitle: "Pick as many genres as you like.")
                        .padding(.top, 26)
                    if !flow.genresLoaded {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(0 ..< 12, id: \.self) { _ in
                                ShimmerBlock(cornerRadius: 18).aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading genres")
                    } else if flow.genres.isEmpty {
                        ContentUnavailableView(
                            "The music catalog isn’t available", systemImage: "music.note.list",
                            description: Text("Standard Music couldn’t open its catalog of real artists. Try reinstalling the app."))
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(flow.genres) { genre in
                                GenrePhotoTile(genre: genre, selected: flow.selectedGenres.contains(genre.name)) {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.4)) { flow.toggle(genre: genre.name) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 30)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)

            StepFooter(
                hint: flow.selectedGenres.isEmpty
                    ? "Choose at least one" : "\(flow.selectedGenres.count) selected",
                action: "Continue", enabled: !flow.selectedGenres.isEmpty
            ) {
                flow.refreshCloudIfNeeded()
                flow.advance()
            }
        }
    }
}

private struct GenrePhotoTile: View {
    let genre: CatalogGenre
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                collage
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                Text(genre.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(14)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.pink : .white.opacity(0.08), lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selected { SelectionCheck().padding(10) }
            }
            .scaleEffect(selected ? 0.96 : hovering ? 1.02 : 1)
            .shadow(color: .black.opacity(0.35), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
            .animation(.snappy(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(genre.name)
        .accessibilityChoice(selected: selected)
    }

    private var collage: some View {
        let pictures = genre.featured.compactMap { $0.pictureSmallURL ?? $0.pictureURL }
        return GeometryReader { geo in
            let half = geo.size.width / 2
            if pictures.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        cell(pictures[0], half)
                        cell(pictures[1], half)
                    }
                    HStack(spacing: 0) {
                        cell(pictures[2], half)
                        cell(pictures[3], half)
                    }
                }
            } else if let first = pictures.first {
                cell(first, geo.size.width)
            } else {
                LinearGradient(colors: ArtworkView.seeded(genre.name), startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private func cell(_ url: URL, _ size: CGFloat) -> some View {
        ArtworkView(source: .url(url), size: size, cornerRadius: 0, shadow: false)
    }
}

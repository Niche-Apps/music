import StandardKit
import SwiftUI

/// Slowly drifting dark mesh gradient behind the welcome, onboarding and building screens.
struct AmbientBackground: View {
    var tint: Color = .pink
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion: hold a single frame of the mesh instead of drifting.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 9
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.5 + 0.18 * sin(t)), Float(0.5 + 0.14 * cos(t * 1.3))], [1, 0.5],
                    [0, 1], [Float(0.5 + 0.2 * cos(t * 0.7)), 1], [1, 1],
                ],
                colors: [
                    Color(hue: 0.72, saturation: 0.55, brightness: 0.16), tint.opacity(0.55 * intensity),
                    Color(hue: 0.62, saturation: 0.6, brightness: 0.14),
                    Color(hue: 0.95, saturation: 0.7, brightness: 0.30 * intensity),
                    Color(hue: 0.78, saturation: 0.6, brightness: 0.22),
                    Color(hue: 0.06, saturation: 0.7, brightness: 0.28 * intensity),
                    Color(hue: 0.66, saturation: 0.5, brightness: 0.08), Color(hue: 0.85, saturation: 0.6, brightness: 0.18),
                    Color(hue: 0.60, saturation: 0.5, brightness: 0.07),
                ],
                smoothsColors: true
            )
        }
        .ignoresSafeArea()
        .background(.black)
        .accessibilityHidden(true)
    }
}

/// White capsule call-to-action used across onboarding.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 28)
            .frame(minWidth: 200, minHeight: 44)
            .background(Capsule().fill(.white.opacity(isEnabled ? 1 : 0.35)))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == OnboardingPrimaryButtonStyle {
    static var onboardingPrimary: OnboardingPrimaryButtonStyle { .init() }
}

/// Selection check badge in the brand color.
struct SelectionCheck: View {
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.pink.gradient))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .transition(.scale(scale: 0.3).combined(with: .opacity))
            // Selection is announced through the .isSelected trait on the choice itself.
            .accessibilityHidden(true)
    }
}

/// Shimmering placeholder block.
struct ShimmerBlock: View {
    var cornerRadius: CGFloat = 12
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(0.07))
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.3)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .onAppear {
                // Reduce Motion: a static placeholder, no sweeping highlight.
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityElement()
            .accessibilityLabel("Loading")
    }
}

extension View {
    /// Dark, title-bar-less presentation for the immersive first-run screens.
    func immersiveChrome() -> some View {
        environment(\.colorScheme, .dark)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
    }
}

extension Catalog {
    /// Album covers for a drifting backdrop: the best-known record of popular artists across genres.
    func backdropCovers(count: Int) -> [URL] {
        let genres = ((try? self.genres()) ?? []).prefix(10).map(\.name)
        let artists = (try? topArtists(genres: genres, perGenre: max(2, count / max(genres.count, 1) + 1))) ?? []
        var urls: [URL] = []
        for artist in artists where urls.count < count {
            if let cover = (try? albums(artistID: artist.id, limit: 1))?.first?.coverSmallURL { urls.append(cover) }
        }
        return urls
    }
}

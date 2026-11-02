import AppKit
import StandardKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var covers: [URL] = []
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AmbientBackground()
            CoverDrift(covers: covers)
                .saturation(0.85)
                .blur(radius: 1.5)
                .opacity(covers.isEmpty ? 0 : 0.3)
                .animation(.easeIn(duration: 2), value: covers.isEmpty)
            RadialGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.5), .black.opacity(0.1)], center: .center, startRadius: 60,
                endRadius: 600
            )
            .ignoresSafeArea()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
            // Reduce Transparency / Increase Contrast: a solid backdrop behind the text.
            LegibilityScrim(opacity: 0.8)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                hero
                Spacer()
                finePrint
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 40)
        }
        .immersiveChrome()
        .debugSnapshots("welcome")
        .task {
            guard covers.isEmpty, let catalog = model.services.catalog else { return }
            covers = await Task.detached(priority: .utility) { catalog.backdropCovers(count: 48) }.value
        }
        .onAppear { withAnimation(reduceMotion ? .easeIn(duration: 0.4) : .smooth(duration: 1.2).delay(0.15)) { appeared = true } }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .accessibilityHidden(true)

            Text("Standard Music")
                .font(.system(size: 64, weight: .bold))
                .tracking(-1.5)
                .foregroundStyle(.white)
                .accessibilityHeading()
            Text("Music that’s never existed — made for you.")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            actions
                .padding(.top, 30)
        }
        .multilineTextAlignment(.center)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 18)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            if model.isSigningIn {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityElement(children: .combine)
                    .onAppear { AccessibilityNotification.Announcement("Finish signing in in your browser").post() }
                    Button("Cancel") { Task { await model.cancelSignIn() } }
                        .accessibilityLabel("Cancel sign in")
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                        .keyboardShortcut(.cancelAction)
                }
                .transition(.blurReplace)
            } else {
                VStack(spacing: 12) {
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        Label("Sign in with ChatGPT", systemImage: "sparkles")
                    }
                    .buttonStyle(.onboardingPrimary)
                    .keyboardShortcut(.defaultAction)

                    if model.canImportCodexLogin {
                        Button {
                            Task { await model.importCodexLogin() }
                        } label: {
                            Label("Use my Codex sign-in", systemImage: "terminal")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .transition(.blurReplace)
            }

            if let error = model.signInError, !model.isSigningIn {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.red.opacity(0.22)))
                    .frame(maxWidth: 460)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .onAppear { AccessibilityNotification.Announcement(error).post() }
            }
        }
        .animation(.smooth(duration: 0.35), value: model.isSigningIn)
        .animation(.smooth(duration: 0.35), value: model.signInError)
    }

    private var finePrint: some View {
        HStack(spacing: 18) {
            Label("Writing and artwork use your ChatGPT plan", systemImage: "text.quote")
            Label("Music is recorded privately on this Mac", systemImage: "lock.fill")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .opacity(appeared ? 1 : 0)
    }
}

/// Tilted columns of album covers scrolling slowly in alternating directions.
struct CoverDrift: View {
    let covers: [URL]
    var columns = 9
    var tile: CGFloat = 150
    var spacing: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let perColumn = max(1, covers.count / columns)
            // Reduce Motion: the wall of covers holds still.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0 ..< columns, id: \.self) { c in
                        let slice = Array(covers.dropFirst(c * perColumn).prefix(perColumn))
                        let loop = CGFloat(slice.count) * (tile + spacing)
                        let speed = 9 + Double(c % 3) * 3
                        let raw = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(max(loop, 1))))
                        let offset = c.isMultiple(of: 2) ? -raw : raw - loop
                        VStack(spacing: spacing) {
                            ForEach(0 ..< 3, id: \.self) { rep in
                                ForEach(Array(slice.enumerated()), id: \.offset) { _, url in
                                    ArtworkView(source: .url(url), size: tile, cornerRadius: 10, shadow: false)
                                        .id("\(rep)-\(url)")
                                }
                            }
                        }
                        .offset(y: offset)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .rotationEffect(.degrees(-14))
            .scaleEffect(1.45)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

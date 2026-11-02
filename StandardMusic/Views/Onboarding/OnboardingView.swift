import StandardKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var flow: OnboardingFlow?

    var body: some View {
        ZStack {
            AmbientBackground(intensity: 0.75)
            if let flow {
                OnboardingSteps(flow: flow)
            }
        }
        .immersiveChrome()
        .debugSnapshots("onboarding")
        .onAppear {
            if flow == nil { flow = OnboardingFlow(model: model) }
        }
    }
}

private struct OnboardingSteps: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                content
                    .id(flow.step)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .offset(x: flow.forward ? 70 : -70).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.98)))
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: flow.step) {
            // VoiceOver: the whole screen swapped; let it re-read from the new heading.
            AccessibilityNotification.LayoutChanged().post()
        }
        .task {
            await flow.loadGenres()
            #if DEBUG
            await flow.autopilot()
            #endif
        }
    }

    private var header: some View {
        ZStack {
            if flow.step != .tuning && flow.step != .reveal {
                StepProgress(fraction: flow.progress)
                    .frame(width: 220)
                    .transition(.opacity)
            }
            HStack {
                if flow.canGoBack {
                    Button {
                        flow.back()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityHint("Goes to the previous step")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
            }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 28)
        .padding(.top, 46)
        .animation(.smooth, value: flow.canGoBack)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .genres: GenreStep(flow: flow)
        case .artists: ArtistStep(flow: flow)
        case .question(let i): QuestionStep(flow: flow, index: i)
        case .notes: NotesStep(flow: flow)
        case .tuning: TuningStep(flow: flow)
        case .reveal: RevealStep(flow: flow)
        }
    }
}

private struct StepProgress: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                    .animation(.smooth(duration: 0.6), value: fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// Title + subtitle shared by every step.
struct StepHeading: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .accessibilityHeading()
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.62))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: 640)
    }
}

/// Bottom bar with a hint on the left and the primary action.
struct StepFooter<Accessory: View>: View {
    var hint: String
    var action: String
    var enabled: Bool
    /// Off while a text field owns the Return key.
    var returnKey = true
    var perform: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            Text(hint)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.numericText())
                .animation(.smooth, value: hint)
            Spacer()
            accessory
            Button(action: perform) {
                Text(action)
            }
            .buttonStyle(.onboardingPrimary)
            .disabled(!enabled)
            .keyboardShortcut(returnKey ? .defaultAction : nil)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            LegibilityScrim(opacity: 0.85)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

extension StepFooter where Accessory == EmptyView {
    init(hint: String, action: String, enabled: Bool, returnKey: Bool = true, perform: @escaping () -> Void) {
        self.init(hint: hint, action: action, enabled: enabled, returnKey: returnKey, perform: perform) { EmptyView() }
    }
}

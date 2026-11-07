import StandardKit
import SwiftUI

// MARK: - Anything else?

struct NotesStep: View {
    @Bindable var flow: OnboardingFlow
    @FocusState private var focused: Bool
    @AppStorage(Pref.allowExplicit) private var allowExplicit = false

    private let suggestions = [
        "More female vocals", "Nothing too heavy", "Lots of instrumentals", "Love a big chorus",
        "No country, please", "Songs in other languages", "Lo-fi and warm", "Weird is good",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(spacing: 28) {
                StepHeading(
                    title: "Anything else we should know?",
                    subtitle: "Moods, eras, pet hates — in your own words. Totally optional.")
                TextField("e.g. Rainy-day records, smoky voices, nothing with autotune", text: $flow.notes, axis: .vertical)
                    .accessibilityLabel("Anything else we should know?")
                    .accessibilityHint("Optional. For example: rainy-day records, smoky voices, nothing with autotune")
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(3 ... 6)
                    .focused($focused)
                    .padding(18)
                    .frame(width: 580)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 18))
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                SuggestionChips(items: suggestions, isOn: contains) { add($0) }
                    .frame(width: 620)
                ExplicitChoice(allowExplicit: $allowExplicit)
                    .padding(.top, 6)
            }
            Spacer(minLength: 16)
            StepFooter(
                hint: flow.notes.isEmpty ? "You can skip this" : "",
                action: flow.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Skip" : "Continue",
                enabled: true, returnKey: !focused || flow.notes.isEmpty
            ) {
                flow.advance()
            }
        }
        .onAppear { focused = true }
    }

    private func contains(_ chip: String) -> Bool { flow.notes.localizedCaseInsensitiveContains(chip) }

    private func add(_ chip: String) {
        if contains(chip) {
            flow.notes = flow.notes.replacingOccurrences(of: chip, with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".  ", with: ". ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
            if !flow.notes.isEmpty { flow.notes += "." }
            return
        }
        let trimmed = flow.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        flow.notes = trimmed.isEmpty ? "\(chip)." : "\(trimmed)\(trimmed.hasSuffix(".") ? "" : ".") \(chip)."
    }
}

/// "Explicit lyrics?" — clean only, or the occasional explicit song (marked E).
private struct ExplicitChoice: View {
    @Binding var allowExplicit: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("Explicit lyrics?")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                option("Keep it clean", systemImage: "checkmark.shield", selected: !allowExplicit) { allowExplicit = false }
                option("Explicit is fine", systemImage: "e.square", selected: allowExplicit) { allowExplicit = true }
            }
            Text(allowExplicit
                ? "Now and then a song will have strong language, more in genres like hip hop. Marked with an E."
                : "Every song will be radio-clean. You can change this in Settings.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .contain)
    }

    private func option(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? .white : .white.opacity(0.8))
                .background(Capsule().fill(selected ? AnyShapeStyle(Color.pink.gradient) : AnyShapeStyle(.white.opacity(0.1))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityChoice(selected: selected)
    }
}

private struct SuggestionChips: View {
    let items: [String]
    let isOn: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        CenteredFlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let on = isOn(item)
                Button {
                    withAnimation(.snappy) { toggle(item) }
                } label: {
                    Label(item, systemImage: on ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(on ? .white : .white.opacity(0.8))
                        .background(Capsule().fill(on ? AnyShapeStyle(Color.pink.gradient) : AnyShapeStyle(.white.opacity(0.1))))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item)
                .accessibilityChoice(selected: on)
            }
        }
    }
}

/// Centered wrapping rows.
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 600, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = ([], 0, 0)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Tuning in

struct TuningStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsVisible) private var windowIsVisible
    @Bindable var flow: OnboardingFlow
    @State private var line = 0
    @State private var start = Date()

    private var lines: [String] {
        let names = flow.liked.prefix(3).map(\.name)
        return [
            "Tuning in…",
            names.isEmpty ? "Listening to your picks…" : "Listening back to \(ListFormatter.localizedString(byJoining: names))…",
            "Finding the threads between them…",
            "Naming your sound…",
        ]
    }

    var body: some View {
        VStack(spacing: 46) {
            ZStack {
                // Reduce Motion: rings and orbiting portraits hold still.
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !windowIsVisible)) { context in
                    let t = context.date.timeIntervalSince(start)
                    ZStack {
                        ForEach(0 ..< 4, id: \.self) { ring in
                            let phase = (t / 3.2 + Double(ring) / 4).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(Color.pink.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                                .frame(width: 140 + 300 * phase, height: 140 + 300 * phase)
                        }
                        let orbit = Array(flow.liked.prefix(8))
                        ForEach(Array(orbit.enumerated()), id: \.element.id) { i, artist in
                            let angle = t / 7 + Double(i) / Double(max(orbit.count, 1)) * 2 * .pi
                            ArtworkView(source: .url(artist.pictureSmallURL), size: 54, circular: true)
                                .offset(x: cos(angle) * 170, y: sin(angle) * 120)
                        }
                    }
                }
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
                    .frame(width: 120, height: 120)
                    .background(Circle().fill(LinearGradient(colors: [.pink, Color(hue: 0.98, saturation: 0.8, brightness: 0.6)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .pink.opacity(0.5), radius: 30)
            }
            .frame(height: 360)
            .accessibilityHidden(true)

            if let error = flow.finishError {
                VStack(spacing: 14) {
                    Text("We couldn’t finish setting up")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityHeading()
                        .onAppear { AccessibilityNotification.Announcement("We couldn’t finish setting up. \(error)").post() }
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button("Try Again") { Task { await flow.finish(using: model) } }
                        .buttonStyle(.onboardingPrimary)
                        .keyboardShortcut(.defaultAction)
                }
                .transition(.blurReplace)
            } else {
                Text(lines[line % lines.count])
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .id(line)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                    .accessibilityAddTraits([.isHeader, .updatesFrequently])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard flow.refined == nil else { return }
            await flow.finish(using: model)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.smooth(duration: 0.5)) { line = min(line + 1, lines.count - 1) }
            }
        }
    }
}

// MARK: - Reveal

struct RevealStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var flow: OnboardingFlow
    @State private var shown = 0

    private var profile: TasteProfile { flow.refined ?? flow.profile() }

    private var headline: String {
        profile.headline.isEmpty ? "Your sound, in a nutshell" : profile.headline
    }

    private var summary: String {
        if !profile.summary.isEmpty { return profile.summary }
        let genres = ListFormatter.localizedString(byJoining: profile.selectedGenres.prefix(4).map { $0 })
        return "We’ll start from \(genres) and the artists you love, then wander somewhere new."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 22) {
                Text("YOUR TASTE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(2.5)
                    .foregroundStyle(.pink)
                    .opacity(shown > 0 ? 1 : 0)
                    .accessibilityLabel("Your taste")
                Text(headline)
                    .font(.system(size: 44, weight: .bold))
                    .tracking(-1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
                    .opacity(shown > 0 ? 1 : 0)
                    .offset(y: shown > 0 || reduceMotion ? 0 : 16)
                    .blur(radius: shown > 0 || reduceMotion ? 0 : 8)
                    .accessibilityHeading()
                Text(summary)
                    .font(.system(size: 17))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
                    .opacity(shown > 1 ? 1 : 0)
                    .offset(y: shown > 1 || reduceMotion ? 0 : 12)
                genreChips
                    .frame(maxWidth: 680)
                    .padding(.top, 8)
                    .opacity(shown > 2 ? 1 : 0)
                    .offset(y: shown > 2 || reduceMotion ? 0 : 12)
                if !profile.descriptors.isEmpty {
                    Text(profile.descriptors.prefix(5).joined(separator: "  ·  "))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                        .opacity(shown > 2 ? 1 : 0)
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 20)
            VStack(spacing: 10) {
                Button("Build My Library") { model.beginBuilding() }
                    .buttonStyle(.onboardingPrimary)
                    .keyboardShortcut(.defaultAction)
                Text("We’ll write about 110 artists for you. It takes a while — you can start listening long before it’s done.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .opacity(shown > 3 ? 1 : 0)
            .padding(.bottom, 34)
        }
        .padding(.horizontal, 40)
        .task {
            for step in 1 ... 4 {
                try? await Task.sleep(for: .milliseconds(step == 1 ? 200 : 550))
                withAnimation(.smooth(duration: 0.8)) { shown = step }
            }
        }
    }

    private var genreChips: some View {
        let core = profile.coreGenres.isEmpty ? profile.selectedGenres : profile.coreGenres
        return CenteredFlowLayout(spacing: 8) {
            ForEach(core, id: \.self) { chip($0, style: .core) }
            ForEach(profile.adjacentGenres.prefix(4), id: \.self) { chip($0, style: .adjacent) }
            ForEach(profile.wildcardGenres.prefix(2), id: \.self) { chip($0, style: .wildcard) }
        }
    }

    private enum ChipStyle { case core, adjacent, wildcard }

    private func chip(_ text: String, style: ChipStyle) -> some View {
        HStack(spacing: 5) {
            if style == .wildcard { Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)) }
            Text(text.capitalized(with: .current))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.capitalized(with: .current))
        .accessibilityValue(style == .core ? "Core" : style == .adjacent ? "Adjacent" : "Wildcard")
        .font(.system(size: 13, weight: style == .core ? .semibold : .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            switch style {
            case .core: Capsule().fill(Color.pink.gradient)
            case .adjacent: Capsule().fill(.white.opacity(0.14))
            case .wildcard: Capsule().strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .help(style == .core ? "Core" : style == .adjacent ? "Adjacent" : "Wildcard")
    }
}

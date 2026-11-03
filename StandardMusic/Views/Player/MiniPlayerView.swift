import StandardKit
import SwiftUI

/// Square MiniPlayer: the artwork is the window. Hovering reveals the controls; Up Next and lyrics
/// unfold below it.
struct MiniPlayerView: View {
    enum Panel: String { case queue, lyrics }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Pref.miniPlayerFloats) private var floats = true
    @AppStorage("miniPlayerPanel") private var panelRaw = ""
    @State private var hovering = ProcessInfo.processInfo.environment["SM_DEV_HOVER"] != nil
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusState private var controlsFocused: Bool

    /// Controls appear on hover, and stay reachable for VoiceOver and keyboard users.
    private var showsControls: Bool { hovering || voiceOver || controlsFocused }

    static let side: CGFloat = 300

    private var panel: Panel? { Panel(rawValue: panelRaw) }

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(width: Self.side, height: Self.side)
            if let panel, model.player.current != nil {
                MiniPlayerPanel(panel: panel)
                    .frame(width: Self.side, height: 280)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background { MiniPlayerBackdrop() }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .background(MiniPlayerWindowConfigurator(floats: floats))
        .animation(.smooth(duration: 0.3), value: panelRaw)
        .contextMenu { contextMenu }
    }

    // MARK: Artwork stage

    private var stage: some View {
        let player = model.player
        return ZStack {
            if let info = player.current {
                ArtworkView(source: .album(info.album), cornerRadius: 0, highResolution: true, shadow: false,
                            accessibilityDescription: Spoken.albumCover(info.album.title, by: info.artist.name))
                    .frame(width: Self.side, height: Self.side)
                    .id(info.album.id)
                    .transition(.opacity)
                if player.isWaiting {
                    MiniPlayerRecordingOverlay(info: info)
                        .opacity(showsControls ? 0 : 1)
                } else if !showsControls {
                    progressHairline
                }
            } else {
                MiniPlayerEmptyState()
            }
            controls
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .focused($controlsFocused)
        }
        .animation(.easeOut(duration: 0.4), value: player.current?.album.id)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: h ? 0.18 : 0.35)) { hovering = h } }
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { switchToMain() }
    }

    private var progressHairline: some View {
        let player = model.player
        return VStack {
            Spacer()
            GeometryReader { geo in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: geo.size.width * (player.duration > 0 ? min(1, player.time / player.duration) : 0), height: 2)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .animation(.linear(duration: 0.25), value: player.time)
            }
            .frame(height: 2)
        }
        .opacity(player.current == nil || player.state == .idle ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controls: some View {
        let player = model.player
        VStack(spacing: 0) {
            HStack {
                MiniPlayerChromeButton(symbol: "xmark", help: "Close MiniPlayer") { close() }
                Spacer()
                MiniPlayerChromeButton(symbol: "arrow.up.backward.and.arrow.down.forward", help: "Switch to Standard Music (⌥⌘M)") {
                    switchToMain()
                }
            }
            Spacer()
            if let info = player.current {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.track.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .explicitBadge(info.track.isExplicit)
                            Text("\(info.artist.name) — \(info.album.title)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        FavoriteButton(isFavorite: info.track.isFavorite) { model.toggleFavorite(track: info.track.id) }
                            .font(.system(size: 14))
                    }
                    PlaybackScrubber(height: 4)
                    HStack {
                        panelToggle(.lyrics, symbol: "quote.bubble", help: "Lyrics")
                        Spacer()
                        TransportControls(size: 20, spacing: 26)
                            .foregroundStyle(.white)
                        Spacer()
                        panelToggle(.queue, symbol: "list.bullet", help: "Up Next")
                    }
                }
                // Reduce Transparency / Increase Contrast: a solid panel behind the text and controls.
                .background(LegibilityScrim(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), opacity: 0.75).padding(-6))
            }
        }
        .padding(12)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .black.opacity(0.0), location: 0.28),
                    .init(color: .black.opacity(0.15), location: 0.45),
                    .init(color: .black.opacity(0.85), location: 1),
                ], startPoint: .top, endPoint: .bottom
            )
            .opacity(player.current == nil ? 0 : 1)
        }
    }

    private func panelToggle(_ p: Panel, symbol: String, help: String) -> some View {
        let on = panel == p
        return Button {
            panelRaw = on ? "" : p.rawValue
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.black : .white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? .white.opacity(0.92) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "Hide \(help)" : "Show \(help)")
        .accessibilityLabel(help)
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let info = model.player.current {
            Button("Go to Album") { AppActions.goToCurrentSong(model, openWindow: openWindow) }
            Button(info.track.isFavorite ? "Remove from Favorites" : "Favorite") { model.toggleFavorite(track: info.track.id) }
            Divider()
        }
        Toggle("Keep MiniPlayer on Top", isOn: $floats)
        Divider()
        Button("Switch to Standard Music") { switchToMain() }
        Button("Close MiniPlayer") { close() }
    }

    private func switchToMain() {
        AppActions.switchToMainWindow(openWindow: openWindow, dismissWindow: dismissWindow)
    }

    private func close() {
        AppActions.closeMiniPlayer(openWindow: openWindow, dismissWindow: dismissWindow)
    }
}

/// Blurred artwork behind the panel, so the window reads as one object.
struct MiniPlayerBackdrop: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black
            if let album = model.player.current?.album {
                ArtworkView(source: .album(album), cornerRadius: 0, shadow: false)
                    .frame(width: 600, height: 600)
                    .blur(radius: 60)
                    .opacity(0.65)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                Color.black.opacity(0.3)
                LegibilityScrim(opacity: 0.55)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MiniPlayerChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 24, height: 24)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression))
    }
}

/// Over the artwork while the current song is still being recorded.
struct MiniPlayerRecordingOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let info: TrackInfo

    var body: some View {
        let active = model.recording.active
        let recordingThis = active?.trackID == info.track.id
        let position = model.recording.position(of: info.track.id)
        ZStack {
            Color.black.opacity(0.42)
            VStack(spacing: 12) {
                ZStack {
                    RecordingRing(fraction: recordingThis ? active?.fraction ?? 0 : 0, lineWidth: 4, tint: .white)
                        .frame(width: 72, height: 72)
                    if recordingThis, let fraction = active?.fraction, fraction > 0.005 {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 22, weight: .medium))
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    }
                }
                VStack(spacing: 3) {
                    Text(recordingThis ? active?.stageLabel ?? "Recording" : waitingLabel(position))
                        .font(.system(size: 13, weight: .semibold))
                    Group {
                        if recordingThis, let left = Format.remaining(active?.remaining) {
                            Text(left)
                        } else if recordingThis {
                            Text("Estimating time…")
                        } else {
                            Text("“\(info.track.title)” is next in the studio")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                }
                .padding(.horizontal, 24)
            }
            .foregroundStyle(.white)
            .animation(.smooth, value: active?.stageLabel)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording progress")
        .accessibilityValue(recordingThis && active != nil
            ? Spoken.recording(fraction: active!.fraction, stage: active!.stageLabel, remaining: active!.remaining)
            : waitingLabel(position))
    }

    private func waitingLabel(_ position: Int?) -> String {
        guard let position, position > 0 else { return "Waiting for the studio" }
        return position == 1 ? "Up next in the studio" : "\(position - 1) ahead in the studio"
    }
}

struct MiniPlayerEmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hue: 0.97, saturation: 0.55, brightness: 0.45), Color(hue: 0.72, saturation: 0.6, brightness: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("Nothing Playing")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Pick an album and the studio will\nrecord it for you as it plays.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Button("Browse Your Library") {
                    AppActions.switchToMainWindow(openWindow: openWindow, dismissWindow: dismissWindow)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
            .foregroundStyle(.white)
        }
    }
}

import StandardKit
import SwiftUI

/// The Music-style player that lives in the main window's toolbar.
/// Toolbar items are hosted outside the view tree and can lose inherited environment values when
/// AppKit rebuilds the toolbar, so every item gets the shared objects injected directly.
struct PlayerToolbar: ToolbarContent {
    let model: AppModel
    let library: LibraryState

    var body: some ToolbarContent {
        // The player draws its own panels (see `playerPanel`) instead of the system's capsules.
        ToolbarItem(placement: .navigation) {
            PlayerTransport().environment(model).environment(library)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            PlayerLCD().environment(model).environment(library)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            VolumeControl().environment(model).environment(library)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            InspectorToggles().environment(model).environment(library)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

struct PlayerTransport: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        HStack(spacing: 14) {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
            }
            .help(player.shuffle ? "Shuffle is on" : "Shuffle is off")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.shuffle ? "On" : "Off")
            .accessibilityAddTraits(player.shuffle ? .isSelected : [])
            TransportControls(size: 15, spacing: 14)
            Button { player.repeatMode = player.repeatMode.next } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .help(player.repeatMode.help)
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.spokenValue)
            .accessibilityAddTraits(player.repeatMode == .off ? [] : .isSelected)
        }
        .font(.system(size: 13, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .playerPanel()
    }
}

extension View {
    /// The toolbar player's glass panel: a softly rounded rectangle rather than a capsule.
    func playerPanel(height: CGFloat = 36) -> some View {
        frame(height: height)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

extension PlayerModel.RepeatMode {
    var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var help: String {
        switch self {
        case .off: "Repeat is off"
        case .all: "Repeating all"
        case .one: "Repeating one song"
        }
    }

    /// VoiceOver value for the repeat button.
    var spokenValue: String {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One song"
        }
    }
}

/// Centre "LCD": artwork, title, artist — album and progress. While the current song is in the
/// studio it shows the recording stage and an estimate instead of the scrubber.
struct PlayerLCD: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    @State private var hovering = false

    var body: some View {
        let player = model.player
        HStack(spacing: 0) {
            if let info = player.current {
                Button { withAnimation(.smooth(duration: 0.45)) { model.showsNowPlaying = true } } label: {
                    ArtworkView(source: .album(info.album), size: 38, cornerRadius: 5, shadow: false)
                        .overlay {
                            if hovering {
                                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Now Playing (⇧⌘F)")
                .accessibilityLabel("Show Now Playing")
                .accessibilityValue(Spoken.albumCover(info.album.title, by: info.artist.name))
                VStack(spacing: 1) {
                    Text(info.track.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityLabel("Now playing, \(info.track.title)")
                        .explicitBadge(info.track.isExplicit, size: 10)
                    HStack(spacing: 0) {
                        Button(info.artist.name) { model.show(.artist(info.artist.id)) }
                            .accessibilityHint("Goes to the artist")
                        Text(" — ").accessibilityHidden(true)
                        Button(info.album.title) { model.show(.album(info.album.id)) }
                            .accessibilityHint("Goes to the album")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    progress(info)
                        .padding(.top, 2)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(width: 460)
        .playerPanel(height: 48)
        .onHover { hovering = $0 }
        .contextMenu {
            if let info = player.current {
                Button("Now Playing", systemImage: "arrow.up.left.and.arrow.down.right") { model.showsNowPlaying = true }
                Button("Reveal in Album", systemImage: "square.stack") { model.revealCurrent(library) }
                Divider()
                TrackMenuItems(info: info)
            }
        }
    }

    @ViewBuilder private func progress(_ info: TrackInfo) -> some View {
        let player = model.player
        if player.isWaiting {
            let active = model.recording.active
            let recordingThis = active?.trackID == info.track.id
            HStack(spacing: 6) {
                ProgressView(value: recordingThis ? active?.fraction ?? 0 : 0)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(.accentColor)
                Text(recordingThis ? [active?.stageLabel, Format.remaining(active?.remaining)].compactMap { $0 }.joined(separator: " · ") : studioLine)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .help("This song is being recorded. It will start playing as soon as it’s done.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording progress")
            .accessibilityValue(recordingThis && active != nil
                ? Spoken.recording(fraction: active!.fraction, stage: active!.stageLabel, remaining: active!.remaining)
                : studioLine)
        } else {
            HStack(spacing: 6) {
                if hovering {
                    Text(Format.duration(player.time)).transition(.opacity).accessibilityHidden(true)
                }
                PlaybackScrubber(showsTimes: false, height: 3)
                    .frame(height: 6)
                if hovering {
                    Text("-" + Format.duration(max(0, player.duration - player.time))).transition(.opacity).accessibilityHidden(true)
                }
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    private var studioLine: String {
        if let active = model.recording.active { return "Waiting for “\(active.title)” to finish" }
        return "Waiting for the studio"
    }
}

struct VolumeControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        HStack(spacing: 6) {
            Button { player.volume = player.volume > 0 ? 0 : 0.6 } label: {
                Image(systemName: "speaker.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help(player.volume > 0 ? "Mute" : "Unmute")
            .accessibilityLabel(player.volume > 0 ? "Mute" : "Unmute")
            Slider(value: $player.volume, in: 0 ... 1)
                .controlSize(.mini)
                .frame(width: 84)
                .accessibilityLabel("Volume")
                .accessibilityValue(Spoken.percent(Double(player.volume)))
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .playerPanel()
    }
}

struct InspectorToggles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) { buttons }
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .playerPanel()
    }

    @ViewBuilder private var buttons: some View {
        Button {
            withAnimation { model.showsLyrics.toggle(); if model.showsLyrics { model.showsQueue = false } }
        } label: {
            Image(systemName: "quote.bubble")
                .foregroundStyle(model.showsLyrics ? Color.accentColor : .primary)
        }
        .help("Lyrics")
        .accessibilityLabel("Lyrics")
        .accessibilityValue(model.showsLyrics ? "Shown" : "Hidden")
        .accessibilityAddTraits(model.showsLyrics ? .isSelected : [])
        .keyboardShortcut("u", modifiers: [.command, .option])
        Button {
            withAnimation { model.showsQueue.toggle(); if model.showsQueue { model.showsLyrics = false } }
        } label: {
            Image(systemName: "list.bullet")
                .foregroundStyle(model.showsQueue ? Color.accentColor : .primary)
        }
        .help("Up Next")
        .accessibilityLabel("Up Next")
        .accessibilityValue(model.showsQueue ? "Shown" : "Hidden")
        .accessibilityAddTraits(model.showsQueue ? .isSelected : [])
        .keyboardShortcut("u", modifiers: [.command])
    }
}

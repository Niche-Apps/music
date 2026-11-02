import AppKit
import StandardKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String { case general, playback, studio, account, library }

    @AppStorage("settingsTab") private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            SwiftUI.Tab("Playback", systemImage: "play.circle", value: .playback) { PlaybackSettings() }
            SwiftUI.Tab("Studio", systemImage: "waveform", value: .studio) { StudioSettings() }
            SwiftUI.Tab("Account", systemImage: "person.crop.circle", value: .account) { AccountSettings() }
            SwiftUI.Tab("Library", systemImage: "music.note.house", value: .library) { LibrarySettings() }
        }
        .frame(width: 560)
        .scenePadding(.top)
    }
}

/// Shared look for every pane.
struct SettingsPane<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(height: height)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Pref.menuBarEnabled) private var menuBarEnabled = true
    @AppStorage(Pref.showDockIcon) private var showDockIcon = true
    @AppStorage(Pref.notifyWhenReady) private var notifyWhenReady = true
    @AppStorage(Pref.miniPlayerFloats) private var miniPlayerFloats = true

    var body: some View {
        SettingsPane(height: 400) {
            Section {
                Toggle(isOn: $menuBarEnabled) {
                    Text("Show in menu bar")
                    Text("Now playing, the studio and quick actions, one click away.")
                }
                .disabled(!showDockIcon)
                Toggle(isOn: $showDockIcon) {
                    Text("Show in Dock")
                    Text(showDockIcon ? "Turn off to run Standard Music from the menu bar only." : "Standard Music lives in the menu bar. Its windows are still a click away.")
                }
                .onChange(of: showDockIcon) { _, show in
                    if !show { menuBarEnabled = true }
                    AppActions.applyDockIconPolicy()
                }
            }
            Section {
                Toggle(isOn: $miniPlayerFloats) {
                    Text("Keep MiniPlayer above other windows")
                }
            }
            Section {
                Toggle(isOn: $notifyWhenReady) {
                    Text("Notify me when songs finish recording")
                    Text("Only while Standard Music is in the background.")
                }
                Button("Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Playback

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.normalizeVolume) private var normalizeVolume = true

    var body: some View {
        @Bindable var player = model.player
        SettingsPane(height: 330) {
            Section {
                Toggle(isOn: $player.autoplay) {
                    Text("Autoplay")
                    Text("When an album ends, keep going with something similar from your library.")
                }
                Toggle(isOn: $normalizeVolume) {
                    Text("Sound Check")
                    Text("Plays every song at the same perceived loudness, starting with the next song.")
                }
            }
            Section("Volume") {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $player.volume, in: 0 ... 1)
                        .accessibilityLabel("Volume")
                        .accessibilityValue(Spoken.percent(Double(player.volume)))
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(Double(player.volume), format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Text("⌘↑ and ⌘↓ change the volume from anywhere in the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

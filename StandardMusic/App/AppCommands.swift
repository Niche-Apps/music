import AppKit
import StandardKit
import SwiftUI
import UniformTypeIdentifiers

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var player: PlayerModel { model.player }
    private var inLibrary: Bool { model.phase == .library }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist") { AppActions.newPlaylist(model, openWindow: openWindow) }
                .keyboardShortcut("n")
                .disabled(!inLibrary)
            Button("Create New Music…") { AppActions.createMusic(model, openWindow: openWindow) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!inLibrary)
            Divider()
            Button("Import Shared Album…") { AppActions.importShare(model, openWindow: openWindow) }
                .keyboardShortcut("o")
                .disabled(!inLibrary)
        }

        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { AppActions.playPauseFromMenu(model) }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.currentEntry == nil || player.isWaiting)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(player.currentEntry == nil)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(player.currentEntry == nil)
            Button("Go to Current Song") { AppActions.goToCurrentSong(model, openWindow: openWindow) }
                .keyboardShortcut("l")
                .disabled(player.current == nil)
            Divider()
            Button("Increase Volume") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow)
                .disabled(player.volume >= 1)
            Button("Decrease Volume") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow)
                .disabled(player.volume <= 0)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.shuffle = $0 }))
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text("Off").tag(PlayerModel.RepeatMode.off)
                Text("All").tag(PlayerModel.RepeatMode.all)
                Text("One").tag(PlayerModel.RepeatMode.one)
            }
            Button("Cycle Repeat Mode") { player.repeatMode = player.repeatMode.next }
                .keyboardShortcut("r")
            Toggle("Autoplay", isOn: Binding(get: { player.autoplay }, set: { player.autoplay = $0 }))
            Divider()
            Button(player.current?.track.isFavorite == true ? "Remove from Favorites" : "Favorite Current Song") {
                if let id = player.current?.track.id { model.toggleFavorite(track: id) }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(player.current == nil)
            Divider()
            Button(model.showsNowPlaying ? "Hide Now Playing" : "Now Playing") {
                AppActions.showMainWindow(openWindow: openWindow)
                withAnimation(.smooth(duration: 0.45)) { model.showsNowPlaying.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(player.current == nil && !model.showsNowPlaying)
            Button("Switch to MiniPlayer") {
                AppActions.switchToMiniPlayer(openWindow: openWindow)
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }

        CommandGroup(before: .windowArrangement) {
            Button("MiniPlayer") { AppActions.toggleMiniPlayer(openWindow: openWindow, dismissWindow: dismissWindow) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Standard Music") { AppActions.showMainWindow(openWindow: openWindow) }
                .keyboardShortcut("0")
            Divider()
        }
    }
}

/// Window switching and app-level actions shared by menus, the MiniPlayer and the menu bar extra.
@MainActor
enum AppActions {
    static func window(_ id: String) -> NSWindow? {
        NSApp.windows.first { w in
            guard let raw = w.identifier?.rawValue else { return false }
            return raw == id || raw.hasPrefix(id + "-")
        }
    }

    static func isVisible(_ id: String) -> Bool { window(id)?.isVisible == true }

    static func showMainWindow(openWindow: OpenWindowAction) {
        openWindow(id: WindowID.main)
        NSApp.activate()
        window(WindowID.main)?.makeKeyAndOrderFront(nil)
    }

    /// Like Music: the MiniPlayer takes over from the main window.
    static func switchToMiniPlayer(openWindow: OpenWindowAction) {
        openWindow(id: WindowID.mini)
        window(WindowID.main)?.orderOut(nil)
        window(WindowID.mini)?.makeKeyAndOrderFront(nil)
    }

    /// And back again.
    static func switchToMainWindow(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        showMainWindow(openWindow: openWindow)
        dismissWindow(id: WindowID.mini)
    }

    /// Closing the MiniPlayer never strands the listener: a main window it replaced comes back.
    static func closeMiniPlayer(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        if let main = window(WindowID.main), !main.isVisible {
            main.makeKeyAndOrderFront(nil)
        }
        dismissWindow(id: WindowID.mini)
    }

    static func toggleMiniPlayer(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        if isVisible(WindowID.mini) {
            closeMiniPlayer(openWindow: openWindow, dismissWindow: dismissWindow)
        } else {
            openWindow(id: WindowID.mini)
            NSApp.activate()
        }
    }

    /// Space types a space in text fields; everywhere else it plays and pauses.
    static func playPauseFromMenu(_ model: AppModel) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.insertText(" ", replacementRange: editor.selectedRange())
            return
        }
        model.player.togglePlayPause()
    }

    static func goToCurrentSong(_ model: AppModel, openWindow: OpenWindowAction) {
        guard let current = model.player.current else { return }
        showMainWindow(openWindow: openWindow)
        if model.path.last != .album(current.album.id) { model.showAlbum(current.album.id) }
        model.revealRequest = current.track.id
    }

    static func createMusic(_ model: AppModel, openWindow: OpenWindowAction) {
        showMainWindow(openWindow: openWindow)
        model.path = []
        model.selection = .create
    }

    static func importShare(_ model: AppModel, openWindow: OpenWindowAction) {
        showMainWindow(openWindow: openWindow)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.standardAlbum]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an album a friend shared with you."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openShareFile(url)
    }

    static func newPlaylist(_ model: AppModel, openWindow: OpenWindowAction) {
        guard let playlist = model.newPlaylist() else {
            model.flash("Couldn't create a playlist.")
            return
        }
        showMainWindow(openWindow: openWindow)
        model.path = []
        model.selection = .playlist(playlist.id)
    }

    /// The Dock icon follows `Pref.showDockIcon`; without it the menu bar extra is the way in.
    static func applyDockIconPolicy() {
        let show = UserDefaults.standard.bool(forKey: Pref.showDockIcon)
        if !show { UserDefaults.standard.set(true, forKey: Pref.menuBarEnabled) }
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching to accessory deactivates the app; keep whatever the listener was looking at in front.
        DispatchQueue.main.async { NSApp.activate() }
    }

    static func quit() { NSApp.terminate(nil) }
}

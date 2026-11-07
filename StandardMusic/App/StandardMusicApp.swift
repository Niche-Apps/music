import StandardKit
import SwiftUI

@main
struct StandardMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(Pref.menuBarEnabled) private var menuBarEnabled = true

    var body: some Scene {
        Window("Standard Music", id: WindowID.main) {
            RootView()
                .tracksWindowVisibility()
                .environment(model)
                .task {
                    AppDelegate.connect { [model] url in model.openShareFile(url) }
                    await model.start()
                }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        // Always open at launch: system restoration would bring back a main window hidden by
        // "Switch to MiniPlayer" (which isn't restored), leaving no window at all. Where the
        // listener was is restored by AppModel's own session instead.
        .restorationBehavior(.disabled)
        .commands { AppCommands(model: model) }

        Window("MiniPlayer", id: WindowID.mini) {
            MiniPlayerView()
                .tracksWindowVisibility()
                .environment(model)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .restorationBehavior(.disabled)

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let mini = "mini"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Pref.register()
        // AppKit state restoration can bring back a main window hidden by "Switch to MiniPlayer"
        // (which isn't restored), leaving no window at all. AppModel restores the session itself.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        MainActor.assumeIsolated {
            AppActions.applyDockIconPolicy()
            _ = AppUpdater.shared  // starts Sparkle's scheduled update checks
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never launch to nothing: if the main window exists but came back hidden, show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard !AppActions.isVisible(WindowID.mini), let main = AppActions.window(WindowID.main), !main.isVisible
                else { return }
                main.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Set by AppModel's owner; receives .standardalbum files opened from Finder, Mail or AirDrop.
    @MainActor static var openShareFile: ((URL) -> Void)?
    @MainActor private static var pendingOpens: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension == ShareManifest.fileExtension {
                if let open = Self.openShareFile { open(url) } else { Self.pendingOpens.append(url) }
            }
            AppActions.window(WindowID.main)?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor static func connect(_ handler: @escaping (URL) -> Void) {
        openShareFile = handler
        pendingOpens.forEach(handler)
        pendingOpens = []
    }

    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool { false }
    func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Pref.menuBarEnabled)
    }

    /// Clicking the Dock icon brings back a main window hidden by "Switch to MiniPlayer".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard let main = AppActions.window(WindowID.main), !main.isVisible else { return true }
            main.makeKeyAndOrderFront(nil)
            return false
        }
    }
}

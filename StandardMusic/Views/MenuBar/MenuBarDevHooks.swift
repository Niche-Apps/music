import AppKit
import GRDB
import StandardKit
import SwiftUI

#if DEBUG

/// Development-only launch hooks for screenshots (UI scripting isn't always available):
///   SM_DEV_PLAY=1        play the album with recorded songs (=pending: from its first unrecorded song)
///   SM_DEV_MINI=1        switch to the MiniPlayer
///   SM_DEV_MENU=1        open the menu bar extra
///   SM_DEV_SETTINGS=tab  open Settings on a tab (general, playback, studio, account, library)
///   SM_DEV_SNAP=dir      a few seconds later, render every visible window to PNGs in dir
struct MenuBarDevHooks: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @MainActor private static var ran = false

    func body(content: Content) -> some View {
        content.task {
            guard !Self.ran else { return }
            Self.ran = true
            let env = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(2))
            if env["SM_DEV_PLAY"] != nil {
                let ids = (try? await model.services.db.reader.read { db in
                    try String.fetchAll(db, sql: "SELECT id FROM track WHERE status = 'ready' ORDER BY albumID, trackNumber")
                }) ?? []
                if let first = ids.first, let info = try? model.services.db.trackInfo(first) {
                    let start = env["SM_DEV_PLAY"] == "pending"
                        ? (try? model.services.db.tracks(forAlbum: info.album.id))?.first { !$0.isPlayable }?.id : nil
                    model.player.play(albumID: info.album.id, startingAt: start)
                }
            }
            if env["SM_DEV_MINI"] != nil { AppActions.switchToMiniPlayer(openWindow: openWindow) }
            if let tab = env["SM_DEV_SETTINGS"] {
                UserDefaults.standard.set(tab, forKey: "settingsTab")
                NSApp.activate()
                openSettings()
            }
            if env["SM_DEV_MENU"] != nil {
                try? await Task.sleep(for: .seconds(1))
                let button = NSApp.windows.lazy.compactMap { w in
                    w.className.contains("StatusBar") ? Self.statusButton(in: w.contentView) : nil
                }.first
                button?.performClick(nil)
            }
            if let dir = env["SM_DEV_SNAP"] {
                try? await Task.sleep(for: .seconds(3))
                Self.snapshotWindows(to: URL(fileURLWithPath: dir))
            }
        }
    }

    /// Renders each visible window of ours to `<dir>/<title>.png` (no screen-recording permission needed).
    private static func snapshotWindows(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = (window.identifier?.rawValue ?? window.className).replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(i)-\(name).png"))
        }
    }

    private static func statusButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton { return b }
        for sub in view.subviews { if let b = statusButton(in: sub) { return b } }
        return nil
    }
}
#endif

extension View {
    func menuBarDevHooks() -> some View {
        #if DEBUG
        modifier(MenuBarDevHooks())
        #else
        self
        #endif
    }
}

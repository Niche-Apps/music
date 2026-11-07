import AppKit

/// A downloaded app opened straight from Downloads (or a disk image) runs from a read-only copy macOS
/// makes ("App Translocation"), where updates can't install. Ask once per launch to move it.
@MainActor
enum AppLocation {
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static func offerMoveIfNeeded() {
        guard isTranslocated else { return }
        let alert = NSAlert()
        alert.messageText = "Move Standard Music to Applications"
        alert.informativeText = """
            macOS is running Standard Music from a temporary copy, so it can't update itself. \
            Quit, drag Standard Music into your Applications folder, and open it from there. Your library stays put.
            """
        alert.addButton(withTitle: "Quit and Show Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        NSApp.terminate(nil)
    }
}

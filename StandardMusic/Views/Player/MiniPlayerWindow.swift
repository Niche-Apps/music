import AppKit
import SwiftUI

/// Gives the MiniPlayer's borderless window its behavior: floats when asked, drags by its background,
/// joins full-screen spaces and remembers where the listener put it.
struct MiniPlayerWindowConfigurator: NSViewRepresentable {
    var floats: Bool

    func makeNSView(context: Context) -> MiniPlayerWindowView { MiniPlayerWindowView() }

    func updateNSView(_ view: MiniPlayerWindowView, context: Context) {
        view.floats = floats
        view.apply()
    }
}

final class MiniPlayerWindowView: NSView {
    nonisolated private static let positionKey = "miniPlayerTopLeft"
    var floats = true
    private weak var configured: NSWindow?
    private var moveObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
            configured = nil
        }
        apply()
    }

    func apply() {
        guard let window else { return }
        window.level = floats ? .floating : .normal
        guard configured !== window else { return }
        configured = window
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
        window.setAccessibilityTitle("MiniPlayer")
        // SwiftUI positions the window after it's attached; restore afterwards.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
                let point = NSPointFromString(saved)
                if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }) {
                    window.setFrameTopLeftPoint(point)
                }
            }
            if let old = self.moveObserver { NotificationCenter.default.removeObserver(old) }
            self.moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
                    UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.positionKey)
                }
            }
        }
    }
}

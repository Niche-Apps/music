import AppKit
import SwiftUI

extension EnvironmentValues {
    /// False while the hosting window is fully covered, minimized, on another Space or the display
    /// is asleep. Continuous animations pause on it: a view that keeps redrawing an invisible window
    /// for hours (overnight, display off) can leave the main thread waiting on the window server.
    @Entry var windowIsVisible = true
}

extension View {
    /// Publishes the hosting window's occlusion state as `windowIsVisible` to this view's subtree.
    func tracksWindowVisibility() -> some View { modifier(WindowVisibilityTracker()) }
}

private struct WindowVisibilityTracker: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowIsVisible, visible)
            .background(Probe { visible = $0 }.frame(width: 0, height: 0).accessibilityHidden(true))
    }

    private struct Probe: NSViewRepresentable {
        let onChange: (Bool) -> Void

        func makeNSView(context: Context) -> View { View() }
        func updateNSView(_ nsView: View, context: Context) { nsView.onChange = onChange }

        final class View: NSView {
            var onChange: ((Bool) -> Void)?
            // Dropped in viewDidMoveToWindow(nil) when the view leaves its window.
            private var observer: NSObjectProtocol?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                observer.map(NotificationCenter.default.removeObserver)
                observer = nil
                guard let window else { return }
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
                report()
            }

            private func report() {
                guard let window else { return }
                let visible = window.occlusionState.contains(.visible)
                DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
            }
        }
    }
}

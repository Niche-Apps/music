import Combine
import Foundation
import Observation
import Sparkle

/// Auto-update via Sparkle 2. The feed (`SUFeedURL`) and EdDSA public key (`SUPublicEDKey`) live in
/// Info.plist; tools/publish-release.sh signs each release and uploads `appcast.xml` next to the zip.
/// Sparkle stores the listener's choices (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`) in the
/// app's defaults; Info.plist only provides the defaults (check daily, ask before installing).
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var subscription: AnyCancellable?
    private var updater: SPUUpdater { controller.updater }

    /// False while a check is already running.
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { access(keyPath: \.automaticallyChecksForUpdates); return updater.automaticallyChecksForUpdates }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) { updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { access(keyPath: \.automaticallyDownloadsUpdates); return updater.automaticallyDownloadsUpdates }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) { updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = controller.updater.canCheckForUpdates
        subscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// "1.1 (3)"
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

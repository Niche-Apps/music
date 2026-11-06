import Combine
import Foundation
import Observation
import Sparkle

/// Auto-update via Sparkle 2. The feed (`SUFeedURL`) and EdDSA public key (`SUPublicEDKey`) live in
/// Info.plist; the release workflow signs each release and uploads `appcast.xml` next to the zip.
/// Sparkle stores the listener's choices (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`) in the
/// app's defaults; Info.plist only provides the defaults (check daily, ask before installing).
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate = UpdateDelegate()

    enum Pending: Equatable {
        /// Found, not downloaded (automatic downloads are off): clicking opens Sparkle's window.
        case available(String)
        /// Downloaded and verified in the background: clicking installs and relaunches at once.
        case ready(String)
        case installing
    }

    /// Drives the sidebar's Update Available button.
    private(set) var pending: Pending?
    @ObservationIgnored private var installNow: (() -> Void)?
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

    /// This is a local OpenRouter-enabled build: the upstream feed ships ChatGPT-only releases that would
    /// silently replace it, so Sparkle never starts, never checks and never installs.
    static let updatesDisabled = (Bundle.main.object(forInfoDictionaryKey: "SMDisableSparkle") as? Bool) ?? false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: !Self.updatesDisabled, updaterDelegate: delegate, userDriverDelegate: delegate)
        if Self.updatesDisabled {
            // Overwrite choices persisted by the upstream build (same bundle id).
            controller.updater.automaticallyChecksForUpdates = false
            controller.updater.automaticallyDownloadsUpdates = false
            canCheckForUpdates = false
            return
        }
        delegate.found = { [weak self] version in
            guard let self, self.installNow == nil else { return }
            self.pending = .available(version)
        }
        delegate.downloaded = { [weak self] version, install in
            self?.installNow = install
            self?.pending = .ready(version)
        }
        canCheckForUpdates = controller.updater.canCheckForUpdates
        subscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
    }

    func checkForUpdates() {
        guard !Self.updatesDisabled else { return }
        controller.checkForUpdates(nil)
    }

    /// The sidebar button: installs a downloaded update and relaunches, or shows Sparkle's window for one
    /// that isn't downloaded yet.
    func installUpdate() {
        guard !Self.updatesDisabled else { return }
        if let installNow {
            pending = .installing
            installNow()
        } else {
            checkForUpdates()
        }
    }

    /// "1.1 (3)"
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Sparkle's callbacks. Updates found by scheduled checks never pop a window: they download quietly
/// (the default) and surface as the sidebar button, which installs them in one click.
@MainActor
private final class UpdateDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var found: (String) -> Void = { _ in }
    var downloaded: (String, @escaping () -> Void) -> Void = { _, _ in }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { found(version) }
    }

    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated { downloaded(version, { install() }) }
        return true
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }
}

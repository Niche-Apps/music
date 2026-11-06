import AppKit
import Foundation
import GRDB
import Observation
import OSLog
import StandardKit
import SwiftUI
import UserNotifications

let appLog = Logger(subsystem: "com.standardmusic", category: "app")

enum SidebarItem: Hashable, Codable {
    case home, browse, create
    case recentlyAdded, artists, albums, songs, favorites
    case playlist(ID)
    case search
}

enum Route: Hashable, Codable {
    case album(ID)
    case artist(ID)
    case genre(String)
    case playlist(ID)
    /// A "See All" page for a Home shelf, keyed by shelf id.
    case shelf(String)
}

/// Root state: account, onboarding phase, library building, model install, player and navigation.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case welcome
        case onboarding
        case building
        case library
        case failed(String)
    }

    enum ModelState: Equatable {
        case unknown
        case installed(URL)
        case downloading(ModelDownloadProgress)
        case failed(String)
    }

    let services: Services
    let recording: RecordingQueue
    let player: PlayerModel

    var phase: Phase = .launching {
        didSet { if phase == .library { openQueuedShares() } }
    }
    /// The album or artist being shared (MainView presents the share sheet).
    var shareRequest: ShareRequest?
    /// A received share waiting for the listener to confirm (MainView presents the import sheet).
    var pendingImport: PendingImport?
    /// Share files opened before the library was ready (e.g. double-clicked to launch the app).
    var queuedShareFiles: [URL] = []
    private(set) var credentials: ChatGPTCredentials?
    private(set) var buildStatus = BuildStatus.idle
    private(set) var modelState: ModelState = .unknown
    private(set) var usage = ChatGPTUsage()
    private(set) var taste = TasteProfile()
    /// The "while you wait" song for the first library build.
    private(set) var opener: OpenerState?
    /// Generation is possible: ChatGPT signed in, or OpenRouter selected with an API key.
    private(set) var isAIReady = false
    var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: Pref.aiProvider) ?? "") ?? .chatGPT
    }
    var signInError: String?
    var isSigningIn = false

    // Navigation
    var selection: SidebarItem? = .home { didSet { persistNavigation() } }
    var path: [Route] = [] { didSet { persistNavigation() } }
    var searchText = ""
    var showsLyrics = false { didSet { persistNavigation() } }
    var showsQueue = false { didSet { persistNavigation() } }
    var toast: String?
    /// Set to a track id to scroll the library to it (⌘L "Go to Current Song").
    var revealRequest: ID?
    /// Full-window Now Playing (MainView presents it).
    var showsNowPlaying = false { didSet { persistNavigation() } }

    /// Where the listener was in the main window, so a relaunch (or a crash) opens on the same page.
    struct NavigationSnapshot: Codable {
        var selection: SidebarItem?
        var path: [Route]
        var showsLyrics: Bool
        var showsQueue: Bool
        var showsNowPlaying: Bool
    }

    private var navigationRestored = false

    private func persistNavigation() {
        guard navigationRestored, phase == .library else { return }
        let snapshot = NavigationSnapshot(
            selection: selection == .search ? .home : selection, path: path, showsLyrics: showsLyrics,
            showsQueue: showsQueue, showsNowPlaying: showsNowPlaying)
        try? services.db.setValue(snapshot, forKey: "navigation")
    }

    /// Puts the window and the player back the way they were.
    private func restoreSession() {
        defer { navigationRestored = true }
        player.restoreSession()
        guard phase == .library, let saved = services.db.value(NavigationSnapshot.self, forKey: "navigation") else { return }
        selection = saved.selection ?? .home
        path = saved.path
        showsQueue = saved.showsQueue
        showsLyrics = saved.showsLyrics
        showsNowPlaying = saved.showsNowPlaying && player.current != nil
    }

    init() {
        Pref.register()
        do {
            services = try Services()
        } catch {
            fatalError("Couldn't open the library: \(error.localizedDescription)")
        }
        recording = RecordingQueue(services: services)
        player = PlayerModel(services: services, recording: recording)
        player.onNotice = { [weak self] message in self?.toast = message }
        recording.modelDirectory = { [weak self] in
            guard let self, case .installed(let url) = self.modelState else { return nil }
            return url
        }
    }

    // MARK: Library state

    /// Stored in the library itself (not UserDefaults) so it travels with the data it describes.
    var onboardingDone: Bool {
        get { services.db.value(Bool.self, forKey: "onboardingDone") ?? false }
        set { try? services.db.setValue(newValue, forKey: "onboardingDone") }
    }

    var libraryEntered: Bool {
        get { services.db.value(Bool.self, forKey: "libraryEntered") ?? false }
        set { try? services.db.setValue(newValue, forKey: "libraryEntered") }
    }

    // MARK: Launch

    func start() async {
        guard phase == .launching else { return }
        try? services.db.resetInterruptedGeneration()
        services.db.backupIfNeeded()
        taste = services.db.value(TasteProfile.self, forKey: TasteProfile.storageKey) ?? TasteProfile()
        credentials = await services.auth.credentials
        await configureClient()
        await services.builder.observe { status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let grew = status.artistsReady != self.buildStatus.artistsReady
                self.buildStatus = status
                if grew { self.recording.kick() }
                self.refreshOpener()
            }
        }
        await services.client.observeUsage { usage in
            Task { @MainActor [weak self] in self?.usage = usage }
        }
        await services.engine.setIdleTimeout(.seconds(60 * max(1, UserDefaults.standard.integer(forKey: Pref.engineIdleMinutes))))
        refreshModelState()
        refreshOpener()
        recording.kick()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !isAIReady {
            phase = .welcome
        } else if !onboardingDone {
            phase = .onboarding
            installModelIfNeeded()
        } else {
            installModelIfNeeded()
            try? await services.builder.resumeUnfinished()
            phase = libraryEntered ? .library : .building
        }
        switch ProcessInfo.processInfo.environment["SM_FORCE_PHASE"] {
        case "welcome": phase = .welcome
        case "onboarding": phase = .onboarding
        case "building": phase = .building
        case "library": phase = .library
        default: break
        }
        if onboardingDone { restoreSession() }
        if let recovered = services.db.recoveredFromBackup {
            toast = "Your library was repaired from a backup made \(recovered.formatted(.relative(presentation: .named)))."
        } else if services.db.resetAfterDamage {
            toast = "Your library file was damaged and no backup could be used. The damaged copy is saved in the Library folder."
        }
    }

    func configureClient() async {
        let d = UserDefaults.standard
        if provider == .openRouter {
            await services.client.configureOpenRouter(
                apiKey: OpenRouterKey.current ?? "",
                writing: d.string(forKey: Pref.openRouterWritingModel) ?? OpenRouterCatalog.defaultModel,
                fast: d.string(forKey: Pref.openRouterFastModel) ?? OpenRouterCatalog.defaultModel,
                imageModel: d.string(forKey: Pref.openRouterImageModel).flatMap { $0.isEmpty ? nil : $0 })
            let cached = OpenRouterCatalog.cached(at: Paths.openRouterCatalog)
            if !cached.isEmpty { await services.client.noteOpenRouterCatalog(cached) }
        } else {
            await services.client.useChatGPT()
            await services.client.setModels(
                writing: d.string(forKey: Pref.writingModel) ?? ChatGPTClient.defaultWritingModel,
                fast: d.string(forKey: Pref.fastModel) ?? ChatGPTClient.defaultFastModel)
        }
        isAIReady = await services.client.isReady
    }

    /// Switches to OpenRouter. A non-empty `apiKey` is saved to the Keychain; an empty one keeps the stored
    /// key or falls back to `OPENROUTER_API_KEY` from the environment.
    func useOpenRouter(apiKey: String, model: String?) async {
        signInError = nil
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !OpenRouterKey.save(apiKey) {
            signInError = "Couldn’t save the API key to the Keychain."
            return
        }
        if let model = model.flatMap(OpenRouterCatalog.normalizedModelID) {
            UserDefaults.standard.set(model, forKey: Pref.openRouterWritingModel)
            UserDefaults.standard.set(model, forKey: Pref.openRouterFastModel)
        }
        UserDefaults.standard.set(AIProvider.openRouter.rawValue, forKey: Pref.aiProvider)
        await configureClient()
        guard isAIReady else {
            signInError = "Enter your OpenRouter API key to continue."
            return
        }
        if phase == .welcome { afterSignIn() }
    }

    func useChatGPTProvider() async {
        UserDefaults.standard.set(AIProvider.chatGPT.rawValue, forKey: Pref.aiProvider)
        await configureClient()
        if !isAIReady { phase = .welcome }
    }

    func clearOpenRouterKey() async {
        OpenRouterKey.delete()
        await configureClient()
    }

    // MARK: Account

    func signIn() async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            credentials = try await services.auth.signIn { url in
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            NSApp.activate()
            UserDefaults.standard.set(AIProvider.chatGPT.rawValue, forKey: Pref.aiProvider)
            await configureClient()
            afterSignIn()
        } catch is CancellationError {
        } catch {
            signInError = error.localizedDescription
        }
    }

    func cancelSignIn() async {
        await services.auth.cancelSignIn()
        isSigningIn = false
    }

    var canImportCodexLogin: Bool { ChatGPTAuth.codexAuthFile != nil }

    func importCodexLogin() async {
        do {
            credentials = try await services.auth.importCodexLogin()
            UserDefaults.standard.set(AIProvider.chatGPT.rawValue, forKey: Pref.aiProvider)
            await configureClient()
            afterSignIn()
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func afterSignIn() {
        installModelIfNeeded()
        if onboardingDone {
            phase = libraryEntered ? .library : .building
            Task { try? await services.builder.resumeUnfinished() }
        } else {
            withAnimation(.smooth(duration: 0.6)) { phase = .onboarding }
        }
    }

    func signOut() async {
        await services.auth.signOut()
        credentials = nil
        await configureClient()
        if !isAIReady { phase = .welcome }
    }

    // MARK: Model

    var preferredVariant: ModelVariant {
        ModelVariant(rawValue: UserDefaults.standard.string(forKey: Pref.modelVariant) ?? "") ?? .recommended
    }

    /// Whether `modelState` describes the custom engine (so switching back doesn't keep its status).
    private var stateFromCustomEngine = false

    /// Points the studio at the engine chosen in Settings › Studio and works out whether it can record.
    func refreshModelState() {
        switch EngineKind.current {
        case .builtIn:
            Task { await services.engine.configure(executable: Paths.engine) }
            if let dir = services.models.installedDirectory(preferred: preferredVariant) {
                modelState = .installed(dir)
            } else if stateFromCustomEngine {
                modelState = .unknown
            }
            stateFromCustomEngine = false
        case .custom:
            stateFromCustomEngine = true
            guard let config = CustomEngineConfig.current else {
                modelState = .failed("Choose your engine program in Settings › Studio.")
                return
            }
            Task { await services.engine.configure(executable: config.executable, arguments: config.arguments) }
            modelState = config.isExecutable
                ? .installed(config.modelDirectory)
                : .failed("The engine at \(config.executable.path) can’t be run. Check the path and that it’s executable (chmod +x).")
        }
    }

    /// A short name for the engine making recordings, stored in shared albums.
    var engineDescription: String {
        switch EngineKind.current {
        case .builtIn: "YuE2 (\(preferredVariant.rawValue))"
        case .custom: CustomEngineConfig.current.map { "Custom: \($0.executable.lastPathComponent)" } ?? "Custom"
        }
    }

    func installModelIfNeeded() {
        refreshModelState()
        guard EngineKind.current == .builtIn else { return }
        if case .installed = modelState { return }
        if case .downloading = modelState { return }
        let variant = preferredVariant
        modelState = .downloading(ModelDownloadProgress(receivedBytes: 0, totalBytes: 0, bytesPerSecond: 0))
        Task {
            do {
                let url = try await services.models.install(variant) { progress in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.modelState { self?.modelState = .downloading(progress) }
                    }
                }
                modelState = .installed(url)
            } catch {
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Onboarding → library

    func finishOnboarding(_ profile: TasteProfile) async throws -> TasteProfile {
        let engine = TasteEngine(client: services.client, catalog: services.catalog)
        var refined = profile
        do {
            refined = try await engine.refine(profile)
        } catch {
            appLog.error("Profile refinement failed: \(error.localizedDescription)")
            refined.coreGenres = profile.selectedGenres
        }
        try services.db.setValue(refined, forKey: TasteProfile.storageKey)
        taste = refined
        onboardingDone = true
        // A retaken quiz keeps the existing library and adds a smaller batch tuned to the new profile.
        let existing = (try? services.db.artistCount()) ?? 0
        if existing == 0 {
            try await services.builder.start(
                kind: .initialLibrary, title: "Your Library",
                request: BuildRequest(artistCount: Int(ProcessInfo.processInfo.environment["SM_INITIAL_ARTISTS"] ?? "") ?? 110))
        } else {
            try await services.builder.start(
                kind: .discover, title: "Fresh picks for your new taste", request: BuildRequest(artistCount: 20))
        }
        return refined
    }

    func beginBuilding() {
        withAnimation(.smooth(duration: 0.8)) { phase = .building }
    }

    func enterLibrary() {
        libraryEntered = true
        navigationRestored = true
        withAnimation(.smooth(duration: 0.8)) { phase = .library }
    }

    // MARK: While you wait

    /// Picks up the opener song once its track list is written and sends it to the front of the
    /// studio. Runs on every builder update (a cheap read) until the song is recorded or has failed;
    /// once the listener is in the library it's an ordinary song again.
    func refreshOpener() {
        guard let state = try? services.db.resolveOpener() else { return }
        if state != opener { opener = state }
        guard let id = state.trackID,
            let track = try? services.db.reader.read({ try Track.fetchOne($0, key: id) }),
            track.status == .pending || track.status == .generating,
            !recording.hasFailed(id), !libraryEntered
        else { return }
        if recording.active?.trackID != id, recording.requested.first != id { recording.prioritize(id) }
    }

    // MARK: Creating more music

    func generateArtists(prompt: String?, count: Int) async {
        let title = prompt.map { "“\($0)”" } ?? "New discoveries"
        do {
            try await services.builder.start(
                kind: prompt == nil ? .discover : .prompt, title: title,
                request: BuildRequest(artistCount: count, prompt: prompt))
            toast = "Scouting \(count) new artists…"
        } catch {
            toast = error.localizedDescription
        }
    }

    func generateSimilar(to artist: Artist, count: Int = 4) async {
        do {
            try await services.builder.start(
                kind: .similar, title: "More like \(artist.name)",
                request: BuildRequest(artistCount: count, seedArtistID: artist.id))
            toast = "Finding artists like \(artist.name)…"
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Commissions a new record from an existing artist and opens it when it's ready.
    func newRelease(from artist: Artist, brief: String? = nil) async {
        toast = "\(artist.name) is heading back into the studio…"
        do {
            let albumID = try await services.builder.newRelease(artistID: artist.id, brief: brief)
            toast = "New from \(artist.name)"
            showAlbum(albumID)
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Create › Custom: the listener's own lyrics and style, as a single that records and plays.
    /// Returns false (with a toast) if it couldn't be written.
    @discardableResult
    func createCustomSong(_ request: CustomSongRequest) async -> Bool {
        toast = request.artistID == nil ? "Finding the right artist for your song…" : "Heading into the studio…"
        do {
            let albumID = try await services.builder.createCustomSong(request)
            toast = "Recording your song"
            showAlbum(albumID)
            player.play(albumID: albumID)
            return true
        } catch {
            toast = error.localizedDescription
            return false
        }
    }

    func draftLyrics(style: String, about: String) async -> String? {
        do { return try await services.songWriter.draft(style: style, about: about) } catch {
            toast = error.localizedDescription
            return nil
        }
    }

    // MARK: Favorites

    func toggleFavorite(track id: ID) {
        guard let updated = try? services.db.modifyTrack(id, { $0.isFavorite.toggle() }),
            let info = try? services.db.trackInfo(id)
        else { return }
        recordSignal(
            ListeningSignal(
                kind: updated.isFavorite ? .favoriteTrack : .unfavorite, artistName: info.artist.name,
                genres: info.album.genres, styleTags: info.track.styleTags, title: info.track.title))
    }

    func toggleFavorite(album id: ID) {
        guard let album = try? services.db.modifyAlbum(id, { $0.isFavorite.toggle() }),
            let info = try? services.db.albumInfo(id)
        else { return }
        recordSignal(
            ListeningSignal(
                kind: album.isFavorite ? .favoriteAlbum : .unfavorite, artistName: info.artist.name,
                genres: album.genres, styleTags: "", title: album.title))
    }

    func toggleFavorite(artist id: ID) {
        guard let artist = try? services.db.modifyArtist(id, { $0.isFavorite.toggle() }) else { return }
        recordSignal(
            ListeningSignal(
                kind: artist.isFavorite ? .favoriteArtist : .unfavorite, artistName: artist.name, genres: artist.genres,
                styleTags: artist.tags.joined(separator: ", "), title: artist.name))
    }

    /// Favorites feed the taste profile used by every future generation.
    private func recordSignal(_ signal: ListeningSignal) {
        if signal.kind == .unfavorite {
            taste.signals.removeAll { $0.title == signal.title && $0.artistName == signal.artistName }
        } else {
            taste.signals.append(signal)
            if taste.signals.count > 200 { taste.signals.removeFirst(taste.signals.count - 200) }
        }
        taste.updatedAt = Date()
        try? services.db.setValue(taste, forKey: TasteProfile.storageKey)
        // Every few favorites, re-distil the profile so new artists follow the listener's evolving taste.
        let count = taste.signals.count
        if count > 0, count % 8 == 0 {
            let snapshot = taste
            Task {
                if let refined = try? await TasteEngine(client: services.client, catalog: services.catalog).refine(snapshot) {
                    var merged = refined
                    merged.signals = self.taste.signals
                    self.taste = merged
                    try? self.services.db.setValue(merged, forKey: TasteProfile.storageKey)
                }
            }
        }
    }

    // MARK: Navigation

    func show(_ route: Route) {
        if selection == .search || selection == nil { selection = .home }
        path.append(route)
    }

    func showAlbum(_ id: ID) { show(.album(id)) }
    func showArtist(_ id: ID) { show(.artist(id)) }

    func flash(_ message: String) {
        toast = message
    }

    /// Stop Recording: the studio stops and forgets its queue. If the player was waiting on a song
    /// that isn't recorded yet, it stops waiting too. Playing anything starts the studio again.
    func stopRecording() {
        recording.stopAll()
        if player.isWaiting { player.stop() }
        flash("Recording stopped. Play a song to start again.")
    }
}

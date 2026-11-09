import Foundation
import StandardKit

/// UserDefaults keys and defaults. Views bind with `@AppStorage(Pref.x)`.
enum Pref {
    static let menuBarEnabled = "menuBarEnabled"
    static let showDockIcon = "showDockIcon"
    static let quality = "generationQuality"
    static let lookahead = "lookahead"
    static let autoplay = "autoplay"
    static let normalizeVolume = "normalizeVolume"
    static let notifyWhenReady = "notifyWhenReady"
    static let writingModel = "writingModel"
    static let fastModel = "fastModel"
    /// "chatGPT" or "openRouter" (AIProvider raw value).
    static let aiProvider = "aiProvider"
    static let openRouterWritingModel = "openRouterWritingModel"
    static let openRouterFastModel = "openRouterFastModel"
    /// Empty = procedural artwork ($0); otherwise an OpenRouter image-capable model slug.
    static let openRouterImageModel = "openRouterImageModel"
    /// Off by default. A paid model tried only after every free model has failed.
    static let openRouterPaidFallback = "openRouterPaidFallback"
    static let openRouterPaidFallbackModel = "openRouterPaidFallbackModel"
    static let engineIdleMinutes = "engineIdleMinutes"
    static let modelVariant = "modelVariant"
    static let miniPlayerFloats = "miniPlayerFloats"
    static let volume = "volume"
    static let backgroundRecording = "backgroundRecording"
    /// Which program records songs: the built-in YuE2 engine or the listener's own.
    static let engineKind = "engineKind"
    static let customEnginePath = "customEnginePath"
    /// Extra command-line arguments for the custom engine, shell-style.
    static let customEngineArguments = "customEngineArguments"
    /// Passed to the custom engine's `load` command (a model folder, a model name — the engine decides).
    static let customEngineModel = "customEngineModel"
    static let scorePlanning = "scorePlanning"
    static let maxSongMinutes = "maxSongMinutes"
    /// Explicit lyrics allowed (asked during onboarding). Read by StandardKit's SongWriter.
    static let allowExplicit = ContentRating.allowExplicitKey
    /// Set by Settings › Library › Erase; the library folder is moved to the Trash on next launch.
    static let eraseLibraryOnLaunch = "eraseLibraryOnLaunch"

    static func register() {
        UserDefaults.standard.register(defaults: [
            menuBarEnabled: true,
            showDockIcon: true,
            quality: GenerationQuality.balanced.rawValue,
            lookahead: 2,
            autoplay: true,
            normalizeVolume: true,
            notifyWhenReady: true,
            writingModel: ChatGPTClient.defaultWritingModel,
            fastModel: ChatGPTClient.defaultFastModel,
            aiProvider: AIProvider.chatGPT.rawValue,
            openRouterWritingModel: OpenRouterCatalog.defaultModel,
            openRouterFastModel: OpenRouterCatalog.defaultModel,
            openRouterImageModel: "",
            openRouterPaidFallback: false,
            openRouterPaidFallbackModel: "",
            engineIdleMinutes: 5,
            modelVariant: ModelVariant.recommended.rawValue,
            miniPlayerFloats: true,
            volume: 0.8,
            backgroundRecording: false,
            engineKind: EngineKind.builtIn.rawValue,
            customEnginePath: "",
            customEngineArguments: "",
            customEngineModel: "",
            scorePlanning: ScorePlanningPref.full.rawValue,
            maxSongMinutes: 5.5,
        ])
    }
}

/// Trade recording time for fidelity (NAR flow-matching steps).
enum GenerationQuality: String, CaseIterable, Identifiable {
    case draft, balanced, studio

    var id: String { rawValue }

    var steps: Int {
        switch self {
        case .draft: 8
        case .balanced: 16
        case .studio: 32
        }
    }

    var title: String {
        switch self {
        case .draft: "Demo"
        case .balanced: "Balanced"
        case .studio: "Studio"
        }
    }

    var detail: String {
        switch self {
        case .draft: "Fastest recordings with a rougher, demo-tape finish."
        case .balanced: "The sweet spot: polished songs in a few minutes."
        case .studio: "Reference quality. Takes about twice as long."
        }
    }

    static var current: GenerationQuality {
        GenerationQuality(rawValue: UserDefaults.standard.string(forKey: Pref.quality) ?? "") ?? .balanced
    }
}

enum EngineKind: String, CaseIterable, Identifiable {
    case builtIn = "yue2"
    case custom

    var id: String { rawValue }

    static var current: EngineKind {
        EngineKind(rawValue: UserDefaults.standard.string(forKey: Pref.engineKind) ?? "") ?? .builtIn
    }
}

/// How much YuE2 plans before it sings. Mirrors YuEKit's `ScorePlanning`.
enum ScorePlanningPref: String, CaseIterable, Identifiable {
    case full, melody, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full score"
        case .melody: "Melody only"
        case .off: "None"
        }
    }

    var detail: String {
        switch self {
        case .full: "Writes out melody, chords and structure first. The most song-like results."
        case .melody: "Plans just the vocal line. A little faster, a little looser."
        case .off: "Sings straight from the lyrics. Fastest, and the least structured."
        }
    }

    static var current: ScorePlanningPref {
        ScorePlanningPref(rawValue: UserDefaults.standard.string(forKey: Pref.scorePlanning) ?? "") ?? .full
    }
}

/// The custom engine as configured in Settings › Studio.
struct CustomEngineConfig: Equatable {
    var executable: URL
    var arguments: [String]
    var model: String

    static var current: CustomEngineConfig? {
        let d = UserDefaults.standard
        let path = (d.string(forKey: Pref.customEnginePath) ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return CustomEngineConfig(
            executable: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            arguments: splitArguments(d.string(forKey: Pref.customEngineArguments) ?? ""),
            model: (d.string(forKey: Pref.customEngineModel) ?? "").trimmingCharacters(in: .whitespaces))
    }

    /// What the engine receives in `load`: the model setting, or the engine's own folder.
    var modelDirectory: URL {
        model.isEmpty
            ? executable.deletingLastPathComponent()
            : URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
    }

    var isExecutable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// Splits like a shell would for the simple cases: spaces separate, quotes group.
    static func splitArguments(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken { args.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }
}

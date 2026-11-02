import Foundation

/// JSON-lines protocol between the app and its music engine: the bundled `StandardMusicEngine`
/// helper (YuE2), or any program the listener points Settings › Studio at. docs/custom-engines.md
/// describes the wire format for people writing their own.

public struct EngineJob: Codable, Sendable, Hashable {
    public var id: String
    public var style: String
    public var lyrics: String
    /// "off", "melody" or "full".
    public var planning: String
    public var seed: UInt64
    public var steps: Int
    public var maxSemanticTokens: Int?
    /// Destination .m4a path. Written atomically.
    public var outputPath: String
    /// Descriptive extras for engines that take them separately. `style` already includes the voice;
    /// the built-in engine ignores these.
    public var title: String?
    public var artist: String?
    public var voice: String?
    public var isInstrumental: Bool?
    /// Longest song the listener wants, in seconds.
    public var maxSeconds: Double?

    public init(
        id: String, style: String, lyrics: String, planning: String, seed: UInt64, steps: Int,
        maxSemanticTokens: Int?, outputPath: String, title: String? = nil, artist: String? = nil,
        voice: String? = nil, isInstrumental: Bool? = nil, maxSeconds: Double? = nil
    ) {
        self.id = id
        self.style = style
        self.lyrics = lyrics
        self.planning = planning
        self.seed = seed
        self.steps = steps
        self.maxSemanticTokens = maxSemanticTokens
        self.outputPath = outputPath
        self.title = title
        self.artist = artist
        self.voice = voice
        self.isInstrumental = isInstrumental
        self.maxSeconds = maxSeconds
    }
}

public enum EngineCommand: Codable, Sendable {
    case load(modelPath: String)
    case generate(EngineJob)
    case cancel(id: String)
    case shutdown
}

public struct EngineProgress: Codable, Sendable, Hashable {
    /// loading, planning, composing, rendering, mastering, encoding
    public var stage: String
    public var stageFraction: Double
    public var overall: Double
    public var estimatedSongSeconds: Double?
    public var elapsed: Double

    public init(stage: String, stageFraction: Double, overall: Double, estimatedSongSeconds: Double?, elapsed: Double) {
        self.stage = stage
        self.stageFraction = stageFraction
        self.overall = overall
        self.estimatedSongSeconds = estimatedSongSeconds
        self.elapsed = elapsed
    }
}

public struct EngineResult: Codable, Sendable, Hashable {
    public var id: String
    public var duration: Double
    /// Approximate integrated loudness (LUFS-like, ungated K-weighting omitted).
    public var loudness: Double
    public var seconds: Double
    public var truncated: Bool
    public var abc: String?

    public init(id: String, duration: Double, loudness: Double, seconds: Double, truncated: Bool, abc: String?) {
        self.id = id
        self.duration = duration
        self.loudness = loudness
        self.seconds = seconds
        self.truncated = truncated
        self.abc = abc
    }
}

public enum EngineEvent: Codable, Sendable {
    case ready(loadSeconds: Double)
    case progress(id: String, EngineProgress)
    case finished(EngineResult)
    case failed(id: String?, message: String)
    case cancelled(id: String)
    case log(String)
}

public enum EngineCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }
}

import Foundation
import MLX
import MLXNN

enum Token {
    static let eod = 151_643
    static let abcStart = 151_847
    static let abcEnd = 151_848
    static let musicStart = 151_851
    static let musicEnd = 151_852
    static let codecOffset = 151_853
    static let codecSize = 32_768
    static let context = 24_576
}

public let sampleRate = 48_000

/// Symbolic planning mode ("chain of thought") before semantic decoding.
public enum ScorePlanning: String, Codable, Sendable, CaseIterable {
    /// No ABC score; direct generation.
    case off
    /// Melody-only ABC score.
    case melody
    /// Chord-annotated ABC score (upstream default, best structure).
    case full

    var instruction: String {
        switch self {
        case .off: "Generate music with codec tokens from the given conditions."
        case .melody:
            "Generate a melody-only ABC transcription without chord symbols, then generate music with codec tokens from the given conditions."
        case .full:
            "Generate a chord-annotated ABC transcription, then generate music with codec tokens from the given conditions."
        }
    }
}

public struct SamplingParameters: Codable, Sendable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var repetitionPenalty: Float
    public var penaltyWindow: Int
    public var minTokens: Int
    public var maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case temperature, topP = "top_p", topK = "top_k", repetitionPenalty = "repetition_penalty"
        case penaltyWindow = "penalty_window", minTokens = "min_tokens", maxTokens = "max_tokens"
    }
}

struct GenerationConfig: Codable {
    var abc: SamplingParameters
    var semantic: SamplingParameters
    var odeSteps: Int?

    enum CodingKeys: String, CodingKey { case abc, semantic, odeSteps = "ode_steps" }
}

/// A short stretch of an artist's earlier recording (semantic tokens plus the acoustic latents they
/// were rendered to). Rendering a new song next to it, pinned, carries the same singer's timbre over:
/// YuE2 has no trained audio prompt, so this is training-free flow-matching inpainting.
public struct VoiceReference: Codable, Sendable {
    public var codec: [Int]
    /// Row-major `[codec.count, 64]` latents.
    public var latents: [Float]

    public init(codec: [Int], latents: [Float]) {
        self.codec = codec
        self.latents = latents
    }

    /// Seconds of reference kept: long enough to hold a phrase or two of singing.
    public static let seconds = 15
}

public struct SongRequest: Codable, Sendable {
    /// Comma separated style tags, e.g. "English, indie pop, bright acoustic guitar, warm female vocal".
    public var style: String
    /// Lyrics with section tags such as `[Verse]`, `[Chorus]`.
    public var lyrics: String
    public var planning: ScorePlanning
    public var seed: UInt64
    /// NAR midpoint ODE steps (32 = reference quality, 8 = fast).
    public var steps: Int
    /// Optional hard cap on semantic frames (25 per second).
    public var maxSemanticTokens: Int?
    /// The artist's voice from an earlier song, held alongside while this one is rendered.
    public var voice: VoiceReference?

    public init(
        style: String, lyrics: String, planning: ScorePlanning = .full, seed: UInt64, steps: Int = 32,
        maxSemanticTokens: Int? = nil, voice: VoiceReference? = nil
    ) {
        self.style = style
        self.lyrics = lyrics
        self.planning = planning
        self.seed = seed
        self.steps = steps
        self.maxSemanticTokens = maxSemanticTokens
        self.voice = voice
    }
}

public enum GenerationStage: String, Codable, Sendable {
    case loading, planning, composing, rendering, mastering
}

public struct GenerationProgress: Codable, Sendable {
    public var stage: GenerationStage
    /// Progress inside the stage, 0…1.
    public var stageFraction: Double
    /// Best-effort overall progress, 0…1.
    public var overall: Double
    /// Estimated duration of the song being generated, in seconds, when known.
    public var estimatedSongSeconds: Double?
    public var detail: String
}

public struct GeneratedSong: Sendable {
    /// Interleaved stereo float samples at 48 kHz.
    public var samples: [Float]
    public var abc: String?
    public var frames: Int
    public var truncated: Bool
    /// A sung stretch of this recording (from the first chorus when the score marks one), ready to
    /// be the artist's voice reference for later songs.
    public var voice: VoiceReference?

    public var duration: Double { Double(samples.count / 2) / Double(sampleRate) }
}

public struct GenerationCancelled: Error {}

/// Deterministic SplitMix64 generator so seeds reproduce on the CPU sampler.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// End-to-end YuE2 song generation: ABC plan → semantic codec tokens → flow-matching latents → waveform.
public final class Yue2Pipeline: @unchecked Sendable {
    public let directory: URL
    let tokenizer: Tokenizer
    let model: Yue2Model
    let vae: OobleckDecoder
    let abcSampling: SamplingParameters
    let semanticSampling: SamplingParameters
    let defaultSteps: Int
    private var heads: [Bool: Linear] = [:]

    /// Apple GPUs before M2 have no native bfloat16; float16 is much faster there.
    public static var preferredComputeType: DType {
        if let forced = ProcessInfo.processInfo.environment["YUE_DTYPE"] {
            return forced == "bf16" ? .bfloat16 : .float16
        }
        return .float16
    }

    public init(directory: URL, computeType: DType = Yue2Pipeline.preferredComputeType) throws {
        self.directory = directory
        let gen = try JSONDecoder().decode(
            GenerationConfig.self,
            from: Data(contentsOf: directory.appending(path: "yue2_generation_config.json")))
        abcSampling = gen.abc
        semanticSampling = gen.semantic
        defaultSteps = gen.odeSteps ?? 32
        tokenizer = try Tokenizer(rankFile: directory.appending(path: "qwen.tiktoken"))
        vae = try OobleckDecoder.load(directory: directory)
        model = try Yue2Model.load(directory: directory, computeType: computeType)
    }

    public func encode(_ text: String) -> [Int] { tokenizer.encode(text) }
    public func decode(_ ids: [Int]) -> String { tokenizer.decode(ids) }

    // MARK: Prompt construction

    func requestText(_ style: String, _ lyrics: String, _ planning: ScorePlanning) -> String {
        "\(planning.instruction)\n[Tags]\n\(style)\n[Lyrics]\n\(lyrics)\n"
    }

    func tokenPrefix(style: String, lyrics: String, planning: ScorePlanning, abc: [Int]?) -> [Int] {
        let base = [Token.eod] + tokenizer.encode(requestText(style, lyrics, planning))
        if planning == .off { return base + [Token.abcStart, Token.abcEnd, Token.musicStart] }
        guard let abc else { return base + [Token.abcStart] }
        return base + [Token.abcStart] + abc + [Token.abcEnd, Token.musicStart]
    }

    // MARK: AR sampling

    /// Samples tokens until the phase end token. Returns (ids, truncated).
    /// Sampling runs on the GPU and the next step is queued before the previous token is read back,
    /// so the CPU never stalls the decoder.
    func generateTokens(
        prefix: [Int], sampling s: SamplingParameters, rng: inout SeededGenerator, abcPhase: Bool,
        onToken: (Int) throws -> Void
    ) throws -> ([Int], Bool) {
        guard prefix.count + s.maxTokens <= Token.context else {
            throw YuEError.promptTooLong
        }
        let caches = (0 ..< model.layerCount).map { _ in KVCache() }
        // Only score the part of the vocabulary this phase may emit: ABC text (+ its end marker), or
        // MUSIC_END followed by the 32k codec tokens. Local logit i is global token `base + i`.
        let base = abcPhase ? 0 : Token.musicEnd
        let rows = abcPhase ? 0 ..< (Token.abcEnd + 1) : Token.musicEnd ..< (Token.codecOffset + Token.codecSize)
        let head = heads[abcPhase] ?? model.head(rows: rows)
        heads[abcPhase] = head
        let vocab = rows.count
        let end = (abcPhase ? Token.abcEnd : Token.musicEnd) - base
        let localIndex = MLXArray(Int32(0) ..< Int32(vocab))
        let allowed: MLXArray? =
            abcPhase
            ? MLX.where((localIndex .< Int32(Token.eod)) .|| (localIndex .== Int32(end)), MLXArray(Float(0)), MLXArray(-Float.infinity))
            : nil
        let blockEnd = MLX.where(localIndex .== Int32(end), MLXArray(-Float.infinity), MLXArray(Float(0)))
        var key = MLXRandom.key(rng.next())
        var recent = MLXArray.zeros([0], dtype: .int32)

        func sample(_ logits: MLXArray, step: Int) -> MLXArray {
            var scores = logits[0].asType(.float32)
            if let allowed { scores = scores + allowed }
            if step < s.minTokens { scores = scores + blockEnd }
            if s.repetitionPenalty != 1, recent.dim(0) > 0 {
                let freq = MLXArray.zeros([vocab], dtype: .float32).at[recent].add(1)
                let alpha = pow(MLXArray(s.repetitionPenalty), freq)
                scores = MLX.where(scores .< 0, scores * alpha, scores / alpha)
            }
            if s.temperature == 0 { return scores.argMax().asType(.int32) }
            scores = scores / s.temperature
            let k = min(s.topK, vocab)
            let candidates = argPartition(-scores, kth: k - 1)[..<k]
            var values = scores[candidates]
            let order = argSort(-values)
            values = values[order]
            let ids = candidates[order]
            let probs = softmax(values)
            let cumulative = cumsum(probs)
            let removed = (cumulative - probs) .> s.topP
            values = MLX.where(removed, MLXArray(-Float.infinity), values)
            let split = MLXRandom.split(key: key)
            key = split.0
            let choice = MLXRandom.categorical(values, key: split.1)
            return ids[choice].asType(.int32)
        }

        func push(_ token: MLXArray) {
            recent = concatenated([recent, token.reshaped(1)])
            if recent.dim(0) > s.penaltyWindow { recent = recent[(recent.dim(0) - s.penaltyWindow)...] }
        }

        var y = sample(model.arStep(MLXArray(prefix.map(Int32.init))[.newAxis], caches: caches, head: head), step: 0)
        push(y)
        asyncEval(y, recent)
        var history: [Int] = []
        for step in 0 ..< s.maxTokens {
            var next: MLXArray?
            if step + 1 < s.maxTokens {
                let logits = model.arStep((y + Int32(base)).reshaped(1, 1), caches: caches, head: head)
                let n = sample(logits, step: step + 1)
                push(n)
                asyncEval(n, recent)
                next = n
            }
            let local = y.item(Int.self)
            if local == end { return (history, false) }
            history.append(local + base)
            try onToken(history.count)
            guard let next else { break }
            y = next
        }
        return (history, true)
    }

    // MARK: NAR flow matching

    private func logit(_ t: Double) -> Float {
        if t <= 0 { return -20 }
        if t >= 1 { return 20 }
        return Float(max(-20, min(20, log(t / (1 - t)))))
    }

    func synthesize(
        prefix: [Int], codec: [Int], seed: UInt64, steps: Int, voice: VoiceReference? = nil,
        onStep: (Int, Int) throws -> Void
    ) throws -> MLXArray {
        let noise = MLXRandom.normal([codec.count, 64], key: MLXRandom.key(seed))
        let dt = 1.0 / Double(steps)
        // The reference sits in front of every chunk, in both the token context and the latent state.
        let refCount = voice?.codec.count ?? 0
        let refLatents = voice.map { MLXArray($0.latents, [$0.codec.count, 64]).asType(model.computeType) }
        let refNoise = MLXRandom.normal([refCount, 64], key: MLXRandom.key(seed &+ 1)).asType(model.computeType)
        let refTokens = (voice?.codec ?? []).map { $0 + Token.codecOffset }
        let size = min((Token.context - prefix.count - 3 - 2 * refCount) / 2, Token.context)
        guard size > 0 else { throw YuEError.promptTooLong }
        /// Holds the reference frames on the flow path of its clean latents (t = 1 is pure noise).
        func pin(_ state: MLXArray, _ t: Double) -> MLXArray {
            guard let refLatents else { return state }
            let ref = refNoise * Float(t) + refLatents * Float(1 - t)
            return concatenated([ref, state[refCount...]], axis: 0)
        }
        let chunks = stride(from: 0, to: codec.count, by: size).map { ($0, min($0 + size, codec.count)) }
        let totalSteps = chunks.count * steps
        var done = 0
        var out: [MLXArray] = []
        for (a, b) in chunks {
            let arTokens = prefix + refTokens + codec[a ..< b].map { $0 + Token.codecOffset } + [Token.musicEnd]
            let arCache = model.narPrefill(arTokens)
            var state = noise[a ..< b].asType(model.computeType)
            if refCount > 0 { state = concatenated([refNoise, state], axis: 0) }
            for step in 0 ..< steps {
                let t = 1.0 - Double(step) * dt
                state = pin(state, t)
                let v1 = model.narVelocity(state, rawT: logit(t), arCache: arCache, arLength: arTokens.count)
                let mid = pin(state - v1 * Float(dt / 2), t - dt / 2)
                let v2 = model.narVelocity(mid, rawT: logit(t - dt / 2), arCache: arCache, arLength: arTokens.count)
                state = state - v2 * Float(dt)
                eval(state)
                done += 1
                try onStep(done, totalSteps)
            }
            out.append(state[refCount...].asType(.float32))
        }
        return concatenated(out)
    }

    /// The stretch of a finished recording to keep as the artist's voice: from the first chorus when
    /// the score marks one (choruses are sung), otherwise a quarter of the way in.
    static func voiceWindow(abc: String?, frames: Int) -> Range<Int> {
        let length = min(frames, VoiceReference.seconds * 25)
        let chorus = abc.flatMap { estimateSeconds(abc: $0, until: "chorus") }.map { Int($0 * 25) }
        let start = min(max(0, chorus ?? frames / 4), frames - length)
        return start ..< start + length
    }

    // MARK: Pipeline

    public func generate(
        _ request: SongRequest, progress: @escaping (GenerationProgress) -> Void, isCancelled: @escaping () -> Bool
    ) throws -> GeneratedSong {
        var rng = SeededGenerator(seed: request.seed)
        let check = { if isCancelled() { throw GenerationCancelled() } }
        var estimate = Self.estimateSeconds(lyrics: request.lyrics)
        // Stage weights are rough wall-clock shares on M-series GPUs.
        let weights: [GenerationStage: (start: Double, span: Double)] =
            request.planning == .off
            ? [.composing: (0, 0.5), .rendering: (0.5, 0.42), .mastering: (0.92, 0.08)]
            : [.planning: (0, 0.1), .composing: (0.1, 0.42), .rendering: (0.52, 0.4), .mastering: (0.92, 0.08)]
        func report(_ stage: GenerationStage, _ fraction: Double, _ detail: String) {
            let w = weights[stage] ?? (0, 0)
            let f = min(max(fraction, 0), 1)
            progress(
                GenerationProgress(
                    stage: stage, stageFraction: f, overall: w.start + w.span * f, estimatedSongSeconds: estimate,
                    detail: detail))
        }

        // 1. Symbolic plan
        var abcIds: [Int]?
        var abcText: String?
        if request.planning != .off {
            report(.planning, 0, "Writing the score")
            let expected = Double(estimate * 6)
            let (ids, _) = try generateTokens(
                prefix: tokenPrefix(style: request.style, lyrics: request.lyrics, planning: request.planning, abc: nil),
                sampling: abcSampling, rng: &rng, abcPhase: true
            ) { count in
                try check()
                if count % 16 == 0 { report(.planning, Double(count) / expected, "Writing the score") }
            }
            abcIds = ids
            abcText = tokenizer.decode(ids)
            if let seconds = abcText.flatMap { Self.estimateSeconds(abc: $0) } { estimate = seconds }
            Memory.clearCache()
        }

        // 2. Semantic codec tokens
        let prefix = tokenPrefix(style: request.style, lyrics: request.lyrics, planning: request.planning, abc: abcIds)
        // Experimental: let composition continue from the reference voice too.
        let composeAfterVoice = ProcessInfo.processInfo.environment["YUE_VOICE_AR"] != nil
        let arPrefix = prefix + (composeAfterVoice ? (request.voice?.codec ?? []).map { $0 + Token.codecOffset } : [])
        var semantic = semanticSampling
        if let cap = request.maxSemanticTokens {
            semantic.maxTokens = cap
            semantic.minTokens = min(semantic.minTokens, cap)
        }
        semantic.maxTokens = min(semantic.maxTokens, Token.context - arPrefix.count)
        report(.composing, 0, "Recording")
        let (ids, truncated) = try generateTokens(prefix: arPrefix, sampling: semantic, rng: &rng, abcPhase: false) {
            count in
            try check()
            if count % 25 == 0 {
                let expected = max(estimate * 25, Double(count) + 50)
                report(.composing, Double(count) / expected, "Recording")
            }
        }
        let codec = ids.map { $0 - Token.codecOffset }
        guard !codec.isEmpty else { throw YuEError.emptySong }
        estimate = Double(codec.count) / 25
        Memory.clearCache()

        // 3. Acoustic latents
        report(.rendering, 0, "Mixing")
        let latents = try synthesize(
            prefix: prefix, codec: codec, seed: request.seed, steps: request.steps > 0 ? request.steps : defaultSteps,
            voice: request.voice
        ) { step, total in
            try check()
            report(.rendering, Double(step) / Double(total), "Mixing")
        }
        eval(latents)
        let window = Self.voiceWindow(abc: abcText, frames: codec.count)
        let voice = VoiceReference(
            codec: Array(codec[window]), latents: latents[window.lowerBound ..< window.upperBound].asArray(Float.self))
        Memory.clearCache()

        // 4. Waveform
        report(.mastering, 0, "Mastering")
        let audio = vae.decodeTiled(latents) { done, total in
            report(.mastering, Double(done) / Double(total), "Mastering")
        }
        // Peak-normalise instead of hard clipping: the decoder can overshoot ±1 on loud passages.
        let peak = audio.abs().max().item(Float.self)
        let samples = (peak > 0.98 ? audio * (0.98 / peak) : audio).asArray(Float.self)
        Memory.clearCache()
        return GeneratedSong(samples: samples, abc: abcText, frames: codec.count, truncated: truncated, voice: voice)
    }

    // MARK: Length estimates

    private static func isHeader(_ line: Substring) -> Bool {
        line.count >= 2 && line.first!.isLetter && line.dropFirst().first == ":"
    }

    /// Rough song length from lyrics: ~2.6 s per sung line plus intro/outro and instrumental sections.
    static func estimateSeconds(lyrics: String) -> Double {
        let lines = lyrics.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let sung = lines.filter { !$0.isEmpty && !$0.hasPrefix("[") }.count
        let sections = lines.filter { $0.hasPrefix("[") }.count
        return min(360, max(60, Double(sung) * 3.2 + Double(sections) * 4 + 20))
    }

    /// Song length from an ABC score's meter, tempo and bar count.
    /// Seconds of music the score describes, or with `until`, the seconds before the first section
    /// whose `%` marker starts with that name.
    static func estimateSeconds(abc: String, until section: String? = nil) -> Double? {
        var beatsPerBar = 4.0
        var bpm = 100.0
        var bars = 0
        var firstVoice: String?
        var currentVoice: String?
        for line in abc.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let section, trimmed.hasPrefix("%"),
                trimmed.dropFirst().trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(section)
            {
                return Double(bars) * beatsPerBar * 60 / bpm
            }
            if trimmed.hasPrefix("V:") {
                let name = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
                currentVoice = name
                if firstVoice == nil { firstVoice = name }
            } else if trimmed.hasPrefix("M:"), let slash = trimmed.firstIndex(of: "/"),
                let n = Double(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2) ..< slash].trimmingCharacters(in: .whitespaces))
            {
                beatsPerBar = n
            } else if trimmed.hasPrefix("Q:"), let eq = trimmed.lastIndex(of: "="),
                let q = Double(trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            {
                bpm = q
            } else if !Self.isHeader(Substring(trimmed)), !trimmed.hasPrefix("%"), currentVoice == firstVoice {
                bars += trimmed.filter { $0 == "|" }.count
            }
        }
        guard section == nil, bars > 4, bpm > 20 else { return nil }
        return min(420, Double(bars) * beatsPerBar * 60 / bpm)
    }
}

public enum YuEError: Error, LocalizedError {
    case promptTooLong, emptySong

    public var errorDescription: String? {
        switch self {
        case .promptTooLong: "The lyrics are too long for the model's context."
        case .emptySong: "The model did not produce any music."
        }
    }
}

extension Yue2Pipeline {
    /// Deterministic numerical probe used to verify parity with the Python reference.
    public func parityProbe(text: String) -> [String: [Float]] {
        let prefix = [Token.eod] + tokenizer.encode(text)
        let caches = (0 ..< model.layerCount).map { _ in KVCache() }
        let logits = model.arStep(MLXArray(prefix.map(Int32.init))[.newAxis], caches: caches)[0].asType(.float32)
        let next = model.arStep(MLXArray([Int32(Token.codecOffset + 5)])[.newAxis], caches: caches)[0].asType(.float32)
        let codec = (0 ..< 40).map { ($0 * 977) % Token.codecSize + Token.codecOffset }
        let arTokens = prefix + codec + [Token.musicEnd]
        let cache = model.narPrefill(arTokens)
        let state = sin(MLXArray(0 ..< Int32(40 * 64)).asType(.float32) * 0.01).reshaped(40, 64).asType(model.computeType)
        let v = model.narVelocity(state, rawT: 0.5, arCache: cache, arLength: arTokens.count).asType(.float32)
        let z = sin(MLXArray(0 ..< Int32(6 * 64)).asType(.float32) * 0.03).reshaped(6, 64)
        let audio = vae(z[.newAxis])[0]
        return [
            "logits": logits[0 ..< 8].asArray(Float.self) + [logits.max().item(Float.self), Float(logits.argMax().item(Int.self))],
            "next": next[(Token.codecOffset) ..< (Token.codecOffset + 6)].asArray(Float.self),
            "velocity": v[0, 0 ..< 6].asArray(Float.self) + [v.mean().item(Float.self), v.abs().mean().item(Float.self)],
            "vae": audio[1000, 0...].asArray(Float.self) + [audio.abs().mean().item(Float.self)],
        ]
    }
}

extension Yue2Pipeline {
    /// Times AR decoding and one NAR velocity evaluation at a realistic song size.
    public func benchmark(frames: Int = 4400, prefixLength: Int = 1500) -> String {
        let prefix = [Token.eod] + Array(repeating: 1000, count: prefixLength - 1)
        let caches = (0 ..< model.layerCount).map { _ in KVCache() }
        var logits = model.arStep(MLXArray(prefix.map(Int32.init))[.newAxis], caches: caches)
        eval(logits)
        var t = Date()
        for _ in 0 ..< 50 {
            logits = model.arStep(MLXArray([Int32(Token.codecOffset + 7)])[.newAxis], caches: caches)
            eval(logits)
        }
        let ar = 50 / Date().timeIntervalSince(t)
        let small = model.head(rows: Token.musicEnd ..< (Token.codecOffset + Token.codecSize))
        eval(small)
        t = Date()
        for _ in 0 ..< 50 {
            logits = model.arStep(MLXArray([Int32(Token.codecOffset + 7)])[.newAxis], caches: caches, head: small)
            eval(logits)
        }
        let arSmall = 50 / Date().timeIntervalSince(t)
        print(String(format: "AR full head %.1f tok/s, codec head %.1f tok/s", ar, arSmall))
        var y = logits.argMax(axis: -1)
        t = Date()
        for _ in 0 ..< 50 {
            let next = model.arStep(y.reshaped(1, 1).asType(.int32) + Int32(Token.musicEnd), caches: caches, head: small).argMax(axis: -1)
            asyncEval(next)
            _ = y.item(Int.self)
            y = next
        }
        print(String(format: "AR pipelined argmax %.1f tok/s", 50 / Date().timeIntervalSince(t)))
        let codec = (0 ..< frames).map { ($0 * 977) % Token.codecSize + Token.codecOffset }
        t = Date()
        let cache = model.narPrefill(prefix + codec + [Token.musicEnd])
        let prefill = Date().timeIntervalSince(t)
        let state = MLXRandom.normal([frames, 64]).asType(model.computeType)
        var v = model.narVelocity(state, rawT: 0.5, arCache: cache, arLength: prefix.count + frames + 1)
        eval(v)
        t = Date()
        v = model.narVelocity(state, rawT: 0.3, arCache: cache, arLength: prefix.count + frames + 1)
        eval(v)
        let nar = Date().timeIntervalSince(t)
        return String(format: "AR %.1f tok/s, prefill %.1fs, NAR velocity %.2fs, finite %@, peak %.1f GB",
            ar, prefill, nar, "\(v.abs().max().item(Float.self).isFinite)", Double(Memory.peakMemory) / 1e9)
    }
}

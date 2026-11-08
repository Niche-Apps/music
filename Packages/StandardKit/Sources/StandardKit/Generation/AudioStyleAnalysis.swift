import AVFoundation
import Foundation

/// Mono PCM handed to the analyzer. Samples are the audio that was actually decoded.
/// `sourceDuration` is the file's duration when known, which can be longer than `samples`
/// because analysis only reads the start of the file.
public struct PCMBuffer: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double
    public var sourceDuration: Double

    public init(samples: [Float], sampleRate: Double, sourceDuration: Double? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        let played = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        self.sourceDuration = sourceDuration ?? played
    }

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Identifies the bytes that were measured so a saved report can be reused or thrown out.
/// The signature mixes file size and modification time. It is not a hash of the audio samples
/// and it is never sent to a model.
public struct AudioFingerprint: Codable, Sendable, Hashable {
    public var signature: UInt64
    public var algorithmVersion: Int
    public var partCount: Int

    public init(signature: UInt64, algorithmVersion: Int, partCount: Int) {
        self.signature = signature
        self.algorithmVersion = algorithmVersion
        self.partCount = partCount
    }

    public static func file(byteCount: Int64, modifiedAt: TimeInterval) -> AudioFingerprint {
        var hash = fnv(14695981039346656037, UInt64(bitPattern: byteCount))
        hash = fnv(hash, modifiedAt.bitPattern)
        return AudioFingerprint(signature: hash, algorithmVersion: AudioStyleAnalyzer.version, partCount: 1)
    }

    public static func file(at url: URL) -> AudioFingerprint? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize else { return nil }
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return file(byteCount: Int64(size), modifiedAt: modified)
    }

    /// Order matters: callers pass parts in the same order they sample (track number, or file name).
    public static func combine(_ parts: [AudioFingerprint]) -> AudioFingerprint {
        var hash: UInt64 = 14695981039346656037
        for part in parts {
            hash = fnv(hash, part.signature)
            hash = fnv(hash, UInt64(part.partCount))
        }
        return AudioFingerprint(signature: hash, algorithmVersion: AudioStyleAnalyzer.version, partCount: parts.count)
    }
}

private func fnv(_ hash: UInt64, _ value: UInt64) -> UInt64 {
    var acc = hash
    var bits = value
    for _ in 0 ..< 8 {
        acc ^= bits & 0xFF
        acc &*= 1099511628211
        bits >>= 8
    }
    return acc
}

/// Numbers computed from the waveform. Nothing here is an instrument, a voice, a key, or a genre.
public struct MeasuredAudioFeatures: Codable, Sendable, Hashable {
    public var sampleRate: Double
    public var sourceDuration: Double
    public var analyzedSeconds: Double
    public var rmsDBFS: Double
    public var peakDBFS: Double
    public var crestDB: Double
    public var silenceRatio: Double
    public var spectralCentroidHz: Double?
    public var spectralFlatness: Double?
    public var lowEnergy: Double
    public var midEnergy: Double
    public var highEnergy: Double
    /// Peak of the onset autocorrelation. Nil when the peak is too weak to report.
    public var tempoBPM: Double?
    public var tempoConfidence: Double
}

/// Words chosen by fixed thresholds on `MeasuredAudioFeatures`. They are not classifications.
public struct InferredAudioDescriptors: Codable, Sendable, Hashable {
    public var words: [String]
    public var notes: [String]
}

public struct AudioTrackSample: Codable, Sendable, Hashable {
    public var label: String
    public var status: AudioAnalysisStatus
    public var analyzedSeconds: Double
    public var sourceDuration: Double
}

public enum AudioAnalysisStatus: String, Codable, Sendable, Hashable {
    case measured
    case silence
    case tooShort
    case unreadable
    case unsupported
    case unavailable
}

/// One local measurement of a selected file, song, or a bounded sample of an album or folder.
public struct AudioStyleReport: Codable, Sendable, Hashable {
    public var algorithmVersion: Int
    public var fingerprint: AudioFingerprint?
    public var status: AudioAnalysisStatus
    public var measured: MeasuredAudioFeatures?
    public var inferred: InferredAudioDescriptors
    public var confidence: Double
    /// Always states what this measurement is not.
    public var limitation: String
    public var coverage: String
    public var samples: [AudioTrackSample]

    public var chipLabel: String {
        switch status {
        case .measured: "Audio"
        case .silence: "Silent"
        case .tooShort: "Too short"
        case .unreadable: "Unreadable"
        case .unsupported: "Unsupported"
        case .unavailable: "Tags only"
        }
    }

    public func matches(_ fingerprint: AudioFingerprint) -> Bool {
        self.fingerprint == fingerprint && algorithmVersion == AudioStyleAnalyzer.version
            && status != .unavailable
    }

    /// Prompt text. Measurements and heuristic words are labeled separately. No paths and no samples.
    public func promptSentence(vocalOnly: Bool) -> String {
        guard let measured else {
            return "\(chipLabel). \(coverage) \(limitation)"
        }
        let centroid = measured.spectralCentroidHz.map { "\(Int($0.rounded())) Hz" } ?? "not available"
        let flatness = measured.spectralFlatness.map { String(format: "%.2f", $0) } ?? "not available"
        let tempo: String
        if let bpm = measured.tempoBPM {
            tempo = "\(Int(bpm.rounded())) BPM, autocorrelation confidence \(String(format: "%.2f", measured.tempoConfidence))"
        } else {
            tempo = "not estimated"
        }
        var words = inferred.words
        if vocalOnly { words.removeAll { VocalOnly.namesInstrument($0) || $0 == "noisy" } }
        let labels = words.isEmpty ? "none" : words.joined(separator: ", ")
        var sentence = "Measured \(formatSeconds(measured.analyzedSeconds)) of \(formatSeconds(measured.sourceDuration)) at \(Int(measured.sampleRate.rounded())) Hz. "
            + "Loudness \(formatDB(measured.rmsDBFS)) dBFS, peak \(formatDB(measured.peakDBFS)) dBFS, crest \(formatDB(measured.crestDB)) dB, "
            + "silence \(Int((measured.silenceRatio * 100).rounded()))%. "
            + "Spectral centroid \(centroid), spectral flatness \(flatness), "
            + "energy low/mid/high \(pct(measured.lowEnergy))/\(pct(measured.midEnergy))/\(pct(measured.highEnergy)). "
            + "Tempo estimate \(tempo). "
            + "Heuristic labels from those thresholds only: \(labels). "
            + coverage
        if vocalOnly {
            sentence += " The listener asked for vocals only, so ignore any reading that suggests drums, noise, or other instruments."
        }
        return sentence
    }

    /// Short words that may be added to the music-model tag line. A whitelist, so this cannot invent an instrument.
    public func engineTags(vocalOnly: Bool) -> [String] {
        guard status == .measured, confidence >= 0.35 else { return [] }
        return inferred.words.filter { word in
            AudioStyleAnalyzer.inferredWhitelist.contains(word)
                && !(vocalOnly && (word == "noisy" || VocalOnly.namesInstrument(word)))
        }
    }
}

public enum AudioReadError: Error, Equatable {
    case unreadable
    case unsupported
    case cancelled
}

/// Local DSP on decoded samples. No model, no network, no instrument or genre classifier.
public enum AudioStyleAnalyzer {
    public static let version = 1
    public static let maxSeconds = 20.0
    public static let maxTracks = 8
    public static let minimumSeconds = 0.45
    /// Walk at most this many directory entries when sampling a folder.
    public static let maxDirectoryEntries = 200
    public static let capability = "Measured from the waveform: duration, loudness, silence, spectral centroid, spectral flatness, low/mid/high energy, and a tempo estimate from onset spacing. Not identified: instruments, vocals, key, or genre. Words such as brighter or faster are thresholds on those numbers."

    static let fftSize = 2048
    static let hop = 1024
    static let inferredWhitelist: Set<String> = [
        "brighter", "darker", "midrange", "tonal", "noisy", "dynamic", "compressed", "slower", "faster", "midtempo",
        "low-frequency", "high-frequency",
    ]

    public static func safeLabel(_ raw: String, index: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains(":") {
            return "Track \(index)"
        }
        return String(trimmed.prefix(80))
    }

    public static func analyze(_ buffer: PCMBuffer, isCancelled: @escaping @Sendable () throws -> Void = {}) throws -> AudioAnalysisResult {
        try isCancelled()
        let rate = buffer.sampleRate
        guard rate >= 2000, rate <= 192_000 else { return failure(.unsupported, "The sample rate can’t be measured with this analyzer.") }
        guard !buffer.samples.isEmpty else { return failure(.unreadable, "The file didn’t contain readable audio samples.") }
        guard buffer.samples.allSatisfy(\.isFinite) else { return failure(.unreadable, "The file contained samples that aren’t finite numbers.") }
        let cap = Int(maxSeconds * rate)
        let used = buffer.samples.count > cap ? Array(buffer.samples.prefix(cap)) : buffer.samples
        let analyzed = Double(used.count) / rate
        let source = max(buffer.sourceDuration, analyzed)
        if analyzed < minimumSeconds {
            let loud = levels(used)
            return AudioAnalysisResult(
                status: .tooShort,
                measured: MeasuredAudioFeatures(
                    sampleRate: rate, sourceDuration: source, analyzedSeconds: analyzed, rmsDBFS: loud.rms, peakDBFS: loud.peak,
                    crestDB: loud.crest, silenceRatio: loud.silence, spectralCentroidHz: nil, spectralFlatness: nil,
                    lowEnergy: 0, midEnergy: 0, highEnergy: 0, tempoBPM: nil, tempoConfidence: 0),
                inferred: InferredAudioDescriptors(words: [], notes: ["The clip is under \(minimumSeconds) seconds, so no spectrum or tempo was estimated."]),
                confidence: 0.2,
                coverage: "Measured \(formatSeconds(analyzed)) of \(formatSeconds(source)).",
                samples: [])
        }
        let frames = frameEnergies(used, isCancelled: isCancelled)
        let energies = try frames.get()
        let silence = energies.isEmpty ? 1 : Double(energies.filter { $0.db < -50 }.count) / Double(energies.count)
        let loud = levels(used)
        if silence > 0.92 && loud.rms < -45 {
            return AudioAnalysisResult(
                status: .silence,
                measured: MeasuredAudioFeatures(
                    sampleRate: rate, sourceDuration: source, analyzedSeconds: analyzed, rmsDBFS: loud.rms, peakDBFS: loud.peak,
                    crestDB: loud.crest, silenceRatio: silence, spectralCentroidHz: nil, spectralFlatness: nil,
                    lowEnergy: 0, midEnergy: 0, highEnergy: 0, tempoBPM: nil, tempoConfidence: 0),
                inferred: InferredAudioDescriptors(words: [], notes: ["Most analyzed frames are below −50 dBFS, so this was measured as silence. No tone or tempo was inferred."]),
                confidence: 0.35,
                coverage: "Measured \(formatSeconds(analyzed)) of \(formatSeconds(source)).",
                samples: [])
        }
        let spectrum = try averageSpectrum(used, rate: rate, energies: energies, isCancelled: isCancelled)
        let bands = bandEnergy(spectrum.bins, rate: rate)
        let tempo = tempoEstimate(energies.map(\.linear), rate: rate)
        let measured = MeasuredAudioFeatures(
            sampleRate: rate, sourceDuration: source, analyzedSeconds: analyzed, rmsDBFS: loud.rms, peakDBFS: loud.peak,
            crestDB: loud.crest, silenceRatio: silence, spectralCentroidHz: spectrum.centroid, spectralFlatness: spectrum.flatness,
            lowEnergy: bands.low, midEnergy: bands.mid, highEnergy: bands.high,
            tempoBPM: tempo.bpm, tempoConfidence: tempo.confidence)
        let inferred = infer(measured)
        var confidence = 0.72
        if analyzed < 2 { confidence *= 0.6 }
        if silence > 0.4 { confidence *= 0.7 }
        if spectrum.centroid == nil { confidence *= 0.5 }
        confidence = min(0.9, confidence)
        return AudioAnalysisResult(
            status: .measured, measured: measured, inferred: inferred, confidence: confidence,
            coverage: "Measured the first \(formatSeconds(analyzed)) of \(formatSeconds(source)).",
            samples: [])
    }

    /// Stops at `maxTracks`. A cancellation throws and returns nothing, so a caller must not keep a partial list.
    public static func analyzeAll(_ buffers: [PCMBuffer], isCancelled: @escaping @Sendable () throws -> Void = {}) throws -> [AudioAnalysisResult] {
        var results: [AudioAnalysisResult] = []
        for buffer in buffers.prefix(maxTracks) {
            try isCancelled()
            results.append(try analyze(buffer, isCancelled: isCancelled))
        }
        return results
    }

    public static func aggregate(_ parts: [(String, AudioAnalysisResult)], considered: Int) -> AudioStyleReport {
        let capped = Array(parts.prefix(maxTracks))
        let samples = capped.enumerated().map { index, part in
            AudioTrackSample(
                label: safeLabel(part.0, index: index + 1),
                status: part.1.status,
                analyzedSeconds: part.1.measured?.analyzedSeconds ?? 0,
                sourceDuration: part.1.measured?.sourceDuration ?? 0)
        }
        let measuredParts = capped.compactMap { part -> MeasuredAudioFeatures? in
            part.1.status == .measured ? part.1.measured : nil
        }
        let consideredCount = max(considered, capped.count)
        let skipped = capped.filter { $0.1.status != .measured }.count
        let notSampled = max(0, consideredCount - capped.count)
        var coverage = "Sampled \(capped.count) of \(consideredCount) audio file\(consideredCount == 1 ? "" : "s")"
        coverage += ", \(measuredParts.count) with a usable measurement"
        if skipped > 0 { coverage += ", \(skipped) skipped as silent, too short, or unreadable" }
        if notSampled > 0 { coverage += ", \(notSampled) not sampled" }
        coverage += ". At most \(Int(maxSeconds)) seconds from the start of each file. This is not a full listen."
        guard !measuredParts.isEmpty else {
            let status = capped.first.map { $0.1.status } ?? .unavailable
            return AudioStyleReport(
                algorithmVersion: version, fingerprint: nil, status: status == .measured ? .unavailable : status,
                measured: nil, inferred: InferredAudioDescriptors(words: [], notes: []), confidence: 0,
                limitation: capability, coverage: coverage, samples: samples)
        }
        let centroidValues = measuredParts.compactMap(\.spectralCentroidHz).sorted()
        let flatValues = measuredParts.compactMap(\.spectralFlatness).sorted()
        let tempos = measuredParts.compactMap { $0.tempoBPM == nil ? nil : $0 }.sorted { ($0.tempoConfidence) > ($1.tempoConfidence) }
        let bestTempo = tempos.first
        let combined = MeasuredAudioFeatures(
            sampleRate: measuredParts.map(\.sampleRate).reduce(0, +) / Double(measuredParts.count),
            sourceDuration: measuredParts.map(\.sourceDuration).reduce(0, +),
            analyzedSeconds: measuredParts.map(\.analyzedSeconds).reduce(0, +),
            rmsDBFS: measuredParts.map(\.rmsDBFS).reduce(0, +) / Double(measuredParts.count),
            peakDBFS: measuredParts.map(\.peakDBFS).max() ?? -160,
            crestDB: measuredParts.map(\.crestDB).reduce(0, +) / Double(measuredParts.count),
            silenceRatio: measuredParts.map(\.silenceRatio).reduce(0, +) / Double(measuredParts.count),
            spectralCentroidHz: median(centroidValues),
            spectralFlatness: median(flatValues),
            lowEnergy: measuredParts.map(\.lowEnergy).reduce(0, +) / Double(measuredParts.count),
            midEnergy: measuredParts.map(\.midEnergy).reduce(0, +) / Double(measuredParts.count),
            highEnergy: measuredParts.map(\.highEnergy).reduce(0, +) / Double(measuredParts.count),
            tempoBPM: bestTempo?.tempoBPM,
            tempoConfidence: bestTempo?.tempoConfidence ?? 0)
        let inferred = infer(combined)
        let meanConfidence = capped.map { $0.1.confidence }.reduce(0, +) / Double(capped.count)
        let coverageFactor = Double(measuredParts.count) / Double(max(consideredCount, 1))
        let confidence = min(0.9, meanConfidence * (0.45 + 0.55 * coverageFactor))
        return AudioStyleReport(
            algorithmVersion: version, fingerprint: nil, status: .measured, measured: combined, inferred: inferred,
            confidence: confidence, limitation: capability, coverage: coverage, samples: samples)
    }

    public static func unavailableReport(_ reason: String) -> AudioStyleReport {
        AudioStyleReport(
            algorithmVersion: version, fingerprint: nil, status: .unavailable, measured: nil,
            inferred: InferredAudioDescriptors(words: [], notes: []), confidence: 0,
            limitation: capability, coverage: reason, samples: [])
    }

    // MARK: Signal math

    struct FrameEnergy { var linear: Double; var db: Double }
    struct SpectrumSummary { var bins: [Double]; var centroid: Double?; var flatness: Double? }

    static func levels(_ samples: [Float]) -> (rms: Double, peak: Double, crest: Double, silence: Double) {
        guard !samples.isEmpty else { return (-160, -160, 0, 1) }
        var sum = 0.0
        var peak = 0.0
        var silent = 0
        let frame = 1024
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            var frameSum = 0.0
            for sample in samples[index ..< end] {
                let value = Double(sample)
                let abs = abs(value)
                if abs > peak { peak = abs }
                sum += value * value
                frameSum += value * value
            }
            let frameRMS = (frameSum / Double(end - index)).squareRoot()
            if dbfs(frameRMS) < -50 { silent += 1 }
            index = end
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        let frames = max(1, (samples.count + frame - 1) / frame)
        let rmsDB = dbfs(rms)
        let peakDB = dbfs(peak)
        return (rmsDB, peakDB, peakDB - rmsDB, Double(silent) / Double(frames))
    }

    static func frameEnergies(_ samples: [Float], isCancelled: @escaping @Sendable () throws -> Void) -> Result<[FrameEnergy], Error> {
        var frames: [FrameEnergy] = []
        var start = 0
        var windows = 0
        while start + fftSize <= samples.count && windows < 400 {
            if windows % 16 == 0, case .failure(let error) = Result(catching: { try isCancelled() }) {
                return .failure(error)
            }
            var sum = 0.0
            for sample in samples[start ..< start + fftSize] {
                let value = Double(sample)
                sum += value * value
            }
            let linear = (sum / Double(fftSize)).squareRoot()
            frames.append(FrameEnergy(linear: linear, db: dbfs(linear)))
            start += hop
            windows += 1
        }
        return .success(frames)
    }

    static func averageSpectrum(_ samples: [Float], rate: Double, energies: [FrameEnergy], isCancelled: @escaping @Sendable () throws -> Void) throws -> SpectrumSummary {
        var sum = [Double](repeating: 0, count: fftSize / 2)
        var used = 0
        var start = 0
        var index = 0
        while start + fftSize <= samples.count && index < energies.count && used < 200 {
            if used % 16 == 0 { try isCancelled() }
            if energies[index].db > -50 {
                let mags = magnitudeSpectrum(Array(samples[start ..< start + fftSize]))
                for bin in 0 ..< mags.count { sum[bin] += mags[bin] }
                used += 1
            }
            start += hop
            index += 1
        }
        guard used > 0 else { return SpectrumSummary(bins: sum, centroid: nil, flatness: nil) }
        for bin in 0 ..< sum.count { sum[bin] /= Double(used) }
        var weighted = 0.0
        var weight = 0.0
        var logSum = 0.0
        var magSum = 0.0
        var count = 0
        for bin in 1 ..< sum.count {
            let mag = max(sum[bin], 1e-12)
            let freq = Double(bin) * rate / Double(fftSize)
            weighted += freq * mag
            weight += mag
            logSum += log(mag)
            magSum += mag
            count += 1
        }
        let centroid = weight > 0 ? weighted / weight : nil
        let flatness = count > 0 && magSum > 0 ? exp(logSum / Double(count)) / (magSum / Double(count)) : nil
        return SpectrumSummary(bins: sum, centroid: centroid, flatness: flatness)
    }

    static func magnitudeSpectrum(_ frame: [Float]) -> [Double] {
        let n = frame.count
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        let scale = n > 1 ? Double(n - 1) : 1
        for i in 0 ..< n {
            let hann = 0.5 * (1 - cos(2 * Double.pi * Double(i) / scale))
            re[i] = Double(frame[i]) * hann
        }
        transform(&re, &im)
        var mags = [Double](repeating: 0, count: n / 2)
        for k in 0 ..< n / 2 {
            mags[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot()
        }
        return mags
    }

    /// In-place radix-2 FFT. Magnitude does not depend on the sign of the exponent.
    static func transform(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        if n > 1 {
            for i in 1 ..< n {
                var bit = n >> 1
                while j & bit != 0 {
                    j ^= bit
                    bit >>= 1
                }
                j ^= bit
                if i < j {
                    re.swapAt(i, j)
                    im.swapAt(i, j)
                }
            }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let stepRe = cos(angle)
            let stepIm = sin(angle)
            var i = 0
            while i < n {
                var wRe = 1.0
                var wIm = 0.0
                for k in 0 ..< (length / 2) {
                    let right = i + k + length / 2
                    let vRe = re[right] * wRe - im[right] * wIm
                    let vIm = re[right] * wIm + im[right] * wRe
                    let uRe = re[i + k]
                    let uIm = im[i + k]
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[right] = uRe - vRe
                    im[right] = uIm - vIm
                    let nextRe = wRe * stepRe - wIm * stepIm
                    wIm = wRe * stepIm + wIm * stepRe
                    wRe = nextRe
                }
                i += length
            }
            length <<= 1
        }
    }

    static func bandEnergy(_ bins: [Double], rate: Double) -> (low: Double, mid: Double, high: Double) {
        var low = 0.0, mid = 0.0, high = 0.0
        for bin in 1 ..< bins.count {
            let freq = Double(bin) * rate / Double(fftSize)
            let power = bins[bin] * bins[bin]
            if freq < 200 { low += power }
            else if freq < 4000 { mid += power }
            else { high += power }
        }
        let total = low + mid + high
        guard total > 0 else { return (0, 0, 0) }
        return (low / total, mid / total, high / total)
    }

    static func tempoEstimate(_ envelope: [Double], rate: Double) -> (bpm: Double?, confidence: Double) {
        guard envelope.count > 16 else { return (nil, 0) }
        let frameRate = rate / Double(hop)
        let minBPM = 70.0
        let maxBPM = 180.0
        let minLag = max(1, Int((frameRate * 60 / maxBPM).rounded(.down)))
        let maxLag = min(envelope.count / 2, Int((frameRate * 60 / minBPM).rounded(.up)))
        guard maxLag > minLag else { return (nil, 0) }
        var diff = [Double](repeating: 0, count: envelope.count)
        for i in 1 ..< envelope.count { diff[i] = max(0, envelope[i] - envelope[i - 1]) }
        var bestLag = minLag
        var best = 0.0
        var total = 0.0
        var counted = 0
        for lag in minLag ... maxLag {
            var score = 0.0
            var i = 0
            while i + lag < diff.count {
                score += diff[i] * diff[i + lag]
                i += 1
            }
            let half = lag * 2
            if half < diff.count {
                var h = 0.0
                var j = 0
                while j + half < diff.count {
                    h += diff[j] * diff[j + half]
                    j += 1
                }
                score += h * 0.5
            }
            total += score
            counted += 1
            if score > best {
                best = score
                bestLag = lag
            }
        }
        let mean = counted > 0 ? total / Double(counted) : 0
        let confidence = best > 0 ? min(1, max(0, (best - mean) / best)) : 0
        let bpm = 60 * frameRate / Double(bestLag)
        guard confidence >= 0.4, bpm >= minBPM, bpm <= maxBPM else { return (nil, confidence) }
        return (bpm, confidence)
    }

    static func infer(_ measured: MeasuredAudioFeatures) -> InferredAudioDescriptors {
        var words: [String] = []
        var notes: [String] = []
        if let centroid = measured.spectralCentroidHz {
            if centroid < 800 {
                words.append("darker")
                notes.append("Centroid \(Int(centroid.rounded())) Hz is below 800 Hz, so the threshold label is darker.")
            } else if centroid > 2500 {
                words.append("brighter")
                notes.append("Centroid \(Int(centroid.rounded())) Hz is above 2500 Hz, so the threshold label is brighter.")
            } else {
                words.append("midrange")
                notes.append("Centroid \(Int(centroid.rounded())) Hz sits between 800 and 2500 Hz, so the threshold label is midrange.")
            }
        }
        if let flatness = measured.spectralFlatness {
            if flatness < 0.2 {
                words.append("tonal")
                notes.append("Spectral flatness \(String(format: "%.2f", flatness)) is below 0.20, so the threshold label is tonal.")
            } else if flatness > 0.55 {
                words.append("noisy")
                notes.append("Spectral flatness \(String(format: "%.2f", flatness)) is above 0.55, so the threshold label is noisy. That is not an instrument.")
            }
        }
        if measured.crestDB >= 14 {
            words.append("dynamic")
            notes.append("Crest factor \(formatDB(measured.crestDB)) dB is at least 14 dB, so the threshold label is dynamic.")
        } else if measured.crestDB < 8 {
            words.append("compressed")
            notes.append("Crest factor \(formatDB(measured.crestDB)) dB is under 8 dB, so the threshold label is compressed.")
        }
        if measured.lowEnergy >= 0.55 {
            words.append("low-frequency")
            notes.append("\(pct(measured.lowEnergy)) of the spectral energy is below 200 Hz, so the threshold label is low-frequency.")
        }
        if measured.highEnergy >= 0.35 {
            words.append("high-frequency")
            notes.append("\(pct(measured.highEnergy)) of the spectral energy is above 4000 Hz, so the threshold label is high-frequency.")
        }
        if let bpm = measured.tempoBPM, measured.tempoConfidence >= 0.4 {
            if bpm < 90 {
                words.append("slower")
            } else if bpm > 120 {
                words.append("faster")
            } else {
                words.append("midtempo")
            }
            notes.append("Onset spacing suggests \(Int(bpm.rounded())) BPM. That estimate can lock onto half or double time, and it is not a drum-kit detection.")
        }
        return InferredAudioDescriptors(words: words, notes: notes)
    }

    static func failure(_ status: AudioAnalysisStatus, _ note: String) -> AudioAnalysisResult {
        AudioAnalysisResult(
            status: status, measured: nil, inferred: InferredAudioDescriptors(words: [], notes: [note]),
            confidence: 0, coverage: note, samples: [])
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        if values.count % 2 == 1 { return values[mid] }
        return (values[mid - 1] + values[mid]) / 2
    }

    static func dbfs(_ amplitude: Double) -> Double {
        guard amplitude > 1e-10 else { return -160 }
        return 20 * log10(amplitude)
    }
}

public struct AudioAnalysisResult: Sendable, Equatable {
    public var status: AudioAnalysisStatus
    public var measured: MeasuredAudioFeatures?
    public var inferred: InferredAudioDescriptors
    public var confidence: Double
    public var coverage: String
    public var samples: [AudioTrackSample]

    public init(status: AudioAnalysisStatus, measured: MeasuredAudioFeatures?, inferred: InferredAudioDescriptors, confidence: Double, coverage: String, samples: [AudioTrackSample]) {
        self.status = status
        self.measured = measured
        self.inferred = inferred
        self.confidence = confidence
        self.coverage = coverage
        self.samples = samples
    }

    public func report(fingerprint: AudioFingerprint? = nil) -> AudioStyleReport {
        AudioStyleReport(
            algorithmVersion: AudioStyleAnalyzer.version, fingerprint: fingerprint, status: status, measured: measured,
            inferred: inferred, confidence: confidence, limitation: AudioStyleAnalyzer.capability, coverage: coverage, samples: samples)
    }
}

func formatSeconds(_ value: Double) -> String { String(format: "%.1fs", value) }
func formatDB(_ value: Double) -> String { String(format: "%.1f", value) }
func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

enum PCMWav {
    static func writeMono16(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = Data()
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var unit = Int16(clamped * 32767).littleEndian
            pcm.append(Data(bytes: &unit, count: 2))
        }
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        append32(&data, UInt32(36 + pcm.count))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        append32(&data, 16)
        append16(&data, 1)
        append16(&data, 1)
        append32(&data, UInt32(sampleRate))
        append32(&data, UInt32(sampleRate * 2))
        append16(&data, 2)
        append16(&data, 16)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        append32(&data, UInt32(pcm.count))
        data.append(pcm)
        try data.write(to: url)
    }

    static func read(url: URL, maxSeconds: Double) throws -> PCMBuffer {
        let data = try Data(contentsOf: url)
        guard data.count >= 44, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" else { throw AudioReadError.unreadable }
        var offset = 12
        var format: UInt16 = 0
        var channels: UInt16 = 0
        var rate: UInt32 = 0
        var bits: UInt16 = 0
        var pcm: Data?
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let size = Int(read32(data, offset + 4))
            let start = offset + 8
            guard size >= 0, start + size <= data.count else { throw AudioReadError.unreadable }
            if id == "fmt ", size >= 16 {
                format = read16(data, start)
                channels = read16(data, start + 2)
                rate = read32(data, start + 4)
                bits = read16(data, start + 14)
            } else if id == "data" {
                pcm = data.subdata(in: start ..< start + size)
            }
            offset = start + size + (size % 2)
        }
        guard format == 1, channels >= 1, channels <= 2, bits == 16, rate >= 2000, let pcm else { throw AudioReadError.unsupported }
        let frameBytes = Int(channels) * 2
        guard frameBytes > 0, pcm.count >= frameBytes else { throw AudioReadError.unreadable }
        let frames = pcm.count / frameBytes
        let source = Double(frames) / Double(rate)
        let limit = maxSeconds > 0 ? min(frames, Int(maxSeconds * Double(rate))) : frames
        var samples = [Float]()
        samples.reserveCapacity(limit)
        pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for frame in 0 ..< limit {
                var sum = 0.0
                for channel in 0 ..< Int(channels) {
                    let unit = Int16(littleEndian: ints[frame * Int(channels) + channel])
                    sum += Double(unit) / 32767
                }
                samples.append(Float(sum / Double(channels)))
            }
        }
        return PCMBuffer(samples: samples, sampleRate: Double(rate), sourceDuration: source)
    }

    private static func append16(_ data: inout Data, _ value: UInt16) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: 2))
    }

    private static func append32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: 4))
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

enum AudioSampleReader {
    static func read(url: URL, maxSeconds: Double, isCancelled: @escaping @Sendable () throws -> Void) throws -> PCMBuffer {
        try isCancelled()
        let header = try? Data(contentsOf: url, options: [.mappedIfSafe]).prefix(12)
        if let header, header.count >= 4, String(decoding: header.prefix(4), as: UTF8.self) == "RIFF" {
            return try PCMWav.read(url: url, maxSeconds: maxSeconds)
        }
        return try readCompressed(url: url, maxSeconds: maxSeconds, isCancelled: isCancelled)
    }

    private static func readCompressed(url: URL, maxSeconds: Double, isCancelled: @escaping @Sendable () throws -> Void) throws -> PCMBuffer {
        try isCancelled()
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioReadError.unreadable }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate >= 2000, channels > 0 else { throw AudioReadError.unsupported }
        let totalFrames = file.length
        guard totalFrames > 0 else { throw AudioReadError.unreadable }
        let maxFrames = AVAudioFramePosition(maxSeconds * rate)
        let target = min(totalFrames, max(0, maxFrames))
        let chunk = AVAudioFrameCount(max(1, min(rate, Double(target))))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw AudioReadError.unreadable }
        guard let pointers = buffer.floatChannelData else { throw AudioReadError.unsupported }
        var mono: [Float] = []
        mono.reserveCapacity(Int(target))
        var remaining = target
        while remaining > 0 {
            try isCancelled()
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: count) } catch { throw AudioReadError.unreadable }
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            for frame in 0 ..< got {
                var sum = 0 as Float
                for channel in 0 ..< channels { sum += pointers[channel][frame] }
                mono.append(sum / Float(channels))
            }
            remaining -= AVAudioFramePosition(got)
        }
        guard !mono.isEmpty else { throw AudioReadError.unreadable }
        return PCMBuffer(samples: mono, sampleRate: rate, sourceDuration: Double(totalFrames) / rate)
    }
}

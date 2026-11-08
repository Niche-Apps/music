import Foundation
import StandardKit

/// Decodes only the files the listener picked and runs the local analyzer off the main thread.
/// A saved report is reused when the file size, modification time, sample count, and algorithm version still match.
enum LocalAudioMeasure {
    @MainActor
    static func measure(
        urls: [(label: String, url: URL)], considered: Int, cached: AudioStyleReport?,
        progress: @MainActor (String) -> Void
    ) async throws -> AudioStyleReport {
        if urls.isEmpty {
            let reason = considered == 0
                ? "No audio file is available for this selection. Tags are metadata only, not a measurement."
                : "Audio was listed but no readable file could be opened. Tags are metadata only."
            return AudioStyleAnalyzer.unavailableReport(reason)
        }
        var fingerprints: [AudioFingerprint] = []
        for item in urls.prefix(AudioStyleAnalyzer.maxTracks) {
            if let fingerprint = AudioFingerprint.file(at: item.url) { fingerprints.append(fingerprint) }
        }
        let identity = AudioFingerprint.combine(fingerprints).tagging(extra: considered)
        if fingerprints.count == min(urls.count, AudioStyleAnalyzer.maxTracks), let cached, cached.matches(identity) {
            progress("Using the saved audio measurement")
            return cached
        }
        let capped = Array(urls.prefix(AudioStyleAnalyzer.maxTracks))
        var parts: [(String, AudioAnalysisResult)] = []
        for (index, item) in capped.enumerated() {
            try Task.checkCancellation()
            progress("Measuring audio \(index + 1) of \(capped.count)")
            let label = AudioStyleAnalyzer.safeLabel(item.label, index: index + 1)
            parts.append((label, try await readAndAnalyze(url: item.url)))
        }
        var report = AudioStyleAnalyzer.aggregate(parts, considered: max(considered, urls.count))
        report.fingerprint = identity
        return report
    }

    private static func readAndAnalyze(url: URL) async throws -> AudioAnalysisResult {
        let task = Task.detached(priority: .utility) { () throws -> AudioAnalysisResult in
            do {
                let decoded = try AudioSampleReader.read(url: url, maxSeconds: AudioStyleAnalyzer.maxSeconds) {
                    try Task.checkCancellation()
                }
                return try AudioStyleAnalyzer.analyze(decoded.buffer) { try Task.checkCancellation() }
            } catch is CancellationError {
                throw CancellationError()
            } catch AudioReadError.unsupported {
                return AudioAnalysisResult(
                    status: .unsupported, measured: nil,
                    inferred: InferredAudioDescriptors(words: [], notes: ["This file’s encoding isn’t one the analyzer can decode."]),
                    confidence: 0, coverage: "Unsupported audio encoding.", samples: [])
            } catch {
                return AudioAnalysisResult(
                    status: .unreadable, measured: nil,
                    inferred: InferredAudioDescriptors(words: [], notes: ["The file could not be decoded."]),
                    confidence: 0, coverage: "The file could not be decoded.", samples: [])
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

extension AudioFingerprint {
    func tagging(extra: Int) -> AudioFingerprint {
        var hash = signature
        var bits = UInt64(extra)
        for _ in 0 ..< 8 {
            hash ^= bits & 0xFF
            hash &*= 1099511628211
            bits >>= 8
        }
        return AudioFingerprint(signature: hash, algorithmVersion: algorithmVersion, partCount: partCount)
    }
}

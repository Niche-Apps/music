import Foundation
import Testing
@testable import StandardKit

@Suite struct AudioStyleAnalysisTests {
    func tone(frequency: Double, seconds: Double, rate: Double = 22050, amplitude: Float = 0.5) -> PCMBuffer {
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            samples[index] = amplitude * Float(sin(phase))
        }
        return PCMBuffer(samples: samples, sampleRate: rate, sourceDuration: seconds)
    }

    func noise(seconds: Double, rate: Double = 22050, seed: UInt64 = 0xC0FFEE) -> PCMBuffer {
        var state = seed
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            state = state &* 6364136223846793005 &+ 1
            let unit = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            samples[index] = unit * 2 - 1
        }
        return PCMBuffer(samples: samples, sampleRate: rate, sourceDuration: seconds)
    }

    func clicks(bpm: Double, seconds: Double, rate: Double = 22050) -> PCMBuffer {
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        let interval = 60 / bpm
        var beat = 0.0
        while beat < seconds {
            let start = Int(beat * rate)
            for offset in 0 ..< 500 where start + offset < count {
                samples[start + offset] = 0.9
            }
            beat += interval
        }
        return PCMBuffer(samples: samples, sampleRate: rate, sourceDuration: seconds)
    }

    @Test func sineCentroidIsNearTheToneAndFlatnessIsLow() throws {
        let low = try AudioStyleAnalyzer.analyze(tone(frequency: 440, seconds: 2))
        let high = try AudioStyleAnalyzer.analyze(tone(frequency: 3000, seconds: 2))
        #expect(low.status == .measured)
        #expect(high.status == .measured)
        let lowCentroid = try #require(low.measured?.spectralCentroidHz)
        let highCentroid = try #require(high.measured?.spectralCentroidHz)
        #expect(abs(lowCentroid - 440) < 80)
        #expect(abs(highCentroid - 3000) < 200)
        #expect((low.measured?.spectralFlatness ?? 1) < 0.35)
        #expect((high.measured?.spectralFlatness ?? 1) < 0.35)
        #expect(low.inferred.words.contains("darker"))
        #expect(low.inferred.words.contains("tonal"))
        #expect(high.inferred.words.contains("brighter"))
        let rms = try #require(low.measured?.rmsDBFS)
        #expect(abs(rms - (-9.0)) < 1.5)
        #expect(low.inferred.words.allSatisfy { AudioStyleAnalyzer.inferredWhitelist.contains($0) })
        #expect(!low.inferred.words.contains("guitar"))
        #expect(!low.promptReadyLimitationClaimsAnInstrument)
    }

    @Test func noiseIsFlatterThanATone() throws {
        let tone = try AudioStyleAnalyzer.analyze(tone(frequency: 440, seconds: 1.5))
        let noise = try AudioStyleAnalyzer.analyze(noise(seconds: 1.5))
        let toneFlat = try #require(tone.measured?.spectralFlatness)
        let noiseFlat = try #require(noise.measured?.spectralFlatness)
        #expect(noiseFlat > toneFlat + 0.15)
        #expect(noise.status == .measured)
    }

    @Test func silenceShortEmptyAndCorruptSamplesAreLabeled() throws {
        let silent = try AudioStyleAnalyzer.analyze(PCMBuffer(samples: [Float](repeating: 0, count: 22050 * 2), sampleRate: 22050))
        #expect(silent.status == .silence)
        #expect(silent.inferred.words.isEmpty)
        #expect((silent.measured?.silenceRatio ?? 0) > 0.9)

        let short = try AudioStyleAnalyzer.analyze(tone(frequency: 440, seconds: 0.1))
        #expect(short.status == .tooShort)
        #expect(short.inferred.words.isEmpty)
        #expect(short.confidence < 0.3)

        let empty = try AudioStyleAnalyzer.analyze(PCMBuffer(samples: [], sampleRate: 22050))
        #expect(empty.status == .unreadable)
        let broken = try AudioStyleAnalyzer.analyze(PCMBuffer(samples: [0, .nan, 1], sampleRate: 22050))
        #expect(broken.status == .unreadable)
        let weirdRate = try AudioStyleAnalyzer.analyze(PCMBuffer(samples: [0.1, 0.2], sampleRate: 0))
        #expect(weirdRate.status == .unsupported)
    }

    @Test func analysisIsCappedAndCancellable() throws {
        let long = tone(frequency: 440, seconds: 25, rate: 8000)
        let capped = try AudioStyleAnalyzer.analyze(long)
        #expect((capped.measured?.analyzedSeconds ?? 99) <= AudioStyleAnalyzer.maxSeconds + 0.05)
        #expect((capped.measured?.sourceDuration ?? 0) >= 25)
        #expect(capped.coverage.contains("not a full listen") == false)
        #expect(capped.coverage.contains("20"))

        #expect(throws: CancellationError.self) {
            _ = try AudioStyleAnalyzer.analyze(tone(frequency: 440, seconds: 2)) { throw CancellationError() }
        }
        let many = (0 ..< 10).map { _ in tone(frequency: 440, seconds: 0.5, rate: 8000) }
        let kept = try AudioStyleAnalyzer.analyzeAll(many)
        #expect(kept.count == AudioStyleAnalyzer.maxTracks)
        var seen = 0
        #expect(throws: CancellationError.self) {
            _ = try AudioStyleAnalyzer.analyzeAll([tone(frequency: 440, seconds: 0.5, rate: 8000), tone(frequency: 880, seconds: 0.5, rate: 8000)]) {
                seen += 1
                if seen > 1 { throw CancellationError() }
            }
        }
    }

    @Test func clicksLandNearTheRequestedTempo() throws {
        let result = try AudioStyleAnalyzer.analyze(clicks(bpm: 120, seconds: 6))
        let bpm = try #require(result.measured?.tempoBPM)
        #expect(abs(bpm - 120) < 15)
        #expect((result.measured?.tempoConfidence ?? 0) >= 0.4)
        #expect(result.inferred.notes.contains { $0.contains("not a drum-kit") })
    }

    @Test func aggregateReportsCoverageAndDoesNotInventAFullListen() throws {
        let one = try AudioStyleAnalyzer.analyze(tone(frequency: 200, seconds: 1, rate: 16000))
        let two = try AudioStyleAnalyzer.analyze(tone(frequency: 2000, seconds: 1, rate: 16000))
        let report = AudioStyleAnalyzer.aggregate([("Song A", one), ("/Users/private/secret.wav", two)], considered: 5)
        #expect(report.coverage.contains("Sampled 2 of 5"))
        #expect(report.coverage.contains("not a full listen"))
        #expect(!report.coverage.contains("/Users"))
        #expect(report.samples.contains { $0.label == "Track 2" })
        #expect(report.samples.allSatisfy { !$0.label.contains("/") })
        let centroid = try #require(report.measured?.spectralCentroidHz)
        #expect(centroid > 200 && centroid < 2000)
    }

    @Test func savedMeasurementIsReusedOnlyWhileTheFileIdentityMatches() throws {
        let report = try AudioStyleAnalyzer.analyze(tone(frequency: 440, seconds: 1)).report(
            fingerprint: AudioFingerprint.file(byteCount: 100, modifiedAt: 10))
        let same = AudioFingerprint.file(byteCount: 100, modifiedAt: 10)
        let changed = AudioFingerprint.file(byteCount: 101, modifiedAt: 10)
        #expect(report.matches(same))
        #expect(!report.matches(changed))
        #expect(!report.matches(AudioFingerprint(signature: same.signature, algorithmVersion: 99, partCount: 1)))
    }

    @Test func wavRoundTripKeepsTheTone() throws {
        let buffer = tone(frequency: 440, seconds: 1.2, rate: 16000)
        let url = FileManager.default.temporaryDirectory.appending(path: "tone-\(UUID().uuidString).wav")
        try PCMWav.writeMono16(samples: buffer.samples, sampleRate: 16000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try AudioSampleReader.read(url: url, maxSeconds: 20) {}
        #expect(abs(read.sampleRate - 16000) < 1)
        let result = try AudioStyleAnalyzer.analyze(read)
        let centroid = try #require(result.measured?.spectralCentroidHz)
        #expect(abs(centroid - 440) < 80)
        let junk = FileManager.default.temporaryDirectory.appending(path: "bad-\(UUID().uuidString).wav")
        try Data("not a wave".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(throws: AudioReadError.self) {
            _ = try PCMWav.read(url: junk, maxSeconds: 5)
        }
    }

    @Test func promptsKeepMeasurementsSeparateFromTagsAndHonorVocalOnly() throws {
        let measured = try AudioStyleAnalyzer.analyze(tone(frequency: 3000, seconds: 1.5)).report()
        var cue = StyleCue(
            kind: .file, title: "Bright", artistName: "A", genres: ["rock"], styleTags: "distorted guitar, drums",
            note: "File tags, separate from the audio measurement.", audio: measured)
        if var audio = cue.audio {
            audio.inferred.words = ["brighter", "noisy", "guitar"]
            cue.audio = audio
        }
        let vocal = StylePipeline.promptAddendum(vocalOnly: true, cues: [cue])
        #expect(vocal.contains("Measured audio"))
        #expect(vocal.contains("Style reference metadata"))
        #expect(vocal.contains("do not identify instruments"))
        #expect(vocal.contains("brighter"))
        #expect(vocal.contains("Spectral centroid"))
        #expect(!vocal.contains("noisy"))
        #expect(!vocal.contains("distorted guitar"))
        #expect(!vocal.contains("/Users"))
        #expect(!vocal.contains("BEGIN_BOOKMARK"))
        let encoded = StyleCue.encode([cue])
        #expect(!encoded.contains("BEGIN_BOOKMARK"))
        #expect(encoded.contains("spectralCentroidHz"))

        let style = RecordingStyle.prepare(
            tags: "electropop, synthesizer, drum machine", genres: ["electropop"], voice: "female alto vocal",
            isInstrumental: true, isCustom: true, vocalOnly: true, cues: [cue])
        #expect(!style.isInstrumental)
        #expect(style.style.contains("brighter"))
        #expect(style.style.contains("a cappella"))
        #expect(!style.style.lowercased().contains("guitar"))
        #expect(!style.style.lowercased().contains("drum"))
        #expect(!style.style.contains("noisy"))

        let open = cue.audio?.engineTags(vocalOnly: false) ?? []
        #expect(open.contains("brighter"))
        #expect(open.contains("noisy"))
        #expect(!open.contains("guitar"))
    }

    @Test func oldReferencesDecodeWithoutAnAudioReport() throws {
        let json = #"{"id":"c","kind":"file","title":"Old Tape","artistName":"Ada","albumTitle":"","genres":["folk"],"styleTags":"guitar","mood":"warm","vocal":"","isInstrumental":false,"note":"tags"}"#
        let cue = try JSONDecoder().decode(StyleCue.self, from: Data(json.utf8))
        #expect(cue.audio == nil)
        #expect(cue.title == "Old Tape")
        let reference = StyleReference(cue: cue, path: "/Users/private/old.wav")
        let db = try AppDatabase(url: FileManager.default.temporaryDirectory.appending(path: "audio-db-\(UUID())/Library.sqlite"))
        try StyleReferenceStore.save(db, [reference])
        let loaded = StyleReferenceStore.load(db)
        #expect(loaded.first?.cue.audio == nil)
        #expect(loaded.first?.path == "/Users/private/old.wav")
        let prompt = StylePipeline.promptAddendum(vocalOnly: false, cues: loaded.compactMap(\.promptCue))
        #expect(prompt.contains("Style reference metadata"))
        #expect(!prompt.contains("Measured audio"))
        #expect(!prompt.contains("/Users/private/old.wav"))
    }
}

private extension AudioAnalysisResult {
    var promptReadyLimitationClaimsAnInstrument: Bool {
        let text = (inferred.notes + inferred.words).joined(separator: " ").lowercased()
        return text.contains("guitar") || text.contains("this is a vocal") || text.contains("genre is")
    }
}

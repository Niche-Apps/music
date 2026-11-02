import AVFoundation
import EngineProtocol
import Foundation
import MLX
import YuEKit

// StandardMusicEngine: a helper process that owns the GPU and the YuE2 model.
// Commands arrive as JSON lines on stdin; events leave as JSON lines on stdout.

setvbuf(stdout, nil, _IOFBF, 1 << 16)
let outputLock = NSLock()

func send(_ event: EngineEvent) {
    outputLock.lock()
    defer { outputLock.unlock() }
    FileHandle.standardOutput.write(EngineCoding.encode(event))
}

final class CancellationFlags: @unchecked Sendable {
    private var ids = Set<String>()
    private let lock = NSLock()
    func cancel(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func isCancelled(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    func clear(_ id: String) { lock.withLock { _ = ids.remove(id) } }
}

final class CommandQueue: @unchecked Sendable {
    private var items: [EngineCommand] = []
    private let condition = NSCondition()

    func push(_ command: EngineCommand) {
        condition.lock()
        items.append(command)
        condition.signal()
        condition.unlock()
    }

    func pop() -> EngineCommand {
        condition.lock()
        while items.isEmpty { condition.wait() }
        let item = items.removeFirst()
        condition.unlock()
        return item
    }
}

let flags = CancellationFlags()
let queue = CommandQueue()

// Reader thread: control commands (cancel) take effect immediately; work is queued.
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        guard let command = EngineCoding.decode(EngineCommand.self, line: Data(line.utf8)) else {
            send(.log("Unreadable command"))
            continue
        }
        switch command {
        case .cancel(let id): flags.cancel(id)
        case .shutdown:
            queue.push(.shutdown)
        default: queue.push(command)
        }
    }
    // Parent closed stdin: the app is gone. `_exit` skips static destructors, which would tear down
    // Metal underneath a render still running on the main thread and crash.
    _exit(0)
}

// MARK: Audio post-processing

/// Gated RMS loudness in dB (BS.1770-style blocks and gates, without K-weighting).
func loudness(_ samples: [Float]) -> Double {
    let block = 19200 * 2  // 400 ms stereo interleaved
    let hop = block / 4
    var energies: [Double] = []
    var start = 0
    while start + block <= samples.count {
        var sum = 0.0
        for i in stride(from: start, to: start + block, by: 1) { sum += Double(samples[i] * samples[i]) }
        energies.append(sum / Double(block))
        start += hop
    }
    func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(max(e, 1e-12)) + 3.01 }
    let absolute = energies.filter { lufs($0) > -70 }
    guard !absolute.isEmpty else { return -70 }
    let mean = absolute.reduce(0, +) / Double(absolute.count)
    let relative = absolute.filter { lufs($0) > lufs(mean) - 10 }
    guard !relative.isEmpty else { return lufs(mean) }
    return lufs(relative.reduce(0, +) / Double(relative.count))
}

/// Trims leading silence, removes dead air at the end, and applies short fades (longer if truncated).
func polish(_ samples: [Float], truncated: Bool) -> [Float] {
    let threshold: Float = 0.0015
    let frames = samples.count / 2
    var first = 0
    while first < frames, abs(samples[first * 2]) < threshold, abs(samples[first * 2 + 1]) < threshold { first += 1 }
    var last = frames - 1
    while last > first, abs(samples[last * 2]) < threshold, abs(samples[last * 2 + 1]) < threshold { last -= 1 }
    first = max(0, first - 2400)  // keep 50 ms of breath before the downbeat
    last = min(frames - 1, last + sampleRate)  // keep a second of natural tail
    var out = Array(samples[(first * 2) ..< ((last + 1) * 2)])
    let n = out.count / 2
    let fadeIn = min(n, 240)
    for i in 0 ..< fadeIn {
        let g = Float(i) / Float(fadeIn)
        out[i * 2] *= g
        out[i * 2 + 1] *= g
    }
    let fadeOut = min(n, truncated ? sampleRate * 4 : sampleRate / 4)
    for i in 0 ..< fadeOut {
        let g = Float(i) / Float(fadeOut)
        let j = n - 1 - i
        out[j * 2] *= g * g
        out[j * 2 + 1] *= g * g
    }
    return out
}

func writeM4A(_ samples: [Float], to url: URL) throws {
    let frames = AVAudioFrameCount(samples.count / 2)
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let left = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    for i in 0 ..< Int(frames) {
        left[i] = samples[i * 2]
        right[i] = samples[i * 2 + 1]
    }
    let partial = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).partial.m4a")
    try? FileManager.default.removeItem(at: partial)
    do {
        let file = try AVAudioFile(
            forWriting: partial,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try FileManager.default.moveItem(at: partial, to: url)
}

// MARK: Main loop

Memory.cacheLimit = 1 << 30
var pipeline: Yue2Pipeline?
var modelPath: String?

@MainActor func ensureLoaded() throws -> Yue2Pipeline {
    if let pipeline { return pipeline }
    guard let modelPath else { throw NSError(domain: "Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "No model path."]) }
    let start = Date()
    let loaded = try Yue2Pipeline(directory: URL(fileURLWithPath: modelPath))
    pipeline = loaded
    send(.ready(loadSeconds: Date().timeIntervalSince(start)))
    return loaded
}

while true {
    switch queue.pop() {
    case .load(let path):
        modelPath = path
        do { _ = try ensureLoaded() } catch { send(.failed(id: nil, message: error.localizedDescription)) }
    case .generate(let job):
        if flags.isCancelled(job.id) {
            flags.clear(job.id)
            send(.cancelled(id: job.id))
            continue
        }
        let start = Date()
        do {
            let pipe = try ensureLoaded()
            let request = SongRequest(
                style: job.style, lyrics: job.lyrics, planning: ScorePlanning(rawValue: job.planning) ?? .full,
                seed: job.seed, steps: job.steps, maxSemanticTokens: job.maxSemanticTokens)
            var lastSent = Date.distantPast
            let song = try pipe.generate(
                request,
                progress: { p in
                    let now = Date()
                    guard now.timeIntervalSince(lastSent) > 0.25 || p.stageFraction >= 1 else { return }
                    lastSent = now
                    send(
                        .progress(
                            id: job.id,
                            EngineProgress(
                                stage: p.stage.rawValue, stageFraction: p.stageFraction, overall: p.overall * 0.99,
                                estimatedSongSeconds: p.estimatedSongSeconds, elapsed: now.timeIntervalSince(start))))
                }, isCancelled: { flags.isCancelled(job.id) })
            send(.progress(id: job.id, EngineProgress(stage: "encoding", stageFraction: 0, overall: 0.995, estimatedSongSeconds: song.duration, elapsed: Date().timeIntervalSince(start))))
            let polished = polish(song.samples, truncated: song.truncated)
            try writeM4A(polished, to: URL(fileURLWithPath: job.outputPath))
            send(
                .finished(
                    EngineResult(
                        id: job.id, duration: Double(polished.count / 2) / Double(sampleRate), loudness: loudness(polished),
                        seconds: Date().timeIntervalSince(start), truncated: song.truncated, abc: song.abc)))
        } catch is GenerationCancelled {
            send(.cancelled(id: job.id))
        } catch {
            send(.failed(id: job.id, message: error.localizedDescription))
        }
        flags.clear(job.id)
        Memory.clearCache()
    case .cancel:
        break
    case .shutdown:
        exit(0)
    }
}

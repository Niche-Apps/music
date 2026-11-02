import AVFoundation
import Foundation
import OSLog

let audioLog = Logger(subsystem: "com.standardmusic", category: "audio")

/// AVAudioEngine output: one file at a time, seekable, with a gain stage for loudness
/// normalisation and a level meter for visuals.
@MainActor
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 0)
    private var file: AVAudioFile?
    private var segmentStart: AVAudioFramePosition = 0
    private var token = 0
    private var pausedTime: Double?
    /// Last position read while rendering, and whether the listener wants sound — both survive the
    /// engine stopping during an output-device change.
    private var lastKnownTime: Double = 0
    private var wantsPlayback = false

    /// Called when the current file plays to the end.
    var onFinished: (() -> Void)?
    /// Smoothed output level 0…1, updated ~30×/s while playing.
    private(set) var level: Float = 0
    var onLevel: ((Float) -> Void)?

    init() {
        engine.attach(node)
        engine.attach(eq)
        engine.connect(node, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        Self.installLevelTap(on: engine.mainMixerNode) { [weak self] rms in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = self.level * 0.6 + min(rms * 3, 1) * 0.4
                self.onLevel?(self.level)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: Double {
        if let pausedTime { return pausedTime }
        guard let file, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return Double(segmentStart) / (file?.processingFormat.sampleRate ?? 48000) }
        let frames = segmentStart + playerTime.sampleTime
        let t = min(Double(max(frames, 0)) / file.processingFormat.sampleRate, duration)
        lastKnownTime = t
        return t
    }

    var isPlaying: Bool { node.isPlaying && pausedTime == nil }

    /// Output gain in dB applied after the player (loudness normalisation).
    var gainDB: Float {
        get { eq.globalGain }
        set { eq.globalGain = max(-24, min(newValue, 12)) }
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func load(_ url: URL, at time: Double = 0) throws {
        stopNode()
        file = try AVAudioFile(forReading: url)
        pausedTime = time
        lastKnownTime = time
        schedule(from: time)
    }

    func play() {
        guard file != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            audioLog.error("Engine start failed: \(error.localizedDescription)")
            return
        }
        pausedTime = nil
        wantsPlayback = true
        node.play()
    }

    func pause() {
        guard file != nil else { return }
        wantsPlayback = false
        let t = currentTime
        // Re-scheduling from the paused position keeps time accurate across output route changes.
        stopNode()
        pausedTime = t
        schedule(from: t)
    }

    func seek(to time: Double) {
        guard file != nil else { return }
        let wasPlaying = wantsPlayback
        stopNode()
        pausedTime = time
        lastKnownTime = time
        schedule(from: time)
        if wasPlaying { play() }
    }

    func stop() {
        stopNode()
        file = nil
        pausedTime = nil
        wantsPlayback = false
        segmentStart = 0
    }

    private func stopNode() {
        token += 1
        node.stop()
    }

    private func schedule(from time: Double) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, min(time, duration)) * rate)
        let count = AVAudioFrameCount(max(0, file.length - start))
        segmentStart = start
        guard count > 0 else {
            finished(token)
            return
        }
        let current = token
        Self.schedule(node, file, start: start, count: count) { [weak self] in
            Task { @MainActor [weak self] in self?.finished(current) }
        }
    }

    private func finished(_ forToken: Int) {
        guard forToken == token else { return }
        pausedTime = duration
        wantsPlayback = false
        onFinished?()
    }

    private func handleConfigurationChange() {
        guard file != nil else { return }
        let wasPlaying = wantsPlayback
        let t = pausedTime ?? lastKnownTime
        stopNode()
        pausedTime = t
        schedule(from: t)
        if wasPlaying { play() }
    }
}

extension AudioOutput {
    /// The tap runs on a realtime messenger queue, so its closure must not inherit main-actor isolation.
    nonisolated private static func installLevelTap(on mixer: AVAudioMixerNode, _ report: @escaping @Sendable (Float) -> Void) {
        mixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
            report(sqrt(sum / Float(max(n / 4, 1))))
        }
    }

    /// AVAudioPlayerNode calls back on its own queue.
    nonisolated private static func schedule(
        _ node: AVAudioPlayerNode, _ file: AVAudioFile, start: AVAudioFramePosition, count: AVAudioFrameCount,
        done: @escaping @Sendable () -> Void
    ) {
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            done()
        }
    }
}

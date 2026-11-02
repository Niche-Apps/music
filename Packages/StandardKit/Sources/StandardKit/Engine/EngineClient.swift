import EngineProtocol
import Foundation
import OSLog

let engineLog = Logger(subsystem: "com.standardmusic", category: "engine")

public enum EngineError: Error, LocalizedError {
    case missingExecutable
    case missingModel
    case crashed(String)
    case failed(String)
    case cancelled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: "The music engine program couldn’t be found, or isn’t executable."
        case .timedOut: "The engine didn’t report that it was ready."
        case .missingModel: "The music model isn't installed yet."
        case .crashed(let m): "The music engine stopped unexpectedly. \(m)"
        case .failed(let m): m
        case .cancelled: "Cancelled"
        }
    }
}

/// Owns the engine helper process: the bundled `StandardMusicEngine`, or a custom engine the
/// listener configured. One song renders at a time; the process is started on demand and stopped
/// after a period of inactivity to give memory back to the system.
public actor EngineClient {
    private var executableURL: URL
    private var arguments: [String] = []
    private var probing: CheckedContinuation<Double, Error>?
    private let stderrTail = StderrTail()
    private var process: Process?
    private var stdin: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var pendingCancels = Set<String>()
    private var running: (job: EngineJob, continuation: CheckedContinuation<EngineResult, Error>, progress: @Sendable (EngineProgress) -> Void)?
    private var idleTask: Task<Void, Never>?
    private var loadedModel: String?
    public var idleTimeout: Duration = .seconds(300)

    public init(executableURL: URL) {
        self.executableURL = executableURL
        // A helper killed mid-write must not take the app down with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    public var isRunning: Bool { process?.isRunning == true }

    public func setIdleTimeout(_ timeout: Duration) { idleTimeout = timeout }

    /// Switches to another engine program. A running helper for the old one is stopped first,
    /// unless it's mid-song, in which case the switch applies from the next song.
    public func configure(executable: URL, arguments: [String] = []) {
        guard executable != executableURL || arguments != self.arguments else { return }
        executableURL = executable
        self.arguments = arguments
        if running == nil { shutdown() } else { restartAfterCurrentJob = true }
    }

    private var restartAfterCurrentJob = false

    /// Launches the engine, asks it to load `modelDirectory`, and waits for it to say it's ready.
    /// Returns the load time in seconds. Used by Settings › Studio › Test Engine.
    public func probe(modelDirectory: URL, timeout: Duration = .seconds(180)) async throws -> Double {
        guard running == nil, probing == nil else { throw EngineError.failed("The studio is busy recording. Try again in a moment.") }
        shutdown()
        try launchIfNeeded()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.finishProbe(.failure(EngineError.timedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            probing = continuation
            loadedModel = modelDirectory.path
            send(.load(modelPath: modelDirectory.path))
        }
    }

    private func finishProbe(_ result: Result<Double, Error>) {
        guard let probing else { return }
        self.probing = nil
        probing.resume(with: result)
        scheduleIdleShutdown()
    }

    /// Renders one song. Throws `EngineError.cancelled` if cancelled.
    public func render(
        _ job: EngineJob, modelDirectory: URL, progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> EngineResult {
        idleTask?.cancel()
        if pendingCancels.remove(job.id) != nil { throw EngineError.cancelled }
        try launchIfNeeded()
        if loadedModel != modelDirectory.path {
            send(.load(modelPath: modelDirectory.path))
            loadedModel = modelDirectory.path
        }
        defer {
            applyPendingRestart()
            scheduleIdleShutdown()
        }
        lastEvent = Date()
        startWatchdog()
        return try await withCheckedThrowingContinuation { continuation in
            running = (job, continuation, progress)
            send(.generate(job))
        }
    }

    public func cancel(jobID: String) {
        if running?.job.id == jobID {
            send(.cancel(id: jobID))
        } else {
            pendingCancels.insert(jobID)
        }
    }

    /// Forgets a cancel issued before the job reached the engine (e.g. the listener changed their mind back).
    public func clearCancel(jobID: String) {
        pendingCancels.remove(jobID)
    }

    public func shutdown() {
        idleTask?.cancel()
        guard let process, process.isRunning else { return }
        send(.shutdown)
        let p = process
        Task {
            try? await Task.sleep(for: .seconds(3))
            if p.isRunning { p.terminate() }
        }
        self.process = nil
        stdin = nil
        loadedModel = nil
    }

    // MARK: Process management

    private func launchIfNeeded() throws {
        if process?.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw EngineError.missingExecutable
        }
        let p = Process()
        p.executableURL = executableURL
        p.arguments = arguments
        p.currentDirectoryURL = executableURL.deletingLastPathComponent()
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        // Keep the end of stderr: for a custom engine (often a Python script) its traceback is the
        // only useful explanation when something goes wrong.
        let errors = Pipe()
        p.standardError = errors
        let tail = stderrTail
        tail.reset()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        var env = ProcessInfo.processInfo.environment
        env["MLX_ENABLE_TF32"] = "0"
        p.environment = env
        p.qualityOfService = .userInitiated
        // Split into lines on the reader's own queue and deliver them through one ordered stream,
        // so large events split across reads can't be reassembled out of order.
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let splitter = LineSplitter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in splitter.append(data) { continuation.yield(line) }
        }
        let owner = ObjectIdentifier(p)
        readerTask = Task { [weak self] in
            for await line in lines {
                await self?.receive(line: line, from: owner)
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let status = proc.terminationStatus
            Task {
                // Let the last of stderr arrive: it usually explains the exit.
                try? await Task.sleep(for: .milliseconds(150))
                await self.processExited(proc, status: status)
            }
        }
        try p.run()
        process = p
        stdin = input.fileHandleForWriting
        loadedModel = nil
        engineLog.info("Engine launched (pid \(p.processIdentifier))")
    }

    private func send(_ command: EngineCommand) {
        guard let stdin else { return }
        do {
            try stdin.write(contentsOf: EngineCoding.encode(command))
        } catch {
            engineLog.error("Failed to write to engine: \(error.localizedDescription)")
        }
    }

    private func receive(line: Data, from owner: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == owner else { return }
        guard let event = EngineCoding.decode(EngineEvent.self, line: line) else {
            engineLog.error("Undecodable engine event (\(line.count) bytes)")
            return
        }
        handle(event)
    }

    private var lastEvent = Date()
    private var watchdog: Task<Void, Never>?

    /// Kills a helper that has gone silent mid-job (hung GPU, deadlock) so the queue can recover.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if await self.isStalled() {
                    engineLog.error("Engine stalled; restarting it")
                    await self.terminateStalled()
                    return
                }
            }
        }
    }

    private func isStalled() -> Bool {
        running != nil && Date().timeIntervalSince(lastEvent) > 600
    }

    private func terminateStalled() {
        process?.terminate()
    }

    private func handle(_ event: EngineEvent) {
        lastEvent = Date()
        switch event {
        case .ready(let seconds):
            engineLog.info("Model ready in \(seconds, format: .fixed(precision: 1))s")
            finishProbe(.success(seconds))
        case .progress(let id, let p):
            if running?.job.id == id { running?.progress(p) }
        case .finished(let result):
            if let run = running, run.job.id == result.id {
                running = nil
                run.continuation.resume(returning: result)
            }
        case .failed(let id, let message):
            engineLog.error("Engine failure: \(message)")
            if id == nil { finishProbe(.failure(EngineError.failed(message))) }
            if let run = running, id == nil || run.job.id == id {
                running = nil
                if id == nil { loadedModel = nil }
                run.continuation.resume(throwing: EngineError.failed(message))
            }
        case .cancelled(let id):
            if let run = running, run.job.id == id {
                running = nil
                run.continuation.resume(throwing: EngineError.cancelled)
            }
        case .log(let message):
            engineLog.debug("\(message)")
        }
    }

    private func processExited(_ proc: Process, status: Int32) {
        engineLog.notice("Engine exited with status \(status)")
        guard process === proc else { return }
        process = nil
        stdin = nil
        loadedModel = nil
        let detail = stderrTail.lastLine.map { " \($0)" } ?? ""
        finishProbe(.failure(EngineError.crashed("Exit code \(status).\(detail)")))
        if let run = running {
            running = nil
            run.continuation.resume(
                throwing: EngineError.crashed(status == 9 ? "It ran out of memory." : "Exit code \(status).\(detail)"))
        }
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await self.shutdownIfIdle()
        }
    }

    private func applyPendingRestart() {
        guard restartAfterCurrentJob else { return }
        restartAfterCurrentJob = false
        shutdown()
    }

    private func shutdownIfIdle() {
        if running == nil { shutdown() }
    }
}

/// The last few kilobytes a helper wrote to stderr.
final class StderrTail: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func reset() { lock.withLock { buffer.removeAll() } }

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > 8192 { buffer = Data(buffer.suffix(8192)) }
        }
    }

    /// The last non-empty line, trimmed to something that fits in an alert.
    var lastLine: String? {
        let text = lock.withLock { String(decoding: buffer, as: UTF8.self) }
        guard let line = text.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else { return nil }
        return String(line.prefix(300))
    }
}

/// Accumulates raw bytes and returns complete newline-terminated lines.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex ..< newline]))
            buffer.removeSubrange(buffer.startIndex ... newline)
        }
        return lines
    }
}

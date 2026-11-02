import Foundation
import OSLog

let modelLog = Logger(subsystem: "com.standardmusic", category: "model")

/// Downloads and verifies the YuE2 MLX weights.
public enum ModelVariant: String, Codable, Sendable, CaseIterable {
    case int8 = "8bit"
    case int4 = "4bit"

    public var directoryName: String { "YuE2-3B-MLX-\(rawValue)" }

    public var displayName: String {
        switch self {
        case .int8: "Studio quality (8-bit, 4.5 GB)"
        case .int4: "Compact (4-bit, 3.6 GB)"
        }
    }

    /// 8-bit needs headroom; Macs with 8 GB of memory get the compact model.
    public static var recommended: ModelVariant {
        ProcessInfo.processInfo.physicalMemory >= 12 << 30 ? .int8 : .int4
    }
}

public struct ModelDownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public var fraction: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }

    public init(receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

public actor ModelStore {
    static let repository = "ahmadw/YuE2-3B-MLX"
    static let files = [
        "config.json", "yue2_generation_config.json", "vae_config.json", "qwen.tiktoken", "vae.safetensors",
        "model.safetensors",
    ]

    public let root: URL
    private var activeDownload: Task<URL, Error>?

    public init(root: URL) {
        self.root = root
    }

    public func directory(for variant: ModelVariant) -> URL {
        root.appending(path: variant.directoryName, directoryHint: .isDirectory)
    }

    public nonisolated func isInstalled(_ variant: ModelVariant) -> Bool {
        let dir = root.appending(path: variant.directoryName, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: dir.appending(path: ".complete").path)
    }

    /// The installed model directory, preferring `preferred`.
    public nonisolated func installedDirectory(preferred: ModelVariant) -> URL? {
        for variant in [preferred] + ModelVariant.allCases where isInstalled(variant) {
            return root.appending(path: variant.directoryName, directoryHint: .isDirectory)
        }
        return nil
    }

    /// Downloads every missing file (resuming partial ones) and marks the variant complete.
    public func install(
        _ variant: ModelVariant, progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        if let activeDownload { return try await activeDownload.value }
        let task = Task { try await self.performInstall(variant, progress: progress) }
        activeDownload = task
        defer { activeDownload = nil }
        return try await task.value
    }

    private func performInstall(
        _ variant: ModelVariant, progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        let dir = directory(for: variant)
        if isInstalled(variant) { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes = try await remoteSizes(variant)
        let total = sizes.values.reduce(0, +)
        var completed: Int64 = 0
        let start = Date()
        for name in Self.files {
            let expected = sizes[name] ?? 0
            let target = dir.appending(path: name)
            if let size = Self.fileSize(target), size == expected, expected > 0 {
                completed += expected
                continue
            }
            let base = completed
            try await download(
                URL(string: "https://huggingface.co/\(Self.repository)/resolve/main/\(variant.rawValue)/\(name)")!,
                to: target, expected: expected
            ) { received in
                let elapsed = max(Date().timeIntervalSince(start), 0.5)
                progress(
                    ModelDownloadProgress(
                        receivedBytes: base + received, totalBytes: total,
                        bytesPerSecond: Double(base + received) / elapsed))
            }
            guard Self.fileSize(target) == expected else {
                throw EngineError.failed("Downloaded \(name) is incomplete. Please try again.")
            }
            completed += expected
        }
        try Data("ok".utf8).write(to: dir.appending(path: ".complete"))
        progress(ModelDownloadProgress(receivedBytes: total, totalBytes: total, bytesPerSecond: 0))
        return dir
    }

    private func remoteSizes(_ variant: ModelVariant) async throws -> [String: Int64] {
        let url = URL(string: "https://huggingface.co/api/models/\(Self.repository)/tree/main/\(variant.rawValue)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var sizes: [String: Int64] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String else { continue }
            let name = (path as NSString).lastPathComponent
            sizes[name] = (entry["size"] as? NSNumber)?.int64Value
                ?? ((entry["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value
        }
        for file in Self.files where sizes[file] == nil {
            throw EngineError.failed("The model repository is missing \(file).")
        }
        return sizes
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Streams to `<target>.partial`, resuming with a Range request when a partial file exists,
    /// and retrying dropped connections with backoff.
    private func download(
        _ url: URL, to target: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let partial = target.appendingPathExtension("partial")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var offset = Self.fileSize(partial) ?? 0
            if offset > expected {
                try? FileManager.default.removeItem(at: partial)
                offset = 0
            }
            do {
                try await FileDownload(url: url, destination: partial, offset: offset, progress: progress).run()
                if let size = Self.fileSize(partial), size >= expected { break }
                throw URLError(.networkConnectionLost)
            } catch let error as URLError where attempt < 12 {
                attempt += 1
                modelLog.notice("Download interrupted (\(error.code.rawValue)); retry \(attempt)")
                try await Task.sleep(for: .seconds(min(30, 2 * attempt)))
            }
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: partial, to: target)
    }
}

/// One HTTP GET streamed to disk through a data delegate (fast, chunked writes).
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    let destination: URL
    let offset: Int64
    let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast
    private var failure: Error?

    init(url: URL, destination: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.offset = offset
        self.progress = progress
    }

    func run() async throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206, let h = try? FileHandle(forWritingTo: destination) else {
            failure = EngineError.failed("Model download failed (HTTP \(status)).")
            completionHandler(.cancel)
            return
        }
        let start = status == 206 ? offset : 0
        try? h.truncate(atOffset: UInt64(start))
        try? h.seekToEnd()
        handle = h
        received = start
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.2 {
            lastReport = Date()
            progress(received)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        progress(received)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

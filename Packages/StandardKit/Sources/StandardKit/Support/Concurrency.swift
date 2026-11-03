import Foundation

/// Limits how many async operations run at once (FIFO).
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ count: Int) { available = count }

    /// Waits for a slot. `first` jumps the line (work the listener is waiting on right now).
    public func wait(first: Bool = false) async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            if first { waiters.insert(continuation, at: 0) } else { waiters.append(continuation) }
        }
    }

    public func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func run<T: Sendable>(first: Bool = false, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await wait(first: first)
        defer { Task { self.signal() } }
        return try await body()
    }
}

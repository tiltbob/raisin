import Dispatch
import Foundation

/// Blocking socket work runs on its own threads, never on Swift's cooperative pool: a
/// receive with a timeout would otherwise tie up one of its few threads.
public enum IO {
    static let queue = DispatchQueue(label: "eardigger.io", qos: .userInitiated, attributes: .concurrent)

    /// Run blocking [work] on an I/O thread and await its result.
    public static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    public static func runThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// A cancellation signal that blocking loops poll between receive timeouts.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A long-running loop on a dedicated thread (a video receiver, a keep-alive). The body
/// checks [isCancelled] between short blocking calls; [sleep] wakes early on [cancel].
final class Worker: @unchecked Sendable {
    let name: String
    private let condition = NSCondition()
    private var cancelled = false
    private var finished = false

    init(_ name: String, _ body: @escaping (Worker) -> Void) {
        self.name = name
        let thread = Thread { [self] in
            body(self)
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }
        thread.name = name
        thread.start()
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Sleep for [seconds]; returns false (early) once cancelled.
    @discardableResult
    func sleep(_ seconds: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while !cancelled {
            if !condition.wait(until: deadline) { break }
        }
        return !cancelled
    }

    /// Cancel and wait up to [timeout] for the body to return. True if it did.
    @discardableResult
    func cancelAndJoin(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        cancelled = true
        condition.broadcast()
        while !finished {
            if !condition.wait(until: deadline) { break }
        }
        return finished
    }
}

/// Monotonic milliseconds, for timeouts and stall detection.
enum Clock {
    static func ms() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

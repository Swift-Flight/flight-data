import Synchronization

/// A sendable execution counter — `Mutex` itself is non-copyable and cannot
/// be captured into `sending` task closures, so tests share it boxed.
final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    /// Increments and returns the new value, so concurrent callers can tell
    /// which attempt they are without a second racy read.
    func incrementAndGet() -> Int { count.withLock { $0 += 1; return $0 } }
    var value: Int { count.withLock { $0 } }
}

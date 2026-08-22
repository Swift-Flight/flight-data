/// A one-shot gate a task waits on until it is opened **or the waiting task
/// is cancelled** — the piece plain `withCheckedContinuation` lacks.
///
/// Concurrency tests need to hold a task at an exact point (say, inside a
/// `@Cacheable` body, so other callers coalesce onto its flight) and then
/// release or cancel it. Doing that with `Task.sleep` encodes a guess about
/// scheduling: too short and the test races, too long and it just wastes
/// time — and either way it stops testing the intended interleaving the
/// moment the machine is loaded. A gate says exactly what is meant.
actor Gate {
    private var isOpen = false
    private var parked: [Int: CheckedContinuation<Void, any Error>] = [:]
    /// Tasks cancelled before they managed to park — their `wait()` throws
    /// immediately instead of suspending into a continuation nobody will
    /// resume.
    private var cancelledBeforeParking: Set<Int> = []
    private var nextTicket = 0

    /// Suspends until `open()`, throwing `CancellationError` if this task is
    /// cancelled first.
    func wait() async throws {
        let ticket = nextTicket
        nextTicket += 1
        try await withTaskCancellationHandler {
            if isOpen { return }
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeParking.remove(ticket) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    parked[ticket] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(ticket) }
        }
    }

    /// Releases every waiter, now and in future.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let released = parked
        parked = [:]
        for (_, continuation) in released {
            continuation.resume()
        }
    }

    private func cancel(_ ticket: Int) {
        if let continuation = parked.removeValue(forKey: ticket) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeParking.insert(ticket)
        }
    }
}

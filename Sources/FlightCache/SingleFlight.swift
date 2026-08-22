import Foundation

/// Local single-flight (design §8): concurrent calls on this instance for
/// the same key coalesce into one execution of the underlying method. An
/// actor-guarded in-flight map — genuinely stateful, serialized-mutation
/// state, exactly the case Core §8 reserves actors for.
///
/// The leader runs the body inline in its own task (structured concurrency —
/// no unstructured `Task` holding a caller's non-`Sendable` self); waiters
/// receive the leader's *encoded bytes* and decode for themselves. §8 pins
/// the failure semantics: a leader error propagates to every waiter, except
/// cancellation, which sends waiters back around to elect a new leader.
///
/// Explicitly NOT distributed (§8): with N instances you get at most N
/// concurrent recomputations rather than one — an honest stopping point.
public actor SingleFlight {
    /// What the leader hands its waiters.
    public enum Outcome: Sendable {
        /// The computation finished. `nil` bytes mean the leader had nothing
        /// publishable (a `nil` result (§5) or an encode failure) — waiters
        /// fall through to computing for themselves.
        case success(Data?)
        /// The computation threw. Waiters rethrow it — re-running a
        /// computation that just errored N more times is the stampede this
        /// type exists to prevent.
        case failure(any Error)
        /// The leader was cancelled. Its `CancellationError` belongs to it
        /// alone; waiters re-enter and one becomes the new leader.
        case leaderCancelled
    }

    /// The result of `join(_:)`: lead and compute, or a completed wait.
    public enum Join: Sendable {
        case lead
        case wait(Outcome)
    }

    /// In-flight keys → parked waiters. Presence of a key (even with no
    /// waiters yet) means a leader is computing.
    private var waiters: [CacheKey: [CheckedContinuation<Outcome, Never>]] = [:]

    public init() {}

    /// Joins the flight for `key`. The first caller becomes the leader and
    /// MUST eventually call `complete(_:with:)` — on every path, including
    /// throws and cancellation — or waiters park forever. Later callers
    /// suspend until the leader completes; a parked waiter is deliberately
    /// not cancellable mid-wait (§8): it waits out the leader's execution,
    /// which is bounded by the computation it was about to run anyway.
    public func join(_ key: CacheKey) async -> Join {
        guard waiters[key] != nil else {
            waiters[key] = []
            return .lead
        }
        // No suspension between the check above and parking below: the
        // continuation body runs synchronously on the actor, so a leader
        // completing cannot slip between them.
        let outcome = await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            let arrived = waiters[key]?.count ?? 0
            releaseObservers(for: key) { $0.threshold <= arrived }
        }
        return .wait(outcome)
    }

    /// Resolves the flight for `key`, resuming every parked waiter.
    public func complete(_ key: CacheKey, with outcome: Outcome) {
        guard let parked = waiters.removeValue(forKey: key) else { return }
        for continuation in parked {
            continuation.resume(returning: outcome)
        }
        // Nothing more can join this flight, so anyone awaiting a
        // coalescing threshold on it must be released rather than parked
        // forever.
        releaseObservers(for: key) { _ in true }
    }

    /// In-flight key count — introspection for tests.
    public var inFlightCount: Int { waiters.count }

    /// Callers currently coalesced onto `key`'s flight, excluding its
    /// leader.
    public func coalescedCount(on key: CacheKey) -> Int {
        waiters[key]?.count ?? 0
    }

    /// Suspends until at least `count` callers are coalesced onto `key`'s
    /// flight (or the flight resolves).
    ///
    /// Coalescing is otherwise invisible from outside: a waiter is
    /// suspended *inside* `join`, so nothing it does can announce that it
    /// arrived. Without this, a test wanting "one leader and one waiter,
    /// in that order" has to sleep and hope — which is a race dressed up
    /// as a delay, and it silently stops testing the intended interleaving
    /// on a loaded machine. This makes the ordering exact.
    public func waitUntilCoalescing(_ count: Int, on key: CacheKey) async {
        guard let parked = waiters[key], parked.count < count else { return }
        await withCheckedContinuation { continuation in
            observers.append(Observer(key: key, threshold: count, continuation: continuation))
        }
    }

    private struct Observer {
        let key: CacheKey
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var observers: [Observer] = []

    private func releaseObservers(for key: CacheKey, matching: (Observer) -> Bool) {
        guard !observers.isEmpty else { return }
        var retained: [Observer] = []
        retained.reserveCapacity(observers.count)
        for observer in observers {
            if observer.key == key, matching(observer) {
                observer.continuation.resume()
            } else {
                retained.append(observer)
            }
        }
        observers = retained
    }
}

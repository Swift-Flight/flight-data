import Synchronization

/// The parked-caller half of a pool that queues (design delta D8).
///
/// A pool needs two things to turn `pool_size` from a wall into a queue: a
/// non-parking "is one free right now?" probe, which only the pool itself can
/// write, and somewhere for callers to wait — which is this, and which is
/// identical for every pool.
///
/// It lives in core rather than in a driver because it was written twice
/// otherwise. The Postgres and Valkey pools have a long history of a fix
/// landing on one twin and not the other — outage-recovery backoff, ping's
/// tolerance of saturation, session reset on release — and a parked-waiter
/// state machine is exactly the sort of thing that ends up subtly different in
/// the copy, in a way tests written against one of them cannot see.
///
/// ## The three states
///
/// A waiter is `reserved` before it suspends, `parked` while it is suspended,
/// and `woken` if a wake arrived in between. That middle state is the whole
/// point: reserving under the lock *before* suspending is what stops a release
/// that lands in the gap from waking nobody and leaving the caller asleep
/// beside a free connection until its deadline.
public final class ConnectionWaiters: Sendable {
    private enum Waiter: Sendable {
        case reserved
        case parked(CheckedContinuation<Void, Never>)
        case woken
    }

    private struct State: Sendable {
        var waiters: [UInt64: Waiter] = [:]
        var nextID: UInt64 = 0
        var peak = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// How many callers are parked right now, and the most there have ever
    /// been. A pool that is too small says so here before it says so as
    /// errors.
    public var counts: (now: Int, peak: Int) {
        state.withLock { ($0.waiters.count, $0.peak) }
    }

    /// The queueing checkout, expressed once for every pool.
    ///
    /// - Parameters:
    ///   - timeout: How long to queue before giving up.
    ///   - attempt: The pool's non-parking probe: a connection, or `nil` when
    ///     nothing is free. Throws for conditions waiting cannot fix — a
    ///     closed or unstarted pool.
    ///   - exhausted: The error to throw when the deadline passes.
    public func checkout<C>(
        waitingUpTo timeout: Duration,
        attempt: () throws -> C?,
        exhausted: () -> any Error
    ) async throws -> C {
        if let connection = try attempt() { return connection }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            // A cancelled caller is not owed its full timeout. Without this,
            // cancellation makes the sleep below throw instantly and the loop
            // registers and removes a fresh waiter at full speed for the rest
            // of the timeout — a busy-spun core in exchange for an answer
            // nobody is waiting for.
            try Task.checkCancellation()
            await waitForWake(until: deadline)
            if let connection = try attempt() { return connection }
        }
        throw exhausted()
    }

    /// Parks until woken or the deadline passes.
    public func waitForWake(until deadline: ContinuousClock.Instant) async {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            let id = state.nextID
            state.waiters[id] = .reserved
            state.peak = max(state.peak, state.waiters.count)
            return id
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.park(id) }
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                self.wake(id)
            }
            await group.next()
            group.cancelAll()
            // Whichever finished first, the other is finished with: waking an
            // already-woken id is a no-op, and it is what guarantees the park
            // task cannot outlive this call.
            self.wake(id)
        }
    }

    private func park(_ id: UInt64) async {
        await withCheckedContinuation { continuation in
            let alreadyWoken = state.withLock { state -> Bool in
                switch state.waiters[id] {
                case .reserved:
                    state.waiters[id] = .parked(continuation)
                    return false
                default:
                    // Woken between reserving and parking. Take the slot and
                    // resume immediately rather than sleeping through it.
                    state.waiters[id] = nil
                    return true
                }
            }
            if alreadyWoken { continuation.resume() }
        }
    }

    /// Wakes one specific waiter. Idempotent.
    private func wake(_ id: UInt64) {
        resume(state.withLock { take(&$0, id) })
    }

    /// Wakes the longest-parked caller, if any. Call this wherever a
    /// connection lands back in the free list — a connection that comes back
    /// with nobody told about it is a caller waiting out its whole timeout
    /// beside a free connection.
    public func wakeOne() {
        resume(state.withLock { state in
            guard let id = state.waiters.keys.min() else { return nil }
            return take(&state, id)
        })
    }

    /// Must run under the state lock.
    private func take(_ state: inout State, _ id: UInt64) -> CheckedContinuation<Void, Never>? {
        switch state.waiters[id] {
        case .parked(let continuation):
            state.waiters[id] = nil
            return continuation
        case .reserved:
            // Reserved but not yet parked: mark it so `park` sees the wake
            // instead of suspending forever.
            state.waiters[id] = .woken
            return nil
        case .woken, nil:
            return nil
        }
    }

    private func resume(_ continuation: CheckedContinuation<Void, Never>?) {
        continuation?.resume()
    }
}

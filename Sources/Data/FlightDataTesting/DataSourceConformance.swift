import FlightDataCore
import Testing

/// The behaviour every `DataSource` owes its callers, as a suite an
/// implementation can run against itself.
///
/// These properties were previously re-derived by hand in each driver's own
/// tests — which meant each driver tested what its author remembered the
/// contract to be, and a property nobody thought to check went unchecked
/// everywhere. Scope-per-connection, release-on-throw and shutdown behaviour
/// are exactly the kind of thing that is obvious until a pool gets it wrong.
///
/// A driver runs the whole suite in one test:
///
/// ```swift
/// @Test func conformsToDataSourceContract() async throws {
///     try await DataSourceConformance.verify(
///         make: { try await PostgresDataSource.started(settings: .test) },
///         shutdown: { await $0.shutdown() })
/// }
/// ```
///
/// Note the argument labels: this used to take its first closure unlabelled,
/// and both driver doccs showed a call that could not compile.
public enum DataSourceConformance {

    /// Runs every contract check against a freshly-made source.
    ///
    /// - Parameters:
    ///   - make: Produces a *started* source, ready for checkout. Called more
    ///     than once; each call must yield an independent pool.
    ///   - shutdown: Tears one down. Called for every source `make` produced.
    public static func verify<Source: DataSource>(
        make: () async throws -> Source,
        shutdown: (Source) async -> Void
    ) async throws {
        try await checkoutReturnsAUsableConnection(make, shutdown)
        try await releaseMakesAConnectionAvailableAgain(make, shutdown)
        try await withConnectionReleasesOnThrow(make, shutdown)
        try await withConnectionIsCallableFromAnActor(make, shutdown)
        try await concurrentCheckoutsNeverHandOutTheSameConnection(make, shutdown)
        try await exhaustionIsTypedNotAHang(make, shutdown)
        try await waitingCheckoutQueuesRatherThanFailing(make, shutdown)
        try await waitingCheckoutGivesUpAtItsDeadline(make, shutdown)
        try await pingAnswersOnALiveSource(make, shutdown)
        try await checkoutAfterShutdownIsRefused(make, shutdown)
    }

    /// Makes a source, runs `body`, and tears it down on every path.
    /// `defer { Task { … } }` would both capture the non-escaping `shutdown`
    /// and make teardown non-deterministic.
    private static func withSource<Source: DataSource, T>(
        _ make: () async throws -> Source,
        _ shutdown: (Source) async -> Void,
        _ body: (Source) async throws -> T
    ) async throws -> T {
        let source = try await make()
        do {
            let result = try await body(source)
            await shutdown(source)
            return result
        } catch {
            await shutdown(source)
            throw error
        }
    }

    // MARK: The clauses

    /// A checkout hands back something the caller can actually use, and the
    /// pool counts it as outstanding.
    static func checkoutReturnsAUsableConnection<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            let connection = try source.checkout()
            source.release(connection)
        }
    }

    /// Release is not optional bookkeeping: a released connection must be
    /// available to the next caller, or a pool of size N serves N requests
    /// for the lifetime of the process.
    static func releaseMakesAConnectionAvailableAgain<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            // Drain to exhaustion first. Eight sequential checkout/release
            // pairs — what this used to do — proved nothing about release for
            // any pool of eight or more: every one of them was served by a
            // connection that had never been released.
            var held = try await drainToExhaustion(source)

            // Give exactly one back. If release is not putting it anywhere the
            // next caller can find, this is where it shows.
            source.release(held.removeLast())
            let reused = try await checkoutQueueing(source)
            #expect(reused != nil, "a released connection must be available to the next caller")
            if let reused { held.append(reused) }
            held.forEach(source.release)
        }
    }

    /// A pool must not over-issue under concurrency. Sixteen callers racing a
    /// pool of four must still see four succeed: a checkout whose free-list
    /// bookkeeping is not atomic hands the same connection to two callers, and
    /// then one of them releases a connection the other is still using.
    ///
    /// Expressed as a count rather than by comparing connection identities,
    /// because `Connection` is only `Sendable` — a store whose connection is a
    /// value type would defeat identity comparison silently.
    static func concurrentCheckoutsNeverHandOutTheSameConnection<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            // Learn the ceiling the honest way — nothing in the contract
            // exposes a pool size — then give it all back.
            let drained = try await drainToExhaustion(source)
            let capacity = drained.count
            drained.forEach(source.release)

            // Everyone holds what they get until the group finishes, so the
            // count is connections outstanding *at the same time*. Releasing
            // inside each task would let one connection satisfy every caller
            // in turn and prove nothing.
            let concurrent = await withTaskGroup(of: Source.Connection?.self) { group in
                for _ in 0..<(capacity * 4) {
                    group.addTask { try? source.checkout() }
                }
                return await group.reduce(into: [Source.Connection]()) { all, one in
                    if let one { all.append(one) }
                }
            }
            #expect(
                concurrent.count <= capacity,
                "\(concurrent.count) callers held a connection at once from a pool of \(capacity)")
            concurrent.forEach(source.release)
        }
    }

    /// A body that throws still returns its connection. Getting this wrong
    /// leaks one connection per failed request — invisible until the pool is
    /// empty and every subsequent request fails for an unrelated reason.
    static func withConnectionReleasesOnThrow<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            for _ in 0..<8 {
                await #expect(throws: ConformanceProbeError.self) {
                    try await source.withConnection { _ in throw ConformanceProbeError() }
                }
            }
            // If throwing leaked, this checkout is the one that fails. Through
            // the queueing form: a driver that clears session state on release
            // has genuinely returned the connection without it being available
            // this instant, and that is not a leak.
            let connection = try await checkoutQueueing(source)
            #expect(connection != nil, "a throwing body leaked its connection")
            if let connection { source.release(connection) }
        }
    }

    /// `withConnection` must be callable from actor-isolated code, which is
    /// where repositories live. Before `isolation:` was threaded through, an
    /// actor calling this got "sending 'self'-isolated value … risks causing
    /// data races" and could not use the pool at all.
    static func withConnectionIsCallableFromAnActor<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            let caller = ConformanceCaller(source: source)
            let first = try await caller.use()
            let second = try await caller.use()
            #expect(first == 1)
            #expect(second == 2)
        }
    }

    /// Exhaustion is a typed error, promptly — not a hang. `checkout()` is
    /// synchronous by contract and must never park the caller, so a pool with
    /// nothing free says so rather than waiting for one.
    static func exhaustionIsTypedNotAHang<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            var held: [Source.Connection] = []
            // Drain well past any plausible pool size; one of these must refuse.
            var refused = false
            for _ in 0..<256 {
                do { held.append(try source.checkout()) } catch {
                    #expect(error is DataSourceError, "exhaustion must be typed, got \(error)")
                    refused = true
                    break
                }
            }
            held.forEach(source.release)
            #expect(refused, "a pool that never refuses has no ceiling at all")
        }
    }

    /// A pool at capacity is a queue, not a wall (core delta D2): a caller
    /// that can await gets the connection the moment one comes back, rather
    /// than the immediate failure the synchronous primitive gives.
    static func waitingCheckoutQueuesRatherThanFailing<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            var held = try await drainToExhaustion(source)
            let last = held.removeLast()

            // The pool is empty and the synchronous checkout says so.
            #expect(throws: DataSourceError.self) { _ = try source.checkout() }

            // The waiting one does not: it parks, and the release below is
            // what completes it.
            async let queued = source.checkout(waitingUpTo: .seconds(10))
            try await Task.sleep(for: .milliseconds(50))
            source.release(last)

            let served = try await queued
            source.release(served)
            held.forEach(source.release)
        }
    }

    /// …and it is a queue with an end. A pool that waits forever turns one
    /// stuck query into an unbounded backlog.
    static func waitingCheckoutGivesUpAtItsDeadline<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            let held = try await drainToExhaustion(source)

            let started = ContinuousClock.now
            await #expect(throws: DataSourceError.self) {
                _ = try await source.checkout(waitingUpTo: .milliseconds(200))
            }
            let elapsed = started.duration(to: .now)
            #expect(elapsed >= .milliseconds(150), "it gave up without waiting")
            #expect(elapsed < .seconds(5), "it waited far past its deadline")

            held.forEach(source.release)
        }
    }

    /// `ping()` is the fourth protocol requirement and the one nothing used to
    /// exercise — so a driver whose ping unconditionally threw passed
    /// conformance while `DataSourceLiveness` reported it dead in production.
    ///
    /// It is also checked under saturation: every connection being checked out
    /// is a busy pool, not a dead store, and a liveness probe that fails there
    /// gets a healthy pod restarted at the worst possible moment.
    static func pingAnswersOnALiveSource<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        try await withSource(make, shutdown) { source in
            try await source.ping()

            let held = try await drainToExhaustion(source)
            try await source.ping()
            held.forEach(source.release)
        }
    }

    /// After shutdown, checkout is refused rather than handing out a
    /// connection to a pool that is no longer maintaining it — and refused
    /// with the vocabulary the protocol promises, not just any error.
    static func checkoutAfterShutdownIsRefused<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        let source = try await make()
        await shutdown(source)
        #expect(throws: DataSourceError.self) { _ = try source.checkout() }
        await #expect(throws: DataSourceError.self) {
            _ = try await source.checkout(waitingUpTo: .milliseconds(50))
        }
    }

    /// A checkout that tolerates a driver holding a connection back for a
    /// moment — clearing session state on release means "returned" and
    /// "available to the next caller" are not the same instant.
    private static func checkoutQueueing<Source: DataSource>(
        _ source: Source, waiting timeout: Duration = .seconds(5)
    ) async throws -> Source.Connection? {
        try? await source.checkout(waitingUpTo: timeout)
    }

    /// Holds every connection the pool has.
    ///
    /// Nothing in the contract exposes a pool size, so capacity is discovered
    /// by taking connections until there are none — through the *queueing*
    /// checkout, because the synchronous one stops early on a driver that is
    /// mid-reset and reports a pool smaller than it is.
    private static func drainToExhaustion<Source: DataSource>(
        _ source: Source
    ) async throws -> [Source.Connection] {
        var held: [Source.Connection] = []
        while held.count < 256,
            let connection = try await checkoutQueueing(source, waiting: .milliseconds(500))
        {
            held.append(connection)
        }
        #expect(!held.isEmpty, "a pool that hands out nothing cannot be checked")
        return held
    }
}

/// Thrown by the release-on-throw check. A file-scope type because a generic
/// function cannot nest one.
struct ConformanceProbeError: Error {}

/// Actor-isolated caller for the isolation check, at file scope for the same
/// reason.
actor ConformanceCaller<S: DataSource> {
    private var count = 0
    let source: S

    init(source: S) { self.source = source }

    func use() async throws -> Int {
        try await source.withConnection { _ in
            self.count += 1
            return self.count
        }
    }
}

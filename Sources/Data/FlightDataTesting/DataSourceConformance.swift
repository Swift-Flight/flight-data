import FlightDataCore
import Testing

/// The behaviour every `DataSource` owes its callers, as a suite an
/// implementation can run against itself.
///
/// These six properties were previously re-derived by hand in each driver's
/// own tests — which meant each driver tested what its author remembered the
/// contract to be, and a property nobody thought to check went unchecked
/// everywhere. Scope-per-connection, release-on-throw and shutdown behaviour
/// are exactly the kind of thing that is obvious until a pool gets it wrong.
///
/// A driver runs the whole suite in one test:
///
/// ```swift
/// @Test func conformsToDataSourceContract() async throws {
///     try await DataSourceConformance.verify {
///         try await PostgresDataSource(settings: .test)
///     } shutdown: { source in
///         await source.shutdown()
///     }
/// }
/// ```
public enum DataSourceConformance {

    /// Runs every contract check against a freshly-made source.
    ///
    /// - Parameters:
    ///   - make: Produces a *started* source, ready for checkout. Called more
    ///     than once; each call must yield an independent pool.
    ///   - shutdown: Tears one down. Called for every source `make` produced.
    public static func verify<Source: DataSource>(
        _ make: () async throws -> Source,
        shutdown: (Source) async -> Void
    ) async throws {
        try await checkoutReturnsAUsableConnection(make, shutdown)
        try await releaseMakesAConnectionAvailableAgain(make, shutdown)
        try await withConnectionReleasesOnThrow(make, shutdown)
        try await withConnectionIsCallableFromAnActor(make, shutdown)
        try await exhaustionIsTypedNotAHang(make, shutdown)
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

    // MARK: The six

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
            for _ in 0..<8 {
                let connection = try source.checkout()
                source.release(connection)
            }
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
            // If throwing leaked, this checkout is the one that fails.
            let connection = try source.checkout()
            source.release(connection)
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

    /// After shutdown, checkout is refused rather than handing out a
    /// connection to a pool that is no longer maintaining it.
    static func checkoutAfterShutdownIsRefused<Source: DataSource>(
        _ make: () async throws -> Source, _ shutdown: (Source) async -> Void
    ) async throws {
        let source = try await make()
        await shutdown(source)
        #expect(throws: (any Error).self) { _ = try source.checkout() }
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

/// A pooled source of store connections. One per configured store —
/// registered as a singleton in the Container; its long-running work is
/// handed to the ServiceGroup via `FlightModule.service` (Flight Core).
///
/// This is the entire cross-store contract, and it is intentionally almost
/// empty. If a future store package needs something this protocol doesn't
/// expose, the fix is to extend it *deliberately* — not to add a side
/// channel, and above all not to add a query method (Flight Data Core
/// must never define a universal query abstraction).
///
/// ## The checkout/release pair (design delta D1)
///
/// `withConnection` looks like the whole contract. Scope-bound
/// checkout forced one deliberate extension: component factories are
/// *synchronous* (Flight Core), so the scoped `ScopedConnection` component
/// must acquire its connection synchronously — an async-only `withConnection`
/// cannot be bridged from a synchronous factory without blocking a
/// cooperative-pool thread, which deadlocks on a single-threaded executor.
/// `checkout()`/`release(_:)` are therefore the pool's primitives, and
/// `withConnection` ships as a derived default on top of them.
///
/// ## Queueing (design delta D8)
///
/// `checkout()` returning promptly-or-throwing is a property of the
/// *synchronous* primitive, not a policy for the whole seam — and it was read
/// as the policy for far too long. `pool_size` became a hard concurrency
/// ceiling: the (pool_size + 1)th simultaneous request did not queue behind
/// the others for a few milliseconds, it returned 500, and the person holding
/// the browser saw an error because someone else was mid-request. Found by a
/// test that created eight issues at once against a pool of four: four
/// succeeded and four failed immediately.
///
/// So a caller that *can* await queues. `checkout(waitingUpTo:)` is the async
/// primitive, `withConnection` is defined on it rather than on `checkout()`,
/// and a pool at capacity is a queue up to `checkoutTimeout` — at which point
/// failing is correct, because a request that has waited that long is a
/// request nobody is still watching.
///
/// Only the synchronous path still fails fast, because it has no choice.
/// `ScopedConnection`'s factory is synchronous, which is why an async caller
/// that wants the scope's connection queued takes it up front and offers it
/// through ``PendingConnections``.
public protocol DataSource: Sendable {
    /// The store-specific connection/session type. Postgres yields a
    /// PostgresConnection; Mongo would yield a session; Redis a command
    /// context. Flight Data Core has NO opinion about what this is —
    /// deliberately, since any opinion here would be the beginning of the
    /// universal-query-model mistake.
    associatedtype Connection: Sendable

    /// Check out a connection from the pool.
    ///
    /// Synchronous because its two callers are synchronous: the scoped
    /// `ScopedConnection` factory and a store package's transaction
    /// coordinator (`FlightTransactionCoordinator.begin` is synchronous by
    /// Flight Core). Implementations return promptly — a free connection or a
    /// typed error from `DataSourceError` — and never park the calling thread.
    ///
    /// Every error thrown here is a `DataSourceError`: that is the portable
    /// vocabulary a store-agnostic caller reacts to without knowing the store,
    /// and `DataSourceConformance` checks it.
    func checkout() throws -> Connection

    /// Check out a connection, queueing up to `timeout` for one to come back
    /// before throwing `DataSourceError.poolExhausted`.
    ///
    /// The async primitive, and what `withConnection` is built on. A default
    /// implementation polls `checkout()`, so every store queues whether or not
    /// its pool has a native wake path; a pool that *does* — both drivers in
    /// this package do — should override this with it, which turns a poll into
    /// a handoff.
    ///
    /// A timeout of `.zero` is the old behaviour: one attempt, then throw.
    /// Cancellation surfaces as `CancellationError`, promptly — a cancelled
    /// caller is not owed the rest of its timeout.
    func checkout(waitingUpTo timeout: Duration) async throws -> Connection

    /// How long ``withConnection(isolation:_:)`` queues before giving up.
    /// Defaults to `DataSourceSettings.defaultCheckoutTimeout`; drivers
    /// surface `datasource.<name>.checkout_timeout_ms` here.
    var checkoutTimeout: Duration { get }

    /// Return a previously checked-out connection to the pool.
    ///
    /// Non-throwing: release runs on cleanup paths (scope close, the error
    /// leg of `withConnection`) where a thrown error would mask the original.
    /// Implementations log a failure, or trap on one that indicates a bug in
    /// the caller rather than in the store — every pool here traps on a double
    /// release or a foreign connection, because continuing past either means
    /// handing one connection to two callers.
    func release(_ connection: Connection)

    /// Check out a connection for the duration of `body`, and return it to
    /// the pool afterward — including on throw.
    ///
    /// A default implementation is provided in terms of
    /// `checkout(waitingUpTo:)`/`release` — so it queues rather than failing
    /// the moment the pool is busy.
    ///
    /// `isolation` defaults to the caller's actor, so `body` runs *on* that
    /// actor rather than being sent to a nonisolated context. Without it,
    /// every actor-isolated caller — which is to say every repository holding
    /// state — gets "sending 'self'-isolated value … risks causing data
    /// races" and cannot call this at all.
    func withConnection<T>(
        isolation: isolated (any Actor)?,
        _ body: (Connection) async throws -> T
    ) async throws -> T

    /// Cheap liveness probe — a `SELECT 1`-equivalent. Surfaced by
    /// Flight Actuator through the `DataSourceLiveness` component that
    /// `register(dataSource:)` registers alongside the pool.
    func ping() async throws
}

extension DataSource {
    /// Poll-based queueing for a pool with no native wake path.
    ///
    /// The backoff starts at a millisecond and caps at ten, so a connection
    /// freed early is picked up almost immediately and a long wait costs a
    /// hundred wakeups a second rather than a spun core. A pool that can wake
    /// a specific waiter should override this and hand the connection over
    /// directly.
    public func checkout(waitingUpTo timeout: Duration) async throws -> Connection {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var backoff = Duration.milliseconds(1)
        while true {
            do {
                return try checkout()
            } catch let error as DataSourceError {
                // Only exhaustion is worth waiting out. A closed or unstarted
                // pool will still be closed or unstarted in five seconds.
                guard case .poolExhausted = error else { throw error }
                try Task.checkCancellation()
                let now = ContinuousClock.now
                guard now < deadline else { throw error }
                try await Task.sleep(for: min(backoff, now.duration(to: deadline)))
                backoff = min(backoff * 2, .milliseconds(10))
            }
        }
    }

    public var checkoutTimeout: Duration { DataSourceSettings.defaultCheckoutTimeout }

    public func withConnection<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Connection) async throws -> T
    ) async throws -> T {
        let connection = try await checkout(waitingUpTo: checkoutTimeout)
        do {
            let result = try await body(connection)
            release(connection)
            return result
        } catch {
            release(connection)
            throw error
        }
    }
}

/// The store-agnostic error vocabulary for pool checkout. Store packages may
/// throw their own richer errors; these two cover the conditions every pool
/// shares, so store-agnostic callers (Actuator, middleware) can react without
/// knowing the store.
public enum DataSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Every pooled connection is checked out and the pool will not grow.
    case poolExhausted(datasource: String, poolSize: Int)
    /// The pool has shut down (its service ended); no further checkouts.
    case closed(datasource: String)
    /// A checkout arrived before the pool's service reached `run()`.
    ///
    /// Distinct from ``closed(datasource:)``: that pool is finished, this one has not
    /// begun. Usually a component resolving a connection during module
    /// configuration rather than from a request scope.
    case notStarted(datasource: String)

    public var description: String {
        switch self {
        case .poolExhausted(let datasource, let poolSize):
            return "Datasource '\(datasource)' has no free connections (pool_size: \(poolSize)). Either raise datasource.\(datasource).pool_size or look for a scope/lease that is being held too long."
        case .closed(let datasource):
            return "Datasource '\(datasource)' is closed — its pool service has shut down."
        case .notStarted(let datasource):
            return "Datasource '\(datasource)' has not started — its pool dials connections when its service runs (Flight Core), and this checkout arrived first. A connection resolved during module configuration rather than from a request scope will always see this; in tests, start the service (or call start()) before resolving connections."
        }
    }
}

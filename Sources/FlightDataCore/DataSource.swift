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
/// `withConnection` ships as a derived default on top of them (overridable —
/// a store whose native pool can *wait* for a free connection should override
/// it with its async path; the synchronous `checkout` is expected to return
/// promptly or throw, never to park).
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
    /// `ScopedConnection` factory and, eventually, a store package's
    /// transaction coordinator (`FlightTransactionCoordinator.begin` is
    /// synchronous by Flight Core). Implementations return promptly —
    /// a free connection or a typed error (`DataSourceError.poolExhausted`,
    /// `.closed`) — and never park the calling thread.
    func checkout() throws -> Connection

    /// Return a previously checked-out connection to the pool.
    ///
    /// Non-throwing: release runs on cleanup paths (scope close, the error
    /// leg of `withConnection`) where a thrown error would mask the original.
    /// Implementations log failures instead.
    func release(_ connection: Connection)

    /// Check out a connection for the duration of `body`, and return it to
    /// the pool afterward — including on throw.
    ///
    /// A default implementation is provided in terms of `checkout`/`release`.
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
    public func withConnection<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Connection) async throws -> T
    ) async throws -> T {
        let connection = try checkout()
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
    /// Distinct from ``closed``: that pool is finished, this one has not
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
            return "Datasource '\(datasource)' has not started yet — its pool service has not reached run(). A connection resolved during module configuration, rather than from a request scope, will always see this."
        }
    }
}

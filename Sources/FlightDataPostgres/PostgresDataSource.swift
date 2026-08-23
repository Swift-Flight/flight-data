import FlightDataCore
import Logging
import NIOCore
import PostgresNIO
import ServiceLifecycle
import Synchronization

/// The Postgres pool behind the `DataSource` seam (design, Flight Data
/// Core /): one per configured datasource, registered `.singleton`, its
/// long-running work handed to the `ServiceGroup` via `FlightModule.service`.
///
/// ## Why this pool exists (design delta P1 — see SPIKE-FINDINGS.md)
///
/// The design doc's sketch leases connections from PostgresNIO's
/// `PostgresClient`. That cannot satisfy the seam: `PostgresClient` exposes
/// only scoped async lending (`withConnection`) — its `leaseConnection()` is
/// private — while `DataSource.checkout()` must be *synchronous* (Flight
/// Data Core delta D1: scoped component factories are synchronous, and a
/// transaction coordinator's `begin()` is synchronous by Flight Core).
/// So this package owns a deliberately small pool of `PostgresConnection`s:
/// eager dial at service start, Mutex-guarded free list, prompt
/// checkout-or-throw (never parks), broken-connection replacement in the
/// service loop. Everything protocol-level — wire handling, TLS, encoding —
/// stays PostgresNIO's.
///
/// `run()` is the module service's body: no request is served before the
/// pool is live (Flight Core bootstrap ordering), and graceful shutdown
/// drains it.
public final class PostgresDataSource: DataSource, Sendable {
    public typealias Connection = PostgresConnection

    /// The datasource's name — config key segment and registration qualifier.
    public let name: String
    /// Fixed pool size: every connection is dialed at `start()`; checkout
    /// never grows the pool (Flight Data Core: prompt or throw).
    public let poolSize: Int
    /// The parsed `datasource.<name>.url`.
    public let url: PostgresDataSourceURL

    private let logger: Logger
    private let state: Mutex<PoolState>
    private let replacementSignal: AsyncStream<Void>
    private let replacementTrigger: AsyncStream<Void>.Continuation

    private enum Phase: Equatable {
        case idle       // constructed at freeze(); service not yet started
        case running
        case closed
    }

    /// `PostgresConnection` is `@unchecked Sendable` in PostgresNIO;
    /// this box carries that judgment through `Mutex`'s `sending` boundary.
    private struct PoolState: Sendable {
        var phase: Phase = .idle
        var available: [PostgresConnection] = []
        var checkedOut: Set<ObjectIdentifier> = []
        /// Connections the transaction coordinator has an open `BEGIN` on.
        /// A connection released while still in here (a scope that died
        /// between `begin` and `commit`/`rollback`) is rolled back before it
        /// is offered for reuse.
        var openTransactions: Set<ObjectIdentifier> = []
        var established = 0
        /// Connections released but not yet reset — checked out by nobody
        /// and available to nobody until `DISCARD ALL` lands.
        var resetsInFlight = 0
        var nextConnectionID = 0
        var totalCheckouts = 0
    }

    /// Whether a released connection is reset with `DISCARD ALL` before it
    /// is offered to the next scope.
    ///
    /// On by default, and only worth turning off for a deployment that is
    /// certain nothing it runs mutates session state — no `SET ROLE`, no
    /// `SET search_path`, no session GUCs, no prepared statements, no
    /// temporary tables. The saving is one round trip per scope; the cost of
    /// being wrong is one request reading another tenant's rows.
    public let resetOnRelease: Bool

    public init(
        settings: DataSourceSettings,
        resetOnRelease: Bool = true,
        logger: Logger? = nil
    ) throws {
        self.name = settings.name
        self.poolSize = settings.poolSize
        self.resetOnRelease = resetOnRelease
        // Parsed here — at freeze()'s eager singleton construction — so a
        // malformed URL fails bootstrap, not the first query ( posture).
        self.url = try PostgresDataSourceURL.parse(settings.url, datasource: settings.name)
        self.logger = logger ?? Logger(label: "flight.data.postgres.\(settings.name)")
        self.state = Mutex(PoolState())
        (self.replacementSignal, self.replacementTrigger) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Service body

    /// Dials the pool, then maintains it (replacing broken connections) until
    /// task cancellation or graceful shutdown, then drains it. This is the
    /// entire body of the module's ServiceLifecycle service.
    public func run() async throws {
        try await start()
        await cancelWhenGracefulShutdown {
            await self.maintainPool()
        }
        await shutdown()
    }

    /// Establishes all `poolSize` connections eagerly. A connection failure
    /// here fails the service — and with it bootstrap — before any request
    /// is served. Exposed separately from `run()` for test harnesses that
    /// drive the lifecycle by hand.
    public func start() async throws {
        state.withLock { state in
            precondition(state.phase == .idle, "PostgresDataSource.start() called twice for datasource '\(name)'.")
            state.phase = .running
        }
        do {
            for _ in 0..<poolSize {
                let connection = try await dial()
                let repooled = state.withLock { state -> Bool in
                    guard state.phase == .running else { return false }
                    state.available.append(connection)
                    state.established += 1
                    return true
                }
                if !repooled {  // shut down mid-start
                    try? await connection.close()
                    return
                }
            }
            logger.info("postgres pool started", metadata: [
                "datasource": "\(name)", "pool_size": "\(poolSize)",
                "host": "\(url.host)", "database": "\(url.database)",
            ])
        } catch {
            await shutdown()
            throw error
        }
    }

    /// Replaces broken connections as checkout/release discover them, until
    /// cancelled. Exposed for hand-driven test harnesses.
    public func maintainPool() async {
        for await _ in replacementSignal {
            await replaceBrokenConnections()
        }
    }

    /// Closes the pool: further checkouts throw `DataSourceError.closed`,
    /// pooled connections are closed now, in-flight ones as they come back.
    public func shutdown() async {
        // Close the door first, then wait for connections still being reset.
        // Their completion handlers decrement `established` and close them;
        // returning before they run would report a pool that still holds
        // connections it is in the middle of letting go.
        state.withLock { $0.phase = .closed }
        await drainPendingResets()

        let toClose = state.withLock { state -> [PostgresConnection] in
            let connections = state.available
            state.available = []
            state.established -= connections.count
            return connections
        }
        replacementTrigger.finish()
        for connection in toClose {
            try? await connection.close()
        }
        logger.info("postgres pool closed", metadata: ["datasource": "\(name)"])
    }

    /// Waits for outstanding `DISCARD ALL`s to finish, so shutdown does not
    /// race the handlers that close their connections.
    private func drainPendingResets() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.withLock({ $0.resetsInFlight }) > 0 {
            guard ContinuousClock.now < deadline else {
                logger.warning(
                    "gave up waiting for session resets during shutdown",
                    metadata: [
                        "datasource": "\(name)",
                        "outstanding": "\(state.withLock { $0.resetsInFlight })",
                    ])
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dial() async throws -> PostgresConnection {
        let id = state.withLock { state -> Int in
            state.nextConnectionID += 1
            return state.nextConnectionID
        }
        return try await PostgresConnection.connect(
            configuration: try url.connectionConfiguration(),
            id: id,
            logger: logger
        )
    }

    private func replaceBrokenConnections() async {
        while true {
            let deficit = state.withLock { state -> Int in
                state.phase == .running ? poolSize - state.established : 0
            }
            guard deficit > 0 else { return }
            do {
                let connection = try await dial()
                let repooled = state.withLock { state -> Bool in
                    guard state.phase == .running else { return false }
                    state.available.append(connection)
                    state.established += 1
                    return true
                }
                if !repooled {
                    try? await connection.close()
                    return
                }
                logger.info("replaced broken postgres connection", metadata: ["datasource": "\(name)"])
            } catch {
                // The server is unreachable; the next checkout/release that
                // notices a broken connection re-triggers replacement, and
                // pings keep Actuator honest in the meantime.
                logger.warning("failed to replace broken postgres connection", metadata: [
                    "datasource": "\(name)", "error": "\(error)",
                ])
                return
            }
        }
    }

    // MARK: - DataSource

    public func checkout() throws -> PostgresConnection {
        var sawBrokenConnection = false
        defer { if sawBrokenConnection { replacementTrigger.yield() } }

        return try state.withLock { state in
            switch state.phase {
            case .closed:
                throw DataSourceError.closed(datasource: name)
            case .idle:
                throw PostgresDataSourceError.notStarted(datasource: name)
            case .running:
                break
            }
            while let connection = state.available.popLast() {
                guard !connection.isClosed else {
                    state.established -= 1
                    sawBrokenConnection = true
                    continue
                }
                state.checkedOut.insert(ObjectIdentifier(connection))
                state.totalCheckouts += 1
                return connection
            }
            throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
        }
    }

    public func release(_ connection: PostgresConnection) {
        enum Disposition {
            case repool
            case closePool     // pool shut down while this was out
            case dropBroken
            case rollbackFirst
            case resetFirst
        }

        let disposition = state.withLock { state -> Disposition in
            let id = ObjectIdentifier(connection)
            precondition(
                state.checkedOut.remove(id) != nil,
                "release of a connection that is not checked out from datasource '\(name)' — double release, or a foreign connection"
            )
            if state.phase == .closed {
                state.openTransactions.remove(id)
                state.established -= 1
                return .closePool
            }
            if connection.isClosed {
                state.openTransactions.remove(id)
                state.established -= 1
                return .dropBroken
            }
            if state.openTransactions.remove(id) != nil {
                return .rollbackFirst
            }
            if resetOnRelease {
                // Held back until the reset lands — see `.resetFirst`.
                state.resetsInFlight += 1
                return .resetFirst
            }
            state.available.append(connection)
            return .repool
        }

        switch disposition {
        case .repool:
            break

        case .resetFirst:
            // A pooled connection is a *session*, and a session remembers.
            // `SET ROLE`, `SET search_path`, `SET app.tenant_id`, prepared
            // statements, temporary tables, advisory-lock-adjacent state —
            // all of it survived being returned to the pool and greeted
            // whichever request checked the connection out next.
            //
            // For the row-level-security pattern this package invites, that
            // is a cross-tenant read: request A sets a tenant, request B
            // inherits it and sees rows it must not. `DISCARD ALL` is what
            // PgBouncer issues between sessions for the same reason.
            //
            // The connection is not available until the reset succeeds. A
            // reset that fails means a session in an unknown state, which is
            // exactly what must not be handed to anyone.
            let reset: EventLoopFuture<Void> = connection.query("DISCARD ALL").map { _ in }
            reset.whenComplete { [self] result in
                switch result {
                case .success:
                    let repooled = state.withLock { state -> Bool in
                        state.resetsInFlight -= 1
                        guard state.phase == .running else { return false }
                        state.available.append(connection)
                        return true
                    }
                    if !repooled {
                        state.withLock { $0.established -= 1 }
                        connection.close().whenComplete { _ in }
                    }
                case .failure(let error):
                    logger.warning(
                        "session reset failed; dropping the connection rather than reusing it",
                        metadata: ["datasource": "\(name)", "error": "\(error)"]
                    )
                    state.withLock {
                        $0.resetsInFlight -= 1
                        $0.established -= 1
                    }
                    connection.close().whenComplete { _ in }
                    replacementTrigger.yield()
                }
            }
        case .closePool:
            connection.close().whenComplete { _ in }
        case .dropBroken:
            replacementTrigger.yield()
        case .rollbackFirst:
            // A scope died between begin and commit/rollback. The macro
            // guarantees paired calls on every code path, so this is a leak
            // (a lease stashed past its scope, a crashed task) — roll the
            // connection back before anyone can reuse it, off the release
            // path (release is synchronous and non-throwing by contract).
            logger.warning(
                "connection returned to pool with an open transaction; rolling back",
                metadata: ["datasource": "\(name)"]
            )
            let future: EventLoopFuture<Void> = connection.query("ROLLBACK").map { _ in }
            future.whenComplete { [self] result in
                switch result {
                case .success:
                    let repooled = state.withLock { state -> Bool in
                        guard state.phase == .running else { return false }
                        state.available.append(connection)
                        return true
                    }
                    if !repooled {
                        state.withLock { $0.established -= 1 }
                        connection.close().whenComplete { _ in }
                    }
                case .failure(let error):
                    logger.warning("rollback of leaked transaction failed; dropping connection", metadata: [
                        "datasource": "\(name)", "error": "\(error)",
                    ])
                    state.withLock { $0.established -= 1 }
                    connection.close().whenComplete { _ in }
                    replacementTrigger.yield()
                }
            }
        }
    }

    /// `SELECT 1`, surfaced by Actuator through the `DataSourceLiveness`
    /// component that `register(dataSource:)` registers alongside the pool.
    public func ping() async throws {
        do {
            try await withConnection { connection in
                _ = try await connection.query("SELECT 1", logger: logger)
            }
        } catch DataSourceError.poolExhausted {
            // A full pool is not a dead database. This used to propagate,
            // so a liveness probe failed under exactly the load the service
            // was handling successfully — and an orchestrator restarted a
            // pod whose only problem was being busy, which is the worst
            // possible moment to lose one.
            //
            // Every connection being checked out is positive evidence that
            // connections exist and work. Saturation belongs in a readiness
            // or capacity signal, not a liveness one.
            logger.debug(
                "ping found the pool saturated; reporting alive",
                metadata: ["datasource": "\(name)", "pool_size": "\(poolSize)"]
            )
        }
    }

    // MARK: - Transaction bookkeeping (internal seam for the coordinator)

    /// Marks `connection` as carrying an open transaction, so a lease that
    /// leaks mid-transaction is rolled back before reuse (see `release`).
    func markTransactionOpen(_ connection: PostgresConnection) {
        state.withLock { _ = $0.openTransactions.insert(ObjectIdentifier(connection)) }
    }

    func markTransactionClosed(_ connection: PostgresConnection) {
        state.withLock { _ = $0.openTransactions.remove(ObjectIdentifier(connection)) }
    }

    // MARK: - Introspection (tests, Actuator)

    /// Connections currently checked out. "Scope close returned the
    /// connection" is `activeCheckouts == 0` after `withScope`.
    public var activeCheckouts: Int { state.withLock { $0.checkedOut.count } }
    /// Connections sitting in the pool ready for reuse.
    public var availableConnections: Int { state.withLock { $0.available.count } }
    /// Live connections, checked out or pooled.
    public var establishedConnections: Int { state.withLock { $0.established } }
    /// Checkouts ever performed, including reuse.
    public var totalCheckouts: Int { state.withLock { $0.totalCheckouts } }
    public var isRunning: Bool { state.withLock { $0.phase == .running } }
    public var isClosed: Bool { state.withLock { $0.phase == .closed } }
}

/// Postgres-specific pool errors beyond the store-agnostic
/// `DataSourceError` vocabulary.
public enum PostgresDataSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Checkout before the pool's service started. Under real bootstrap this
    /// is unreachable (Flight Core: services start before requests are
    /// served); reaching it means a test harness resolved a connection
    /// without starting the module's service.
    case notStarted(datasource: String)

    public var description: String {
        switch self {
        case .notStarted(let datasource):
            return "Datasource '\(datasource)' has not started — its pool dials connections when its service runs (Flight Core). In tests, start the service (or call start()) before resolving connections."
        }
    }
}

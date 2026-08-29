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
/// checkout-or-throw for the synchronous primitive, a parked queue for callers
/// that can await (core delta D8), broken-connection replacement with backoff
/// in the service loop. Everything protocol-level — wire handling, TLS,
/// encoding — stays PostgresNIO's.
///
/// `run()` is the module service's body: no request is served before the
/// pool is live (Flight Core bootstrap ordering), and graceful shutdown
/// drains it.
public final class PostgresDataSource: DataSource, Sendable {
    public typealias Connection = PostgresConnection

    /// The datasource's name — config key segment and registration qualifier.
    public let name: String
    /// Fixed pool size: every connection is dialed at `start()`; checkout
    /// never grows the pool — a caller past the ceiling queues rather than
    /// growing it (core delta D8).
    public let poolSize: Int
    /// The parsed `datasource.<name>.url`.
    public let url: PostgresDataSourceURL
    /// How long `withConnection` queues before `poolExhausted`, from
    /// `datasource.<name>.checkout_timeout_ms`.
    public let checkoutTimeout: Duration

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
        /// Connections released but not yet back in `available` — checked out
        /// by nobody and available to nobody until their `ROLLBACK` and/or
        /// `DISCARD ALL` lands. Shutdown waits on this reaching zero, so
        /// *every* asynchronous return path has to count itself here or
        /// shutdown races the handler that closes the connection.
        var pendingReturns = 0
        var nextConnectionID = 0
        var totalCheckouts = 0
    }

    /// Callers parked in `checkout(waitingUpTo:)`. Core's, not this pool's —
    /// the Valkey pool parks callers in exactly the same one.
    private let waiters = ConnectionWaiters()

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
        self.checkoutTimeout = settings.checkoutTimeout
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
                waiters.wakeOne()
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
        await drainPendingReturns()

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

    /// Waits for outstanding `ROLLBACK`s and `DISCARD ALL`s to finish, so
    /// shutdown does not race the handlers that close their connections.
    private func drainPendingReturns() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.withLock({ $0.pendingReturns }) > 0 {
            guard ContinuousClock.now < deadline else {
                logger.warning(
                    "gave up waiting for connections to finish returning during shutdown",
                    metadata: [
                        "datasource": "\(name)",
                        "outstanding": "\(state.withLock { $0.pendingReturns })",
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

    /// Backoff between failed replacement dials: doubles from 100ms, capped
    /// at 5s, so an outage costs a handful of attempts a minute rather than a
    /// spin. Same numbers as Flight Data Valkey's pool, deliberately — the
    /// two are the same machine and drifting apart is how one of them ends up
    /// with a bug the other already fixed.
    private static let minimumReplacementBackoff = Duration.milliseconds(100)
    private static let maximumReplacementBackoff = Duration.seconds(5)

    private func replaceBrokenConnections() async {
        var backoff = Self.minimumReplacementBackoff
        var consecutiveFailures = 0

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
                waiters.wakeOne()
                if consecutiveFailures > 0 {
                    logger.info(
                        "postgres reachable again; pool refilling",
                        metadata: [
                            "datasource": "\(name)",
                            "failed-attempts": "\(consecutiveFailures)",
                        ])
                } else {
                    logger.info(
                        "replaced broken postgres connection",
                        metadata: ["datasource": "\(name)"])
                }
                backoff = Self.minimumReplacementBackoff
                consecutiveFailures = 0
            } catch {
                // Returning here is what wedged the pool. The reasoning was
                // that "the next checkout/release re-triggers replacement" —
                // but once every connection has been retired there are no more
                // releases, and a checkout that finds an empty free list never
                // reached the broken-connection branch that yields the
                // trigger. The pool sat at zero established, answering
                // `poolExhausted` and blaming the operator's `pool_size`,
                // until the process was restarted: a transient outage became
                // permanent. Flight Data Valkey hit this first and fixed it
                // with exactly this loop; this is the port.
                consecutiveFailures += 1
                logger.warning(
                    "failed to replace broken postgres connection; retrying",
                    metadata: [
                        "datasource": "\(name)",
                        "error": "\(error)",
                        "attempt": "\(consecutiveFailures)",
                        "retry-in": "\(backoff)",
                    ])

                do {
                    try await Task.sleep(for: backoff)
                } catch {
                    return  // cancelled: the service is shutting down
                }
                backoff = min(backoff * 2, Self.maximumReplacementBackoff)
            }
        }
    }

    // MARK: - DataSource

    /// Checks a connection out, waiting up to `timeout` for one to come back.
    ///
    /// The seam's async primitive (core delta D8), overriding the polling
    /// default with this pool's native handoff: a release wakes the
    /// longest-parked caller directly rather than being noticed on a poll.
    public func checkout(waitingUpTo timeout: Duration) async throws -> PostgresConnection {
        try await waiters.checkout(
            waitingUpTo: timeout,
            attempt: checkoutIfAvailable,
            exhausted: { DataSourceError.poolExhausted(datasource: name, poolSize: poolSize) })
    }

    /// `checkout()`'s body, with "nothing free" as a value rather than an
    /// error — the distinction the waiting form needs and the throwing one
    /// does not.
    private func checkoutIfAvailable() throws -> PostgresConnection? {
        var sawBrokenConnection = false
        var poolIsEmpty = false
        defer {
            // The second condition is the wedge insurance: a pool at zero
            // established has no release and no broken connection left to
            // notice, so a checkout finding nothing is the *only* remaining
            // event that can re-arm maintenance.
            if sawBrokenConnection || poolIsEmpty { replacementTrigger.yield() }
        }

        return try state.withLock { state in
            switch state.phase {
            case .closed:
                throw DataSourceError.closed(datasource: name)
            case .idle:
                throw DataSourceError.notStarted(datasource: name)
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
            poolIsEmpty = state.established == 0
            return nil
        }
    }

    /// How many callers are parked waiting for a connection right now, and
    /// the most there have ever been. A pool that is too small says so here
    /// before it says so as errors.
    public var waitingCallers: (now: Int, peak: Int) { waiters.counts }

    public func checkout() throws -> PostgresConnection {
        guard let connection = try checkoutIfAvailable() else {
            throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
        }
        return connection
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
                // Held back until the rollback (and the reset that follows it)
                // lands — see `.rollbackFirst`.
                state.pendingReturns += 1
                return .rollbackFirst
            }
            if resetOnRelease {
                // Held back until the reset lands — see `.resetFirst`.
                state.pendingReturns += 1
                return .resetFirst
            }
            state.available.append(connection)
            return .repool
        }

        switch disposition {
        case .repool:
            // Back in the pool, so whoever is parked can stop waiting. Every
            // path that appends to `available` does this — a connection that
            // comes back with nobody told about it is a caller waiting out
            // its whole timeout beside a free connection.
            waiters.wakeOne()

        case .resetFirst:
            resetAndRepool(connection)

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
                    // …and then reset it like any other release. Rolling back
                    // undoes the *transaction*; it does not undo the session.
                    // A scope that did `SET ROLE tenant_a` and then died
                    // mid-transaction still has that role set after the
                    // rollback, and repooling here — as this path used to —
                    // handed it straight to the next scope: precisely the
                    // cross-tenant read `DISCARD ALL` exists to prevent, on
                    // the one path most likely to be carrying tenant state.
                    enum Next { case reset, repooled, closed }
                    let next = state.withLock { state -> Next in
                        guard state.phase == .running else {
                            state.pendingReturns -= 1
                            state.established -= 1
                            return .closed
                        }
                        if resetOnRelease { return .reset }  // keeps the pendingReturns credit
                        state.pendingReturns -= 1
                        state.available.append(connection)
                        return .repooled
                    }
                    switch next {
                    case .reset: resetAndRepool(connection)
                    case .repooled: waiters.wakeOne()
                    case .closed: connection.close().whenComplete { _ in }
                    }
                case .failure(let error):
                    logger.warning("rollback of leaked transaction failed; dropping connection", metadata: [
                        "datasource": "\(name)", "error": "\(error)",
                    ])
                    state.withLock {
                        $0.pendingReturns -= 1
                        $0.established -= 1
                    }
                    connection.close().whenComplete { _ in }
                    replacementTrigger.yield()
                }
            }
        }
    }

    /// Issues `DISCARD ALL` and repools on success; drops the connection on
    /// failure. The caller must already have counted this connection in
    /// `pendingReturns` — shutdown waits on that count, and this consumes it.
    ///
    /// A pooled connection is a *session*, and a session remembers. `SET
    /// ROLE`, `SET search_path`, `SET app.tenant_id`, prepared statements,
    /// temporary tables, advisory-lock-adjacent state — all of it survived
    /// being returned to the pool and greeted whichever request checked the
    /// connection out next.
    ///
    /// For the row-level-security pattern this package invites, that is a
    /// cross-tenant read: request A sets a tenant, request B inherits it and
    /// sees rows it must not. `DISCARD ALL` is what PgBouncer issues between
    /// sessions for the same reason.
    ///
    /// The connection is not available until the reset succeeds. A reset that
    /// fails means a session in an unknown state, which is exactly what must
    /// not be handed to anyone.
    private func resetAndRepool(_ connection: PostgresConnection) {
        let reset: EventLoopFuture<Void> = connection.query("DISCARD ALL").map { _ in }
        reset.whenComplete { [self] result in
            switch result {
            case .success:
                let repooled = state.withLock { state -> Bool in
                    state.pendingReturns -= 1
                    guard state.phase == .running else { return false }
                    state.available.append(connection)
                    return true
                }
                if repooled {
                    waiters.wakeOne()
                } else {
                    state.withLock { $0.established -= 1 }
                    connection.close().whenComplete { _ in }
                }
            case .failure(let error):
                logger.warning(
                    "session reset failed; dropping the connection rather than reusing it",
                    metadata: ["datasource": "\(name)", "error": "\(error)"]
                )
                state.withLock {
                    $0.pendingReturns -= 1
                    $0.established -= 1
                }
                connection.close().whenComplete { _ in }
                replacementTrigger.yield()
            }
        }
    }

    /// `SELECT 1`, surfaced by Actuator through the `DataSourceLiveness`
    /// component that `register(dataSource:)` registers alongside the pool.
    public func ping() async throws {
        do {
            // The non-waiting checkout on purpose: `withConnection` now queues
            // for `checkoutTimeout`, and a liveness probe that queues answers
            // "alive" five seconds late instead of answering "saturated" now.
            // Saturation is the interesting case here, so ask directly.
            let connection = try checkout()
            defer { release(connection) }
            _ = try await connection.query("SELECT 1", logger: logger)
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
            //
            // *Being checked out* is the load-bearing word, and swallowing
            // this unconditionally is what turned that reasoning into a lie:
            // a pool that has lost every connection to an outage is also
            // "exhausted", with zero of them checked out and nothing working
            // at all. Reported alive, it was the one state an orchestrator
            // most needed to hear about.
            guard establishedConnections > 0 else {
                replacementTrigger.yield()  // nudge maintenance on the way out
                logger.error(
                    "ping found no established connections; reporting dead",
                    metadata: ["datasource": "\(name)", "pool_size": "\(poolSize)"]
                )
                throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
            }
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

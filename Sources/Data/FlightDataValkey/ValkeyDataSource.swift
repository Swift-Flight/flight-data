import FlightDataCore
import Logging
import ServiceLifecycle
import Synchronization
import Valkey

/// The Valkey/Redis pool behind the `DataSource` seam (design, Flight
/// Data Core /): one per configured datasource, registered `.singleton`,
/// its long-running work handed to the `ServiceGroup` via
/// `FlightModule.service`.
///
/// ## Why this pool exists (design delta V1 — see README.md)
///
/// valkey-swift's `ValkeyClient` exposes only scoped async lending
/// (`withConnection`); its `connect()` is internal. The seam needs a
/// *synchronous* `checkout()` (Flight Data Core delta D1: scoped component
/// factories are synchronous), so — exactly as Flight Data Postgres resolved
/// the same tension with PostgresNIO (its delta P1) — this package owns a
/// deliberately small pool. The one twist valkey-swift adds: the only public
/// way to *hold* a connection is inside `ValkeyConnection.withConnection`'s
/// closure. So each pool slot is a **lender task** that dials through that
/// public API and then parks, leaving its connection in the free list until
/// the connection is retired (broken, or pool shutdown); retiring resumes
/// the lender's parked continuation, its closure returns, and the driver
/// closes the connection. Everything protocol-level — RESP framing, TLS,
/// auth, database selection — stays valkey-swift's.
///
/// `run()` is the module service's body: no request is served before the
/// pool is live (Flight Core bootstrap ordering), and graceful shutdown
/// drains it.
///
/// ## Convergence with the Postgres pool (design delta V2)
///
/// These two pools are the same machine with different dial tones, and for a
/// while every fix landed on exactly one of them: outage-recovery backoff here
/// but not there, tolerating a saturated pool in `ping` there but not here,
/// session reset on release there but not here, queueing there but not here.
/// Each gap was a real bug in whichever twin missed it. The queueing machinery
/// now lives in core (`ConnectionWaiters`), and the remaining three landed
/// here together: a fix to one pool ships with its twin.
public final class ValkeyDataSource: DataSource, Sendable {
    public typealias Connection = ValkeyConnection

    /// The datasource's name — config key segment and registration qualifier.
    public let name: String
    /// Fixed pool size: every connection is dialed at `start()`; checkout
    /// never grows the pool — a caller past the ceiling queues rather than
    /// growing it (core delta D2).
    public let poolSize: Int
    /// The parsed `datasource.<name>.url`.
    public let url: ValkeyDataSourceURL
    /// How long `withConnection` queues before `poolExhausted`, from
    /// `datasource.<name>.checkout_timeout_ms`.
    public let checkoutTimeout: Duration

    /// Whether a released connection has its session state cleared before it
    /// is offered to the next scope.
    ///
    /// A Valkey connection is a *session* every bit as much as a Postgres one,
    /// and this pool used to repool it untouched. `SELECT 5` through the raw
    /// command hatch handed the next scope the wrong database; a leaked
    /// `WATCH` made an unrelated `MULTI` abort for no visible reason; a
    /// connection abandoned inside `MULTI` queued the next scope's commands
    /// instead of running them. One pipelined round trip closes all three.
    ///
    /// On by default, and only worth turning off for a deployment certain that
    /// nothing it runs touches session state. The saving is one round trip per
    /// scope; the cost of being wrong is a scope reading the wrong database.
    ///
    /// Deliberately not the server's own `RESET`: that also deauthenticates
    /// the connection, so on any password-protected server the next command
    /// would fail `NOAUTH`. Subscriptions entered through the raw hatch are
    /// likewise out of scope — that hatch is explicitly outside the
    /// compatibility guarantee.
    public let resetOnRelease: Bool

    private let logger: Logger
    private let connectionConfiguration: ValkeyConnectionConfiguration
    private let state: Mutex<PoolState>
    private let replacementSignal: AsyncStream<Void>
    private let replacementTrigger: AsyncStream<Void>.Continuation

    private enum Phase: Equatable {
        case idle       // constructed at freeze(); service not yet started
        case running
        case closed
    }

    private struct PoolState: Sendable {
        var phase: Phase = .idle
        var available: [ValkeyConnection] = []
        var checkedOut: Set<ObjectIdentifier> = []
        /// Checked-out connections whose channel has already closed (the
        /// `onClose` handler fired mid-lease). Retired at release instead of
        /// being repooled.
        var broken: Set<ObjectIdentifier> = []
        /// Parked lender continuations, by connection identity. Resuming one
        /// retires its connection: the lender's `withConnection` closure
        /// returns and the driver closes the connection.
        var parked: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
        /// Connections retired before their lender managed to park (the
        /// close/shutdown raced the park) — the park resumes immediately.
        var retiredBeforePark: Set<ObjectIdentifier> = []
        var established = 0
        var totalCheckouts = 0
        var totalRetired = 0
        /// Connections released but not yet back in `available` — checked out
        /// by nobody and available to nobody until their session reset lands.
        /// Shutdown waits on this being empty, or it retires a connection out
        /// from under an in-flight reset.
        var resetting: Set<ObjectIdentifier> = []
    }

    /// Callers parked in `checkout(waitingUpTo:)`. Core's, not this pool's —
    /// the Postgres pool parks callers in exactly the same one.
    private let waiters = ConnectionWaiters()

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
        // malformed URL fails bootstrap, not the first command (Flight
        // Data Core posture). TLS context construction likewise.
        self.url = try ValkeyDataSourceURL.parse(settings.url, datasource: settings.name)
        self.connectionConfiguration = try self.url.connectionConfiguration()
        self.logger = logger ?? Logger(label: "flight.data.valkey.\(settings.name)")
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

    /// Establishes all `poolSize` connections eagerly. A dial failure here
    /// fails the service — and with it bootstrap — before any request is
    /// served. Exposed separately from `run()` for test harnesses that drive
    /// the lifecycle by hand.
    public func start() async throws {
        state.withLock { state in
            precondition(state.phase == .idle, "ValkeyDataSource.start() called twice for datasource '\(name)'.")
            state.phase = .running
        }
        do {
            for _ in 0..<poolSize {
                guard isRunning else { return }  // shut down mid-start
                try await addConnection()
            }
            logger.info("valkey pool started", metadata: [
                "datasource": "\(name)", "pool_size": "\(poolSize)",
                "host": "\(url.host)", "port": "\(url.port)", "database": "\(url.database)",
            ])
        } catch {
            await shutdown()
            throw error
        }
    }

    /// Replaces broken connections as `onClose`/release discover them, until
    /// cancelled. Exposed for hand-driven test harnesses.
    public func maintainPool() async {
        for await _ in replacementSignal {
            await replaceBrokenConnections()
        }
    }

    /// Closes the pool: further checkouts throw `DataSourceError.closed`,
    /// pooled connections are retired now (their lenders return and the
    /// driver closes them), in-flight ones as they come back.
    public func shutdown() async {
        // Close the door first, then wait for connections still being reset:
        // one of those is in neither `available` nor `checkedOut`, so retiring
        // the free list without waiting would leave its lender parked forever.
        state.withLock { $0.phase = .closed }
        await drainPendingReturns()

        let toResume = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let connections = state.available
            state.available = []
            return connections.compactMap { retireLocked(&state, ObjectIdentifier($0)) }
        }
        replacementTrigger.finish()
        for continuation in toResume {
            continuation.resume()
        }
        logger.info("valkey pool closed", metadata: ["datasource": "\(name)"])
    }

    /// Waits for outstanding session resets to finish, so shutdown does not
    /// race the task that repools or retires their connections.
    private func drainPendingReturns() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !state.withLock({ $0.resetting.isEmpty }) {
            guard ContinuousClock.now < deadline else {
                logger.warning(
                    "gave up waiting for session resets during shutdown",
                    metadata: [
                        "datasource": "\(name)",
                        "outstanding": "\(state.withLock { $0.resetting.count })",
                    ])
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The lender (delta V1)

    /// Starts one lender task and waits until it either parks its dialed
    /// connection in the free list (success) or fails the dial (throws).
    private func addConnection() async throws {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, any Error>) in
            // The lender resumes `started` exactly once: on adoption or on
            // dial failure. After that, the gate is empty and the lender's
            // remaining lifetime belongs to the pool's own bookkeeping.
            let startedGate = Mutex<CheckedContinuation<Void, any Error>?>(started)
            let resumeStarted: @Sendable (Result<Void, any Error>) -> Void = { result in
                guard let continuation = startedGate.withLock({ gate in
                    defer { gate = nil }
                    return gate
                }) else { return }
                continuation.resume(with: result)
            }

            Task { [self] in
                do {
                    try await ValkeyConnection.withConnection(
                        address: url.address,
                        configuration: connectionConfiguration,
                        logger: logger
                    ) { connection in
                        let id = ObjectIdentifier(connection)
                        // Installed before adoption so a close can never slip
                        // between the two; closeFuture fires the handler even
                        // if the channel is already closed.
                        connection.onClose { [weak self] _ in
                            self?.connectionDidClose(id)
                        }
                        let adopted = self.adopt(connection)
                        resumeStarted(.success(()))
                        guard adopted else { return }  // pool closed mid-dial
                        await self.parkUntilRetired(id)
                    }
                } catch {
                    resumeStarted(.failure(error))
                }
            }
        }
    }

    private func adopt(_ connection: ValkeyConnection) -> Bool {
        let adopted = state.withLock { state in
            guard state.phase == .running else { return false }
            state.available.append(connection)
            state.established += 1
            return true
        }
        if adopted { waiters.wakeOne() }
        return adopted
    }

    private func parkUntilRetired(_ id: ObjectIdentifier) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.retiredBeforePark.remove(id) != nil {
                    return true
                }
                state.parked[id] = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    /// Marks `id` retired and returns the parked continuation to resume (nil
    /// when the retirement raced the park; the park then resumes itself).
    /// Callers must already have removed the connection from
    /// `available`/`checkedOut`. Must run under the state lock.
    private func retireLocked(_ state: inout PoolState, _ id: ObjectIdentifier) -> CheckedContinuation<Void, Never>? {
        state.established -= 1
        state.totalRetired += 1
        if let continuation = state.parked.removeValue(forKey: id) {
            return continuation
        }
        state.retiredBeforePark.insert(id)
        return nil
    }

    /// The `onClose` handler: a pooled connection's channel closed under us.
    /// Free-list connections are retired immediately and replaced; a
    /// checked-out one is flagged broken and retired at release.
    private func connectionDidClose(_ id: ObjectIdentifier) {
        let (continuation, needsReplacement) = state.withLock {
            state -> (CheckedContinuation<Void, Never>?, Bool) in
            if let index = state.available.firstIndex(where: { ObjectIdentifier($0) == id }) {
                state.available.remove(at: index)
                return (retireLocked(&state, id), state.phase == .running)
            }
            if state.checkedOut.contains(id) {
                state.broken.insert(id)
            }
            // Neither pooled nor leased: already retired (e.g. the driver
            // closing it after its lender returned). Nothing to do.
            return (nil, false)
        }
        continuation?.resume()
        if needsReplacement {
            logger.warning("pooled valkey connection closed; replacing", metadata: ["datasource": "\(name)"])
            replacementTrigger.yield()
        }
    }

    /// Backoff between failed replacement dials: doubles from 100ms, capped
    /// at 5s, so an outage costs a handful of attempts a minute rather than a
    /// spin.
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
                try await addConnection()
                if consecutiveFailures > 0 {
                    logger.info(
                        "valkey reachable again; pool refilling",
                        metadata: [
                            "datasource": "\(name)",
                            "failed-attempts": "\(consecutiveFailures)",
                        ])
                }
                backoff = Self.minimumReplacementBackoff
                consecutiveFailures = 0
            } catch {
                // Returning here is what wedged the pool. The reasoning was
                // that "the next close/release re-triggers replacement" — but
                // once every connection has been retired there are no more
                // closes and no more releases, so nothing ever re-triggered
                // it. The pool sat at zero established, answering
                // `poolExhausted` and blaming the operator's `pool_size`,
                // until the process was restarted. A transient outage became
                // permanent.
                consecutiveFailures += 1
                logger.warning(
                    "failed to replace broken valkey connection; retrying",
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

    public func checkout() throws -> ValkeyConnection {
        guard let connection = try checkoutIfAvailable() else {
            throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
        }
        return connection
    }

    /// Checks a connection out, waiting up to `timeout` for one to come back.
    ///
    /// The seam's async primitive (core delta D2), overriding the polling
    /// default with this pool's native handoff: a release wakes the
    /// longest-parked caller directly rather than being noticed on a poll.
    public func checkout(waitingUpTo timeout: Duration) async throws -> ValkeyConnection {
        try await waiters.checkout(
            waitingUpTo: timeout,
            attempt: checkoutIfAvailable,
            exhausted: { DataSourceError.poolExhausted(datasource: name, poolSize: poolSize) })
    }

    /// `checkout()`'s body, with "nothing free" as a value rather than an
    /// error — the distinction the waiting form needs and the throwing one
    /// does not.
    private func checkoutIfAvailable() throws -> ValkeyConnection? {
        try state.withLock { state in
            switch state.phase {
            case .closed:
                throw DataSourceError.closed(datasource: name)
            case .idle:
                throw ValkeyDataSourceError.notStarted(datasource: name)
            case .running:
                break
            }
            guard let connection = state.available.popLast() else { return nil }
            state.checkedOut.insert(ObjectIdentifier(connection))
            state.totalCheckouts += 1
            return connection
        }
    }

    public func release(_ connection: ValkeyConnection) {
        enum Disposition {
            case retire(CheckedContinuation<Void, Never>?, replace: Bool)
            case repool
            case resetFirst
        }

        let id = ObjectIdentifier(connection)
        let disposition = state.withLock { state -> Disposition in
            precondition(
                state.checkedOut.remove(id) != nil,
                "release of a connection that is not checked out from datasource '\(name)' — double release, or a foreign connection"
            )
            if state.phase == .closed {
                state.broken.remove(id)
                return .retire(retireLocked(&state, id), replace: false)
            }
            if state.broken.remove(id) != nil {
                return .retire(retireLocked(&state, id), replace: true)
            }
            if resetOnRelease {
                // Held back until the reset lands — see `resetAndRepool`.
                state.resetting.insert(id)
                return .resetFirst
            }
            state.available.append(connection)
            return .repool
        }

        switch disposition {
        case .retire(let continuation, let replace):
            continuation?.resume()
            if replace { replacementTrigger.yield() }
        case .repool:
            // Back in the pool, so whoever is parked can stop waiting. Every
            // path that appends to `available` does this — a connection that
            // comes back with nobody told about it is a caller waiting out its
            // whole timeout beside a free connection.
            waiters.wakeOne()
        case .resetFirst:
            // Release is synchronous and non-throwing by contract, so the
            // round trip runs off it. The connection is not in `available`
            // until the reset lands: a session in an unknown state is exactly
            // what must not be handed to anyone.
            Task { await resetAndRepool(connection) }
        }
    }

    /// Clears session state and repools, or retires the connection if the
    /// reset did not land. The caller must already have put `connection` in
    /// `resetting` — shutdown waits on that, and this clears it.
    private func resetAndRepool(_ connection: ValkeyConnection) async {
        let id = ObjectIdentifier(connection)

        // One pipelined round trip, in this order for a reason: a connection
        // abandoned inside `MULTI` *queues* whatever it is sent next, so
        // `DISCARD` has to go first or the reset itself would be queued rather
        // than run. `DISCARD` then fails with "without MULTI" in the common
        // case, which is why individual failures are tolerated and only the
        // trailing `SELECT` — the one that has to have taken effect — decides
        // whether the connection is reusable.
        let commands: [any ValkeyCommand] = [
            ValkeyRawCommand("DISCARD", arguments: []),
            ValkeyRawCommand("UNWATCH", arguments: []),
            ValkeyRawCommand("SELECT", arguments: ["\(url.database)"]),
        ]
        let results = await connection.execute(commands)
        var failure: (any Error)?
        if case .failure(let error) = results.last { failure = error }

        let disposition = state.withLock { state -> (CheckedContinuation<Void, Never>?, Bool) in
            state.resetting.remove(id)
            guard state.phase == .running, failure == nil else {
                return (retireLocked(&state, id), state.phase == .running)
            }
            state.available.append(connection)
            return (nil, false)
        }

        if let failure {
            logger.warning(
                "session reset failed; dropping the connection rather than reusing it",
                metadata: ["datasource": "\(name)", "error": "\(failure)"])
        }
        if let continuation = disposition.0 {
            continuation.resume()
        } else {
            waiters.wakeOne()
        }
        if disposition.1 { replacementTrigger.yield() }
    }

    /// `PING`, surfaced by Actuator through the `DataSourceLiveness`
    /// component that `register(dataSource:)` registers alongside the pool
    ///.
    public func ping() async throws {
        do {
            // The non-waiting checkout on purpose: `withConnection` queues for
            // `checkoutTimeout`, and a liveness probe that queues answers
            // "alive" five seconds late instead of answering now.
            let connection = try checkout()
            defer { release(connection) }
            _ = try await connection.ping()
        } catch DataSourceError.poolExhausted {
            // A full pool is not a dead server. Propagating this — as this
            // driver used to, while its Postgres twin had already stopped —
            // failed a liveness probe under exactly the load the service was
            // handling successfully, and an orchestrator restarted a pod whose
            // only problem was being busy.
            //
            // *Being checked out* is the load-bearing part: connections that
            // are all busy are positive evidence connections exist and work. A
            // pool that has lost every connection to an outage is "exhausted"
            // too, with none of them checked out and nothing working at all,
            // and that one has to be reported.
            guard establishedConnections > 0 else {
                replacementTrigger.yield()  // nudge maintenance on the way out
                logger.error(
                    "ping found no established connections; reporting dead",
                    metadata: ["datasource": "\(name)", "pool_size": "\(poolSize)"])
                throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
            }
            logger.debug(
                "ping found the pool saturated; reporting alive",
                metadata: ["datasource": "\(name)", "pool_size": "\(poolSize)"])
        }
    }

    /// How many callers are parked waiting for a connection right now, and
    /// the most there have ever been. A pool that is too small says so here
    /// before it says so as errors.
    public var waitingCallers: (now: Int, peak: Int) { waiters.counts }

    // MARK: - Introspection (tests, Actuator)

    /// Connections currently checked out. "Scope close returned the
    /// connection" is `activeCheckouts == 0` after `withScope`.
    public var activeCheckouts: Int { state.withLock { $0.checkedOut.count } }
    /// Connections sitting in the free list ready for reuse.
    public var availableConnections: Int { state.withLock { $0.available.count } }
    /// Live connections, checked out or pooled.
    public var establishedConnections: Int { state.withLock { $0.established } }
    /// Checkouts ever performed, including reuse.
    public var totalCheckouts: Int { state.withLock { $0.totalCheckouts } }
    /// Connections ever retired — broken ones noticed by `onClose`, plus
    /// pool drain at shutdown. A rising count while running means the server
    /// is dropping connections.
    public var retiredConnections: Int { state.withLock { $0.totalRetired } }
    public var isRunning: Bool { state.withLock { $0.phase == .running } }
    public var isClosed: Bool { state.withLock { $0.phase == .closed } }
}

/// Valkey-specific pool errors beyond the store-agnostic `DataSourceError`
/// vocabulary.
public enum ValkeyDataSourceError: Error, Sendable, Equatable, CustomStringConvertible {
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

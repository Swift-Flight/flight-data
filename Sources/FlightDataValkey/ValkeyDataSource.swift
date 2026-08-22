import FlightDataCore
import Logging
import ServiceLifecycle
import Synchronization
import Valkey

/// The Valkey/Redis pool behind the `DataSource` seam (design §4.1, Flight
/// Data Core §2/§3): one per configured datasource, registered `.singleton`,
/// its long-running work handed to the `ServiceGroup` via
/// `FlightModule.service` (§6).
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
/// pool is live (Flight Core §7 bootstrap ordering), and graceful shutdown
/// drains it.
public final class ValkeyDataSource: DataSource, Sendable {
    public typealias Connection = ValkeyConnection

    /// The datasource's name — config key segment and registration qualifier.
    public let name: String
    /// Fixed pool size: every connection is dialed at `start()`; checkout
    /// never grows the pool (Flight Data Core §2: prompt or throw).
    public let poolSize: Int
    /// The parsed `datasource.<name>.url`.
    public let url: ValkeyDataSourceURL

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
    }

    public init(settings: DataSourceSettings, logger: Logger? = nil) throws {
        self.name = settings.name
        self.poolSize = settings.poolSize
        // Parsed here — at freeze()'s eager singleton construction — so a
        // malformed URL fails bootstrap, not the first command (§3.2, Flight
        // Data Core §4 posture). TLS context construction likewise.
        self.url = try ValkeyDataSourceURL.parse(settings.url, datasource: settings.name)
        self.connectionConfiguration = try self.url.connectionConfiguration()
        self.logger = logger ?? Logger(label: "flight.data.valkey.\(settings.name)")
        self.state = Mutex(PoolState())
        (self.replacementSignal, self.replacementTrigger) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Service body (§6)

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
        let toResume = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.phase = .closed
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
        state.withLock { state in
            guard state.phase == .running else { return false }
            state.available.append(connection)
            state.established += 1
            return true
        }
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

    private func replaceBrokenConnections() async {
        while true {
            let deficit = state.withLock { state -> Int in
                state.phase == .running ? poolSize - state.established : 0
            }
            guard deficit > 0 else { return }
            do {
                try await addConnection()
                logger.info("replaced broken valkey connection", metadata: ["datasource": "\(name)"])
            } catch {
                // The server is unreachable; the next close/release that
                // notices a broken connection re-triggers replacement, and
                // pings keep Actuator honest in the meantime.
                logger.warning("failed to replace broken valkey connection", metadata: [
                    "datasource": "\(name)", "error": "\(error)",
                ])
                return
            }
        }
    }

    // MARK: - DataSource

    public func checkout() throws -> ValkeyConnection {
        try state.withLock { state in
            switch state.phase {
            case .closed:
                throw DataSourceError.closed(datasource: name)
            case .idle:
                throw ValkeyDataSourceError.notStarted(datasource: name)
            case .running:
                break
            }
            guard let connection = state.available.popLast() else {
                throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
            }
            state.checkedOut.insert(ObjectIdentifier(connection))
            state.totalCheckouts += 1
            return connection
        }
    }

    public func release(_ connection: ValkeyConnection) {
        let id = ObjectIdentifier(connection)
        let (continuation, needsReplacement) = state.withLock {
            state -> (CheckedContinuation<Void, Never>?, Bool) in
            precondition(
                state.checkedOut.remove(id) != nil,
                "release of a connection that is not checked out from datasource '\(name)' — double release, or a foreign connection"
            )
            if state.phase == .closed {
                state.broken.remove(id)
                return (retireLocked(&state, id), false)
            }
            if state.broken.remove(id) != nil {
                return (retireLocked(&state, id), true)
            }
            state.available.append(connection)
            return (nil, false)
        }
        continuation?.resume()
        if needsReplacement {
            replacementTrigger.yield()
        }
    }

    /// `PING`, surfaced by Actuator through the `DataSourceLiveness`
    /// component that `register(dataSource:)` registers alongside the pool
    /// (design §4.1).
    public func ping() async throws {
        try await withConnection { connection in
            _ = try await connection.ping()
        }
    }

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
    /// is unreachable (Flight Core §7: services start before requests are
    /// served); reaching it means a test harness resolved a connection
    /// without starting the module's service.
    case notStarted(datasource: String)

    public var description: String {
        switch self {
        case .notStarted(let datasource):
            return "Datasource '\(datasource)' has not started — its pool dials connections when its service runs (Flight Core §7). In tests, start the service (or call start()) before resolving connections."
        }
    }
}

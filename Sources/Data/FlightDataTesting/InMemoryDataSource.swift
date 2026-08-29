import FlightDataCore
import Synchronization

/// A connection backed by nothing. Reference semantics on purpose:
/// scoping tests assert connection *identity* (`===`) — "same connection
/// within one scope" is the property under test.
public final class InMemoryConnection: Sendable {
    /// Stable id, assigned in creation order starting at 1 — lets tests
    /// assert reuse ("the second scope got the first scope's connection
    /// back") without holding references across scopes.
    public let id: Int
    /// The pool this connection belongs to, by name.
    public let datasourceName: String

    private let journalStorage = Mutex<[String]>([])

    internal init(id: Int, datasourceName: String) {
        self.id = id
        self.datasourceName = datasourceName
    }

    /// Records one unit of pretend work. A test double's observation hook —
    /// deliberately *not* a query API; there is nothing behind it but
    /// this list.
    public func perform(_ work: String) {
        journalStorage.withLock { $0.append(work) }
    }

    /// Everything `perform`ed on this connection, in order, across all
    /// checkouts — a pooled connection's journal survives release and reuse.
    public var journal: [String] {
        journalStorage.withLock { $0 }
    }
}

/// A `DataSource` conformance backed by nothing — real pool semantics
/// (bounded size, checkout/release accounting, close), no store behind it.
/// Useful for verifying scoping and lifecycle without a live database; store
/// packages provide their own integration-test support against real servers.
///
/// Connections are created lazily up to `poolSize`, so the source works with
/// no service running — a `TestContainer` needs no `ServiceGroup`. Released
/// connections are reused, newest first.
public final class InMemoryDataSource: DataSource, Sendable {
    public typealias Connection = InMemoryConnection

    public let name: String
    public let poolSize: Int
    /// How long `withConnection` queues before `poolExhausted` (core delta
    /// D2). The fake parks callers in core's own `ConnectionWaiters`, the same
    /// one both real drivers use, so a test written against this exercises the
    /// queueing machinery rather than a simplified stand-in.
    public let checkoutTimeout: Duration

    private struct PoolState {
        var available: [InMemoryConnection] = []
        var checkedOut: Set<ObjectIdentifier> = []
        var created = 0
        var totalCheckouts = 0
        var closed = false
    }

    private let state: Mutex<PoolState>
    private let pingFailure = Mutex<(any Error)?>(nil)
    private let waiters = ConnectionWaiters()

    public init(
        name: String = PrimaryDataSource.name,
        poolSize: Int = 4,
        checkoutTimeout: Duration = DataSourceSettings.defaultCheckoutTimeout
    ) {
        precondition(poolSize >= 1, "a pool needs at least 1 connection")
        self.name = name
        self.poolSize = poolSize
        self.checkoutTimeout = checkoutTimeout
        self.state = Mutex(PoolState())
    }

    public convenience init(settings: DataSourceSettings) {
        self.init(
            name: settings.name,
            poolSize: settings.poolSize,
            checkoutTimeout: settings.checkoutTimeout)
    }

    // MARK: - DataSource

    public func checkout() throws -> InMemoryConnection {
        guard let connection = try checkoutIfAvailable() else {
            throw DataSourceError.poolExhausted(datasource: name, poolSize: poolSize)
        }
        return connection
    }

    public func checkout(waitingUpTo timeout: Duration) async throws -> InMemoryConnection {
        try await waiters.checkout(
            waitingUpTo: timeout,
            attempt: checkoutIfAvailable,
            exhausted: { DataSourceError.poolExhausted(datasource: name, poolSize: poolSize) })
    }

    private func checkoutIfAvailable() throws -> InMemoryConnection? {
        try state.withLock { state in
            guard !state.closed else {
                throw DataSourceError.closed(datasource: name)
            }
            let connection: InMemoryConnection
            if let reused = state.available.popLast() {
                connection = reused
            } else if state.created < poolSize {
                state.created += 1
                connection = InMemoryConnection(id: state.created, datasourceName: name)
            } else {
                return nil
            }
            state.checkedOut.insert(ObjectIdentifier(connection))
            state.totalCheckouts += 1
            return connection
        }
    }

    public func release(_ connection: InMemoryConnection) {
        let repooled = state.withLock { state -> Bool in
            let id = ObjectIdentifier(connection)
            precondition(
                state.checkedOut.remove(id) != nil,
                "release of a connection that is not checked out from datasource '\(name)' — double release, or a foreign connection"
            )
            // After close, returned connections are dropped, not repooled.
            guard !state.closed else { return false }
            state.available.append(connection)
            return true
        }
        if repooled { waiters.wakeOne() }
    }

    public func ping() async throws {
        if state.withLock({ $0.closed }) {
            throw DataSourceError.closed(datasource: name)
        }
        if let failure = pingFailure.withLock({ $0 }) {
            throw failure
        }
    }

    // MARK: - Lifecycle

    /// Shuts the pool down: further checkouts throw `DataSourceError.closed`,
    /// pooled connections are dropped, in-flight ones are dropped as they
    /// come back. What a store module's service does when the ServiceGroup
    /// winds down.
    public func close() {
        state.withLock { state in
            state.closed = true
            state.available.removeAll()
        }
    }

    // MARK: - Test introspection

    /// Connections currently checked out. The assertion "scope close
    /// returned the connection" is `activeCheckouts == 0` after `withScope`.
    public var activeCheckouts: Int {
        state.withLock { $0.checkedOut.count }
    }

    /// Connections sitting in the pool, ready for reuse.
    public var availableConnections: Int {
        state.withLock { $0.available.count }
    }

    /// Distinct connections ever created (≤ `poolSize`).
    public var connectionsCreated: Int {
        state.withLock { $0.created }
    }

    /// Checkouts ever performed, including reuse.
    public var totalCheckouts: Int {
        state.withLock { $0.totalCheckouts }
    }

    public var isClosed: Bool {
        state.withLock { $0.closed }
    }

    /// How many callers are parked waiting for a connection right now, and
    /// the most there have ever been.
    public var waitingCallers: (now: Int, peak: Int) { waiters.counts }

    /// Makes subsequent `ping()`s throw `error` — for testing liveness
    /// surfacing without a store to actually take down.
    public func failPings(with error: any Error) {
        pingFailure.withLock { $0 = error }
    }

    /// Undoes `failPings(with:)`.
    public func restorePings() {
        pingFailure.withLock { $0 = nil }
    }
}

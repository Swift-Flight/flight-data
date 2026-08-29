import FlightCore
import FlightDataCore
import Hangar
import Logging
import NIOCore
import PostgresNIO
import Synchronization

/// The Postgres implementation of `FlightTransactionCoordinator`:
/// what `@Transactional`'s generated `begin`/`commit`/`rollback` calls reach
/// when a unit of work runs under `withPostgresScope` /
/// `withPostgresTransactions`.
///
/// - **Operates on the scope's connection.** `begin()` resolves the ambient
///   scope's `ScopedConnection` lease — the same connection every repository
///   in that scope uses — and issues `BEGIN` on it. Called outside an active
///   `Scope`, it throws `ResolutionError.noActiveScope` (whether a caller
///   is inside `withScope` is genuinely runtime information, so this is the
///   residual throwing case the project rule reserves).
/// - **Nesting maps to savepoints**: a `begin()` under an already-open
///   transaction issues `SAVEPOINT flight_sp_<depth>`; its commit issues
///   `RELEASE SAVEPOINT`; its rollback `ROLLBACK TO SAVEPOINT`.
/// - **Two conformances, one bookkeeping** (Core delta 14): the type is both
///   the sync `FlightTransactionCoordinator` and the async-native
///   `FlightAsyncTransactionCoordinator`. Async `@Transactional` methods —
///   the common shape — reach the async conformance, whose control
///   statements are *awaited* on PostgresNIO's modern query API. Sync
///   methods can't await, so their path remains **the sync/async bridge**
///   (delta P2): transaction-control statements through the
///   `EventLoopFuture` query API, blocking the calling thread on `wait()`.
///   That bridge is deadlock-free by construction — the future completes on
///   the connection's NIO event loop, which never depends on the blocked
///   thread — and costs one short round-trip per control statement; calling
///   it from an event-loop thread would deadlock and is rejected with
///   `PostgresTransactionError.calledFromEventLoop`.
///
/// One coordinator per datasource, registered `.singleton` by
/// `PostgresDataModule`. Transactional methods within a single scope must
/// not run concurrently with each other — a scope has one connection, and a
/// transaction is a serial protocol on it (the same constraint Spring's
/// thread-bound transactions carry).
public final class PostgresTransactionCoordinator: FlightTransactionCoordinator, Sendable {
    private let container: Container
    /// The datasource whose scoped connection this coordinator manages.
    public let datasource: String
    private let logger: Logger

    private struct Frame {
        let connectionID: ObjectIdentifier
        let level: Int  // 0 = outermost BEGIN; n>0 = SAVEPOINT flight_sp_n
        let connection: PostgresConnection
    }

    /// Bookkeeping is keyed by *connection*, not scope: a checked-out
    /// connection belongs to exactly one scope, the pool is a small fixed
    /// set (so state stays bounded even if a scope dies mid-transaction),
    /// and `begin()` can recognize a connection re-checked-out by a *new*
    /// scope — stale bookkeeping from a torn unit of work the pool already
    /// rolled back — and start fresh.
    private struct ConnectionTx: Sendable {
        var scopeID: ObjectIdentifier
        var depth: Int
    }

    private struct State: Sendable {
        var connections: [ObjectIdentifier: ConnectionTx] = [:]
        var frames: [UInt64: Frame] = [:]
        var nextToken: UInt64 = 1
    }

    private let state = Mutex(State())

    public init(container: Container, datasource: String = PrimaryDataSource.name) {
        self.container = container
        self.datasource = datasource
        self.logger = Logger(label: "flight.data.postgres.tx.\(datasource)")
    }

    // MARK: - FlightTransactionCoordinator (sync — the bridge path)

    public func begin() throws -> FlightTransactionToken {
        let context = try prepareBegin()
        if context.level == 0 {
            try run("BEGIN", on: context.connection)
            try markTransactionOpen(context.connection)
        } else {
            try run("SAVEPOINT \(savepointName(context.level))", on: context.connection)
        }
        return recordBegin(context)
    }

    public func commit(_ token: FlightTransactionToken) throws {
        let frame = try popFrame(for: token, expectInnermost: true)
        if frame.level == 0 {
            defer { markTransactionClosed(frame.connection) }
            // A failed COMMIT (e.g. a deferred constraint) aborts the
            // transaction server-side; rethrowing turns it into the method's
            // thrown error, exactly as if the body had failed.
            try run("COMMIT", on: frame.connection)
        } else {
            try run("RELEASE SAVEPOINT \(savepointName(frame.level))", on: frame.connection)
        }
    }

    public func rollback(_ token: FlightTransactionToken) {
        let frame: Frame
        do {
            frame = try popFrame(for: token, expectInnermost: false)
        } catch {
            logger.warning("rollback of unknown transaction token \(token.id) ignored")
            return
        }
        do {
            if frame.level == 0 {
                defer { markTransactionClosed(frame.connection) }
                try run("ROLLBACK", on: frame.connection)
            } else {
                // The savepoint stays defined after ROLLBACK TO — deliberate:
                // a later begin() at this level re-issues SAVEPOINT with the
                // same name, which Postgres replaces. One round-trip, not two.
                try run("ROLLBACK TO SAVEPOINT \(savepointName(frame.level))", on: frame.connection)
            }
        } catch {
            // Non-throwing by contract (a second error would mask the one
            // that triggered rollback). A connection this failed on is
            // rolled back or dropped by the pool when the scope releases it.
            logger.error("transaction rollback failed", metadata: [
                "datasource": "\(datasource)", "error": "\(error)",
            ])
        }
    }

    // MARK: - Shared bookkeeping (sync and async paths)

    private struct BeginContext {
        let connection: PostgresConnection
        let connectionID: ObjectIdentifier
        let scopeID: ObjectIdentifier
        let level: Int
    }

    /// Whether this coordinator currently holds an open transaction on
    /// `connection`.
    ///
    /// The seam a scoped `Repo` needs. Hangar cannot ask a `PostgresConnection`
    /// whether it is inside a transaction — PostgresNIO does not expose the
    /// protocol's transaction status — so a repo bound to a connection that is
    /// already in one would emit a literal `BEGIN`/`COMMIT` and its `COMMIT`
    /// would end the enclosing transaction, making work the caller intended to
    /// roll back durable.
    ///
    /// The coordinator does know, because it opened it.
    public func isTransactionOpen(on connection: PostgresConnection) -> Bool {
        let connectionID = ObjectIdentifier(connection)
        return state.withLock { state in
            // Written as an explicit `guard let`, not
            // `state.connections[connectionID]?.depth ?? 0 > 0`. Swift 6.2.3
            // on Linux miscompiles `dictionary[key]?.field ?? default` in
            // -Onone builds when the value is a multi-field struct: the
            // missing-key path reads uninitialized memory instead of the
            // default, so a lookup that misses reports a garbage depth and
            // this method answers "yes, in a transaction" for a connection
            // that is not. Every scoped Repo then nests as a savepoint with
            // no enclosing BEGIN — Postgres 25P01, on the first write of
            // every request. Release builds are unaffected, which is what
            // makes it worth a comment rather than a silent rewrite.
            guard let entry = state.connections[connectionID] else { return false }
            return entry.depth > 0
        }
    }

    /// Resolves the ambient scope's connection and computes the nesting
    /// level — everything `begin()` does except the control statement itself.
    private func prepareBegin() throws -> BeginContext {
        guard let scope = Scope.active else {
            throw ResolutionError.noActiveScope(
                "@Transactional (datasource '\(datasource)') — transactional methods must run inside an active Scope; open one with withPostgresScope or bind an existing one with withPostgresTransactions"
            )
        }
        let connection = try container.resolve(
            ScopedConnection<PostgresDataSource>.self, qualifier: datasource, in: scope
        ).connection

        let scopeID = ObjectIdentifier(scope)
        let connectionID = ObjectIdentifier(connection)
        let level = state.withLock { state -> Int in
            guard let entry = state.connections[connectionID] else { return 0 }
            if entry.scopeID == scopeID {
                return entry.depth  // genuinely nested within this scope
            }
            // Stale bookkeeping: a previous scope died mid-transaction, the
            // pool rolled the connection back on release, and it has been
            // re-checked-out by a new scope. Start over.
            state.frames = state.frames.filter { $0.value.connectionID != connectionID }
            state.connections.removeValue(forKey: connectionID)
            return 0
        }
        return BeginContext(
            connection: connection, connectionID: connectionID,
            scopeID: scopeID, level: level)
    }

    private func recordBegin(_ context: BeginContext) -> FlightTransactionToken {
        state.withLock { state in
            let token = state.nextToken
            state.nextToken += 1
            state.frames[token] = Frame(
                connectionID: context.connectionID, level: context.level,
                connection: context.connection)
            state.connections[context.connectionID] = ConnectionTx(
                scopeID: context.scopeID, depth: context.level + 1)
            return FlightTransactionToken(id: token)
        }
    }

    private func markTransactionOpen(_ connection: PostgresConnection) throws {
        try container.resolve(PostgresDataSource.self, qualifier: datasource)
            .markTransactionOpen(connection)
    }

    private func markTransactionClosed(_ connection: PostgresConnection) {
        try? container.resolve(PostgresDataSource.self, qualifier: datasource)
            .markTransactionClosed(connection)
    }

    // MARK: - Internals

    private func savepointName(_ level: Int) -> String {
        "flight_sp_\(level)"
    }

    private func popFrame(for token: FlightTransactionToken, expectInnermost: Bool) throws -> Frame {
        try state.withLock { state in
            guard let frame = state.frames.removeValue(forKey: token.id) else {
                throw PostgresTransactionError.unknownToken(token.id)
            }
            // Same -Onone miscompile as isTransactionOpen — see the comment there.
            let depth = state.connections[frame.connectionID].map { $0.depth } ?? 0
            if expectInnermost && depth != frame.level + 1 {
                throw PostgresTransactionError.misorderedCompletion(
                    tokenLevel: frame.level, openDepth: depth)
            }
            // Rolling back an outer frame implicitly discards any leaked
            // inner frames; drop their bookkeeping too.
            if !expectInnermost {
                state.frames = state.frames.filter {
                    !($0.value.connectionID == frame.connectionID && $0.value.level > frame.level)
                }
            }
            if frame.level == 0 {
                state.connections.removeValue(forKey: frame.connectionID)
            } else {
                state.connections[frame.connectionID]?.depth = frame.level
            }
            return frame
        }
    }

    /// Transaction-control statements through the future-based API,
    /// synchronously — the bridge sync `@Transactional` methods use. See the
    /// type comment for why this is deadlock-free.
    private func run(_ sql: String, on connection: PostgresConnection) throws {
        guard !connection.eventLoop.inEventLoop else {
            throw PostgresTransactionError.calledFromEventLoop
        }
        let future: EventLoopFuture<Void> = connection.query(sql).map { _ in }
        try future.wait()
    }

    /// The async-native counterpart (Core delta 14): awaited, no blocked
    /// thread, callable from any context — the event-loop guard applies only
    /// to the blocking bridge. `unsafeSQL` because control statements carry
    /// no user data (the only interpolation is the coordinator's own
    /// savepoint counter).
    private func runAsync(_ sql: String, on connection: PostgresConnection) async throws {
        _ = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
    }
}

// MARK: - Async-native conformance (Core delta 14)

/// The same bookkeeping, the same statements, awaited instead of blocked on.
/// `withPostgresScope`/`withPostgresTransactions` bind this conformance as
/// `FlightTransactions.asyncCoordinator`, so async `@Transactional` methods
/// (the common shape — repository I/O is async) never touch the
/// `EventLoopFuture.wait()` bridge; sync methods still use it, as the only
/// thing a non-async body can call (delta P2's recorded trade, now confined
/// to the sync case).
extension PostgresTransactionCoordinator: FlightAsyncTransactionCoordinator {
    public func begin() async throws -> FlightTransactionToken {
        let context = try prepareBegin()
        if context.level == 0 {
            try await runAsync("BEGIN", on: context.connection)
            try markTransactionOpen(context.connection)
        } else {
            try await runAsync("SAVEPOINT \(savepointName(context.level))", on: context.connection)
        }
        return recordBegin(context)
    }

    public func commit(_ token: FlightTransactionToken) async throws {
        let frame = try popFrame(for: token, expectInnermost: true)
        if frame.level == 0 {
            defer { markTransactionClosed(frame.connection) }
            try await runAsync("COMMIT", on: frame.connection)
        } else {
            try await runAsync("RELEASE SAVEPOINT \(savepointName(frame.level))", on: frame.connection)
        }
    }

    public func rollback(_ token: FlightTransactionToken) async {
        let frame: Frame
        do {
            frame = try popFrame(for: token, expectInnermost: false)
        } catch {
            logger.warning("rollback of unknown transaction token \(token.id) ignored")
            return
        }
        do {
            if frame.level == 0 {
                defer { markTransactionClosed(frame.connection) }
                try await runAsync("ROLLBACK", on: frame.connection)
            } else {
                try await runAsync("ROLLBACK TO SAVEPOINT \(savepointName(frame.level))", on: frame.connection)
            }
        } catch {
            logger.error("transaction rollback failed", metadata: [
                "datasource": "\(datasource)", "error": "\(error)",
            ])
        }
    }
}

public enum PostgresTransactionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `commit`/`rollback` with a token this coordinator never issued (or
    /// already completed) — a torn or double completion.
    case unknownToken(UInt64)
    /// `commit` of a frame that is not the innermost open one — transactional
    /// methods in one scope interleaved rather than nested, which a single
    /// connection cannot serialize.
    case misorderedCompletion(tokenLevel: Int, openDepth: Int)
    /// The coordinator was invoked from a NIO event-loop thread, where
    /// blocking on the connection's own event loop would deadlock. Run
    /// transactional work from Swift-concurrency or app threads.
    case calledFromEventLoop

    public var description: String {
        switch self {
        case .unknownToken(let id):
            return "Transaction token \(id) is unknown to this coordinator — completed twice, or issued by another coordinator."
        case .misorderedCompletion(let level, let depth):
            return "Transaction at nesting level \(level) completed while depth is \(depth). Transactional methods in one scope must nest, not interleave — do not run them concurrently on one scope."
        case .calledFromEventLoop:
            return "@Transactional ran on a NIO event-loop thread; the synchronous BEGIN/COMMIT bridge would deadlock there. Dispatch the unit of work onto Swift concurrency first."
        }
    }
}

// MARK: - Binding the coordinator and scope around a unit of work

extension Container {
    /// Opens a `Scope` and runs `body` with both task-locals `@Transactional`
    /// needs bound: `Scope.active` (so `begin()` finds the scope's
    /// connection) and `FlightTransactions.coordinator` (this datasource's
    /// Postgres coordinator, replacing Core's no-op default).
    ///
    /// This is the unit-of-work entry point for anything that isn't already
    /// scope-managed: CLI commands, background jobs, tests —
    ///
    /// ```swift
    /// try await container.withPostgresScope { scope in
    ///     let ledger = try container.resolve(LedgerRepository.self, in: scope)
    ///     try await ledger.transfer(amount, from: a, to: b)   // @Transactional
    /// }
    /// ```
    public func withPostgresScope<T>(
        datasource name: String = PrimaryDataSource.name,
        _ body: (Scope) async throws -> T
    ) async throws -> T {
        try await withScope { scope in
            try await withPostgresTransactions(in: scope, datasource: name) {
                try await body(scope)
            }
        }
    }

    /// Runs `body` with `Scope.active` and `FlightTransactions.coordinator`
    /// bound to an *existing* scope — for callers that already have one, such
    /// as a Flight Web handler with its request scope:
    ///
    /// ```swift
    /// try await container.withPostgresTransactions(in: context.scope) {
    ///     try await service.transfer(...)   // @Transactional methods inside
    /// }
    /// ```
    /// How a unit of work gets its connection.
    ///
    /// `.lazy` is the original behaviour and the right default for a scope
    /// that may never touch the database: nothing is checked out until
    /// something asks, and if the pool is full at that moment the request
    /// fails immediately, because a synchronous factory cannot wait.
    ///
    /// `.waiting` takes the connection up front, queueing for one if the pool
    /// is busy, and offers it to the scope. That is what turns `pool_size`
    /// from a hard concurrency ceiling into a queue: the (pool_size + 1)th
    /// simultaneous request waits a few milliseconds instead of failing. The
    /// cost is that the connection is held for the whole unit of work even if
    /// it goes unused, so it suits request handlers that mostly do use the
    /// database — not long-lived sockets or streams.
    public enum ConnectionAcquisition: Sendable {
        case lazy
        case waiting(timeout: Duration)
    }

    public func withPostgresTransactions<T>(
        in scope: Scope,
        datasource name: String = PrimaryDataSource.name,
        acquiring acquisition: ConnectionAcquisition = .lazy,
        _ body: () async throws -> T
    ) async throws -> T {
        guard case .waiting(let timeout) = acquisition else {
            return try await bindPostgresTransactions(in: scope, datasource: name, body)
        }

        let source = try resolve(PostgresDataSource.self, qualifier: name)
        let connection = try await source.checkout(waitingUpTo: timeout)
        // `offering` merges rather than replacing, so a nested `.waiting` unit
        // of work on a second datasource does not erase this offer for its
        // duration — which used to send this scope's factory down the
        // non-waiting path and fail beside its own reserved connection. It also
        // owns the "nobody took it" return: if no scoped component ever asked,
        // nothing leased the connection and the lease's deinit never runs.
        return try await PendingConnections.offering(
            name, connection: connection, returning: source.release
        ) {
            try await bindPostgresTransactions(in: scope, datasource: name, body)
        }
    }

    private func bindPostgresTransactions<T>(
        in scope: Scope,
        datasource name: String,
        _ body: () async throws -> T
    ) async throws -> T {
        let coordinator = try resolve(PostgresTransactionCoordinator.self, qualifier: name)
        return try await Scope.$active.withValue(scope) {
            try await FlightTransactions.$coordinator.withValue(coordinator) {
                // Same coordinator, both spellings (Core delta 14): async
                // @Transactional methods take the async-native path; sync
                // ones the blocking bridge.
                try await FlightTransactions.$asyncCoordinator.withValue(coordinator) {
                    // Hangar's ambient repo (hangar-design.1/), bound
                    // to this scope's connection so `Repo.require()` inside
                    // the unit of work participates in its transactions.
                    let repo = try resolve(Repo.self, qualifier: name, in: scope)
                    return try await Repo.with(repo) {
                        try await body()
                    }
                }
            }
        }
    }
}

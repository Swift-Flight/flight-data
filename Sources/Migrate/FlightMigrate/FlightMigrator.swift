import Foundation
import Logging
import PostgresNIO

/// The migration runner.
///
/// ```swift
/// let migrator = FlightMigrator(client: postgresClient, migrations: _allMigrations())
/// try await migrator.migrate()
/// ```
///
/// Guarantees:
/// - Each wrapped migration runs in its own transaction **together with its bookkeeping
///   write**: a failure rolls back both, leaving the database byte-for-byte where it
///   started.
/// - The whole run holds a Postgres advisory lock, so concurrent instances serialize;
///   latecomers find nothing pending.
/// - Already-applied migrations are verified against their recorded checksums before
///   anything runs; drift is a hard error.
///
/// Deliberately **not** run at boot for you: schema changes are a deploy step, not a
/// side effect of a process starting. Call it from your migrate binary or test harness.
public struct FlightMigrator: Sendable {
    /// The constant advisory lock key: the ASCII bytes `"FLIGHTMG"` as a
    /// big-endian `Int64`. Override via ``Configuration/advisoryLockKey`` if it collides
    /// with an advisory-lock scheme your application already uses.
    public static let defaultAdvisoryLockKey = Int64(0x464C_4947_4854_4D47)

    public struct Configuration: Sendable {
        /// Bookkeeping table name; may be schema-qualified (`"ops.flight_migrations"`).
        public var migrationsTable: String

        /// Advisory lock key held for the duration of every mutating run.
        public var advisoryLockKey: Int64

        /// How long to wait for the advisory lock before giving up.
        ///
        /// A migration run holds a session-scoped advisory lock so two
        /// deploys cannot migrate the same database at once. Without a bound,
        /// a run that cannot get the lock — because another run is wedged, or
        /// a session leaked it — waits forever, and a deploy that never
        /// finishes is harder to diagnose than one that fails.
        ///
        /// `nil` waits indefinitely, which is the old behavior and still the
        /// right choice for an interactive run you are watching.
        public var lockTimeout: Duration?

        /// If `true`, versions recorded as applied that this binary doesn't know about are
        /// a hard error. The default (`false`) warns and proceeds, because an older binary
        /// observing a newer schema is normal mid-deploy; the strict mode is for catching
        /// deleted migration files.
        public var failOnUnknownApplied: Bool

        public var logger: Logger

        /// Progress callback for CLI output or metrics; invoked synchronously.
        public var onEvent: (@Sendable (MigrationEvent) -> Void)?

        public init(
            migrationsTable: String = "flight_migrations",
            advisoryLockKey: Int64 = FlightMigrator.defaultAdvisoryLockKey,
            lockTimeout: Duration? = .seconds(30),
            failOnUnknownApplied: Bool = false,
            logger: Logger = Logger(label: "flight-migrate"),
            onEvent: (@Sendable (MigrationEvent) -> Void)? = nil
        ) {
            self.migrationsTable = migrationsTable
            self.advisoryLockKey = advisoryLockKey
            self.lockTimeout = lockTimeout
            self.failOnUnknownApplied = failOnUnknownApplied
            self.logger = logger
            self.onEvent = onEvent
        }
    }

    let database: any MigrationDatabase
    let migrations: [MigrationEntry]
    let configuration: Configuration

    /// Creates a migrator over a `PostgresClient`. The client's `run()` must be active
    /// (see PostgresNIO docs); the migrator checks out one connection per operation.
    public init(
        client: PostgresClient,
        migrations: [MigrationEntry],
        configuration: Configuration = Configuration()
    ) {
        self.init(
            database: PostgresMigrationDatabase(client: client, logger: configuration.logger),
            migrations: migrations,
            configuration: configuration
        )
    }

    /// Creates a migrator over any `MigrationDatabase` (custom adapters, tests).
    public init(
        database: any MigrationDatabase,
        migrations: [MigrationEntry],
        configuration: Configuration = Configuration()
    ) {
        self.database = database
        self.migrations = migrations
        self.configuration = configuration
    }

    // MARK: - Migrate

    /// Applies all pending migrations in version order. Returns the migrations applied
    /// (empty if the database was already up to date).
    @discardableResult
    public func migrate() async throws -> [AppliedMigration] {
        let entries = try validatedEntries()
        return try await withLockedSession { session in
            try await ensureLedger(session)
            let applied = try await session.fetchApplied(configuration.migrationsTable)
            try verifyIntegrity(applied: applied, entries: entries)

            let appliedVersions = Set(applied.map(\.version))
            let pending = entries.filter { !appliedVersions.contains($0.version) }
            guard !pending.isEmpty else {
                emit(.upToDate)
                configuration.logger.info("database is up to date; nothing to apply")
                return []
            }

            var results: [AppliedMigration] = []
            for entry in pending {
                results.append(try await run(entry, direction: .up, in: session))
            }
            return results
        }
    }

    /// Renders what `migrate()` would run, without executing anything. Performs the same
    /// checksum verification a real run would, so a drifted ledger fails here too.
    public func planMigrate() async throws -> MigrationPlan {
        let entries = try validatedEntries()
        return try await database.withSession { session in
            let applied = try await fetchAppliedIfLedgerExists(session)
            try verifyIntegrity(applied: applied, entries: entries)
            let appliedVersions = Set(applied.map(\.version))
            let steps = entries.filter { !appliedVersions.contains($0.version) }
                .map { entry in
                    MigrationPlan.Step(
                        version: entry.version,
                        name: entry.name,
                        transactional: entry.wrapInTransaction,
                        statements: statements(for: entry, direction: .up)
                    )
                }
            return MigrationPlan(direction: .up, steps: steps)
        }
    }

    // MARK: - Rollback

    /// Reverts the most recently applied migration(s). `steps` may exceed
    /// the number of applied migrations; everything applied is then reverted.
    @discardableResult
    public func rollback(steps: Int = 1) async throws -> [RolledBackMigration] {
        guard steps >= 1 else {
            throw MigrationError.invalidRequest("rollback steps must be at least 1 (got \(steps))")
        }
        return try await performRollback { applied in Array(applied.suffix(steps).reversed()) }
    }

    /// Reverts every migration applied **after** `version`, leaving `version` itself
    /// applied — i.e. "roll back *to* this version". Pass `0` to revert everything.
    @discardableResult
    public func rollback(to version: Int64) async throws -> [RolledBackMigration] {
        try await performRollback { applied in
            if version != 0, !applied.contains(where: { $0.version == version }) {
                throw MigrationError.rollbackTargetNotApplied(version: version)
            }
            return applied.filter { $0.version > version }.sorted { $0.version > $1.version }
        }
    }

    /// Renders what `rollback(steps:)` would run, without executing anything.
    public func planRollback(steps: Int = 1) async throws -> MigrationPlan {
        guard steps >= 1 else {
            throw MigrationError.invalidRequest("rollback steps must be at least 1 (got \(steps))")
        }
        return try await planRollbackTargets { applied in Array(applied.suffix(steps).reversed()) }
    }

    /// Renders what `rollback(to:)` would run, without executing anything.
    public func planRollback(to version: Int64) async throws -> MigrationPlan {
        try await planRollbackTargets { applied in
            if version != 0, !applied.contains(where: { $0.version == version }) {
                throw MigrationError.rollbackTargetNotApplied(version: version)
            }
            return applied.filter { $0.version > version }.sorted { $0.version > $1.version }
        }
    }

    // MARK: - Status

    /// Applied + pending, with checksum states. Read-only: takes no lock, creates nothing.
    public func status() async throws -> MigrationStatus {
        let entries = try validatedEntries()
        let byVersion = Dictionary(uniqueKeysWithValues: entries.map { ($0.version, $0) })
        return try await database.withSession { session in
            let applied = try await fetchAppliedIfLedgerExists(session)
            let appliedVersions = Set(applied.map(\.version))

            let appliedStatuses = applied.map { record -> MigrationStatus.Applied in
                let state: MigrationStatus.AppliedState
                if let entry = byVersion[record.version] {
                    state = entry.checksum == record.checksum
                        ? .ok
                        : .checksumMismatch(recorded: record.checksum, current: entry.checksum)
                } else {
                    state = .missingLocally
                }
                return MigrationStatus.Applied(
                    version: record.version, name: record.name, appliedAt: record.appliedAt,
                    state: state)
            }
            let pending = entries.filter { !appliedVersions.contains($0.version) }
                .map {
                    MigrationStatus.Pending(
                        version: $0.version, name: $0.name, transactional: $0.wrapInTransaction)
                }
            return MigrationStatus(applied: appliedStatuses, pending: pending)
        }
    }

    // MARK: - Repair

    /// Re-baselines recorded checksums (and names) to the currently registered values,
    /// for applied migrations whose source was edited in a confirmed-safe way.
    /// All updates commit atomically. Rows with no registered migration are reported, not
    /// touched.
    @discardableResult
    public func repair() async throws -> RepairOutcome {
        let entries = try validatedEntries()
        let byVersion = Dictionary(uniqueKeysWithValues: entries.map { ($0.version, $0) })
        return try await withLockedSession { session in
            guard try await session.migrationsTableExists(configuration.migrationsTable) else {
                return RepairOutcome(repaired: [], missingLocally: [])
            }
            let applied = try await session.fetchApplied(configuration.migrationsTable)

            var repaired: [RepairOutcome.Repaired] = []
            var missing: [UnknownApplied] = []
            var updates: [(record: AppliedMigrationRecord, entry: MigrationEntry)] = []
            for record in applied {
                guard let entry = byVersion[record.version] else {
                    missing.append(UnknownApplied(version: record.version, name: record.name))
                    continue
                }
                if entry.checksum != record.checksum || entry.name != record.name {
                    updates.append((record, entry))
                }
            }

            if !updates.isEmpty {
                try await session.begin()
                do {
                    for (record, entry) in updates {
                        try await session.updateApplied(
                            configuration.migrationsTable,
                            version: entry.version, name: entry.name, checksum: entry.checksum)
                        repaired.append(
                            RepairOutcome.Repaired(
                                version: entry.version, name: entry.name,
                                oldChecksum: record.checksum, newChecksum: entry.checksum))
                    }
                    try await session.commit()
                } catch {
                    try? await session.rollback()
                    throw error
                }
                for item in repaired {
                    emit(
                        .repairedChecksum(
                            version: item.version, name: item.name,
                            oldChecksum: item.oldChecksum, newChecksum: item.newChecksum))
                    configuration.logger.notice(
                        "re-baselined checksum",
                        metadata: ["migration": "\(item.version)_\(item.name)"])
                }
            }
            return RepairOutcome(repaired: repaired, missingLocally: missing)
        }
    }

    // MARK: - Shared plumbing

    /// Validates and sorts the registered migrations. The build plugin already guarantees
    /// these properties for generated registries; hand-built lists get the same checks.
    func validatedEntries() throws -> [MigrationEntry] {
        let sorted = migrations.sorted { $0.version < $1.version }
        var seen = Set<Int64>()
        for entry in sorted {
            guard entry.version > 0 else {
                throw MigrationError.invalidMigrationSet(
                    reason: "migration \(entry.qualifiedName) has a non-positive version")
            }
            guard seen.insert(entry.version).inserted else {
                let duplicates = sorted.filter { $0.version == entry.version }.map(\.name)
                throw MigrationError.invalidMigrationSet(
                    reason:
                        "duplicate version \(entry.version) (\(duplicates.joined(separator: ", ")))")
            }
        }
        return sorted
    }

    /// Runs `body` on one session with the advisory lock held; releases it on every path.
    private func withLockedSession<T: Sendable>(
        _ body: @Sendable (any MigrationSession) async throws -> T
    ) async throws -> T {
        try await database.withSession { session in
            try await session.acquireAdvisoryLock(
                key: configuration.advisoryLockKey, timeout: configuration.lockTimeout)
            do {
                let result = try await body(session)
                do {
                    try await session.releaseAdvisoryLock(key: configuration.advisoryLockKey)
                } catch {
                    // The work committed; a failed unlock means the connection is likely
                    // dead, in which case the server releases the lock anyway.
                    configuration.logger.warning(
                        "failed to release advisory lock; the connection will release it on close",
                        metadata: ["error": "\(error)"])
                }
                return result
            } catch {
                try? await session.releaseAdvisoryLock(key: configuration.advisoryLockKey)
                throw error
            }
        }
    }

    /// Creates the bookkeeping table if needed, inside a transaction.
    private func ensureLedger(_ session: any MigrationSession) async throws {
        guard try await !session.migrationsTableExists(configuration.migrationsTable) else {
            return
        }
        configuration.logger.info(
            "creating bookkeeping table", metadata: ["table": "\(configuration.migrationsTable)"])
        try await session.begin()
        do {
            try await session.createMigrationsTable(configuration.migrationsTable)
            try await session.commit()
        } catch {
            try? await session.rollback()
            throw error
        }
    }

    private func fetchAppliedIfLedgerExists(
        _ session: any MigrationSession
    ) async throws -> [AppliedMigrationRecord] {
        guard try await session.migrationsTableExists(configuration.migrationsTable) else {
            return []
        }
        return try await session.fetchApplied(configuration.migrationsTable)
    }

    /// Checksum verification for every applied migration, plus the
    /// unknown-applied policy.
    private func verifyIntegrity(
        applied: [AppliedMigrationRecord], entries: [MigrationEntry]
    ) throws {
        let byVersion = Dictionary(uniqueKeysWithValues: entries.map { ($0.version, $0) })
        var unknown: [UnknownApplied] = []
        for record in applied {
            guard let entry = byVersion[record.version] else {
                unknown.append(UnknownApplied(version: record.version, name: record.name))
                continue
            }
            guard entry.checksum == record.checksum else {
                throw MigrationError.checksumMismatch(
                    version: record.version, name: record.name,
                    recorded: record.checksum, current: entry.checksum)
            }
        }
        if !unknown.isEmpty {
            if configuration.failOnUnknownApplied {
                throw MigrationError.unknownAppliedMigrations(unknown)
            }
            emit(.unknownAppliedVersions(unknown))
            configuration.logger.warning(
                "database records migrations unknown to this binary",
                metadata: [
                    "versions": "\(unknown.map { "\($0.version)_\($0.name)" }.joined(separator: ", "))"
                ])
        }
    }

    private func statements(for entry: MigrationEntry, direction: MigrationDirection) -> [String] {
        let migration = entry.type.init()
        let schema = SchemaBuilder()
        switch direction {
        case .up: migration.up(schema)
        case .down: migration.down(schema)
        }
        return schema.statements
    }

    /// Runs one migration in the given direction — the transactional core.
    private func run(
        _ entry: MigrationEntry, direction: MigrationDirection, in session: any MigrationSession
    ) async throws -> AppliedMigration {
        let statements = statements(for: entry, direction: direction)
        let transactional = entry.wrapInTransaction

        switch direction {
        case .up:
            emit(
                .willApply(
                    version: entry.version, name: entry.name, transactional: transactional,
                    statementCount: statements.count))
        case .down:
            emit(
                .willRollBack(
                    version: entry.version, name: entry.name, transactional: transactional,
                    statementCount: statements.count))
        }
        if statements.isEmpty {
            emit(.emptyMigration(version: entry.version, name: entry.name, direction: direction))
            configuration.logger.notice(
                "migration has no statements",
                metadata: [
                    "migration": "\(entry.qualifiedName)", "direction": "\(direction.rawValue)",
                ])
        }

        func failure(
            _ phase: MigrationError.FailurePhase, applied: Int, _ underlying: any Error
        ) -> MigrationError {
            .migrationFailed(
                version: entry.version, name: entry.name, direction: direction,
                transactional: transactional, phase: phase, statementsApplied: applied,
                underlying: underlying)
        }

        let start = ContinuousClock.now

        if transactional {
            do {
                try await session.begin()
            } catch {
                throw failure(.begin, applied: 0, error)
            }
            do {
                for (index, sql) in statements.enumerated() {
                    do {
                        try await session.execute(sql)
                    } catch {
                        throw failure(
                            .statement(index: index, total: statements.count, sql: sql),
                            applied: index, error)
                    }
                }
                do {
                    try await bookkeep(entry, direction: direction, in: session)
                } catch {
                    throw failure(.bookkeeping, applied: statements.count, error)
                }
                do {
                    try await session.commit()
                } catch {
                    throw failure(.commit, applied: statements.count, error)
                }
            } catch {
                try? await session.rollback()
                throw error
            }
        } else {
            if statements.count > 1 {
                emit(
                    .unwrappedMigrationHasMultipleStatements(
                        version: entry.version, name: entry.name,
                        statementCount: statements.count, direction: direction))
                configuration.logger.warning(
                    """
                    unwrapped migration has multiple statements; a partial failure cannot be \
                    rolled back — prefer one statement per wrapInTransaction=false migration
                    """,
                    metadata: [
                        "migration": "\(entry.qualifiedName)",
                        "statements": "\(statements.count)",
                    ])
            }
            for (index, sql) in statements.enumerated() {
                do {
                    try await session.execute(sql)
                } catch {
                    throw failure(
                        .statement(index: index, total: statements.count, sql: sql),
                        applied: index, error)
                }
            }
            do {
                try await bookkeep(entry, direction: direction, in: session)
            } catch {
                throw failure(.bookkeeping, applied: statements.count, error)
            }
        }

        let duration = start.duration(to: .now)
        switch direction {
        case .up:
            emit(.didApply(version: entry.version, name: entry.name, duration: duration))
            configuration.logger.info(
                "applied migration", metadata: ["migration": "\(entry.qualifiedName)"])
        case .down:
            emit(.didRollBack(version: entry.version, name: entry.name, duration: duration))
            configuration.logger.info(
                "rolled back migration", metadata: ["migration": "\(entry.qualifiedName)"])
        }
        return AppliedMigration(version: entry.version, name: entry.name, duration: duration)
    }

    private func bookkeep(
        _ entry: MigrationEntry, direction: MigrationDirection, in session: any MigrationSession
    ) async throws {
        switch direction {
        case .up:
            try await session.insertApplied(
                configuration.migrationsTable,
                version: entry.version, name: entry.name, checksum: entry.checksum)
        case .down:
            try await session.deleteApplied(configuration.migrationsTable, version: entry.version)
        }
    }

    /// Shared rollback driver: `selectTargets` picks which applied records to revert,
    /// newest first.
    private func performRollback(
        selectTargets: @Sendable @escaping ([AppliedMigrationRecord]) throws ->
            [AppliedMigrationRecord]
    ) async throws -> [RolledBackMigration] {
        let entries = try validatedEntries()
        let byVersion = Dictionary(uniqueKeysWithValues: entries.map { ($0.version, $0) })
        return try await withLockedSession { session in
            let applied = try await fetchAppliedIfLedgerExists(session)
            // Rolling back is as destructive as migrating forward, so the same
            // integrity gate applies: a ledger holding versions this binary does
            // not know about means the local set and the database disagree, and
            // `failOnUnknownApplied` is how an operator says to stop there.
            try verifyIntegrity(applied: applied, entries: entries)
            let targets = try selectTargets(applied)
            guard !targets.isEmpty else {
                configuration.logger.info("nothing to roll back")
                return []
            }
            let resolved = try resolve(targets: targets, against: byVersion)

            var results: [RolledBackMigration] = []
            for entry in resolved {
                let applied = try await run(entry, direction: .down, in: session)
                results.append(
                    RolledBackMigration(
                        version: applied.version, name: applied.name, duration: applied.duration))
            }
            return results
        }
    }

    private func planRollbackTargets(
        selectTargets: @Sendable @escaping ([AppliedMigrationRecord]) throws ->
            [AppliedMigrationRecord]
    ) async throws -> MigrationPlan {
        let entries = try validatedEntries()
        let byVersion = Dictionary(uniqueKeysWithValues: entries.map { ($0.version, $0) })
        return try await database.withSession { session in
            let applied = try await fetchAppliedIfLedgerExists(session)
            let targets = try selectTargets(applied)
            let resolved = try resolve(targets: targets, against: byVersion)
            let steps = resolved.map { entry in
                MigrationPlan.Step(
                    version: entry.version,
                    name: entry.name,
                    transactional: entry.wrapInTransaction,
                    statements: statements(for: entry, direction: .down)
                )
            }
            return MigrationPlan(direction: .down, steps: steps)
        }
    }

    /// Maps applied records to registered entries, enforcing that each target exists in
    /// this binary and hasn't drifted — rolling back an edited migration would run a
    /// `down` that no longer matches what was applied.
    private func resolve(
        targets: [AppliedMigrationRecord], against byVersion: [Int64: MigrationEntry]
    ) throws -> [MigrationEntry] {
        try targets.map { record in
            guard let entry = byVersion[record.version] else {
                throw MigrationError.cannotRollBackUnknownMigration(
                    version: record.version, name: record.name)
            }
            guard entry.checksum == record.checksum else {
                throw MigrationError.checksumMismatch(
                    version: record.version, name: record.name,
                    recorded: record.checksum, current: entry.checksum)
            }
            return entry
        }
    }

    private func emit(_ event: MigrationEvent) {
        configuration.onEvent?(event)
    }
}

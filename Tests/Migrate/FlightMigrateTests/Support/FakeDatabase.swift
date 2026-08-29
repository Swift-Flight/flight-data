import Foundation

@testable import FlightMigrate

/// In-memory `MigrationDatabase` that records every operation and models transaction
/// semantics for the bookkeeping rows. Unit tests assert on the exact operation
/// transcript — BEGIN before the body, bookkeeping inside the transaction, ROLLBACK on
/// failure, unlock on every path — which is precisely the behavior the design guarantees.
actor FakeDatabase: MigrationDatabase, MigrationSession {
    enum Op: Equatable, Sendable {
        case acquireLock(Int64)
        case releaseLock(Int64)
        case begin
        case commit
        case rollback
        case execute(String)
        case tableExists
        case createTable
        case fetchApplied
        case insert(Int64)
        case delete(Int64)
        case update(Int64)
    }

    struct StubError: Error, Equatable {
        let id: Int
    }

    struct StateError: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var transcript: [Op] = []

    /// Committed bookkeeping rows.
    private(set) var rows: [AppliedMigrationRecord] = []
    /// Staged rows while a transaction is open (nil = no transaction).
    private var stagedRows: [AppliedMigrationRecord]?
    private(set) var tableCreated: Bool
    private var heldLocks: Set<Int64> = []

    private var failures: [(matches: @Sendable (Op) -> Bool, error: any Error, remaining: Int)] = []

    init(tableCreated: Bool = false, seededRows: [AppliedMigrationRecord] = []) {
        self.tableCreated = tableCreated
        self.rows = seededRows
    }

    // MARK: Test configuration

    func fail(with error: any Error, times: Int = 1, when matches: @Sendable @escaping (Op) -> Bool)
    {
        failures.append((matches, error, times))
    }

    func failOnExecute(containing fragment: String, error: any Error, times: Int = 1) {
        fail(with: error, times: times) { op in
            if case .execute(let sql) = op { return sql.contains(fragment) }
            return false
        }
    }

    func appliedVersions() -> [Int64] {
        rows.map(\.version).sorted()
    }

    // MARK: MigrationDatabase

    func withSession<T: Sendable>(
        _ body: @Sendable (any MigrationSession) async throws -> T
    ) async throws -> T {
        try await body(self)
    }

    // MARK: MigrationSession

    func execute(_ sql: String) async throws {
        try record(.execute(sql))
    }

    func begin() async throws {
        try record(.begin)
        guard stagedRows == nil else {
            throw StateError(description: "BEGIN while a transaction is already open")
        }
        stagedRows = rows
    }

    func commit() async throws {
        try record(.commit)
        guard let staged = stagedRows else {
            throw StateError(description: "COMMIT without an open transaction")
        }
        rows = staged
        stagedRows = nil
    }

    func rollback() async throws {
        try record(.rollback)
        guard stagedRows != nil else {
            throw StateError(description: "ROLLBACK without an open transaction")
        }
        stagedRows = nil
    }

    /// Set to make every acquisition fail as if another run held the lock —
    /// the path a real database reaches only under contention, and the one
    /// nothing exercised because this fake ignored `timeout` entirely.
    private var lockIsHeldByAnotherRun = false

    func setLockIsHeldByAnotherRun(_ held: Bool) { lockIsHeldByAnotherRun = held }
    /// The timeout each acquisition was asked for, so a test can assert the
    /// configured one actually reaches the database.
    private(set) var requestedLockTimeouts: [Duration?] = []

    func acquireAdvisoryLock(key: Int64, timeout: Duration?) async throws {
        requestedLockTimeouts.append(timeout)
        if lockIsHeldByAnotherRun {
            throw MigrationError.lockTimeout(key: key, waited: timeout ?? .zero)
        }
        try record(.acquireLock(key))
        guard heldLocks.insert(key).inserted else {
            throw StateError(description: "advisory lock \(key) acquired twice on one session")
        }
    }

    func releaseAdvisoryLock(key: Int64) async throws {
        try record(.releaseLock(key))
        guard heldLocks.remove(key) != nil else {
            throw StateError(description: "released advisory lock \(key) that was not held")
        }
    }

    func migrationsTableExists(_ table: String) async throws -> Bool {
        try record(.tableExists)
        return tableCreated
    }

    func createMigrationsTable(_ table: String) async throws {
        try record(.createTable)
        tableCreated = true
    }

    func fetchApplied(_ table: String) async throws -> [AppliedMigrationRecord] {
        try record(.fetchApplied)
        return (stagedRows ?? rows).sorted { $0.version < $1.version }
    }

    func insertApplied(_ table: String, version: Int64, name: String, checksum: String) async throws
    {
        try record(.insert(version))
        var target = stagedRows ?? rows
        guard !target.contains(where: { $0.version == version }) else {
            throw StateError(description: "duplicate key: version \(version) already applied")
        }
        target.append(
            AppliedMigrationRecord(
                version: version, name: name, checksum: checksum, appliedAt: Date()))
        if stagedRows != nil { stagedRows = target } else { rows = target }
    }

    func deleteApplied(_ table: String, version: Int64) async throws {
        try record(.delete(version))
        var target = stagedRows ?? rows
        target.removeAll { $0.version == version }
        if stagedRows != nil { stagedRows = target } else { rows = target }
    }

    func updateApplied(_ table: String, version: Int64, name: String, checksum: String) async throws
    {
        try record(.update(version))
        var target = stagedRows ?? rows
        guard let index = target.firstIndex(where: { $0.version == version }) else {
            throw StateError(description: "update of version \(version) that is not applied")
        }
        target[index] = AppliedMigrationRecord(
            version: version, name: name, checksum: checksum, appliedAt: target[index].appliedAt)
        if stagedRows != nil { stagedRows = target } else { rows = target }
    }

    // MARK: Internals

    private func record(_ op: Op) throws {
        transcript.append(op)
        for index in failures.indices where failures[index].remaining > 0 {
            if failures[index].matches(op) {
                failures[index].remaining -= 1
                throw failures[index].error
            }
        }
    }
}

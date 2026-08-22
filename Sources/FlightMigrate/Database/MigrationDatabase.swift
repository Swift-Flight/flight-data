import Foundation

/// A row of the bookkeeping table (design §4).
public struct AppliedMigrationRecord: Sendable, Equatable {
    public let version: Int64
    public let name: String
    public let checksum: String
    public let appliedAt: Date

    public init(version: Int64, name: String, checksum: String, appliedAt: Date) {
        self.version = version
        self.name = name
        self.checksum = checksum
        self.appliedAt = appliedAt
    }
}

/// The database operations `FlightMigrator` needs, on one session.
///
/// A *session* is a single database connection: the advisory lock (design §6) is
/// session-scoped, and `begin`/`commit`/`rollback` bracket work on the same connection —
/// both are meaningless across a connection pool. The Postgres implementation is
/// ``PostgresMigrationDatabase``; tests substitute an in-memory fake to assert on the
/// exact operation sequence (BEGIN before body, bookkeeping inside the transaction,
/// unlock on every path, ...).
public protocol MigrationSession: Sendable {
    /// Executes one SQL statement, discarding any rows.
    func execute(_ sql: String) async throws

    func begin() async throws
    func commit() async throws
    func rollback() async throws

    /// Blocks until the session-scoped advisory lock is acquired (design §6).
    func acquireAdvisoryLock(key: Int64) async throws
    func releaseAdvisoryLock(key: Int64) async throws

    /// Whether the bookkeeping table exists.
    func migrationsTableExists(_ table: String) async throws -> Bool

    /// Creates the bookkeeping table (the caller wraps this in a transaction, §4).
    func createMigrationsTable(_ table: String) async throws

    /// All bookkeeping rows, ordered by version ascending.
    func fetchApplied(_ table: String) async throws -> [AppliedMigrationRecord]

    /// Records a migration as applied. Runs inside the migration's transaction when the
    /// migration is wrapped (design §3.1).
    func insertApplied(_ table: String, version: Int64, name: String, checksum: String) async throws

    /// Removes a migration's bookkeeping row (rollback, §3.3).
    func deleteApplied(_ table: String, version: Int64) async throws

    /// Re-baselines a recorded name/checksum (repair, §5).
    func updateApplied(_ table: String, version: Int64, name: String, checksum: String) async throws
}

/// Provides sessions. The Postgres implementation checks a connection out of the
/// `PostgresClient` pool for the duration of `body`.
public protocol MigrationDatabase: Sendable {
    func withSession<T: Sendable>(
        _ body: @Sendable (any MigrationSession) async throws -> T
    ) async throws -> T
}

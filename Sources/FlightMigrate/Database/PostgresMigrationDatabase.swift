import Foundation
import Logging
import PostgresNIO

/// `MigrationDatabase` backed by a `PostgresClient` connection pool.
///
/// Each `withSession` checks out **one** connection for the whole run: advisory locks are
/// session-scoped, so lock, migrations, and unlock must share a connection. The unlock is
/// explicit on every path — pooled connections are reused, and a leaked advisory lock
/// would block every future migration run against the database. (If the process dies
/// outright, the connection dies with it and Postgres releases the lock server-side.)
public struct PostgresMigrationDatabase: MigrationDatabase {
    let client: PostgresClient
    let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    public func withSession<T: Sendable>(
        _ body: @Sendable (any MigrationSession) async throws -> T
    ) async throws -> T {
        try await client.withConnection { connection in
            try await body(PostgresMigrationSession(connection: connection, logger: logger))
        }
    }
}

struct PostgresMigrationSession: MigrationSession {
    let connection: PostgresConnection
    let logger: Logger

    func execute(_ sql: String) async throws {
        logger.debug("executing SQL", metadata: ["sql": "\(sql)"])
        try await run(PostgresQuery(unsafeSQL: sql))
    }

    func begin() async throws {
        try await run("BEGIN")
    }

    func commit() async throws {
        try await run("COMMIT")
    }

    func rollback() async throws {
        try await run("ROLLBACK")
    }

    func acquireAdvisoryLock(key: Int64) async throws {
        logger.debug("acquiring advisory lock", metadata: ["key": "\(key)"])
        try await run("SELECT pg_advisory_lock(\(key))")
    }

    func releaseAdvisoryLock(key: Int64) async throws {
        logger.debug("releasing advisory lock", metadata: ["key": "\(key)"])
        try await run("SELECT pg_advisory_unlock(\(key))")
    }

    func migrationsTableExists(_ table: String) async throws -> Bool {
        let rows = try await connection.query(
            "SELECT to_regclass(\(table)) IS NOT NULL", logger: logger)
        for try await exists in rows.decode(Bool.self) {
            return exists
        }
        return false
    }

    func createMigrationsTable(_ table: String) async throws {
        // Design §4, verbatim modulo identifier quoting. `version` as primary key makes
        // double-application structurally impossible even without the advisory lock.
        try await execute(
            """
            CREATE TABLE IF NOT EXISTS \(SQL.identifier(table)) (
                "version"    BIGINT PRIMARY KEY,
                "name"       TEXT NOT NULL,
                "applied_at" TIMESTAMPTZ NOT NULL DEFAULT now(),
                "checksum"   TEXT NOT NULL
            )
            """)
    }

    func fetchApplied(_ table: String) async throws -> [AppliedMigrationRecord] {
        let rows = try await connection.query(
            PostgresQuery(
                unsafeSQL: """
                    SELECT "version", "name", "checksum", "applied_at" \
                    FROM \(SQL.identifier(table)) ORDER BY "version"
                    """),
            logger: logger)
        var records: [AppliedMigrationRecord] = []
        for try await (version, name, checksum, appliedAt) in rows.decode(
            (Int64, String, String, Date).self)
        {
            records.append(
                AppliedMigrationRecord(
                    version: version, name: name, checksum: checksum, appliedAt: appliedAt))
        }
        return records
    }

    func insertApplied(_ table: String, version: Int64, name: String, checksum: String) async throws
    {
        var binds = PostgresBindings()
        binds.append(version)
        binds.append(name)
        binds.append(checksum)
        try await run(
            PostgresQuery(
                unsafeSQL: """
                    INSERT INTO \(SQL.identifier(table)) ("version", "name", "checksum") \
                    VALUES ($1, $2, $3)
                    """,
                binds: binds))
    }

    func deleteApplied(_ table: String, version: Int64) async throws {
        var binds = PostgresBindings()
        binds.append(version)
        try await run(
            PostgresQuery(
                unsafeSQL: "DELETE FROM \(SQL.identifier(table)) WHERE \"version\" = $1",
                binds: binds))
    }

    func updateApplied(_ table: String, version: Int64, name: String, checksum: String) async throws
    {
        var binds = PostgresBindings()
        binds.append(version)
        binds.append(name)
        binds.append(checksum)
        try await run(
            PostgresQuery(
                unsafeSQL: """
                    UPDATE \(SQL.identifier(table)) SET "name" = $2, "checksum" = $3 \
                    WHERE "version" = $1
                    """,
                binds: binds))
    }

    /// Runs a query and drains its rows so execution errors surface here.
    private func run(_ query: PostgresQuery) async throws {
        let rows = try await connection.query(query, logger: logger)
        for try await _ in rows {}
    }
}

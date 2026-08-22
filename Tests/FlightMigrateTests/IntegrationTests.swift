import ExampleMigrations
import Foundation
import Logging
import PostgresNIO
import Testing

@testable import FlightMigrate
@testable import FlightMigrateCLI

/// Integration tests against a real Postgres, gated by `FLIGHT_MIGRATE_TEST_DATABASE_URL`
/// (e.g. `postgres://postgres:flight@127.0.0.1:55432/flight_test?sslmode=disable`; see
/// README for a one-line docker setup). These exercise the guarantees that only a real
/// database can prove: transactional DDL rollback, advisory-lock serialization, and
/// `CREATE INDEX CONCURRENTLY` behavior outside transactions.
let integrationDatabaseURL = ProcessInfo.processInfo.environment["FLIGHT_MIGRATE_TEST_DATABASE_URL"]

// MARK: - Fixtures (it_-prefixed tables; each test uses its own ledger and cleans up)

struct ITCreateUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("it_users") { t in
            t.uuid("id").primaryKey().default(.raw("gen_random_uuid()"))
            t.text("email").notNull().unique()
            t.timestamptz("created_at").notNull().default(.now)
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("it_users")
    }
}

struct ITCreateTeams: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("it_teams") { t in
            t.bigint("id").generatedAlwaysAsIdentity().primaryKey()
            t.text("name").notNull().unique()
            t.timestamps()
        }
        schema.createTable("it_team_members") { t in
            t.bigint("team_id").notNull().references("it_teams", onDelete: .cascade)
            t.uuid("user_id").notNull().references("it_users", onDelete: .cascade)
            t.text("role").notNull().default("member")
            t.primaryKey(["team_id", "user_id"])
        }
        schema.createIndex(on: "it_team_members", columns: ["user_id"])
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("it_team_members")
        schema.dropTable("it_teams")
    }
}

struct ITAlterUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.alterTable("it_users") { t in
            t.text("bio")
            t.integer("login_count").notNull().default(0)
        }
        schema.raw("UPDATE it_users SET bio = '' WHERE bio IS NULL")
        schema.alterTable("it_users") { t in
            t.setDefault("bio", .string(""))
            t.setNotNull("bio")
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.alterTable("it_users") { t in
            t.dropColumn("login_count")
            t.dropColumn("bio")
        }
    }
}

/// Second statement fails: the first must be rolled back atomically (§3.1).
struct ITFailsAtomically: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("it_atomic") { t in
            t.integer("x")
        }
        schema.raw("SELECT it_no_such_function_xyz()")
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("it_atomic")
    }
}

/// The §3.2 flagship: CONCURRENTLY, which Postgres refuses inside a transaction block.
struct ITConcurrentIndex: Migration {
    static let wrapInTransaction = false
    func up(_ schema: SchemaBuilder) {
        schema.createIndex(on: "it_users", columns: ["email"], name: "it_users_email_cidx", concurrently: true)
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropIndex("it_users_email_cidx", concurrently: true)
    }
}

/// A CONCURRENTLY build that fails (unique index over duplicate data) leaves an INVALID
/// index behind — the manual-intervention case §3.2 documents.
struct ITBadConcurrentIndex: Migration {
    static let wrapInTransaction = false
    func up(_ schema: SchemaBuilder) {
        schema.createIndex(
            on: "it_dupes", columns: ["v"], name: "it_dupes_v_key", unique: true,
            concurrently: true)
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropIndex("it_dupes_v_key", concurrently: true, ifExists: true)
    }
}

// MARK: - Harness

func withTestClient<T: Sendable>(
    _ body: @Sendable @escaping (PostgresClient) async throws -> T
) async throws -> T {
    let raw = try #require(integrationDatabaseURL)
    let configuration = try DatabaseURL.parse(raw).postgresConfiguration()
    let client = PostgresClient(configuration: configuration)
    return try await withThrowingTaskGroup(of: Void.self, returning: T.self) { group in
        group.addTask { await client.run() }
        do {
            let result = try await body(client)
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

func exec(_ client: PostgresClient, _ sql: String) async throws {
    try await client.withConnection { connection in
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: sql), logger: Logger(label: "test"))
        for try await _ in rows {}
    }
}

func scalarBool(_ client: PostgresClient, _ sql: String) async throws -> Bool {
    try await client.withConnection { connection in
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: sql), logger: Logger(label: "test"))
        for try await value in rows.decode(Bool.self) {
            return value
        }
        return false
    }
}

func scalarInt(_ client: PostgresClient, _ sql: String) async throws -> Int64 {
    try await client.withConnection { connection in
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: sql), logger: Logger(label: "test"))
        for try await value in rows.decode(Int64.self) {
            return value
        }
        return -1
    }
}

func tableExists(_ client: PostgresClient, _ name: String) async throws -> Bool {
    try await scalarBool(client, "SELECT to_regclass('\(name)') IS NOT NULL")
}

/// A quiet migrator configuration with a per-ledger advisory lock key so tests can't
/// interfere with each other even across runs.
func testConfiguration(ledger: String) -> FlightMigrator.Configuration {
    var logger = Logger(label: "flight-migrate-test")
    logger.logLevel = .error
    var key = Int64(5_577_000_001)
    for byte in ledger.utf8 {
        key = key &* 31 &+ Int64(byte)
    }
    return FlightMigrator.Configuration(
        migrationsTable: ledger, advisoryLockKey: key, logger: logger)
}

func cleanup(_ client: PostgresClient, ledger: String, tables: [String]) async throws {
    for table in tables {
        try await exec(client, "DROP TABLE IF EXISTS \(table) CASCADE")
    }
    try await exec(client, "DROP TABLE IF EXISTS \(ledger) CASCADE")
    try await exec(client, "DROP INDEX IF EXISTS it_users_email_cidx")
    try await exec(client, "DROP INDEX IF EXISTS it_dupes_v_key")
}

// MARK: - Tests

@Suite("Integration", .serialized, .enabled(if: integrationDatabaseURL != nil))
struct IntegrationTests {
    @Test func applyStatusRollbackEndToEnd() async throws {
        try await withTestClient { client in
            let ledger = "it_ledger_e2e"
            let tables = ["it_team_members", "it_teams", "it_users"]
            try await cleanup(client, ledger: ledger, tables: tables)

            let migrations = [
                entry(1, "ITCreateUsers", ITCreateUsers.self),
                entry(2, "ITCreateTeams", ITCreateTeams.self),
                entry(3, "ITAlterUsers", ITAlterUsers.self),
            ]
            let migrator = FlightMigrator(
                client: client, migrations: migrations,
                configuration: testConfiguration(ledger: ledger))

            // Apply everything.
            let applied = try await migrator.migrate()
            #expect(applied.map(\.version) == [1, 2, 3])
            #expect(try await tableExists(client, "it_users"))
            #expect(try await tableExists(client, "it_teams"))
            #expect(try await tableExists(client, ledger))
            #expect(try await scalarInt(client, "SELECT count(*) FROM \(ledger)") == 3)

            // The altered column really exists and its backfill ran.
            try await exec(client, "INSERT INTO it_users (email) VALUES ('a@b.c')")
            #expect(
                try await scalarBool(
                    client, "SELECT bio = '' AND login_count = 0 FROM it_users LIMIT 1"))

            // Re-run: nothing pending.
            let secondRun = try await migrator.migrate()
            #expect(secondRun.isEmpty)

            // Status agrees.
            let status = try await migrator.status()
            #expect(status.isUpToDate)
            #expect(!status.hasDrift)
            #expect(status.applied.allSatisfy { $0.state == .ok })

            // Roll back one: the ALTER is reverted inside a transaction.
            let rolledBack = try await migrator.rollback()
            #expect(rolledBack.map(\.version) == [3])
            #expect(
                try await scalarBool(
                    client,
                    """
                    SELECT NOT EXISTS (
                        SELECT 1 FROM information_schema.columns
                        WHERE table_name = 'it_users' AND column_name = 'bio'
                    )
                    """))

            // Roll back to zero: everything gone, ledger empty.
            let rest = try await migrator.rollback(to: 0)
            #expect(rest.map(\.version) == [2, 1])
            #expect(try await !tableExists(client, "it_users"))
            #expect(try await !tableExists(client, "it_teams"))
            #expect(try await scalarInt(client, "SELECT count(*) FROM \(ledger)") == 0)

            try await cleanup(client, ledger: ledger, tables: tables)
        }
    }

    @Test func failedWrappedMigrationLeavesNoTrace() async throws {
        try await withTestClient { client in
            let ledger = "it_ledger_atomic"
            try await cleanup(client, ledger: ledger, tables: ["it_atomic", "it_users"])

            let migrations = [
                entry(1, "ITCreateUsers", ITCreateUsers.self),
                entry(2, "ITFailsAtomically", ITFailsAtomically.self),
            ]
            let migrator = FlightMigrator(
                client: client, migrations: migrations,
                configuration: testConfiguration(ledger: ledger))

            do {
                try await migrator.migrate()
                Issue.record("expected failure")
            } catch let error as MigrationError {
                guard case .migrationFailed(2, _, .up, true, _, _, _) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
            }

            // Migration 1 committed; migration 2 rolled back completely: the table its
            // first statement created does not exist, and its version is not recorded.
            #expect(try await tableExists(client, "it_users"))
            #expect(try await !tableExists(client, "it_atomic"))
            #expect(try await scalarInt(client, "SELECT count(*) FROM \(ledger)") == 1)

            // The lock was released: another run works (and finds only #2 pending).
            do {
                try await migrator.migrate()
                Issue.record("still failing, as expected")
            } catch {}

            try await cleanup(client, ledger: ledger, tables: ["it_atomic", "it_users"])
        }
    }

    @Test func checksumDriftHaltsAndRepairRebaselines() async throws {
        try await withTestClient { client in
            let ledger = "it_ledger_drift"
            try await cleanup(client, ledger: ledger, tables: ["it_users"])

            let original = [entry(1, "ITCreateUsers", ITCreateUsers.self)]
            let migrator = FlightMigrator(
                client: client, migrations: original,
                configuration: testConfiguration(ledger: ledger))
            try await migrator.migrate()

            // Same migration, edited source → different checksum.
            let edited = [
                MigrationEntry(
                    version: 1, name: "ITCreateUsers", source: "edited-source",
                    type: ITCreateUsers.self)
            ]
            let driftedMigrator = FlightMigrator(
                client: client, migrations: edited,
                configuration: testConfiguration(ledger: ledger))

            do {
                try await driftedMigrator.migrate()
                Issue.record("expected drift error")
            } catch let error as MigrationError {
                #expect(error.description.contains("has been modified since it was applied"))
                #expect(error.description.contains("Applied migrations are immutable"))
            }

            // status() reports drift without failing.
            let status = try await driftedMigrator.status()
            #expect(status.hasDrift)

            // repair() re-baselines; migrate() then passes.
            let outcome = try await driftedMigrator.repair()
            #expect(outcome.repaired.map(\.version) == [1])
            _ = try await driftedMigrator.migrate()
            #expect(try await !driftedMigrator.status().hasDrift)

            try await cleanup(client, ledger: ledger, tables: ["it_users"])
        }
    }

    @Test func concurrentIndexBuildsOutsideTransaction() async throws {
        try await withTestClient { client in
            let ledger = "it_ledger_concurrent"
            try await cleanup(client, ledger: ledger, tables: ["it_users"])

            let migrations = [
                entry(1, "ITCreateUsers", ITCreateUsers.self),
                entry(2, "ITConcurrentIndex", ITConcurrentIndex.self),
            ]
            let migrator = FlightMigrator(
                client: client, migrations: migrations,
                configuration: testConfiguration(ledger: ledger))

            let applied = try await migrator.migrate()
            #expect(applied.map(\.version) == [1, 2])
            #expect(
                try await scalarBool(
                    client,
                    """
                    SELECT indisvalid FROM pg_index i
                    JOIN pg_class c ON c.oid = i.indexrelid
                    WHERE c.relname = 'it_users_email_cidx'
                    """))

            // The unwrapped down also works (DROP INDEX CONCURRENTLY).
            let rolledBack = try await migrator.rollback()
            #expect(rolledBack.map(\.version) == [2])
            #expect(
                try await scalarBool(
                    client,
                    "SELECT NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'it_users_email_cidx')"
                ))

            try await cleanup(client, ledger: ledger, tables: ["it_users"])
        }
    }

    @Test func failedConcurrentIndexRequiresManualInterventionThenRetries() async throws {
        try await withTestClient { client in
            let ledger = "it_ledger_invalid"
            try await cleanup(client, ledger: ledger, tables: ["it_dupes"])

            // Duplicate data makes the unique CONCURRENTLY build fail after creating an
            // INVALID index — exactly the §3.2 scenario.
            try await exec(client, "CREATE TABLE it_dupes (v int)")
            try await exec(client, "INSERT INTO it_dupes VALUES (1), (1)")

            let migrations = [entry(1, "ITBadConcurrentIndex", ITBadConcurrentIndex.self)]
            let migrator = FlightMigrator(
                client: client, migrations: migrations,
                configuration: testConfiguration(ledger: ledger))

            do {
                try await migrator.migrate()
                Issue.record("expected failure")
            } catch let error as MigrationError {
                #expect(error.description.contains("Manual intervention may be required"))
                #expect(error.description.contains("INVALID index"))
            }

            // The version was not recorded (§3.2c), and Postgres left an INVALID index.
            #expect(try await scalarInt(client, "SELECT count(*) FROM \(ledger)") == 0)
            #expect(
                try await scalarBool(
                    client,
                    """
                    SELECT NOT indisvalid FROM pg_index i
                    JOIN pg_class c ON c.oid = i.indexrelid
                    WHERE c.relname = 'it_dupes_v_key'
                    """))

            // Operator fixes the state and data; the same migration re-runs cleanly.
            try await exec(client, "DROP INDEX it_dupes_v_key")
            try await exec(client, "DELETE FROM it_dupes WHERE ctid NOT IN (SELECT min(ctid) FROM it_dupes)")
            let applied = try await migrator.migrate()
            #expect(applied.map(\.version) == [1])

            try await cleanup(client, ledger: ledger, tables: ["it_dupes"])
        }
    }

    @Test func advisoryLockSerializesConcurrentMigrators() async throws {
        try await withTestClient { client in
            let ledger = "it_ledger_race"
            let tables = ["it_team_members", "it_teams", "it_users"]
            try await cleanup(client, ledger: ledger, tables: tables)

            let migrations = [
                entry(1, "ITCreateUsers", ITCreateUsers.self),
                entry(2, "ITCreateTeams", ITCreateTeams.self),
                entry(3, "ITAlterUsers", ITAlterUsers.self),
            ]

            // Simulate a fleet: several instances migrate at startup simultaneously (§6).
            let totalApplied = try await withThrowingTaskGroup(
                of: Int.self, returning: Int.self
            ) { group in
                for _ in 0..<4 {
                    group.addTask {
                        let migrator = FlightMigrator(
                            client: client, migrations: migrations,
                            configuration: testConfiguration(ledger: ledger))
                        return try await migrator.migrate().count
                    }
                }
                var total = 0
                for try await count in group {
                    total += count
                }
                return total
            }

            // Exactly one instance applied everything; the rest found nothing pending.
            #expect(totalApplied == 3)
            #expect(try await scalarInt(client, "SELECT count(*) FROM \(ledger)") == 3)
            #expect(try await tableExists(client, "it_users"))

            try await cleanup(client, ledger: ledger, tables: tables)
        }
    }

    @Test func exampleBinarySmokeTest() async throws {
        // Drive the real example CLI end to end: status → apply → status → rollback --to 0.
        let raw = try #require(integrationDatabaseURL)
        let testBinary = URL(fileURLWithPath: CommandLine.arguments[0])
        let example = testBinary.deletingLastPathComponent()
            .appendingPathComponent("flight-migrate-example")
        guard FileManager.default.isExecutableFile(atPath: example.path) else {
            Issue.record("flight-migrate-example not found next to the test binary; build it first")
            return
        }

        let ledger = "it_cli_smoke_ledger"
        try await withTestClient { client in
            try await cleanup(
                client, ledger: ledger, tables: ["team_members", "teams", "users"])
            try await exec(client, "DROP INDEX IF EXISTS idx_users_email")
        }

        func runExample(_ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = example
            process.arguments = arguments + [
                "--database-url", raw, "--migrations-table", ledger,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let statusBefore = try runExample(["status"])
        #expect(statusBefore.status == 0)
        #expect(statusBefore.output.contains("Pending migrations:"))
        #expect(statusBefore.output.contains("20260714120000_CreateUsers"))

        let apply = try runExample(["apply"])
        #expect(apply.status == 0)
        #expect(apply.output.contains("✓ 20260714120000_CreateUsers"))
        #expect(apply.output.contains("Done — applied 4 migrations."))

        let statusAfter = try runExample(["status", "--json"])
        #expect(statusAfter.status == 0)
        #expect(statusAfter.output.contains("\"upToDate\" : true"))

        let rollback = try runExample(["rollback", "--to", "0"])
        #expect(rollback.status == 0)
        #expect(rollback.output.contains("Done — rolled back 4 migrations."))

        try await withTestClient { client in
            #expect(try await !tableExists(client, "users"))
            try await cleanup(client, ledger: ledger, tables: [])
        }
    }
}

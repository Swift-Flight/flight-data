import FlightMigrate
import FlightMigrateCore
import Foundation

// Migration fixtures for migrator unit tests, and helpers to build entries whose
// checksums are stable per name (so tests can simulate drift by seeding a different
// checksum in the fake database).

struct CreateAlpha: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("alpha") { t in
            t.integer("x").notNull()
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("alpha")
    }
}

struct CreateBeta: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("beta") { t in
            t.integer("x")
        }
        schema.createIndex(on: "beta", columns: ["x"])
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("beta")
    }
}

struct CreateGamma: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("gamma") { t in
            t.integer("x")
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("gamma")
    }
}

/// Second statement is a recognizable failure point for injection.
struct FailsSecondStatement: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("target") { t in
            t.integer("x")
        }
        schema.raw("SELECT boom()")
    }
    func down(_ schema: SchemaBuilder) {
        schema.raw("SELECT unboom()")
        schema.dropTable("target")
    }
}

/// Unwrapped, multi-statement (deliberately, to test the §3.2 warning and failure text).
struct UnwrappedConcurrent: Migration {
    static let wrapInTransaction = false

    func up(_ schema: SchemaBuilder) {
        schema.raw("CREATE INDEX CONCURRENTLY one ON t (a)")
        schema.raw("CREATE INDEX CONCURRENTLY two ON t (b)")
    }
    func down(_ schema: SchemaBuilder) {
        schema.raw("DROP INDEX CONCURRENTLY one")
    }
}

/// No statements in either direction.
struct EmptyMigration: Migration {
    func up(_ schema: SchemaBuilder) {}
    func down(_ schema: SchemaBuilder) {}
}

/// Builds an entry whose checksum derives deterministically from the name.
func entry(_ version: Int64, _ name: String, _ type: any Migration.Type) -> MigrationEntry {
    MigrationEntry(version: version, name: name, source: "source-of-\(name)", type: type)
}

/// The checksum `entry(_:_:_:)` produces, for seeding matching rows in the fake database.
func checksum(_ version: Int64, _ name: String) -> String {
    MigrationChecksum.compute(version: version, name: name, source: "source-of-\(name)")
}

/// A committed bookkeeping row that matches `entry(version, name, ...)`.
func appliedRow(_ version: Int64, _ name: String, checksum explicit: String? = nil)
    -> AppliedMigrationRecord
{
    AppliedMigrationRecord(
        version: version,
        name: name,
        checksum: explicit ?? checksum(version, name),
        appliedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

/// Collects emitted events for assertions.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MigrationEvent] = []

    var events: [MigrationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @Sendable func collect(_ event: MigrationEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}

/// A migrator over the fake database with standard test configuration.
func makeMigrator(
    database: FakeDatabase,
    migrations: [MigrationEntry],
    failOnUnknownApplied: Bool = false,
    onEvent: (@Sendable (MigrationEvent) -> Void)? = nil
) -> FlightMigrator {
    var configuration = FlightMigrator.Configuration()
    configuration.failOnUnknownApplied = failOnUnknownApplied
    configuration.onEvent = onEvent
    return FlightMigrator(database: database, migrations: migrations, configuration: configuration)
}

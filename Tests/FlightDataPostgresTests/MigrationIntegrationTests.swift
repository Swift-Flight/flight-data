import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightMigrate
import PostgresNIO
import Testing

/// wiring: the migrator runs against the URL resolved from Flight Config,
/// through the same path production deploys use — and the test schema itself
/// was created by it (see `TestSchema`), so this suite mostly asserts the
/// bookkeeping is real.
extension PostgresIntegrationSuite {
@Suite("Flight Migrate wiring")
struct MigrationIntegrationTests {
    @Test func migrateIsIdempotentAndTracked() async throws {
        try await TestSchema.shared.ensure()

        // A second run through the same config-resolved path applies nothing.
        let applied = try await PostgresMigrations.migrate(
            configuration: try TestDatabase.configuration(),
            migrations: TestMigrations.all
        )
        #expect(applied.isEmpty)

        // The ledger records exactly this suite's migrations.
        let status = try await PostgresMigrations.withMigrator(
            settings: try TestDatabase.settings(),
            migrations: TestMigrations.all
        ) { migrator in
            try await migrator.status()
        }
        #expect(status.pending.isEmpty)
        let appliedVersions = status.applied.map(\.version)
        for entry in TestMigrations.all {
            #expect(appliedVersions.contains(entry.version))
        }
        #expect(status.applied.allSatisfy { $0.state == .ok })
    }
}
}

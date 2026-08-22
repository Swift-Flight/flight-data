import FlightCore
import FlightDataCore
import FlightMigrate
import Logging
import PostgresNIO

/// The §7 wiring — and nothing more. Migrations themselves are Flight
/// Migrate's: plain `Migration` types, each applied in its own transaction,
/// tracked in `flight_migrations`, run as a deliberate step (`flight
/// migrate` / a migrate binary), never automatically at boot. This package
/// only connects that machinery to the datasource URL resolved from Flight
/// Config.
///
/// The test suite uses the same path to prepare its schema (§8): migrations
/// are exercised on every test run, with no separate schema-setup mechanism.
public enum PostgresMigrations {
    /// Runs `body` with a `FlightMigrator` wired to the datasource's URL. A
    /// short-lived `PostgresClient` runs for the duration — the migrator is
    /// a deploy-step tool, deliberately independent of the serving pool.
    public static func withMigrator<T: Sendable>(
        settings: DataSourceSettings,
        migrations: [MigrationEntry],
        configuration: FlightMigrator.Configuration = FlightMigrator.Configuration(),
        _ body: @Sendable @escaping (FlightMigrator) async throws -> T
    ) async throws -> T {
        let url = try PostgresDataSourceURL.parse(settings.url, datasource: settings.name)
        let client = PostgresClient(configuration: try url.clientConfiguration())
        return try await withThrowingTaskGroup(of: Void.self, returning: T.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            let migrator = FlightMigrator(
                client: client, migrations: migrations, configuration: configuration)
            return try await body(migrator)
        }
    }

    /// Applies all pending migrations for a configured datasource:
    ///
    /// ```swift
    /// try await PostgresMigrations.migrate(
    ///     configuration: try container.resolve(Configuration.self),
    ///     migrations: _allMigrations()   // the FlightMigratePlugin registry
    /// )
    /// ```
    @discardableResult
    public static func migrate(
        configuration: Configuration,
        datasource name: String = PrimaryDataSource.name,
        migrations: [MigrationEntry],
        migratorConfiguration: FlightMigrator.Configuration = FlightMigrator.Configuration()
    ) async throws -> [AppliedMigration] {
        let settings = try DataSourceSettings.load(name: name, from: configuration)
        return try await withMigrator(
            settings: settings, migrations: migrations, configuration: migratorConfiguration
        ) { migrator in
            try await migrator.migrate()
        }
    }
}

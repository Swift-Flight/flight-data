import FlightMigrate
import Foundation
import Logging
import PostgresNIO

/// Shared execution plumbing for commands that talk to the database: builds the
/// `PostgresClient`, keeps its pool `run()`-ning for the duration of `body`, and tears it
/// down afterwards.
enum Runtime {
    static func withMigrator<T: Sendable>(
        options: DatabaseOptions,
        onEvent: (@Sendable (MigrationEvent) -> Void)? = nil,
        _ body: @Sendable @escaping (FlightMigrator) async throws -> T
    ) async throws -> T {
        let url = try DatabaseURL.resolve(flag: options.databaseUrl)
        let clientConfiguration = try url.postgresConfiguration()

        var logger = Logger(label: "flight-migrate")
        logger.logLevel = options.verbose ? .debug : .warning

        let client = PostgresClient(
            configuration: clientConfiguration,
            backgroundLogger: logger
        )

        var migratorConfiguration = FlightMigrator.Configuration()
        migratorConfiguration.migrationsTable = options.migrationsTable
        // 0 means "wait indefinitely", which is the right choice for an
        // interactive run someone is watching — and was unreachable from the
        // CLI, which pinned every run to the 30-second default.
        migratorConfiguration.lockTimeout =
            options.lockTimeout > 0 ? .seconds(options.lockTimeout) : nil
        if let key = options.advisoryLockKey {
            migratorConfiguration.advisoryLockKey = key
        }
        migratorConfiguration.failOnUnknownApplied = options.failOnUnknownApplied
        migratorConfiguration.logger = logger
        migratorConfiguration.onEvent = onEvent

        let migrator = FlightMigrator(
            client: client,
            migrations: MigrationRegistry.migrations,
            configuration: migratorConfiguration
        )

        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await client.run()
            }
            do {
                let result = try await body(migrator)
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Formats a duration for human output, e.g. `12 ms` or `3.4 s`.
    static func format(_ duration: Duration) -> String {
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}

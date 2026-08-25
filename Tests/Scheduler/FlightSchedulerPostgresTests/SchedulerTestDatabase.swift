import FlightDataCore
import FlightDataPostgres
import Foundation

/// The integration gate for the coordinator suite.
///
/// Reuses the same variable every other Postgres suite here uses, so one
/// `scripts/test.sh` run arms them all.
enum SchedulerTestDatabase {
    static var url: String? {
        let value = ProcessInfo.processInfo.environment["FLIGHT_POSTGRES_TEST_DATABASE_URL"]
        return (value?.isEmpty == false) ? value : nil
    }

    static var isConfigured: Bool { url != nil }

    /// One pool for the whole suite.
    ///
    /// A pool per test leaked them: shutdown is async, so a `defer` could
    /// only fire it detached and the next test started before the previous
    /// pool drained. Sharing one is also what a real deployment does.
    static func shared() async throws -> PostgresDataSource {
        try await Pool.shared.dataSource()
    }

    actor Pool {
        static let shared = Pool()
        private var started: PostgresDataSource?

        func dataSource() async throws -> PostgresDataSource {
            if let started { return started }
            guard let url = SchedulerTestDatabase.url else { throw Missing() }
            // Comfortably above the suite's peak concurrency: the contention
            // test deliberately claims from several tasks at once, and a pool
            // sized exactly to that has no room for the claim already in
            // flight.
            let dataSource = try PostgresDataSource(
                settings: try DataSourceSettings(name: "scheduler-test", url: url, poolSize: 16))
            try await dataSource.start()
            started = dataSource
            return dataSource
        }
    }

    struct Missing: Error {}
}

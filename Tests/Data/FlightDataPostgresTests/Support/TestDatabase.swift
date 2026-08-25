import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres

/// Integration tests run against a real Postgres — the whole
/// value of this package is that queries are real SQL; mocking the
/// connection would test nothing that matters. They are gated on
/// `FLIGHT_POSTGRES_TEST_DATABASE_URL`:
///
/// ```
/// $ docker run -d --name flight-data-pg -e POSTGRES_PASSWORD=flight \
///     -e POSTGRES_DB=flight_data_test -p 127.0.0.1:55432:5432 postgres:16-alpine
/// $ export FLIGHT_POSTGRES_TEST_DATABASE_URL="postgres://postgres:flight@127.0.0.1:55432/flight_data_test?sslmode=disable"
/// $ swift test
/// ```
///
/// Without the variable, integration suites are skipped and only the
/// no-server unit tests run.
enum TestDatabase {
    static let url = ProcessInfo.processInfo.environment["FLIGHT_POSTGRES_TEST_DATABASE_URL"]

    static var isConfigured: Bool { url != nil }

    /// A `Configuration` whose `datasource.<name>.url` points at the test
    /// database — what `PostgresDataModule`'s factory reads at freeze().
    static func configuration(
        datasource name: String = PrimaryDataSource.name,
        poolSize: Int = 4,
        resetOnRelease: Bool = true
    ) throws -> Configuration {
        let url = try requireURL()
        return Configuration(values: [
            DataSourceConfigKey.url(datasource: name): url,
            DataSourceConfigKey.poolSize(datasource: name): "\(poolSize)",
            "datasource.\(name).reset_on_release": "\(resetOnRelease)",
        ])
    }

    static func settings(
        datasource name: String = PrimaryDataSource.name,
        poolSize: Int = 4
    ) throws -> DataSourceSettings {
        try DataSourceSettings(name: name, url: try requireURL(), poolSize: poolSize)
    }

    private static func requireURL() throws -> String {
        guard let url else {
            throw TestDatabaseError.notConfigured
        }
        return url
    }
}

enum TestDatabaseError: Error {
    case notConfigured
}

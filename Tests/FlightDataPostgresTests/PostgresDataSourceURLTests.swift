import FlightDataPostgres
import Testing

@Suite("datasource.<name>.url parsing")
struct PostgresDataSourceURLTests {
    @Test func parsesFullURL() throws {
        let url = try PostgresDataSourceURL.parse(
            "postgres://app:s%40cret@db.internal:6432/orders?sslmode=require",
            datasource: "primary"
        )
        #expect(url.host == "db.internal")
        #expect(url.port == 6432)
        #expect(url.username == "app")
        #expect(url.password == "s@cret")
        #expect(url.database == "orders")
        #expect(url.sslMode == .require)
    }

    @Test func appliesDefaults() throws {
        let url = try PostgresDataSourceURL.parse(
            "postgresql://localhost/app", datasource: "primary")
        #expect(url.port == 5432)
        #expect(url.username == "postgres")
        #expect(url.password == nil)
        #expect(url.sslMode == .prefer)
        #expect(url.database == "app")
    }

    @Test func rejectsForeignScheme() {
        #expect(throws: PostgresDataSourceURLError.unsupportedScheme(datasource: "primary", scheme: "mysql")) {
            try PostgresDataSourceURL.parse("mysql://localhost/app", datasource: "primary")
        }
    }

    @Test func rejectsMissingDatabase() {
        #expect(throws: PostgresDataSourceURLError.missingDatabase(datasource: "analytics")) {
            try PostgresDataSourceURL.parse("postgres://localhost:5432", datasource: "analytics")
        }
    }

    @Test func rejectsUnknownSSLMode() {
        #expect(throws: PostgresDataSourceURLError.invalidSSLMode(datasource: "primary", value: "verify-full")) {
            try PostgresDataSourceURL.parse(
                "postgres://localhost/app?sslmode=verify-full", datasource: "primary")
        }
    }

    @Test func rejectsUnknownParameters() {
        // A typo'd sslmode must not silently downgrade to the default.
        #expect(throws: PostgresDataSourceURLError.unsupportedParameter(datasource: "primary", parameter: "sslmodee")) {
            try PostgresDataSourceURL.parse(
                "postgres://localhost/app?sslmodee=disable", datasource: "primary")
        }
    }
}

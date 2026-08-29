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
        #expect(throws: PostgresDataSourceURLError.invalidSSLMode(datasource: "primary", value: "allow")) {
            try PostgresDataSourceURL.parse(
                "postgres://localhost/app?sslmode=allow", datasource: "primary")
        }
    }

    @Test("every libpq sslmode this package supports parses to itself",
          arguments: PostgresDataSourceURL.SSLMode.allCases)
    func sslModesRoundTrip(mode: PostgresDataSourceURL.SSLMode) throws {
        // `verify-ca` and `verify-full` used to be rejected outright, while
        // `prefer` and `require` quietly performed full verification under
        // libpq's names — so the two modes that authenticate the server were
        // unavailable, and the default failed against any self-signed
        // Postgres, which is most development and staging.
        let url = try PostgresDataSourceURL.parse(
            "postgres://localhost/app?sslmode=\(mode.rawValue)", datasource: "primary")
        #expect(url.sslMode == mode)
    }

    @Test func rejectsUnknownParameters() {
        // A typo'd sslmode must not silently downgrade to the default.
        #expect(throws: PostgresDataSourceURLError.unsupportedParameter(datasource: "primary", parameter: "sslmodee")) {
            try PostgresDataSourceURL.parse(
                "postgres://localhost/app?sslmodee=disable", datasource: "primary")
        }
    }

    @Test("a password containing a percent escape survives")
    func passwordWithALiteralPercentEscape() throws {
        // `URLComponents.password` is already decoded, and this used to decode
        // it a second time: `%2541` in the URL decodes to the literal `%41`,
        // which the second pass turned into `A`. The existing `s%40cret` test
        // could not see it — `s@cret` decodes to itself — so the corruption
        // only ever showed up as an authentication failure blaming the server.
        let url = try PostgresDataSourceURL.parse(
            "postgres://app:pa%2541ss@db.internal:5432/orders", datasource: "primary")
        #expect(url.password == "pa%41ss")
    }

    @Test("a username containing a percent escape survives too")
    func usernameWithALiteralPercentEscape() throws {
        let url = try PostgresDataSourceURL.parse(
            "postgres://a%2542b:secret@db.internal:5432/orders", datasource: "primary")
        #expect(url.username == "a%42b")
    }
}

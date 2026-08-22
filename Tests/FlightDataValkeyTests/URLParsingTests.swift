import FlightDataValkey
import Testing

/// §3.2's URL convention, no server required. The load-bearing assertion is
/// the first one: `valkey://` and `redis://` parse to the *same* value —
/// §3's seamlessness is a compatible pair, not a behavior switch.
@Suite("Datasource URL parsing (§3.2)")
struct URLParsingTests {
    @Test func valkeyAndRedisSchemesAreSynonyms() throws {
        let valkey = try ValkeyDataSourceURL.parse("valkey://localhost:6379", datasource: "primary")
        let redis = try ValkeyDataSourceURL.parse("redis://localhost:6379", datasource: "primary")
        #expect(valkey == redis)

        let valkeys = try ValkeyDataSourceURL.parse("valkeys://localhost", datasource: "primary")
        let rediss = try ValkeyDataSourceURL.parse("rediss://localhost", datasource: "primary")
        #expect(valkeys == rediss)
    }

    @Test func minimalURLGetsDefaults() throws {
        let url = try ValkeyDataSourceURL.parse("valkey://localhost", datasource: "primary")
        #expect(url.host == "localhost")
        #expect(url.port == 6379)
        #expect(url.database == 0)
        #expect(url.username == nil)
        #expect(url.password == nil)
        #expect(!url.useTLS)
    }

    @Test func explicitPortAndDatabase() throws {
        let url = try ValkeyDataSourceURL.parse("valkey://cache.internal:7000/3", datasource: "primary")
        #expect(url.host == "cache.internal")
        #expect(url.port == 7000)
        #expect(url.database == 3)
    }

    @Test func trailingSlashMeansDatabaseZero() throws {
        let url = try ValkeyDataSourceURL.parse("valkey://localhost/", datasource: "primary")
        #expect(url.database == 0)
    }

    @Test func tlsSchemesEnableTLS() throws {
        #expect(try ValkeyDataSourceURL.parse("valkeys://h", datasource: "d").useTLS)
        #expect(try ValkeyDataSourceURL.parse("rediss://h", datasource: "d").useTLS)
        #expect(!(try ValkeyDataSourceURL.parse("valkey://h", datasource: "d").useTLS))
    }

    @Test func passwordOnlyGetsDefaultUsername() throws {
        let url = try ValkeyDataSourceURL.parse("valkey://:sekrit@localhost", datasource: "primary")
        #expect(url.username == "default")
        #expect(url.password == "sekrit")
    }

    @Test func usernameAndPassword() throws {
        let url = try ValkeyDataSourceURL.parse("redis://app:sekrit@localhost/1", datasource: "primary")
        #expect(url.username == "app")
        #expect(url.password == "sekrit")
        #expect(url.database == 1)
    }

    @Test func usernameWithoutPasswordIsRejected() {
        #expect(throws: ValkeyDataSourceURLError.usernameWithoutPassword(datasource: "primary")) {
            try ValkeyDataSourceURL.parse("valkey://app@localhost", datasource: "primary")
        }
    }

    @Test func foreignSchemeIsRejected() {
        #expect(throws: ValkeyDataSourceURLError.unsupportedScheme(datasource: "primary", scheme: "postgres")) {
            try ValkeyDataSourceURL.parse("postgres://localhost:5432/app", datasource: "primary")
        }
    }

    @Test func missingHostIsRejected() {
        #expect(throws: ValkeyDataSourceURLError.missingHost(datasource: "primary")) {
            try ValkeyDataSourceURL.parse("valkey://", datasource: "primary")
        }
    }

    @Test func nonNumericDatabaseIsRejected() {
        #expect(throws: ValkeyDataSourceURLError.invalidDatabase(datasource: "primary", path: "/three")) {
            try ValkeyDataSourceURL.parse("valkey://localhost/three", datasource: "primary")
        }
        #expect(throws: ValkeyDataSourceURLError.invalidDatabase(datasource: "primary", path: "/1/2")) {
            try ValkeyDataSourceURL.parse("valkey://localhost/1/2", datasource: "primary")
        }
    }

    @Test func notAURLIsRejected() {
        // No scheme at all — a bare word is not a datasource URL.
        #expect(throws: (any Error).self) {
            try ValkeyDataSourceURL.parse("localhost", datasource: "primary")
        }
    }

    @Test func connectionConfigurationCarriesAuthAndDatabase() throws {
        let url = try ValkeyDataSourceURL.parse("valkey://app:sekrit@localhost/5", datasource: "primary")
        let configuration = try url.connectionConfiguration()
        #expect(configuration.authentication?.username == "app")
        #expect(configuration.authentication?.password == "sekrit")
        #expect(configuration.databaseNumber == 5)
    }
}

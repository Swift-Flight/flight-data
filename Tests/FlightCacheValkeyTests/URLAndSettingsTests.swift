import FlightCore
import Testing

@testable import FlightCacheValkey

@Suite("cache.valkey.* settings and URL parsing")
struct URLAndSettingsTests {

    @Test("valkey:// and redis:// are exact synonyms")
    func schemeSynonyms() throws {
        let valkey = try ValkeyCacheURL.parse("valkey://localhost:6379")
        let redis = try ValkeyCacheURL.parse("redis://localhost:6379")
        #expect(valkey == redis)
        #expect(!valkey.useTLS)
    }

    @Test("TLS schemes set the flag; port defaults to 6379")
    func tlsAndDefaults() throws {
        let url = try ValkeyCacheURL.parse("rediss://cache.example.com")
        #expect(url.useTLS)
        #expect(url.port == 6379)
        #expect(url.database == 0)
        #expect(url.username == nil && url.password == nil)
    }

    @Test("auth and database parse; password-only gets the default user")
    func authAndDatabase() throws {
        let url = try ValkeyCacheURL.parse("valkey://:secret@host:6380/2")
        #expect(url.username == "default")
        #expect(url.password == "secret")
        #expect(url.database == 2)
        #expect(url.port == 6380)
    }

    @Test("rejections: scheme, host, database, lone username")
    func rejections() {
        #expect(throws: ValkeyCacheURLError.unsupportedScheme(scheme: "http")) {
            _ = try ValkeyCacheURL.parse("http://localhost")
        }
        #expect(throws: ValkeyCacheURLError.missingHost) {
            _ = try ValkeyCacheURL.parse("valkey://")
        }
        #expect(throws: ValkeyCacheURLError.invalidDatabase(path: "/two")) {
            _ = try ValkeyCacheURL.parse("valkey://host/two")
        }
        #expect(throws: ValkeyCacheURLError.usernameWithoutPassword) {
            _ = try ValkeyCacheURL.parse("valkey://user@host")
        }
    }

    @Test("settings load: url required, everything else defaulted and validated")
    func settingsLoad() throws {
        let loaded = try ValkeyCacheSettings.load(
            from: Configuration(values: ["cache.valkey.url": "valkey://localhost:56379"]))
        #expect(loaded.commandTimeout == ValkeyCacheSettings.defaultCommandTimeout)
        #expect(loaded.poolSize == ValkeyCacheSettings.defaultPoolSize)
        #expect(loaded.minimumConnections == ValkeyCacheSettings.defaultMinimumConnections)

        let tuned = try ValkeyCacheSettings.load(
            from: Configuration(values: [
                "cache.valkey.url": "valkey://localhost:56379",
                "cache.valkey.command_timeout_ms": "100",
                "cache.valkey.unreachable_after_ms": "80",
                "cache.valkey.pool_size": "50",
                "cache.valkey.min_connections": "4",
            ]))
        #expect(tuned.commandTimeout == .milliseconds(100))
        #expect(tuned.unreachableAfter == .milliseconds(80))
        #expect(tuned.poolSize == 50)
        #expect(tuned.minimumConnections == 4)

        #expect(throws: (any Error).self) {
            _ = try ValkeyCacheSettings.load(from: Configuration())
        }
    }

    @Test("unreachable_after_ms defaults to the command timeout — one knob covers both phases")
    func unreachableDefaultsToCommandTimeout() throws {
        let loaded = try ValkeyCacheSettings.load(
            from: Configuration(values: [
                "cache.valkey.url": "valkey://localhost",
                "cache.valkey.command_timeout_ms": "120",
            ]))
        #expect(loaded.unreachableAfter == .milliseconds(120))
    }

    /// Delta CV1: the pool's connection-creation breaker is what bounds an
    /// operation when the server is down, so it must actually be set.
    @Test("both timeout phases reach the driver configuration")
    func clientConfigurationCarriesBothTimeouts() throws {
        let settings = ValkeyCacheSettings(
            url: try ValkeyCacheURL.parse("valkey://localhost"),
            commandTimeout: .milliseconds(250),
            unreachableAfter: .milliseconds(150),
            poolSize: 30,
            minimumConnections: 2
        )
        let configuration = try settings.clientConfiguration()
        #expect(configuration.commandTimeout == .milliseconds(250))
        #expect(configuration.connectionPool.circuitBreakerTripAfter == .milliseconds(150))
        #expect(configuration.connectionPool.maximumConnectionHardLimit == 30)
        #expect(configuration.connectionPool.minimumConnectionCount == 2)
    }

    @Test("invalid timeouts and pool sizing are rejected at load")
    func rejectsInvalidTuning() {
        #expect(
            throws: ValkeyCacheConfigurationError.invalidTimeout(
                key: ValkeyCacheConfigKey.commandTimeoutMilliseconds, milliseconds: 0)
        ) {
            _ = try ValkeyCacheSettings.load(
                from: Configuration(values: [
                    "cache.valkey.url": "valkey://localhost",
                    "cache.valkey.command_timeout_ms": "0",
                ]))
        }
        #expect(throws: ValkeyCacheConfigurationError.invalidPoolSize(0)) {
            _ = try ValkeyCacheSettings.load(
                from: Configuration(values: [
                    "cache.valkey.url": "valkey://localhost",
                    "cache.valkey.pool_size": "0",
                ]))
        }
        #expect(throws: ValkeyCacheConfigurationError.invalidMinimumConnections(9, poolSize: 4)) {
            _ = try ValkeyCacheSettings.load(
                from: Configuration(values: [
                    "cache.valkey.url": "valkey://localhost",
                    "cache.valkey.pool_size": "4",
                    "cache.valkey.min_connections": "9",
                ]))
        }
    }

    @Test("glob metacharacters in eviction patterns are escaped")
    func globEscaping() {
        #expect(ValkeyCache.globEscaped("plain:ns:") == "plain:ns:")
        #expect(ValkeyCache.globEscaped(#"a*b?c[d]e\f"#) == #"a\*b\?c\[d\]e\\f"#)
    }
}

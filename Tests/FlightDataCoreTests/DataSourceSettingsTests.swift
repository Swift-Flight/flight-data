import Testing
import FlightCore
import FlightDataCore

/// — the one shared key convention that lets multiple stores coexist.
@Suite("Configuration conventions")
struct DataSourceSettingsTests {

    @Test("the convention keys spell datasource.<name>.<suffix>")
    func keySpelling() {
        #expect(DataSourceConfigKey.url(datasource: "primary") == "datasource.primary.url")
        #expect(DataSourceConfigKey.poolSize(datasource: "analytics") == "datasource.analytics.pool_size")
        #expect(DataSourceConfigKey.key("tls.mode", datasource: "primary") == "datasource.primary.tls.mode")
    }

    @Test("load resolves url and pool_size for a named datasource")
    func happyPath() throws {
        let configuration = Configuration(values: [
            "datasource.primary.url": "postgres://localhost:5432/app",
            "datasource.primary.pool_size": "10",
        ])
        let settings = try DataSourceSettings.load(from: configuration)
        #expect(settings == (try DataSourceSettings(
            name: "primary", url: "postgres://localhost:5432/app", poolSize: 10)))
    }

    @Test("multiple named datasources coexist in one configuration")
    func namedDataSources() throws {
        let configuration = Configuration(values: [
            "datasource.primary.url": "postgres://localhost:5432/app",
            "datasource.primary.pool_size": "10",
            "datasource.analytics.url": "postgres://localhost:5432/warehouse",
            "datasource.analytics.pool_size": "4",
        ])
        let primary = try DataSourceSettings.load(name: "primary", from: configuration)
        let analytics = try DataSourceSettings.load(name: "analytics", from: configuration)
        #expect(primary.url.hasSuffix("/app"))
        #expect(analytics.url.hasSuffix("/warehouse"))
        #expect((primary.poolSize, analytics.poolSize) == (10, 4))
    }

    @Test("a missing url fails loudly with the key named (at bootstrap, not first query)")
    func missingURL() {
        let configuration = Configuration(values: [:])
        #expect {
            _ = try DataSourceSettings.load(from: configuration)
        } throws: { error in
            guard case ConfigError.missingKey(let key, _) = error else { return false }
            return key == "datasource.primary.url"
        }
    }

    @Test("pool_size is optional and defaults")
    func defaultPoolSize() throws {
        let configuration = Configuration(values: [
            "datasource.primary.url": "postgres://localhost:5432/app"
        ])
        let settings = try DataSourceSettings.load(from: configuration)
        #expect(settings.poolSize == DataSourceSettings.defaultPoolSize)
    }

    @Test("a malformed pool_size throws — the default never masks corruption")
    func malformedPoolSize() {
        let configuration = Configuration(values: [
            "datasource.primary.url": "postgres://localhost:5432/app",
            "datasource.primary.pool_size": "many",
        ])
        #expect {
            _ = try DataSourceSettings.load(from: configuration)
        } throws: { error in
            guard case ConfigError.decodingFailed(let key, let raw, _) = error else { return false }
            return key == "datasource.primary.pool_size" && raw == "many"
        }
    }

    @Test("a zero or negative pool_size is rejected as semantic nonsense")
    func nonPositivePoolSize() {
        #expect(throws: DataSourceConfigurationError.invalidPoolSize(datasource: "primary", value: 0)) {
            _ = try DataSourceSettings(name: "primary", url: "memory://", poolSize: 0)
        }
        let configuration = Configuration(values: [
            "datasource.primary.url": "postgres://localhost:5432/app",
            "datasource.primary.pool_size": "-3",
        ])
        #expect(throws: DataSourceConfigurationError.invalidPoolSize(datasource: "primary", value: -3)) {
            _ = try DataSourceSettings.load(from: configuration)
        }
    }

    @Test("an empty url is rejected")
    func emptyURL() {
        #expect(throws: DataSourceConfigurationError.emptyURL(datasource: "primary")) {
            _ = try DataSourceSettings(name: "primary", url: "   ")
        }
    }
}

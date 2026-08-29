import Foundation
import FlightCore
import FlightDataCore
import FlightDataTesting
import FlightDataValkey
import Testing

/// Integration tests run against a real server — the value of
/// this package is real commands against a real server; mocking the
/// connection would test nothing meaningful. And they run against **both
/// Valkey and Redis** — that's what keeps compatibility policy honest
/// rather than aspirational. Each server is gated on its own variable:
///
/// ```
/// $ docker run -d --name flight-data-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
/// $ docker run -d --name flight-data-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
/// $ export FLIGHT_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
/// $ export FLIGHT_REDIS_TEST_URL="redis://127.0.0.1:56380"
/// $ swift test
/// ```
///
/// Integration suites are parameterized over every configured server — one
/// code path, two servers, per (no detection logic, no dual paths).
/// Without either variable they are skipped and only the no-server unit
/// tests run.
enum TestServer: String, CaseIterable, Sendable, CustomStringConvertible {
    case valkey
    case redis

    var environmentKey: String {
        switch self {
        case .valkey: return "FLIGHT_VALKEY_TEST_URL"
        case .redis: return "FLIGHT_REDIS_TEST_URL"
        }
    }

    /// The configured URL, pinned to a database index of this suite's own.
    ///
    /// These tests `flushdb`, and so do FlightCacheValkeyTests — two suites
    /// in two targets, each `.serialized` only against itself. Sharing one
    /// database meant one suite could wipe the other mid-test. The database
    /// index is exactly the tool for this and works across processes, which
    /// an in-process lock would not. Data tests use 2, cache tests use 1,
    /// and neither touches whatever a developer left in 0.
    var url: String? {
        guard let base = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        guard let marker = base.range(of: "://") else { return base }
        let afterScheme = base[marker.upperBound...]
        if let slash = afterScheme.firstIndex(of: "/") {
            return String(base[..<slash]) + "/2"
        }
        return base + "/2"
    }

    /// Every server the environment configures — what integration tests are
    /// parameterized over.
    static let available: [TestServer] = allCases.filter { $0.url != nil }

    var description: String { rawValue }

    /// A `Configuration` whose `datasource.<name>.url` points at this
    /// server — what `ValkeyDataModule`'s factory reads at freeze().
    func configuration(
        datasource name: String = PrimaryDataSource.name,
        poolSize: Int = 4
    ) throws -> Configuration {
        guard let url else { throw TestServerError.notConfigured(self) }
        return Configuration(values: [
            DataSourceConfigKey.url(datasource: name): url,
            DataSourceConfigKey.poolSize(datasource: name): "\(poolSize)",
        ])
    }

    func settings(
        datasource name: String = PrimaryDataSource.name,
        poolSize: Int = 4,
        checkoutTimeout: Duration = DataSourceSettings.defaultCheckoutTimeout
    ) throws -> DataSourceSettings {
        guard let url else { throw TestServerError.notConfigured(self) }
        return try DataSourceSettings(
            name: name, url: url, poolSize: poolSize, checkoutTimeout: checkoutTimeout)
    }
}

enum TestServerError: Error {
    case notConfigured(TestServer)
    case timedOut(String)
}

/// Builds a frozen container (module DAG order, real macro-registered
/// repositories), starts the pool by hand — tests drive the lifecycle a
/// `ServiceGroup` would — flushes the test database, runs `body`, and drains
/// the pool.
func withValkeyContainer<T>(
    _ server: TestServer,
    poolSize: Int = 4,
    _ body: (Container, ValkeyDataSource) async throws -> T
) async throws -> T {
    let container = try TestContainer.build(
        configuration: try server.configuration(poolSize: poolSize)
    ) {
        ValkeyTestAppModule()
    }
    let source = try container.resolve(ValkeyDataSource.self, qualifier: PrimaryDataSource.name)
    try await source.start()
    do {
        try await flush(source)
        let result = try await body(container, source)
        await source.shutdown()
        return result
    } catch {
        await source.shutdown()
        throw error
    }
}

/// Empties the test database so each test starts from a known state (suites
/// are `.serialized`, so this never races another test).
func flush(_ source: ValkeyDataSource) async throws {
    try await source.withConnection { connection in
        try await connection.flushdb()
    }
    // Releasing a connection starts its session reset, and it is not back in
    // the free list until that lands. A test that asserts pool counts right
    // after this would otherwise be racing the reset.
    try await settle(source)
}

/// Waits for every connection to be back in the free list — after a release,
/// or after a replacement dial.
func settle(_ source: ValkeyDataSource) async throws {
    try await waitUntil("every connection back in the pool") {
        source.availableConnections == source.poolSize
    }
}

/// Polls `condition` until it holds or `timeout` elapses — for the
/// asynchronous pool events (replacement dials) that have no completion
/// signal to await.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ what: String,
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestServerError.timedOut(what)
}

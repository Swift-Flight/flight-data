import FlightCore
import FlightDataCore
import FlightDataPostgres
import Foundation
import Testing

/// What a transient outage costs — the Postgres half of the story its Valkey
/// twin has been telling for a while.
///
/// Replacement gave up after one failed dial, on the reasoning that "the next
/// checkout/release re-triggers replacement". That holds while some
/// connections survive. Once the outage retires all of them there are no more
/// releases, and a checkout that finds an empty free list never reached the
/// broken-connection branch that yields the trigger — so nothing re-triggered
/// anything: the pool sat at zero established, answered `poolExhausted`, and
/// blamed the operator's `pool_size` until the process was restarted.
///
/// And it did that while reporting itself healthy. `ping()` swallowed
/// `poolExhausted` unconditionally, on the reasoning that every connection
/// being checked out is evidence connections exist — true of a busy pool, and
/// exactly backwards for a pool that has none. The orchestrator was told the
/// pod was fine.
///
/// Gated on a server this test is allowed to stop and start, which is not the
/// shared one the rest of the suite uses.
@Suite(.serialized, .enabled(if: PostgresOutageServer.isConfigured))
struct PostgresOutageRecoveryTests {

    @Test("a pool that lost every connection reports dead rather than alive")
    func pingDoesNotLieAboutAnEmptyPool() async throws {
        let source = try PostgresDataSource(settings: try PostgresOutageServer.settings(poolSize: 2))
        try await source.start()
        try await source.ping()

        let maintenance = Task { await source.maintainPool() }
        defer { maintenance.cancel() }

        PostgresOutageServer.stop()
        await driveDiscoveryOfDeadConnections(source)
        #expect(source.establishedConnections == 0, "the outage should have retired every connection")

        // The whole point: this used to answer "alive".
        await #expect(throws: DataSourceError.self) {
            try await source.ping()
        }

        PostgresOutageServer.start()
        await source.shutdown()
    }

    @Test("the pool refills itself after the server comes back")
    func poolRecoversFromTransientOutage() async throws {
        let source = try PostgresDataSource(settings: try PostgresOutageServer.settings(poolSize: 2))
        try await source.start()
        #expect(source.establishedConnections == 2)

        let maintenance = Task { await source.maintainPool() }
        defer { maintenance.cancel() }

        PostgresOutageServer.stop()
        await driveDiscoveryOfDeadConnections(source)

        PostgresOutageServer.start()

        // The pool must come back on its own. Before the fix this waited
        // forever, because nothing was still trying.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while source.establishedConnections < 2 {
            guard ContinuousClock.now < deadline else {
                Issue.record(
                    "pool never refilled: established=\(source.establishedConnections) of 2")
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(source.establishedConnections == 2)

        // And it is honest again.
        try await source.ping()
        await source.shutdown()
    }

    /// A checkout/release cycle is what notices dead connections, exactly as
    /// it would under load.
    private func driveDiscoveryOfDeadConnections(_ source: PostgresDataSource) async {
        for _ in 0..<8 {
            if let connection = try? source.checkout() { source.release(connection) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// A disposable Postgres this suite may stop and restart.
enum PostgresOutageServer {
    static let containerName = "flight-postgres-outage"
    static let port = 55499

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["FLIGHT_POSTGRES_OUTAGE_TEST"] != nil
    }

    static func settings(poolSize: Int) throws -> DataSourceSettings {
        try DataSourceSettings(
            name: PrimaryDataSource.name,
            url: "postgres://postgres:flight@127.0.0.1:\(port)/flight_test",
            poolSize: poolSize,
            // Short, so the "pool is empty" assertions are not waiting out a
            // five-second queue that cannot possibly be satisfied.
            checkoutTimeout: .milliseconds(100))
    }

    static func stop() { docker(["stop", containerName]) }

    static func start() {
        docker(["start", containerName])
        // `docker start` returns before Postgres is accepting connections.
        for _ in 0..<60 {
            if docker(["exec", containerName, "pg_isready", "-U", "postgres"]) == 0 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    @discardableResult
    private static func docker(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

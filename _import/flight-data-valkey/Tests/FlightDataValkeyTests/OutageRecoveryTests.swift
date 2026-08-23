import FlightCore
import FlightDataCore
import FlightDataValkey
import Foundation
import Testing

/// What a transient outage costs.
///
/// Replacement gave up after one failed dial, on the reasoning that "the next
/// close/release re-triggers replacement". That holds while some connections
/// survive. Once the outage retires all of them there are no more closes and
/// no more releases, so nothing re-triggered anything: the pool sat at zero
/// established, answered `poolExhausted`, and blamed the operator's
/// `pool_size` — until the process was restarted. A blip became permanent.
///
/// Gated on a server this test is allowed to stop and start, which is not the
/// shared one the rest of the suite uses.
@Suite(.serialized, .enabled(if: OutageServer.isConfigured))
struct OutageRecoveryTests {

    @Test("the pool refills itself after the server comes back")
    func poolRecoversFromTransientOutage() async throws {
        let source = try ValkeyDataSource(settings: try OutageServer.settings(poolSize: 2))
        try await source.start()
        #expect(source.establishedConnections == 2)

        let maintenance = Task { await source.maintainPool() }
        defer { maintenance.cancel() }

        OutageServer.stop()
        // Drive discovery of the dead connections: a checkout/release cycle
        // is what notices, exactly as it would under load.
        for _ in 0..<8 {
            if let connection = try? source.checkout() { source.release(connection) }
            try? await Task.sleep(for: .milliseconds(50))
        }

        OutageServer.start()

        // The pool must come back on its own. Before the fix this waited
        // forever, because nothing was still trying.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while source.establishedConnections < 2 {
            guard ContinuousClock.now < deadline else {
                Issue.record(
                    "pool never refilled: established=\(source.establishedConnections) of 2")
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(source.establishedConnections == 2)

        await source.shutdown()
    }
}

/// A disposable Valkey this suite may stop and restart.
enum OutageServer {
    static let containerName = "flight-valkey-outage"
    static let port = 56399

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["FLIGHT_VALKEY_OUTAGE_TEST"] != nil
    }

    static func settings(poolSize: Int) throws -> DataSourceSettings {
        try DataSourceSettings(
            name: PrimaryDataSource.name,
            url: "valkey://127.0.0.1:\(port)",
            poolSize: poolSize)
    }

    static func stop() { docker(["stop", containerName]) }
    static func start() { docker(["start", containerName]) }

    private static func docker(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

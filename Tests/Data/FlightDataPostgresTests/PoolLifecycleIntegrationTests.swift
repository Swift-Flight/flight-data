import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightDataTesting
import PostgresNIO
import ServiceLifecycle
import Testing

/// The service story end to end: the module's service dials the pool,
/// requests are served only once it is live, broken connections are
/// replaced while it runs, and cancellation drains it.
extension PostgresIntegrationSuite {
/// The cross-store contract, run against the real driver.
///
/// `DataSourceConformance` is billed as "the contract every data source must
/// satisfy" and was run by neither driver — which is exactly the failure mode
/// its own doc comment says it exists to end. Both run it now.
@Suite("DataSource conformance — PostgresDataSource")
struct PostgresConformanceTests {
    @Test("the driver satisfies the DataSource contract")
    func conforms() async throws {
        try await DataSourceConformance.verify(
            make: {
                let source = try PostgresDataSource(
                    settings: try TestDatabase.settings(poolSize: 4))
                try await source.start()
                return source
            },
            shutdown: { await $0.shutdown() })
    }
}

@Suite("Pool service lifecycle")
struct PoolLifecycleIntegrationTests {
    @Test func moduleServiceRunsAndDrainsThePool() async throws {
        try await TestSchema.shared.ensure()
        let container = try TestContainer.build(
            configuration: try TestDatabase.configuration(poolSize: 2)
        ) {
            TestAppModule()
        }
        // Drive the pool's run() the way bootstrap's ServiceGroup drives the
        // module's service (start → serve → cancel).
        let source = try container.resolve(PostgresDataSource.self, qualifier: "primary")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await source.run() }

            // Wait until the pool is live, as bootstrap ordering guarantees.
            for _ in 0..<100 where source.establishedConnections < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(source.establishedConnections == 2)

            try await container.withScope { scope in
                let repo = try container.resolve(UserRepository.self, in: scope)
                #expect(try await repo.find(byEmail: "nobody@example.com") == nil)
            }

            group.cancelAll()
        }
        #expect(source.isClosed)
        #expect(source.establishedConnections == 0)
        #expect(throws: DataSourceError.closed(datasource: "primary")) {
            _ = try source.checkout()
        }
    }

    @Test func brokenConnectionsAreReplacedWhileServiceRuns() async throws {
        try await TestSchema.shared.ensure()
        let source = try PostgresDataSource(settings: try TestDatabase.settings(poolSize: 2))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await source.run() }
            for _ in 0..<100 where source.establishedConnections < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }

            // Kill a connection out from under the pool — a server restart
            // in miniature. Release notices, drops it, and the service loop
            // dials a replacement.
            let casualty = try source.checkout()
            try await casualty.close()
            source.release(casualty)

            for _ in 0..<100 where source.establishedConnections < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(source.establishedConnections == 2)

            // And the replacement actually works.
            try await source.withConnection { connection in
                _ = try await connection.query("SELECT 1", logger: .init(label: "test"))
            }
            group.cancelAll()
        }
    }
}
}

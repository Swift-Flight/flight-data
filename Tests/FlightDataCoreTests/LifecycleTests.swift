import Testing
import FlightCore
import FlightDataCore
import FlightDataTesting
import ServiceLifecycle

/// — every store module follows one shape: configure registers the pool,
/// the pool's long-running work is a Service, health falls out of bootstrap
/// with no per-store instrumentation.
@Suite("Module lifecycle and health")
struct LifecycleTests {

    @Test("assemble wires a store module: components registered, module .running, source stamped")
    func assembleStoreModule() throws {
        let app = try Flight.assemble(
            configuration: Configuration(values: ["datasource.primary.pool_size": "2"]),
            modules: [InMemoryDataModule<PrimaryDataSource>.self]
        )
        #expect(app.moduleOrder == ["InMemoryDataModule<PrimaryDataSource>"])

        let source = try app.container.resolve(InMemoryDataSource.self, qualifier: "primary")
        #expect(source.poolSize == 2)

        let pool = try #require(app.container.allRegistrations().first {
            $0.typeName.contains("InMemoryDataSource")
        })
        #expect(pool.sourceModule == "InMemoryDataModule<PrimaryDataSource>")

        let status = try #require(app.container.moduleStatuses().first)
        guard case .running = status.health else {
            Issue.record("expected .running, got \(status.health)")
            return
        }
    }

    @Test("bad datasource config fails at bootstrap, not at first query")
    func configFailureAtBootstrap() {
        do {
            _ = try Flight.assemble(
                configuration: Configuration(values: ["datasource.primary.pool_size": "0"]),
                modules: [InMemoryDataModule<PrimaryDataSource>.self]
            )
            Issue.record("expected singletonConstructionFailed")
        } catch let error as BootstrapError {
            guard case .singletonConstructionFailed(let underlying) = error else {
                Issue.record("expected singletonConstructionFailed, got \(error)")
                return
            }
            #expect(underlying as? DataSourceConfigurationError
                == .invalidPoolSize(datasource: "primary", value: 0))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("one module type, instantiated per named datasource")
    func modulePerNamedDataSource() throws {
        let app = try Flight.assemble(
            configuration: Configuration(values: [
                "datasource.primary.pool_size": "2",
                "datasource.analytics.pool_size": "3",
            ]),
            modules: [
                InMemoryDataModule<PrimaryDataSource>.self,
                InMemoryDataModule<Analytics>.self,
            ]
        )
        #expect(app.moduleOrder == [
            "InMemoryDataModule<PrimaryDataSource>",
            "InMemoryDataModule<Analytics>",
        ])
        let primary = try app.container.resolve(InMemoryDataSource.self, qualifier: "primary")
        let analytics = try app.container.resolve(InMemoryDataSource.self, qualifier: "analytics")
        #expect(primary !== analytics)
        #expect((primary.poolSize, analytics.poolSize) == (2, 3))
    }

    @Test("TestContainer honors declared module dependencies")
    func testContainerDependencies() throws {
        // UserRepositoryModule declares InMemoryDataModule<PrimaryDataSource>;
        // listing only the dependent module must still produce a working graph.
        let container = try TestContainer.build { UserRepositoryModule() }
        _ = try container.resolve(InMemoryDataSource.self, qualifier: "primary")
    }

    @Test("a store module's service runs under bootstrap and can wind the pool down")
    func serviceOwningStoreModule() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [InMemoryDataModule<PrimaryDataSource>.self, PoolServiceModule.self]
        )
        let entry = try #require(app.services.first { $0.moduleName == "PoolServiceModule" })
        #expect(entry.completion == .endsApp)

        // Run the (health-wrapped) service directly — deterministic, no
        // ServiceGroup; Core's own suite covers the group mapping.
        try await entry.service.run()

        let source = try app.container.resolve(InMemoryDataSource.self, qualifier: "primary")
        #expect(source.isClosed, "the service closed the pool on completion")
        #expect(source.totalCheckouts == 1, "the service did one unit of pooled work")
        #expect(source.activeCheckouts == 0)
    }

    @Test("a store service failure flips its module to .failed with zero instrumentation")
    func serviceFailureHealth() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [InMemoryDataModule<PrimaryDataSource>.self, FailingPoolServiceModule.self]
        )
        let entry = try #require(app.services.first { $0.moduleName == "FailingPoolServiceModule" })

        await #expect(throws: PoolStartupError.self) {
            try await entry.service.run()
        }

        let status = try #require(app.container.moduleStatuses().first {
            $0.moduleName == "FailingPoolServiceModule"
        })
        guard case .failed = status.health else {
            Issue.record("expected .failed, got \(status.health)")
            return
        }
    }

    @Test("full bootstrap: a one-shot store service ends the app gracefully")
    func fullBootstrap() async throws {
        try await Flight.bootstrap(
            configuration: Configuration(),
            modules: [InMemoryDataModule<PrimaryDataSource>.self, PoolServiceModule.self]
        )
    }
}

// MARK: - Service-owning fixtures

/// The shape: a module whose service does the pool's "long-running" work.
/// Bounded (.endsApp) so tests and bootstrap can run it to completion.
final class PoolServiceModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [InMemoryDataModule<PrimaryDataSource>.self]
    }

    private var container: Container?

    init() {}

    func configure(_ container: Container) throws {
        self.container = container
    }

    var service: (any Service)? {
        container.map(PoolService.init(container:))
    }

    var serviceCompletion: ServiceCompletionPolicy { .endsApp }
}

struct PoolService: Service {
    let container: Container

    func run() async throws {
        // Post-freeze by construction (bootstrap ordering): the pool
        // singleton exists before any service starts.
        let source = try container.resolve(InMemoryDataSource.self, qualifier: "primary")
        try await source.withConnection { $0.perform("startup probe") }
        source.close()
    }
}

struct PoolStartupError: Error {}

final class FailingPoolServiceModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [InMemoryDataModule<PrimaryDataSource>.self]
    }

    private var container: Container?

    init() {}

    func configure(_ container: Container) throws {
        self.container = container
    }

    var service: (any Service)? {
        FailingPoolService()
    }
}

struct FailingPoolService: Service {
    func run() async throws {
        throw PoolStartupError()
    }
}

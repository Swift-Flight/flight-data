import Testing
import FlightCore
import FlightDataCore
import FlightDataTesting

/// The three components `register(dataSource:)` promises (§3, §5), and the
/// qualifier discipline that makes named datasources work (§4).
@Suite("register(dataSource:) (§3–§5)")
struct RegistrationTests {

    @Test("the instance form registers pool, scoped connection, and liveness — all name-qualified")
    func registeredBeans() throws {
        let container = Container()
        container.register(dataSource: InMemoryDataSource(poolSize: 2))
        try container.freeze()

        let descriptors = container.allRegistrations()
        func descriptor(_ typeName: String) -> ComponentDescriptor? {
            descriptors.first { $0.typeName.contains(typeName) }
        }

        let pool = try #require(descriptor("InMemoryDataSource"))
        #expect(pool.scope == .singleton)
        #expect(pool.qualifier == "primary")

        let lease = try #require(descriptor("ScopedConnection"))
        #expect(lease.scope == .scoped)
        #expect(lease.qualifier == "primary")

        let liveness = try #require(descriptor("DataSourceLiveness"))
        #expect(liveness.scope == .singleton)
        #expect(liveness.qualifier == "primary")
    }

    @Test("the pool singleton is the very instance that was registered")
    func poolIdentity() throws {
        let source = InMemoryDataSource(poolSize: 2)
        let container = Container()
        container.register(dataSource: source)
        try container.freeze()
        let resolved = try container.resolve(InMemoryDataSource.self, qualifier: "primary")
        #expect(resolved === source)
    }

    @Test("the factory form defers construction to freeze, where Configuration is readable")
    func factoryFormReadsConfig() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["datasource.primary.pool_size": "7"])
        }
        container.register(dataSource: InMemoryDataSource.self) { c in
            let configuration = try c.resolve(Configuration.self)
            let poolSize = try configuration.getIfPresent(
                DataSourceConfigKey.poolSize(datasource: "primary"), as: Int.self) ?? 4
            return InMemoryDataSource(poolSize: poolSize)
        }
        try container.freeze()
        let source = try container.resolve(InMemoryDataSource.self, qualifier: "primary")
        #expect(source.poolSize == 7)
    }

    @Test("two names of one store type resolve to two independent pools")
    func namedPoolsAreIndependent() throws {
        let container = Container()
        container.register(dataSource: InMemoryDataSource(name: "primary", poolSize: 1))
        container.register(dataSource: InMemoryDataSource(name: "analytics", poolSize: 3), name: "analytics")
        try container.freeze()

        let primary = try container.resolve(InMemoryDataSource.self, qualifier: "primary")
        let analytics = try container.resolve(InMemoryDataSource.self, qualifier: "analytics")
        #expect(primary !== analytics)
        #expect((primary.poolSize, analytics.poolSize) == (1, 3))
    }

    @Test("liveness pings through to the pool (§5)")
    func livenessProbe() async throws {
        struct StoreDown: Error {}
        let source = InMemoryDataSource(poolSize: 1)
        let container = Container()
        container.register(dataSource: source)
        try container.freeze()

        let liveness = try container.resolve(DataSourceLiveness.self, qualifier: "primary")
        try await liveness.ping()

        source.failPings(with: StoreDown())
        await #expect(throws: StoreDown.self) { try await liveness.ping() }
    }

    @Test("DataSourceLiveness.all discovers every datasource, store-unseen (§5)")
    func livenessDiscovery() throws {
        let container = Container()
        container.register(dataSource: InMemoryDataSource(name: "primary", poolSize: 1))
        container.register(dataSource: InMemoryDataSource(name: "analytics", poolSize: 1), name: "analytics")
        try container.freeze()

        let probes = try DataSourceLiveness.all(in: container)
        #expect(probes.map(\.datasourceName).sorted() == ["analytics", "primary"])
    }

    @Test("a container with no datasources has no probes — all(in:) is empty, not an error")
    func livenessEmpty() throws {
        let container = Container()
        try container.freeze()
        #expect(try DataSourceLiveness.all(in: container).isEmpty)
    }
}

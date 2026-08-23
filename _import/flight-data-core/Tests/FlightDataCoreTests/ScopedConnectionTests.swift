import Testing
import FlightCore
import FlightDataCore
import FlightDataTesting

/// — the architecturally significant part of the package: a connection
/// checked out per scope, with neither Flight Core nor the consumer knowing
/// what the scope *means* (request, job, CLI invocation).
@Suite("Scope-bound connections")
struct ScopedConnectionTests {

    private func makeContainer(poolSize: Int = 4) throws -> (Container, InMemoryDataSource) {
        let source = InMemoryDataSource(poolSize: poolSize)
        let container = Container()
        container.register(dataSource: source)
        try container.freeze()
        return (container, source)
    }

    // The canonical scoping test, spelled against the shipped API.
    @Test("a repository uses its scope's connection")
    func repositoryUsesScopedConnection() async throws {
        let container = try TestContainer.build {
            UserRepositoryModule()  // pulls in InMemoryDataModule<PrimaryDataSource> via the DAG
        }

        try await container.withScope { scope in
            let repo = try container.resolve(UserRepository.self, in: scope)
            let a = repo.connection
            let b = try container.resolve(UserRepository.self, in: scope).connection
            #expect(a === b)   // same connection within one scope
        }
    }

    @Test("independent lease resolutions in one scope share one connection")
    func leaseIdentityWithinScope() throws {
        let (container, source) = try makeContainer()
        try container.withScope { scope in
            let a = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            let b = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            #expect(a === b, "scoped component: one lease per scope")
            #expect(a.connection === b.connection)
            #expect(source.totalCheckouts == 1, "second resolution must not check out again")
        }
    }

    @Test("distinct scopes hold distinct connections")
    func isolationAcrossScopes() throws {
        let (container, source) = try makeContainer()
        try container.withScope { outer in
            let a = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: outer)
            try container.withScope { inner in
                let b = try container.resolve(
                    ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: inner)
                #expect(a.connection !== b.connection)
                #expect(source.activeCheckouts == 2, "both scopes hold one connection each")
            }
        }
    }

    @Test("checkout is lazy: no connection leaves the pool until first resolution")
    func lazyCheckout() throws {
        let (container, source) = try makeContainer()
        try container.withScope { scope in
            #expect(source.totalCheckouts == 0, "opening a scope must not touch the pool")
            _ = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            #expect(source.totalCheckouts == 1)
        }
    }

    @Test("scope close returns the connection to the pool")
    func returnOnScopeClose() throws {
        let (container, source) = try makeContainer()
        try container.withScope { scope in
            _ = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            #expect(source.activeCheckouts == 1)
        }
        #expect(source.activeCheckouts == 0, "the scope's connection returns at close")
        #expect(source.availableConnections == 1, "…to the pool, not the floor")
    }

    @Test("the connection returns even when the scope body throws")
    func returnOnThrow() throws {
        struct Boom: Error {}
        let (container, source) = try makeContainer()
        #expect(throws: Boom.self) {
            try container.withScope { scope in
                _ = try container.resolve(
                    ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
                throw Boom()
            }
        }
        #expect(source.activeCheckouts == 0)
    }

    @Test("the next scope reuses the returned connection")
    func reuseAcrossSequentialScopes() throws {
        let (container, source) = try makeContainer()
        var firstID = 0
        try container.withScope { scope in
            firstID = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope
            ).connection.id
        }
        try container.withScope { scope in
            let secondID = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope
            ).connection.id
            #expect(secondID == firstID, "sequential scopes share one physical connection")
        }
        #expect(source.connectionsCreated == 1)
    }

    @Test("resolving the connection without a scope is an error, not a hidden checkout")
    func scopeRequired() throws {
        let (container, _) = try makeContainer()
        #expect(throws: ResolutionError.self) {
            _ = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary")
        }
    }

    @Test("pool exhaustion surfaces as DataSourceError.poolExhausted at resolution")
    func exhaustionSurfaces() throws {
        let (container, _) = try makeContainer(poolSize: 1)
        try container.withScope { holder in
            _ = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: holder)
            try container.withScope { starved in
                #expect(throws: DataSourceError.poolExhausted(datasource: "primary", poolSize: 1)) {
                    _ = try container.resolve(
                        ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: starved)
                }
            }
        }
    }

    @Test("two named datasources coexist in one scope, each with its own connection")
    func namedDataSourcesCoexist() throws {
        let primary = InMemoryDataSource(name: "primary", poolSize: 2)
        let analytics = InMemoryDataSource(name: "analytics", poolSize: 2)
        let container = Container()
        container.register(dataSource: primary)
        container.register(dataSource: analytics, name: "analytics")
        try container.freeze()

        try container.withScope { scope in
            let p = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            let a = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "analytics", in: scope)
            #expect(p.connection !== a.connection)
            #expect(p.connection.datasourceName == "primary")
            #expect(a.connection.datasourceName == "analytics")
            #expect(p.datasourceName == "primary")
            #expect(a.datasourceName == "analytics")
        }
        #expect(primary.activeCheckouts == 0)
        #expect(analytics.activeCheckouts == 0)
    }

    @Test("a scoped repository and a direct lease resolution see the same connection")
    func repositoryAndLeaseAgree() throws {
        let container = try TestContainer.build { UserRepositoryModule() }
        try container.withScope { scope in
            let repo = try container.resolve(UserRepository.self, in: scope)
            let lease = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            #expect(repo.connection === lease.connection)
        }
    }

    @Test("work performed through a repository lands on the scope's one connection")
    func repositoryWorkJournal() throws {
        let container = try TestContainer.build { UserRepositoryModule() }
        try container.withScope { scope in
            let repo = try container.resolve(UserRepository.self, in: scope)
            repo.save("ada")
            repo.save("grace")
            #expect(repo.connection.journal == ["INSERT ada", "INSERT grace"])
        }
    }

    @Test("concurrent scopes on distinct tasks stay isolated")
    func concurrentScopes() async throws {
        let (container, source) = try makeContainer(poolSize: 8)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await container.withScope { scope in
                        let lease = try container.resolve(
                            ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
                        await Task.yield()
                        // Identity is stable across the whole scope body.
                        let again = try container.resolve(
                            ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
                        #expect(lease === again)
                        return lease.connection.id
                    }
                }
            }
            var ids: [Int] = []
            for try await id in group { ids.append(id) }
            #expect(ids.count == 8)
        }
        #expect(source.activeCheckouts == 0, "every scope returned its connection")
    }
}

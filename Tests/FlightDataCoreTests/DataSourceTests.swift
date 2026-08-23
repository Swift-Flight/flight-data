import Testing
import FlightCore
import FlightDataCore
import FlightDataTesting

/// — the cross-store contract, exercised through its default
/// `withConnection` implementation and the InMemory conformance.
@Suite("DataSource contract")
struct DataSourceContractTests {

    @Test("withConnection checks out for the body and returns the pool afterward")
    func withConnectionRoundTrip() async throws {
        let source = InMemoryDataSource(poolSize: 2)
        let result = try await source.withConnection { connection in
            connection.perform("SELECT 1")
            return connection.id
        }
        #expect(result == 1)
        #expect(source.activeCheckouts == 0)
        #expect(source.availableConnections == 1)
    }

    @Test("withConnection returns the connection to the pool on throw")
    func withConnectionThrow() async throws {
        struct Boom: Error {}
        let source = InMemoryDataSource(poolSize: 2)
        await #expect(throws: Boom.self) {
            try await source.withConnection { _ -> Void in throw Boom() }
        }
        #expect(source.activeCheckouts == 0)
        #expect(source.availableConnections == 1)
    }

    @Test("nested withConnection uses two distinct connections")
    func nestedWithConnection() async throws {
        let source = InMemoryDataSource(poolSize: 2)
        try await source.withConnection { outer in
            try await source.withConnection { inner in
                #expect(outer !== inner)
            }
        }
        #expect(source.activeCheckouts == 0)
    }

    @Test("checkout beyond pool_size throws poolExhausted, not a new connection")
    func exhaustion() throws {
        let source = InMemoryDataSource(name: "primary", poolSize: 2)
        let a = try source.checkout()
        let b = try source.checkout()
        #expect(throws: DataSourceError.poolExhausted(datasource: "primary", poolSize: 2)) {
            _ = try source.checkout()
        }
        source.release(a)
        source.release(b)
    }

    @Test("concurrent pooled work up to pool_size never exhausts and always returns")
    func concurrencySmoke() async throws {
        let source = InMemoryDataSource(poolSize: 4)
        let iterations = 50
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<iterations {
                        try await source.withConnection { connection in
                            connection.perform("work")
                            await Task.yield()
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(source.activeCheckouts == 0)
        #expect(source.totalCheckouts == 4 * iterations)
        #expect(source.connectionsCreated <= 4)
    }
}

/// — the test double's own semantics, since every store-agnostic test in
/// the Flight family will lean on them.
@Suite("InMemoryDataSource")
struct InMemoryDataSourceTests {

    @Test("connections are created lazily, with stable sequential ids")
    func lazyCreation() throws {
        let source = InMemoryDataSource(poolSize: 3)
        #expect(source.connectionsCreated == 0)
        let a = try source.checkout()
        let b = try source.checkout()
        #expect((a.id, b.id) == (1, 2))
        #expect(source.connectionsCreated == 2)
        source.release(a)
        source.release(b)
    }

    @Test("released connections are reused before new ones are created")
    func reuse() throws {
        let source = InMemoryDataSource(poolSize: 3)
        let first = try source.checkout()
        source.release(first)
        let second = try source.checkout()
        #expect(second === first)
        #expect(source.connectionsCreated == 1)
        source.release(second)
    }

    @Test("settings-based construction honors name and pool size")
    func fromSettings() throws {
        let settings = try DataSourceSettings(name: "analytics", url: "memory://", poolSize: 2)
        let source = InMemoryDataSource(settings: settings)
        #expect(source.name == "analytics")
        #expect(source.poolSize == 2)
    }

    @Test("close(): checkout refuses, in-flight connections drop on return")
    func closeSemantics() throws {
        let source = InMemoryDataSource(name: "primary", poolSize: 2)
        let inFlight = try source.checkout()
        source.close()
        #expect(source.isClosed)
        #expect(throws: DataSourceError.closed(datasource: "primary")) {
            _ = try source.checkout()
        }
        source.release(inFlight)
        #expect(source.activeCheckouts == 0)
        #expect(source.availableConnections == 0, "a closed pool drops returned connections")
    }

    @Test("ping: healthy by default, controllable, and closed-aware")
    func pingBehavior() async throws {
        struct StoreDown: Error {}
        let source = InMemoryDataSource(name: "primary", poolSize: 1)
        try await source.ping()

        source.failPings(with: StoreDown())
        await #expect(throws: StoreDown.self) { try await source.ping() }

        source.restorePings()
        try await source.ping()

        source.close()
        await #expect(throws: DataSourceError.closed(datasource: "primary")) {
            try await source.ping()
        }
    }

    @Test("a connection's journal survives release and reuse")
    func journalAcrossReuse() throws {
        let source = InMemoryDataSource(poolSize: 1)
        let first = try source.checkout()
        first.perform("one")
        source.release(first)
        let second = try source.checkout()
        second.perform("two")
        #expect(second.journal == ["one", "two"])
        source.release(second)
    }

    @Test("error descriptions name the datasource and the fix")
    func errorDescriptions() {
        let exhausted = DataSourceError.poolExhausted(datasource: "primary", poolSize: 2)
        #expect(exhausted.description.contains("datasource.primary.pool_size"))
        let closed = DataSourceError.closed(datasource: "analytics")
        #expect(closed.description.contains("analytics"))
    }
}

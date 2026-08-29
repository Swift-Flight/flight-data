import FlightDataCore
import FlightDataTesting
import Testing

/// The reference driver runs the same conformance suite the real drivers do.
///
/// If `InMemoryDataSource` can drift from the contract, so can anything a
/// user writes against it — and the in-memory source is what
/// `InMemoryDataModule` substitutes into tests, so a divergence here makes
/// every downstream test lie about production behaviour.
@Suite("DataSource conformance — InMemoryDataSource")
struct InMemoryConformanceTests {

    @Test("the reference driver satisfies the DataSource contract")
    func conforms() async throws {
        try await DataSourceConformance.verify(
            make: { InMemoryDataSource(poolSize: 4) },
            shutdown: { $0.close() })
    }
}

/// The store-agnostic half of `PendingConnections`, which shipped with its
/// only coverage in a suite that needs a live Postgres — so on a machine
/// without one, every documented property of the offer went unchecked.
@Suite("Offered connections")
struct PendingConnectionsTests {

    @Test("the scoped factory takes the offered connection instead of checking out")
    func offerIsTaken() async throws {
        let source = InMemoryDataSource(poolSize: 4)
        let connection = try source.checkout()
        let before = source.totalCheckouts

        try await PendingConnections.offering(
            source.name, connection: connection, returning: source.release
        ) {
            let taken: InMemoryConnection? = PendingConnections.take(datasource: source.name)
            #expect(taken === connection)
        }
        #expect(source.totalCheckouts == before, "taking an offer must not check anything out")
        #expect(source.activeCheckouts == 1, "the taker owns it now")
        source.release(connection)
    }

    @Test("an offer is one-shot: a second scope gets its own connection")
    func offerIsTakenExactlyOnce() async throws {
        let source = InMemoryDataSource(poolSize: 4)
        let connection = try source.checkout()

        try await PendingConnections.offering(
            source.name, connection: connection, returning: source.release
        ) {
            let first: InMemoryConnection? = PendingConnections.take(datasource: source.name)
            let second: InMemoryConnection? = PendingConnections.take(datasource: source.name)
            #expect(first === connection)
            #expect(second == nil, "a nested scope must check out its own, not alias this one")
        }
        source.release(connection)
    }

    @Test("a wrong-typed taker leaves the offer intact")
    func typeMismatchLeavesTheOffer() async throws {
        let source = InMemoryDataSource(poolSize: 4)
        let connection = try source.checkout()

        try await PendingConnections.offering(
            source.name, connection: connection, returning: source.release
        ) {
            // Degrading a mistyped take to a plain checkout is the point: the
            // alternative is destroying an offer the right taker still needs.
            let wrong: String? = PendingConnections.take(datasource: source.name)
            #expect(wrong == nil)
            let right: InMemoryConnection? = PendingConnections.take(datasource: source.name)
            #expect(right === connection)
        }
        source.release(connection)
    }

    @Test("an offer nobody claimed is returned rather than leaked")
    func unclaimedOfferIsReturned() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let connection = try source.checkout()

        try await PendingConnections.offering(
            source.name, connection: connection, returning: source.release
        ) {
            // A unit of work that touches no repository.
        }
        #expect(source.activeCheckouts == 0, "the one connection would be leaked forever")
    }

    @Test("an offer nobody claimed is returned even when the body throws")
    func unclaimedOfferIsReturnedOnThrow() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let connection = try source.checkout()

        await #expect(throws: OfferProbeError.self) {
            try await PendingConnections.offering(
                source.name, connection: connection, returning: source.release
            ) {
                throw OfferProbeError()
            }
        }
        #expect(source.activeCheckouts == 0, "a failed request must not cost a connection")
    }

    @Test("a nested offer on another datasource does not erase the outer one")
    func nestedOffersMerge() async throws {
        let outer = InMemoryDataSource(name: "primary", poolSize: 1)
        let inner = InMemoryDataSource(name: "analytics", poolSize: 1)
        let outerConnection = try outer.checkout()
        let innerConnection = try inner.checkout()

        try await PendingConnections.offering(
            outer.name, connection: outerConnection, returning: outer.release
        ) {
            try await PendingConnections.offering(
                inner.name, connection: innerConnection, returning: inner.release
            ) {
                // Binding by replacing the dictionary — what the call site used
                // to do — erased the outer offer here, and the outer scope's
                // synchronous factory then failed on an exhausted pool while
                // its own connection sat reserved for it.
                let outerOffer: InMemoryConnection? =
                    PendingConnections.take(datasource: outer.name)
                let innerOffer: InMemoryConnection? =
                    PendingConnections.take(datasource: inner.name)
                #expect(outerOffer === outerConnection)
                #expect(innerOffer === innerConnection)
            }
        }
        outer.release(outerConnection)
        inner.release(innerConnection)
    }

    @Test("offers do not leak between sibling tasks")
    func offersAreTaskLocal() async throws {
        let source = InMemoryDataSource(poolSize: 2)
        let connection = try source.checkout()

        try await PendingConnections.offering(
            source.name, connection: connection, returning: source.release
        ) {
            let escaped = await Task.detached {
                let taken: InMemoryConnection? = PendingConnections.take(datasource: source.name)
                return taken
            }.value
            #expect(escaped == nil, "one request must never see another's offer")
            let taken: InMemoryConnection? = PendingConnections.take(datasource: source.name)
            #expect(taken === connection)
        }
        source.release(connection)
    }
}

struct OfferProbeError: Error {}

/// A pool at capacity is a queue, not a wall — against the reference driver,
/// so the property is checked on every machine rather than only where a live
/// database happens to be configured.
@Suite("Queueing for a connection")
struct QueueingTests {

    @Test("the waiting checkout is served by a release")
    func waitsForARelease() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()

        async let queued = source.checkout(waitingUpTo: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.waitingCallers.now == 1, "the caller should be parked, not spinning")
        source.release(held)

        let served = try await queued
        source.release(served)
        #expect(source.waitingCallers.now == 0, "a served waiter must not stay on the books")
    }

    @Test("waiting gives up at its deadline")
    func timesOut() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()
        defer { source.release(held) }

        let started = ContinuousClock.now
        await #expect(throws: DataSourceError.self) {
            _ = try await source.checkout(waitingUpTo: .milliseconds(200))
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(5))
        #expect(source.waitingCallers.now == 0, "a timed-out waiter must clean itself up")
    }

    @Test("every caller past the ceiling is eventually served")
    func everyWaiterIsServed() async throws {
        let source = InMemoryDataSource(poolSize: 2)
        let served = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    guard let connection = try? await source.checkout(waitingUpTo: .seconds(10))
                    else { return false }
                    try? await Task.sleep(for: .milliseconds(5))
                    source.release(connection)
                    return true
                }
            }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }
        #expect(served == 10, "the (pool_size + 1)th caller must queue, not fail")
    }

    @Test("a cancelled waiter gives up at once rather than spinning out its timeout")
    func cancellationIsPrompt() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()
        defer { source.release(held) }

        let task = Task {
            try await source.checkout(waitingUpTo: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        // Without a cancellation check the loop re-registers a waiter at full
        // speed for the remaining thirty seconds, burning a core for an answer
        // nobody is waiting for.
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("a closed pool refuses immediately instead of queueing")
    func closedPoolDoesNotQueue() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        source.close()

        let started = ContinuousClock.now
        await #expect(throws: DataSourceError.self) {
            _ = try await source.checkout(waitingUpTo: .seconds(30))
        }
        #expect(started.duration(to: .now) < .seconds(1), "waiting cannot fix a closed pool")
    }

    @Test("withConnection queues rather than failing at capacity")
    func withConnectionQueues() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()

        async let work: Void = source.withConnection { connection in
            connection.perform("queued")
        }
        try await Task.sleep(for: .milliseconds(50))
        source.release(held)
        try await work

        #expect(source.activeCheckouts == 0)
    }
}

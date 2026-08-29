import FlightCore
import Foundation
import Testing

import FlightCacheTesting

@testable import FlightCache

/// Every interleaving here is established by an explicit signal — a `Gate`
/// to hold the leader inside its body, and `SingleFlight.waitUntilCoalescing`
/// to know waiters have actually parked. No test sleeps to "let" something
/// happen: a sleep would be a guess about scheduling that races on a loaded
/// machine and silently stops testing the intended ordering.
@Suite("Single-flight — stampede protection")
struct SingleFlightTests {

    private let key = CacheKey(namespace: "prices", parts: ["hot"])

    private func runtime(_ store: RecordingCache = RecordingCache()) throws -> CacheRuntime {
        try CacheRuntime(store: store, configuration: Configuration())
    }

    @Test("concurrent same-key misses coalesce into one execution")
    func coalescing() async throws {
        let runtime = try runtime()
        let executions = Counter()
        let leaderInBody = Gate()
        let release = Gate()

        let body: @Sendable () async throws -> Int = {
            executions.increment()
            await leaderInBody.open()
            try await release.wait()
            return 42
        }

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
            }
            // The leader is now definitively inside its body, so the flight
            // exists and everyone after this coalesces onto it.
            try await leaderInBody.wait()

            for _ in 0..<19 {
                group.addTask {
                    try await runtime.cacheable(
                        namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
                }
            }
            // All 19 have parked — only now can releasing the leader prove
            // they were served from its single execution.
            await runtime.flights.waitUntilCoalescing(19, on: key)
            await release.open()

            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(values.count == 20)
        #expect(values.allSatisfy { $0 == 42 })
        #expect(executions.value == 1)
        #expect(await runtime.flights.inFlightCount == 0)
    }

    @Test("different keys do not coalesce")
    func distinctKeysRunIndependently() async throws {
        let runtime = try runtime()
        let executions = Counter()

        _ = try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 0..<5 {
                group.addTask {
                    try await runtime.cacheable(
                        namespace: "prices", parts: ["\(id)"], ttl: nil, as: Int.self
                    ) {
                        executions.increment()
                        return id
                    }
                }
            }
            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }
        #expect(executions.value == 5)
    }

    @Test("a leader error propagates to every waiter — no re-stampede")
    func leaderErrorShared() async throws {
        struct Boom: Error {}
        let runtime = try runtime()
        let executions = Counter()
        let leaderInBody = Gate()
        let release = Gate()

        let body: @Sendable () async throws -> Int = {
            executions.increment()
            await leaderInBody.open()
            try await release.wait()
            throw Boom()
        }

        let failures = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.didFail(runtime, body)
            }
            try? await leaderInBody.wait()

            for _ in 0..<9 {
                group.addTask { await self.didFail(runtime, body) }
            }
            await runtime.flights.waitUntilCoalescing(9, on: key)
            await release.open()

            var failed = 0
            for await didFail in group where didFail { failed += 1 }
            return failed
        }

        #expect(failures == 10)
        #expect(executions.value == 1, "waiters must not re-run a computation that just failed")
        #expect(await runtime.flights.inFlightCount == 0)
    }

    @Test("a cancelled leader does not fail its waiters — one takes over")
    func leaderCancellationHandsOver() async throws {
        let runtime = try runtime()
        let executions = Counter()
        let leaderInBody = Gate()

        // The leader parks in the gate and is cancelled there; the waiter's
        // own execution is never gated, so it can complete on its own.
        let body: @Sendable () async throws -> Int = {
            let attempt = executions.incrementAndGet()
            if attempt == 1 {
                await leaderInBody.open()
                try await Task.sleep(for: .seconds(3600))  // cancelled, never elapses
            }
            return 42
        }

        let leader = Task {
            try await runtime.cacheable(
                namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
        }
        try await leaderInBody.wait()

        let waiter = Task {
            try await runtime.cacheable(
                namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
        }
        // The waiter is parked on the leader's flight — so cancelling the
        // leader now exercises the handover path, not "waiter becomes
        // leader because it arrived after the flight cleared".
        await runtime.flights.waitUntilCoalescing(1, on: key)

        leader.cancel()

        #expect(try await waiter.value == 42)
        await #expect(throws: (any Error).self) { _ = try await leader.value }
        #expect(executions.value == 2, "the waiter should have taken over, not inherited the error")
        #expect(await runtime.flights.inFlightCount == 0)
    }

    private func didFail(
        _ runtime: CacheRuntime, _ body: @escaping @Sendable () async throws -> Int
    ) async -> Bool {
        do {
            _ = try await runtime.cacheable(
                namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
            return false
        } catch {
            return true
        }
    }

    // MARK: - The waiter arms nothing used to reach

    @Test("a leader whose value cannot be encoded leaves waiters to compute")
    func unpublishableLeaderReleasesWaiters() async throws {
        // `.unpublishable` — the leader produced a value, it was not nil, and
        // it could not be encoded. There is nothing to hand a waiter, so each
        // must run the body itself rather than hang or inherit a failure.
        let runtime = try runtime()
        let executions = Counter()
        let leaderInBody = Gate()
        let release = Gate()

        let body: @Sendable () async throws -> Unencodable = {
            executions.increment()
            if executions.value == 1 {
                await leaderInBody.open()
                try await release.wait()
            }
            return Unencodable()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: Unencodable.self, body)
            }
            try await leaderInBody.wait()
            group.addTask {
                _ = try await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: Unencodable.self, body)
            }
            await runtime.flights.waitUntilCoalescing(1, on: key)
            await release.open()
            for try await _ in group {}
        }

        #expect(executions.value == 2, "the waiter had nothing to decode, so it must compute")
        #expect(await runtime.flights.inFlightCount == 0)
    }

    @Test("a waiter whose type cannot decode the leader's bytes computes its own")
    func typeCollisionWaiterComputes() async throws {
        // Two methods sharing a key with different value types — legal,
        // because a key is namespace + arguments and deliberately not the
        // method name. The waiter must not re-join the flight it cannot use,
        // which would loop on the same bytes forever.
        let runtime = try runtime()
        let executions = Counter()
        let leaderInBody = Gate()
        let release = Gate()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self
                ) {
                    await leaderInBody.open()
                    try await release.wait()
                    return 42
                }
            }
            try await leaderInBody.wait()
            group.addTask {
                let value = try await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: [String].self
                ) {
                    executions.increment()
                    return ["computed"]
                }
                #expect(value == ["computed"])
            }
            await runtime.flights.waitUntilCoalescing(1, on: key)
            await release.open()
            for try await _ in group {}
        }

        #expect(executions.value == 1, "the mistyped waiter must compute exactly once")
        #expect(await runtime.flights.inFlightCount == 0)
    }

    @Test("the non-throwing overload's waiter is served the leader's bytes")
    func nonThrowingWaiterArm() async throws {
        let runtime = try runtime()
        let executions = Counter()
        let leaderInBody = Gate()
        let release = Gate()

        let body: @Sendable () async -> Int = {
            executions.increment()
            await leaderInBody.open()
            try? await release.wait()
            return 7
        }

        let values = await withTaskGroup(of: Int.self) { group in
            group.addTask {
                await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
            }
            try? await leaderInBody.wait()
            group.addTask {
                await runtime.cacheable(
                    namespace: "prices", parts: ["hot"], ttl: nil, as: Int.self, body)
            }
            await runtime.flights.waitUntilCoalescing(1, on: key)
            await release.open()
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }

        #expect(values == [7, 7])
        #expect(executions.value == 1, "the non-throwing waiter must coalesce too")
    }

    @Test("a cancelled leader hands leadership to its waiter rather than failing it")
    func cancelledLeaderHandsOver() async throws {
        // Cancellation is not a cache failure. A waiter whose leader was
        // cancelled re-enters the flow — becoming the leader itself — rather
        // than inheriting a `CancellationError` it never asked for, and the
        // retry is bounded so repeated cancellations cannot livelock it.
        let runtime = try runtime()
        let computed = Counter()
        let leaderInBody = Gate()
        let neverOpens = Gate()

        let leader = Task {
            try await runtime.cacheable(
                namespace: "prices", parts: ["cold"], ttl: nil, as: Int.self
            ) {
                computed.increment()
                await leaderInBody.open()
                try await neverOpens.wait()
                return -1
            }
        }
        try await leaderInBody.wait()

        let waiter = Task {
            try await runtime.cacheable(
                namespace: "prices", parts: ["cold"], ttl: nil, as: Int.self
            ) {
                computed.increment()
                return 5
            }
        }
        await runtime.flights.waitUntilCoalescing(
            1, on: CacheKey(namespace: "prices", parts: ["cold"]))

        leader.cancel()
        _ = try? await leader.value

        #expect(try await waiter.value == 5, "the waiter must get an answer, not the cancellation")
        #expect(computed.value == 2, "the leader ran, was cancelled, and the waiter took over")
        #expect(await runtime.flights.inFlightCount == 0)
    }
}

/// Encodes to nothing an encoder will accept — for the `.unpublishable` arm.
/// A `Double.nan` is not representable in JSON, so `JSONEncoder` throws.
struct Unencodable: Codable, Sendable, Equatable {
    var value: Double = .nan

    static func == (lhs: Unencodable, rhs: Unencodable) -> Bool { true }
}

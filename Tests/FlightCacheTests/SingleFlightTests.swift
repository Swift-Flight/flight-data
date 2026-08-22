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
@Suite("Single-flight — §8 stampede protection")
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

    @Test("a leader error propagates to every waiter — no re-stampede (§8)")
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

    @Test("a cancelled leader does not fail its waiters — one takes over (§8)")
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
}

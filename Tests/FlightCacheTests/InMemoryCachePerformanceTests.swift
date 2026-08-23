import FlightCache
import Foundation
import Testing

/// The default store's cost per write, below and at its own default bound.
///
/// `enforceBound` used to scan every entry looking for expired ones on every
/// single `set` once the cache was full — an O(n) sweep at n = 10,000, the
/// package's own default. Measured at 465µs per write against 1.9µs below the
/// bound: a 244x cliff, reached by any cache that actually fills up, which is
/// what a bounded cache is for. Raising `max_entries` made it worse.
@Suite("InMemoryCache write cost")
struct InMemoryCachePerformanceTests {

    private func timeWrites(into cache: InMemoryCache, count: Int, from offset: Int) async
        -> Duration
    {
        let payload = Data(repeating: 0x41, count: 64)
        let clock = ContinuousClock()
        return await clock.measure {
            for i in 0..<count {
                await cache.set(
                    CacheKey(namespace: "bench", parts: ["\(offset + i)"]),
                    value: payload, ttl: .seconds(600))
            }
        }
    }

    @Test("a write at the bound costs about what a write below it costs")
    func writeCostDoesNotCliffAtTheBound() async throws {
        let bound = 2_000
        let cache = InMemoryCache(maxEntries: bound)

        // Fill to just under the bound, timing the last stretch as the baseline.
        _ = await timeWrites(into: cache, count: bound - 500, from: 0)
        let below = await timeWrites(into: cache, count: 500, from: bound - 500)

        // Now every write evicts.
        let at = await timeWrites(into: cache, count: 500, from: bound)

        let ratio = Double(at.components.attoseconds) / Double(max(below.components.attoseconds, 1))
        #expect(
            ratio < 10,
            """
            writes at the bound are \(String(format: "%.1f", ratio))x the cost of writes below it \
            (below: \(below), at: \(at)). The bound is where a bounded cache spends its life; \
            a cliff here is the whole cache getting slower exactly when it starts working.
            """)
    }

    @Test("the bound is actually enforced")
    func boundHolds() async throws {
        let cache = InMemoryCache(maxEntries: 100)
        _ = await timeWrites(into: cache, count: 500, from: 0)
        #expect(await cache.count == 100)
    }
}

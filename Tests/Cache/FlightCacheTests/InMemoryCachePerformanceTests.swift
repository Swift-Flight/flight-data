import FlightCache
import Foundation
import Testing

/// The default store's cost per operation at its own default bound.
///
/// Two cliffs have lived here. `enforceBound` used to scan every entry looking
/// for expired ones on every single `set` once the cache was full — an O(n)
/// sweep at n = 10,000, the package's own default; measured at 465µs per write
/// against 1.9µs below the bound.
///
/// And the recency order was an `OrderedDictionary`, refreshed by remove and
/// reinsert. That stores keys and values in dense arrays, so every **hit** at
/// the bound shifted ~10,000 elements twice — under a comment claiming O(1).
/// This suite could not see it, because it measured fresh-key writes at a bound
/// of 2,000 and never measured a hit at all, which is the operation a cache
/// performs most. Hence `hitCostDoesNotGrowWithTheBound` below.
@Suite("InMemoryCache operation cost")
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

    private func timeHits(in cache: InMemoryCache, count: Int, spread: Int) async -> Duration {
        let clock = ContinuousClock()
        return await clock.measure {
            for i in 0..<count {
                // Read across the whole cache, not one key: a hit's cost is in
                // moving that entry to the recent end, and the entry furthest
                // from it is the expensive one.
                _ = await cache.get(CacheKey(namespace: "bench", parts: ["\(i % spread)"]))
            }
        }
    }

    @Test("a hit costs the same at 10,000 entries as at 500")
    func hitCostDoesNotGrowWithTheBound() async throws {
        let small = InMemoryCache(maxEntries: 500)
        _ = await timeWrites(into: small, count: 500, from: 0)
        _ = await timeHits(in: small, count: 2_000, spread: 500)  // warm up
        let atFiveHundred = await timeHits(in: small, count: 5_000, spread: 500)

        // The package's own default bound — the size a real deployment runs.
        let large = InMemoryCache(maxEntries: 10_000)
        _ = await timeWrites(into: large, count: 10_000, from: 0)
        _ = await timeHits(in: large, count: 2_000, spread: 10_000)
        let atTenThousand = await timeHits(in: large, count: 5_000, spread: 10_000)

        let ratio =
            Double(atTenThousand.components.attoseconds)
            / Double(max(atFiveHundred.components.attoseconds, 1))
        #expect(
            ratio < 5,
            """
            hits at a 10,000-entry bound are \(String(format: "%.1f", ratio))x the cost of hits at \
            500 (500: \(atFiveHundred), 10,000: \(atTenThousand)). A hit must not get more \
            expensive as the cache gets bigger — that is the one operation a cache does on \
            every request.
            """)
    }

    @Test("the bound is actually enforced")
    func boundHolds() async throws {
        let cache = InMemoryCache(maxEntries: 100)
        _ = await timeWrites(into: cache, count: 500, from: 0)
        #expect(await cache.count == 100)
    }

    @Test("eviction takes the least recently used, not the least recently written")
    func evictionFollowsReads() async throws {
        let cache = InMemoryCache(maxEntries: 3)
        let payload = Data("x".utf8)
        for name in ["a", "b", "c"] {
            await cache.set(CacheKey(namespace: "lru", parts: [name]), value: payload, ttl: nil)
        }

        // Reading "a" makes it the most recent, so "b" is now the oldest.
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["a"])) != nil)
        await cache.set(CacheKey(namespace: "lru", parts: ["d"]), value: payload, ttl: nil)

        #expect(await cache.count == 3)
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["a"])) != nil, "just read")
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["b"])) == nil, "the oldest goes")
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["c"])) != nil)
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["d"])) != nil, "just written")
    }

    @Test("overwriting an existing key refreshes its recency without growing the cache")
    func overwriteIsAlsoATouch() async throws {
        let cache = InMemoryCache(maxEntries: 3)
        let payload = Data("x".utf8)
        for name in ["a", "b", "c"] {
            await cache.set(CacheKey(namespace: "lru", parts: [name]), value: payload, ttl: nil)
        }
        await cache.set(
            CacheKey(namespace: "lru", parts: ["a"]), value: Data("y".utf8), ttl: nil)
        #expect(await cache.count == 3, "an overwrite is not a new entry")

        await cache.set(CacheKey(namespace: "lru", parts: ["d"]), value: payload, ttl: nil)
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["a"])) == Data("y".utf8))
        #expect(await cache.get(CacheKey(namespace: "lru", parts: ["b"])) == nil)
    }
}

import Foundation
import Testing

@testable import FlightCache

@Suite("InMemoryCache — bounded LRU with TTL")
struct InMemoryCacheTests {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test("set/get round-trip; absent key misses")
    func roundTrip() async {
        let cache = InMemoryCache()
        let key = CacheKey(namespace: "ns", parts: ["a"])
        #expect(await cache.get(key) == nil)
        await cache.set(key, value: data("v"), ttl: nil)
        #expect(await cache.get(key) == data("v"))
    }

    @Test("an expired entry is a miss and is dropped on touch")
    func expiry() async throws {
        let cache = InMemoryCache()
        let key = CacheKey(namespace: "ns", parts: ["a"])
        await cache.set(key, value: data("v"), ttl: .milliseconds(20))
        #expect(await cache.get(key) == data("v"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(await cache.get(key) == nil)
        #expect(await cache.count == 0)
    }

    @Test("the LRU bound holds, and get refreshes recency")
    func lruBound() async {
        let cache = InMemoryCache(maxEntries: 3)
        let keys = (0..<4).map { CacheKey(namespace: "ns", parts: ["\($0)"]) }
        for key in keys.prefix(3) {
            await cache.set(key, value: data(key.storageKey), ttl: nil)
        }
        // Touch key 0 so key 1 is now the least recently used.
        _ = await cache.get(keys[0])
        await cache.set(keys[3], value: data("3"), ttl: nil)
        #expect(await cache.count == 3)
        #expect(await cache.get(keys[1]) == nil)  // evicted
        #expect(await cache.get(keys[0]) != nil)  // survived: recently used
    }

    @Test("expired entries are swept before live ones are LRU-evicted")
    func expiredSweptFirst() async throws {
        let cache = InMemoryCache(maxEntries: 2)
        let doomed = CacheKey(namespace: "ns", parts: ["doomed"])
        let live = CacheKey(namespace: "ns", parts: ["live"])
        let incoming = CacheKey(namespace: "ns", parts: ["incoming"])
        await cache.set(doomed, value: data("d"), ttl: .milliseconds(10))
        await cache.set(live, value: data("l"), ttl: nil)
        try await Task.sleep(for: .milliseconds(40))
        await cache.set(incoming, value: data("i"), ttl: nil)
        #expect(await cache.get(live) != nil)
        #expect(await cache.get(incoming) != nil)
        #expect(await cache.get(doomed) == nil)
    }

    @Test("evict removes one entry; evictNamespace removes only its namespace")
    func eviction() async {
        let cache = InMemoryCache()
        let a1 = CacheKey(namespace: "a", parts: ["1"])
        let a2 = CacheKey(namespace: "a", parts: ["2"])
        let b1 = CacheKey(namespace: "b", parts: ["1"])
        for key in [a1, a2, b1] {
            await cache.set(key, value: data(key.storageKey), ttl: nil)
        }
        await cache.evict(a1)
        #expect(await cache.get(a1) == nil)
        #expect(await cache.get(a2) != nil)
        await cache.evictNamespace("a")
        #expect(await cache.get(a2) == nil)
        #expect(await cache.get(b1) != nil)
    }
}

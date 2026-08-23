import FlightCore
import Synchronization
import Testing

import FlightCache
import FlightCacheTesting

/// The real macro path: annotated methods on a real class, expanded by the
/// real compiler plugin, running against a runtime bound through the
/// task-local override — the claims proven end to end, including the
/// one Spring cannot make: self-invocation caches.
@Suite("End-to-end — real @Cacheable/@CachePut/@CacheEvict expansion")
struct EndToEndMacroTests {

    final class PricingService: Sendable {
        let executions = Mutex(0)

        @Cacheable(namespace: "e2e_prices", ttl: .seconds(60))
        func price(for productID: Int, in region: String) async throws -> Int {
            executions.withLock { $0 += 1 }
            return productID * 100
        }

        /// self-invocation case: an internal call to a @Cacheable
        /// method on self. No proxy, so nothing to bypass.
        func priceViaInternalCall(productID: Int, region: String) async throws -> Int {
            try await price(for: productID, in: region)
        }

        @CachePut(namespace: "e2e_prices", excluding: ["price"])
        func overridePrice(for productID: Int, in region: String, to price: Int) async -> Int {
            price
        }

        @CacheEvict(namespace: "e2e_prices")
        func remove(productID: Int, region: String) async {
        }

        @CacheEvict(namespace: "e2e_prices", allEntries: true)
        func removeAll() async {
        }

        @Cacheable(namespace: "e2e_prices")
        func nonThrowingPrice(productID: Int, region: String) async -> Int {
            executions.withLock { $0 += 1 }
            return productID * 100
        }
    }

    private func withRuntime<T>(
        _ body: (PricingService, RecordingCache) async throws -> T
    ) async throws -> T {
        let store = RecordingCache()
        let runtime = try CacheRuntime(store: store, configuration: Configuration())
        return try await FlightCaches.$override.withValue(runtime) {
            try await body(PricingService(), store)
        }
    }

    @Test("@Cacheable: second call is served from cache")
    func cacheableHit() async throws {
        try await withRuntime { service, _ in
            let first = try await service.price(for: 7, in: "eu")
            let second = try await service.price(for: 7, in: "eu")
            #expect(first == 700 && second == 700)
            #expect(service.executions.withLock { $0 } == 1)
            // A different key computes again.
            _ = try await service.price(for: 7, in: "us")
            #expect(service.executions.withLock { $0 } == 2)
        }
    }

    @Test("self-invocation caches — the Spring footgun that cannot occur")
    func selfInvocationCaches() async throws {
        try await withRuntime { service, _ in
            _ = try await service.priceViaInternalCall(productID: 7, region: "eu")
            _ = try await service.priceViaInternalCall(productID: 7, region: "eu")
            _ = try await service.price(for: 7, in: "eu")
            #expect(service.executions.withLock { $0 } == 1)
        }
    }

    @Test("@CachePut overwrites the entry @Cacheable reads (same key contract)")
    func putTargetsCacheableEntry() async throws {
        try await withRuntime { service, _ in
            _ = try await service.price(for: 7, in: "eu")
            let overridden = await service.overridePrice(for: 7, in: "eu", to: 999)
            #expect(overridden == 999)
            let served = try await service.price(for: 7, in: "eu")
            #expect(served == 999)
            #expect(service.executions.withLock { $0 } == 1)
        }
    }

    @Test("@CacheEvict removes the keyed entry; allEntries wipes the namespace")
    func evictTargetsCacheableEntry() async throws {
        try await withRuntime { service, store in
            _ = try await service.price(for: 7, in: "eu")
            _ = try await service.price(for: 8, in: "eu")
            #expect(store.entryCount == 2)

            await service.remove(productID: 7, region: "eu")
            #expect(store.entryCount == 1)
            _ = try await service.price(for: 7, in: "eu")
            #expect(service.executions.withLock { $0 } == 3)

            await service.removeAll()
            #expect(store.entryCount == 0)
        }
    }

    @Test("non-throwing @Cacheable methods expand and cache")
    func nonThrowingCacheable() async throws {
        try await withRuntime { service, _ in
            let first = await service.nonThrowingPrice(productID: 3, region: "eu")
            let second = await service.nonThrowingPrice(productID: 3, region: "eu")
            #expect(first == 300 && second == 300)
            #expect(service.executions.withLock { $0 } == 1)
        }
    }

    @Test("without a bound runtime, annotated methods still work — uncached")
    func unwiredAnnotationsFailOpen() async throws {
        let service = PricingService()
        FlightCaches.uninstall()
        let first = try await service.price(for: 5, in: "eu")
        let second = try await service.price(for: 5, in: "eu")
        #expect(first == 500 && second == 500)
        #expect(service.executions.withLock { $0 } == 2)
    }
}

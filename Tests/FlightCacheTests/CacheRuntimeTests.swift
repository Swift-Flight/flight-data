import FlightCore
import Foundation
import Synchronization
import Testing

import FlightCacheTesting

@testable import FlightCache

@Suite("CacheRuntime — the §3.1 entry points")
struct CacheRuntimeTests {

    private func runtime(
        store: any Cache, values: [String: String] = [:]
    ) throws -> CacheRuntime {
        try CacheRuntime(store: store, configuration: Configuration(values: values))
    }

    @Test("miss computes, stores, returns; hit skips the body")
    func missThenHit() async throws {
        let store = RecordingCache()
        let runtime = try runtime(store: store)
        let executions = Counter()

        for _ in 0..<2 {
            let value = try await runtime.cacheable(
                namespace: "prices", parts: ["1"], ttl: nil, as: Int.self
            ) {
                executions.increment()
                return 42
            }
            #expect(value == 42)
        }
        #expect(executions.value == 1)
        #expect(store.data(for: CacheKey(namespace: "prices", parts: ["1"])) != nil)
    }

    @Test("a decode failure is a miss: recomputed and overwritten (§5)")
    func decodeFailureIsMiss() async throws {
        let store = RecordingCache()
        let key = CacheKey(namespace: "prices", parts: ["1"])
        store.seed(key, data: Data("not json at all {{{".utf8))
        let runtime = try runtime(store: store)

        let value = try await runtime.cacheable(
            namespace: "prices", parts: ["1"], ttl: nil, as: Int.self
        ) { 42 }
        #expect(value == 42)
        #expect(store.data(for: key) == Data("42".utf8))
    }

    @Test("a nil result is returned but never stored (§5)")
    func nilNotCached() async throws {
        let store = RecordingCache()
        let runtime = try runtime(store: store)
        let executions = Counter()

        for _ in 0..<2 {
            let value = try await runtime.cacheable(
                namespace: "prices", parts: ["1"], ttl: nil, as: Int?.self
            ) {
                executions.increment()
                return nil as Int?
            }
            #expect(value == nil)
        }
        #expect(executions.value == 2)
        #expect(store.data(for: CacheKey(namespace: "prices", parts: ["1"])) == nil)
    }

    @Test("TTL precedence: annotation > namespace > default > none (§6)")
    func ttlPrecedence() async throws {
        let store = RecordingCache()
        let runtime = try runtime(
            store: store,
            values: ["cache.default_ttl": "300", "cache.namespaces.prices": "900"])

        _ = try await runtime.cacheable(
            namespace: "prices", parts: ["annotated"], ttl: .seconds(15), as: Int.self
        ) { 1 }
        #expect(
            store.ttl(for: CacheKey(namespace: "prices", parts: ["annotated"])) == .seconds(15))

        _ = try await runtime.cacheable(namespace: "prices", parts: ["ns"], ttl: nil, as: Int.self) {
            1
        }
        #expect(store.ttl(for: CacheKey(namespace: "prices", parts: ["ns"])) == .seconds(900))

        _ = try await runtime.cacheable(namespace: "other", parts: ["dflt"], ttl: nil, as: Int.self)
        { 1 }
        #expect(store.ttl(for: CacheKey(namespace: "other", parts: ["dflt"])) == .seconds(300))
    }

    @Test("no config at all means no expiry")
    func noTTLAnywhere() async throws {
        let store = RecordingCache()
        let runtime = try CacheRuntime(store: store)
        _ = try await runtime.cacheable(namespace: "ns", parts: ["1"], ttl: nil, as: Int.self) { 1 }
        #expect(store.ttl(for: CacheKey(namespace: "ns", parts: ["1"])) == Duration??.some(nil))
    }

    @Test("a negative default TTL fails construction — bootstrap, not first request")
    func negativeDefaultTTLThrows() {
        #expect(throws: CacheConfigurationError.negativeDefaultTTL(-5)) {
            _ = try CacheRuntime(
                store: RecordingCache(),
                configuration: Configuration(values: ["cache.default_ttl": "-5"]))
        }
    }

    @Test("a malformed per-namespace TTL falls back to the default (§6)")
    func malformedNamespaceTTLIgnored() async throws {
        let store = RecordingCache()
        let runtime = try runtime(
            store: store,
            values: ["cache.default_ttl": "300", "cache.namespaces.prices": "soon"])
        _ = try await runtime.cacheable(namespace: "prices", parts: ["1"], ttl: nil, as: Int.self) {
            1
        }
        #expect(store.ttl(for: CacheKey(namespace: "prices", parts: ["1"])) == .seconds(300))
    }

    @Test("cachePut always overwrites (§3)")
    func putOverwrites() async throws {
        let store = RecordingCache()
        let runtime = try runtime(store: store)
        let key = CacheKey(namespace: "prices", parts: ["1"])

        _ = try await runtime.cacheable(namespace: "prices", parts: ["1"], ttl: nil, as: Int.self) {
            1
        }
        await runtime.cachePut(namespace: "prices", parts: ["1"], ttl: nil, value: 2)
        #expect(store.data(for: key) == Data("2".utf8))

        // And the next cacheable read serves the put value without running
        // its body.
        let value = try await runtime.cacheable(
            namespace: "prices", parts: ["1"], ttl: nil, as: Int.self
        ) {
            Issue.record("body must not run on a hit")
            return -1
        }
        #expect(value == 2)
    }

    @Test("evict removes one entry; allEntries evicts the namespace")
    func evict() async throws {
        let store = RecordingCache()
        let runtime = try runtime(store: store)
        await runtime.cachePut(namespace: "prices", parts: ["1"], ttl: nil, value: 1)
        await runtime.cachePut(namespace: "prices", parts: ["2"], ttl: nil, value: 2)

        await runtime.evict(namespace: "prices", parts: ["1"])
        #expect(store.data(for: CacheKey(namespace: "prices", parts: ["1"])) == nil)
        #expect(store.data(for: CacheKey(namespace: "prices", parts: ["2"])) != nil)

        await runtime.evict(namespace: "prices", parts: nil)
        #expect(store.entryCount == 0)
    }

    @Test("a downed store degrades to uncached, never to broken (§7)")
    func failOpen() async throws {
        let store = RecordingCache()
        store.misbehave()
        let runtime = try runtime(store: store)
        let executions = Counter()

        for _ in 0..<3 {
            let value = try await runtime.cacheable(
                namespace: "prices", parts: ["1"], ttl: nil, as: Int.self
            ) {
                executions.increment()
                return 42
            }
            #expect(value == 42)
        }
        #expect(executions.value == 3)
    }

    @Test("a thrown body error propagates and nothing is stored")
    func bodyErrorPropagates() async throws {
        struct Boom: Error {}
        let store = RecordingCache()
        let runtime = try runtime(store: store)

        await #expect(throws: Boom.self) {
            _ = try await runtime.cacheable(
                namespace: "prices", parts: ["1"], ttl: nil, as: Int.self
            ) { throw Boom() }
        }
        #expect(store.data(for: CacheKey(namespace: "prices", parts: ["1"])) == nil)
    }

    @Test("the non-throwing variant works end to end")
    func nonThrowingVariant() async throws {
        let store = RecordingCache()
        let runtime = try runtime(store: store)
        let executions = Counter()

        for _ in 0..<2 {
            let value = await runtime.cacheable(
                namespace: "prices", parts: ["1"], ttl: nil, as: String.self
            ) {
                executions.increment()
                return "cached"
            }
            #expect(value == "cached")
        }
        #expect(executions.value == 1)
    }
}

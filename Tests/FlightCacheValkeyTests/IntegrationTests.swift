// Integration tests against a real Valkey/Redis — gated per server and run
// against every server configured, the same §3.1-compatibility duality as
// flight-data-valkey's suite:
//
//   $ docker run -d --name flight-cache-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
//   $ docker run -d --name flight-cache-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
//   $ export FLIGHT_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
//   $ export FLIGHT_REDIS_TEST_URL="redis://127.0.0.1:56380"
//   $ swift test
//
// The suites FLUSHDB between tests — point them at throwaway servers only.

import FlightCache
import Foundation
import Testing
import Valkey

@testable import FlightCacheValkey

enum TestServer: String, CaseIterable, Sendable, CustomStringConvertible {
    case valkey
    case redis

    var environmentKey: String {
        switch self {
        case .valkey: return "FLIGHT_VALKEY_TEST_URL"
        case .redis: return "FLIGHT_REDIS_TEST_URL"
        }
    }

    var url: String? { ProcessInfo.processInfo.environment[environmentKey] }

    static let available: [TestServer] = allCases.filter { $0.url != nil }

    var description: String { rawValue }
}

/// Runs `body` with a live, flushed cache; the client pool runs for the
/// duration and is cancelled on the way out.
private func withCache<T>(
    _ server: TestServer, _ body: (ValkeyCache) async throws -> T
) async throws -> T {
    let cache = try ValkeyCache(
        settings: ValkeyCacheSettings(url: ValkeyCacheURL.parse(server.url!)))
    let runner = Task { await cache.client.run() }
    defer { runner.cancel() }
    _ = try await cache.client.flushdb()
    return try await body(cache)
}

@Suite(.serialized, .enabled(if: !TestServer.available.isEmpty))
struct ValkeyCacheIntegrationTests {

    @Test("set/get round-trip, under the flight-cache: key prefix", arguments: TestServer.available)
    func roundTrip(_ server: TestServer) async throws {
        try await withCache(server) { cache in
            let key = CacheKey(namespace: "prices", parts: ["123", "eu"])
            #expect(await cache.get(key) == nil)
            await cache.set(key, value: Data("42".utf8), ttl: nil)
            #expect(await cache.get(key) == Data("42".utf8))

            // The raw key is the documented shape (§10.2) — inspectable in
            // the store.
            let raw = try await cache.client.get("flight-cache:prices:123:eu")
            #expect(raw.map { Data($0) } == Data("42".utf8))
            // And carries no expiry when ttl is nil.
            let pttl = try await cache.client.pttl("flight-cache:prices:123:eu")
            #expect(pttl == -1)
        }
    }

    @Test("TTL maps to native expiry", arguments: TestServer.available)
    func ttlExpiry(_ server: TestServer) async throws {
        try await withCache(server) { cache in
            let key = CacheKey(namespace: "prices", parts: ["ttl"])
            await cache.set(key, value: Data("v".utf8), ttl: .milliseconds(150))
            #expect(await cache.get(key) != nil)
            try await Task.sleep(for: .milliseconds(400))
            #expect(await cache.get(key) == nil)
        }
    }

    @Test("set overwrites; evict removes exactly one entry", arguments: TestServer.available)
    func overwriteAndEvict(_ server: TestServer) async throws {
        try await withCache(server) { cache in
            let one = CacheKey(namespace: "ns", parts: ["1"])
            let two = CacheKey(namespace: "ns", parts: ["2"])
            await cache.set(one, value: Data("a".utf8), ttl: nil)
            await cache.set(one, value: Data("b".utf8), ttl: nil)
            await cache.set(two, value: Data("c".utf8), ttl: nil)
            #expect(await cache.get(one) == Data("b".utf8))

            await cache.evict(one)
            #expect(await cache.get(one) == nil)
            #expect(await cache.get(two) == Data("c".utf8))
        }
    }

    @Test(
        "namespace eviction sweeps every batch and spares other namespaces",
        arguments: TestServer.available)
    func namespaceEviction(_ server: TestServer) async throws {
        try await withCache(server) { cache in
            // More keys than one SCAN batch (500), so the cursor loop is
            // exercised for real.
            for index in 0..<750 {
                await cache.set(
                    CacheKey(namespace: "doomed", parts: ["\(index)"]),
                    value: Data("d".utf8), ttl: nil)
            }
            for index in 0..<50 {
                await cache.set(
                    CacheKey(namespace: "spared", parts: ["\(index)"]),
                    value: Data("s".utf8), ttl: nil)
            }

            await cache.evictNamespace("doomed")

            #expect(await cache.get(CacheKey(namespace: "doomed", parts: ["0"])) == nil)
            #expect(await cache.get(CacheKey(namespace: "doomed", parts: ["749"])) == nil)
            #expect(await cache.get(CacheKey(namespace: "spared", parts: ["0"])) != nil)
            let remaining = try await cache.client.dbsize()
            #expect(remaining == 50)
        }
    }

    @Test(
        "a namespace that prefix-collides in the raw string is NOT evicted",
        arguments: TestServer.available)
    func namespacePrefixSafety(_ server: TestServer) async throws {
        try await withCache(server) { cache in
            await cache.set(CacheKey(namespace: "prices", parts: ["1"]), value: Data("a".utf8), ttl: nil)
            await cache.set(CacheKey(namespace: "prices2", parts: ["1"]), value: Data("b".utf8), ttl: nil)
            await cache.evictNamespace("prices")
            #expect(await cache.get(CacheKey(namespace: "prices", parts: ["1"])) == nil)
            #expect(await cache.get(CacheKey(namespace: "prices2", parts: ["1"])) != nil)
        }
    }
}

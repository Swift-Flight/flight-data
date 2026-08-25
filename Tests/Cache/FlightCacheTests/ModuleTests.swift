import Foundation
import FlightCore
import Testing

import FlightCacheTesting

@testable import FlightCache

/// Serialized: these tests exercise the process-global `FlightCaches`
/// install seam, so they must not interleave.
@Suite("FlightCacheModule — wiring", .serialized)
struct ModuleTests {

    /// The adapter-module contract from, in miniature: register the
    /// store under the well-known qualifier, depend on FlightCacheModule.
    final class RecordingAdapterModule: FlightModule {
        static var dependencies: [any FlightModule.Type] { [FlightCacheModule.self] }
        init() {}
        func configure(_ container: Container) throws {
            container.register(
                (any Cache).self, qualifier: FlightCacheModule.storeQualifier, scope: .singleton
            ) { _ in RecordingCache() }
        }
    }

    @Test("without an adapter module, the in-memory store is the cache")
    func inMemoryDefault() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let application = try Flight.assemble(
                configuration: Configuration(values: ["cache.memory.max_entries": "5"]),
                modules: [FlightCacheModule.self])
            let store = try application.container.resolve((any Cache).self)
            let memory = try #require(store as? InMemoryCache)
            #expect(memory.maxEntries == 5)
            #expect(FlightCaches.isInstalled)
        }
    }

    @Test("a registered adapter store wins over the in-memory default")
    func adapterComposesByPresence() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let application = try Flight.assemble(
                configuration: Configuration(),
                modules: [FlightCacheModule.self, RecordingAdapterModule.self])
            let store = try application.container.resolve((any Cache).self)
            #expect(store is RecordingCache)
            #expect(FlightCaches.isInstalled)
        }
    }

    @Test("a non-positive LRU bound fails bootstrap, not the first request")
    func invalidMaxEntriesFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            #expect(throws: (any Error).self) {
                _ = try Flight.assemble(
                    configuration: Configuration(values: ["cache.memory.max_entries": "0"]),
                    modules: [FlightCacheModule.self])
            }
        }
    }

    @Test("without any install, annotations run against the no-op runtime")
    func unwiredFailsOpen() async throws {
        FlightCaches.uninstall()
        let executions = try await confirmationFreeCount()
        #expect(executions == 2)
    }

    private func confirmationFreeCount() async throws -> Int {
        var executions = 0
        for _ in 0..<2 {
            let value = try await FlightCaches.current.cacheable(
                namespace: "unwired", parts: ["1"], ttl: nil, as: Int.self
            ) {
                executions += 1
                return 7
            }
            #expect(value == 7)
        }
        return executions
    }
}

/// The codec seam, which the module used to leave unreachable.
@Suite("CacheCodec is resolvable")
struct CacheCodecSeamTests {

    /// Encodes to a marker no JSON encoder would produce, so a test can tell
    /// which codec actually ran.
    struct MarkerCodec: CacheCodec {
        func encode(_ value: some Encodable) throws -> Data {
            Data("marker:".utf8) + (try JSONCacheCodec().encode(value))
        }
        func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            try JSONCacheCodec().decode(type, from: data.dropFirst("marker:".count))
        }
    }

    /// Registers a codec the way an application would: its own module.
    struct MarkerCodecModule: FlightModule {
        static var dependencies: [any FlightModule.Type] { [FlightCacheModule.self] }
        func configure(_ container: Container) throws {
            container.register((any CacheCodec).self, scope: .singleton) { _ in MarkerCodec() }
        }
    }

    @Test("an application's registered codec is the one the runtime uses")
    func registeredCodecIsUsed() async throws {
        defer { FlightCaches.uninstall() }
        let application = try Flight.assemble(
            configuration: Configuration(),
            modules: [FlightCacheModule.self, MarkerCodecModule.self])
        let runtime = try application.container.resolve(CacheRuntime.self)
        _ = try await runtime.cacheable(namespace: "codec", parts: ["1"], ttl: .seconds(60)) { 42 }

        let store = try application.container.resolve((any Cache).self)
        let stored = await store.get(CacheKey(namespace: "codec", parts: ["1"]))
        #expect(stored.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("marker:") == true)
    }

    @Test("no registered codec still means JSON")
    func defaultCodecIsJSON() async throws {
        defer { FlightCaches.uninstall() }
        let application = try Flight.assemble(
            configuration: Configuration(), modules: [FlightCacheModule.self])
        let runtime = try application.container.resolve(CacheRuntime.self)
        _ = try await runtime.cacheable(namespace: "codec", parts: ["2"], ttl: .seconds(60)) { 42 }

        let store = try application.container.resolve((any Cache).self)
        let stored = await store.get(CacheKey(namespace: "codec", parts: ["2"]))
        #expect(stored.map { String(decoding: $0, as: UTF8.self) } == "42")
    }
}

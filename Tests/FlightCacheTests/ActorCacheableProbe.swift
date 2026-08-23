import FlightCache
import FlightCore
import Synchronization
import Testing

/// `@Cacheable` on isolated types.
///
/// This did not compile at all: the runtime's `cacheable` was nonisolated, so
/// a body closure formed inside an actor was "sent" to it and Swift 6
/// rejected every expansion with "sending 'self'-isolated value … risks
/// causing data races". Every actor and every `@MainActor` type was excluded
/// from the package's headline feature, and the end-to-end suite missed it
/// because its one fixture was a nonisolated `final class`.
@Suite("@Cacheable under isolation")
struct IsolatedCacheableTests {

    actor PriceService {
        private(set) var lookups = 0

        @Cacheable(namespace: "prices", ttl: .seconds(60))
        func price(for symbol: String) async throws -> Int {
            lookups += 1
            return symbol.count
        }
    }

    @MainActor
    final class ViewModelService {
        private(set) var lookups = 0

        @Cacheable(namespace: "view", ttl: .seconds(60))
        func title(for id: String) async throws -> String {
            lookups += 1
            return "title-\(id)"
        }
    }

    // Same treatment the runtime needed, for the same reason: without it the
    // @MainActor test below cannot call this helper either.
    private func withRuntime<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        let runtime = try CacheRuntime(store: InMemoryCache(), configuration: Configuration())
        return try await FlightCaches.$override.withValue(runtime) { try await body() }
    }

    @Test("an actor method caches, and the body runs once")
    func actorMethodCaches() async throws {
        try await withRuntime {
            let service = PriceService()
            let first = try await service.price(for: "AAPL")
            let second = try await service.price(for: "AAPL")
            let lookups = await service.lookups
            #expect(first == 4 && second == 4)
            #expect(lookups == 1, "the second call must come from cache")
        }
    }

    @Test("a @MainActor method caches too")
    @MainActor
    func mainActorMethodCaches() async throws {
        try await withRuntime {
            let service = ViewModelService()
            let first = try await service.title(for: "a")
            let second = try await service.title(for: "a")
            #expect(first == "title-a" && second == "title-a")
            #expect(service.lookups == 1)
        }
    }
}

/// Coalescing when the answer is `nil`.
///
/// A `nil` result is not stored — caching absence is a separate decision with
/// its own semantics. But *not storing* and *having no answer* were the same
/// outcome to a waiter, so every concurrent caller of a `nil`-returning method
/// recomputed: twenty callers, twenty executions, on exactly the shape where a
/// stampede hurts most. A miss storm on an absent key is the classic case.
@Suite("Coalescing a nil result")
struct NilResultCoalescingTests {

    final class Lookups: Sendable {
        let executions = Mutex(0)

        @Cacheable(namespace: "absent", ttl: .seconds(60))
        func missing(id: Int) async throws -> String? {
            executions.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(30))
            return nil
        }

        @Cacheable(namespace: "present", ttl: .seconds(60))
        func found(id: Int) async throws -> String? {
            executions.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(30))
            return "value-\(id)"
        }
    }

    private func withRuntime<T>(_ body: (Lookups) async throws -> T) async throws -> T {
        let runtime = try CacheRuntime(store: InMemoryCache(), configuration: Configuration())
        return try await FlightCaches.$override.withValue(runtime) { try await body(Lookups()) }
    }

    @Test("twenty concurrent callers of a nil-returning method run the body once")
    func nilResultCoalesces() async throws {
        try await withRuntime { service in
            let results = try await withThrowingTaskGroup(of: String?.self) { group in
                for _ in 0..<20 {
                    group.addTask { try await service.missing(id: 1) }
                }
                var collected: [String?] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            #expect(results.count == 20)
            #expect(results.allSatisfy { $0 == nil }, "every caller must get the nil answer")
            #expect(
                service.executions.withLock { $0 } == 1,
                "the leader computed; the other nineteen waited")
        }
    }

    @Test("a nil answer is still not stored — later callers recompute")
    func nilIsNotCached() async throws {
        try await withRuntime { service in
            _ = try await service.missing(id: 2)
            _ = try await service.missing(id: 2)
            // Coalescing is about concurrent callers; caching absence is a
            // separate decision this package does not make for you.
            #expect(service.executions.withLock { $0 } == 2)
        }
    }

    @Test("a non-nil result still coalesces and still caches")
    func nonNilStillWorks() async throws {
        try await withRuntime { service in
            let results = try await withThrowingTaskGroup(of: String?.self) { group in
                for _ in 0..<20 { group.addTask { try await service.found(id: 3) } }
                var collected: [String?] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            #expect(results.allSatisfy { $0 == "value-3" })
            #expect(service.executions.withLock { $0 } == 1)
            // And it was stored, so a later caller does not recompute.
            _ = try await service.found(id: 3)
            #expect(service.executions.withLock { $0 } == 1)
        }
    }
}

// Cache macro expansion fixtures — the same posture as flight-core's
// MacroFixtureTests: these expected strings ARE the specification of the
// expansions; a prose example is illustrative, these
// are normative.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import FlightCacheMacrosImpl

private let testMacros: [String: MacroSpec] = [
    "Cacheable": MacroSpec(type: CacheableMacro.self),
    "CacheEvict": MacroSpec(type: CacheEvictMacro.self),
    "CachePut": MacroSpec(type: CachePutMacro.self),
]

final class CacheMacroFixtureTests: XCTestCase {

    // MARK: Fixture 1 — @Cacheable on an async throws method (the design's
    // example, corrected spellings)

    func testCacheableAsyncThrows() {
        assertMacroExpansion(
            """
            final class PricingService {
                @Cacheable(namespace: "prices", ttl: .seconds(900))
                func price(for productID: ProductID, in region: Region) async throws -> Price {
                    try await repository.computePrice(productID, region)
                }
            }
            """,
            expandedSource: """
            final class PricingService {
                func price(for productID: ProductID, in region: Region) async throws -> Price {
                    return try await FlightCache.FlightCaches.current.cacheable(
                        namespace: "prices",
                        parts: [FlightCache.CacheKey.part(productID), FlightCache.CacheKey.part(region)],
                        ttl: .seconds(900),
                        as: Price.self
                    ) { () async throws -> Price in
                        try await repository.computePrice(productID, region)
                    }
                }
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 2 — @Cacheable, non-throwing, no annotation TTL,
    // excluded parameter

    func testCacheableNonThrowingExcluding() {
        assertMacroExpansion(
            """
            final class PricingService {
                @Cacheable(namespace: "prices", excluding: ["traceID"])
                func price(for productID: ProductID, traceID: String) async -> Price {
                    await repository.lookup(productID)
                }
            }
            """,
            expandedSource: """
            final class PricingService {
                func price(for productID: ProductID, traceID: String) async -> Price {
                    return await FlightCache.FlightCaches.current.cacheable(
                        namespace: "prices",
                        parts: [FlightCache.CacheKey.part(productID)],
                        ttl: nil,
                        as: Price.self
                    ) { () async -> Price in
                        await repository.lookup(productID)
                    }
                }
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 3 — @CacheEvict, namespace-wide, Void async

    func testCacheEvictAllEntries() {
        assertMacroExpansion(
            """
            final class PricingService {
                @CacheEvict(namespace: "prices", allEntries: true)
                func invalidateAll() async {
                }
            }
            """,
            expandedSource: """
            final class PricingService {
                func invalidateAll() async {
                    await { () async -> Void in

                    }()
                    await FlightCache.FlightCaches.current.evict(namespace: "prices", parts: nil)
                }
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 4 — @CacheEvict keyed on an argument, with a result

    func testCacheEvictKeyed() {
        assertMacroExpansion(
            """
            final class PricingService {
                @CacheEvict(namespace: "prices")
                func remove(productID: ProductID) async throws -> Bool {
                    try await repository.delete(productID)
                }
            }
            """,
            expandedSource: """
            final class PricingService {
                func remove(productID: ProductID) async throws -> Bool {
                    let _flightCacheResult: Bool = try await { () async throws -> Bool in
                        try await repository.delete(productID)
                    }()
                    await FlightCache.FlightCaches.current.evict(namespace: "prices", parts: [FlightCache.CacheKey.part(productID)])
                    return _flightCacheResult
                }
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 5 — @CachePut with the new value excluded (the
    // corrected overridePrice example)

    func testCachePutExcludingNewValue() {
        assertMacroExpansion(
            """
            final class PricingService {
                @CachePut(namespace: "prices", ttl: .seconds(900), excluding: ["price"])
                func overridePrice(for productID: ProductID, in region: Region, to price: Price) async throws -> Price {
                    try await repository.store(productID, region, price)
                }
            }
            """,
            expandedSource: """
            final class PricingService {
                func overridePrice(for productID: ProductID, in region: Region, to price: Price) async throws -> Price {
                    let _flightCacheValue: Price = try await { () async throws -> Price in
                        try await repository.store(productID, region, price)
                    }()
                    await FlightCache.FlightCaches.current.cachePut(
                        namespace: "prices",
                        parts: [FlightCache.CacheKey.part(productID), FlightCache.CacheKey.part(region)],
                        ttl: .seconds(900),
                        value: _flightCacheValue
                    )
                    return _flightCacheValue
                }
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Diagnostics

    func testCacheableRequiresAsync() {
        assertMacroExpansion(
            """
            final class S {
                @Cacheable(namespace: "prices")
                func price(id: Int) throws -> Int {
                    id
                }
            }
            """,
            expandedSource: """
            final class S {
                func price(id: Int) throws -> Int {
                    id
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Cacheable requires an async method — the Cache protocol is async, and a synchronous caching path would need a blocking store API this package deliberately doesn't have.",
                    line: 3, column: 10)
            ],
            macroSpecs: testMacros
        )
    }

    func testCacheableRequiresResult() {
        assertMacroExpansion(
            """
            final class S {
                @Cacheable(namespace: "prices")
                func warm(id: Int) async {
                }
            }
            """,
            expandedSource: """
            final class S {
                func warm(id: Int) async {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Cacheable requires a method that returns a value — caching Void is meaningless. Use @CacheEvict for side-effecting invalidation.",
                    line: 3, column: 10)
            ],
            macroSpecs: testMacros
        )
    }

    func testUnknownExcludedParameterIsRejected() {
        assertMacroExpansion(
            """
            final class S {
                @Cacheable(namespace: "prices", excluding: ["traceId"])
                func price(id: Int, traceID: String) async -> Int {
                    id
                }
            }
            """,
            expandedSource: """
            final class S {
                func price(id: Int, traceID: String) async -> Int {
                    id
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "excluding: names parameter 'traceId', but price has no parameter with that internal name.",
                    line: 2, column: 5)
            ],
            macroSpecs: testMacros
        )
    }

    func testEvictWithoutKeyOrAllEntriesIsRejected() {
        assertMacroExpansion(
            """
            final class S {
                @CacheEvict(namespace: "prices")
                func invalidateAll() async {
                }
            }
            """,
            expandedSource: """
            final class S {
                func invalidateAll() async {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@CacheEvict has no key-contributing parameters to derive an entry from — pass allEntries: true to evict the whole namespace, or add a key parameter.",
                    line: 2, column: 5)
            ],
            macroSpecs: testMacros
        )
    }

    func testNamespaceMustBeStringLiteral() {
        assertMacroExpansion(
            """
            final class S {
                @Cacheable(namespace: dynamicNamespace)
                func price(id: Int) async -> Int {
                    id
                }
            }
            """,
            expandedSource: """
            final class S {
                func price(id: Int) async -> Int {
                    id
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "namespace: must be a plain string literal — the namespace is compile-time cache identity, not a runtime value.",
                    line: 2, column: 27)
            ],
            macroSpecs: testMacros
        )
    }

    func testTypedThrowsIsRejected() {
        assertMacroExpansion(
            """
            final class S {
                @Cacheable(namespace: "prices")
                func price(id: Int) async throws(PricingError) -> Int {
                    id
                }
            }
            """,
            expandedSource: """
            final class S {
                func price(id: Int) async throws(PricingError) -> Int {
                    id
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Cacheable does not support typed throws — the cache runtime propagates coalesced errors as any Error. Use an untyped throws.",
                    line: 3, column: 31)
            ],
            macroSpecs: testMacros
        )
    }
}

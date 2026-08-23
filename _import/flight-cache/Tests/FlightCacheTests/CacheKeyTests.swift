import Foundation
import Testing

@testable import FlightCache

@Suite("CacheKey — injective, prefix-safe encoding")
struct CacheKeyTests {

    @Test("adjacent parts cannot collide")
    func injectivity() {
        let left = CacheKey(namespace: "ns", parts: ["ab", "c"])
        let right = CacheKey(namespace: "ns", parts: ["a", "bc"])
        #expect(left.storageKey != right.storageKey)
    }

    @Test("colons and backslashes in segments are escaped")
    func escaping() {
        let tricky = CacheKey(namespace: "ns", parts: ["a:b", #"c\d"#])
        let literal = CacheKey(namespace: "ns", parts: [#"a\:b"#, "c", "d"])
        #expect(tricky.storageKey != literal.storageKey)
        // A namespace containing a colon cannot fake another namespace's
        // prefix.
        let sneaky = CacheKey(namespace: "prices:1", parts: [])
        #expect(!sneaky.storageKey.hasPrefix(CacheKey.storagePrefix(namespace: "prices")))
    }

    @Test("no parts, one empty part, and the empty string differ")
    func emptySegments() {
        let none = CacheKey(namespace: "ns", parts: [])
        let empty = CacheKey(namespace: "ns", parts: [""])
        let literalMarker = CacheKey(namespace: "ns", parts: [#"\e"#])
        #expect(none.storageKey != empty.storageKey)
        #expect(empty.storageKey != literalMarker.storageKey)
    }

    @Test("every key in a namespace carries its storage prefix, and only its own")
    func prefixSafety() {
        let key = CacheKey(namespace: "prices", parts: ["123", "eu"])
        #expect(key.storageKey.hasPrefix(CacheKey.storagePrefix(namespace: "prices")))
        #expect(!key.storageKey.hasPrefix(CacheKey.storagePrefix(namespace: "price")))
        let other = CacheKey(namespace: "prices2", parts: ["123"])
        #expect(!other.storageKey.hasPrefix(CacheKey.storagePrefix(namespace: "prices")))
    }

    @Test("readable in the common case")
    func readability() {
        #expect(CacheKey(namespace: "prices", parts: ["123", "eu"]).storageKey == "prices:123:eu")
    }
}

@Suite("CacheKeyContributing — stable representations")
struct CacheKeyContributingTests {

    enum Region: String, CacheKeyContributing { case eu, us }

    @Test("primitives")
    func primitives() {
        #expect(CacheKey.part("abc") == "abc")
        #expect(CacheKey.part(42) == "42")
        #expect(CacheKey.part(true) == "true")
        #expect(CacheKey.part(3.5) == "3.5")
        let uuid = UUID(uuidString: "0EA14D3E-BB43-4C43-9B33-338996EC0EF0")!
        #expect(CacheKey.part(uuid) == "0EA14D3E-BB43-4C43-9B33-338996EC0EF0")
    }

    @Test("optionals")
    func optionals() {
        let some: Int? = 7
        let none: Int? = nil
        #expect(CacheKey.part(some) == "7")
        #expect(CacheKey.part(none) == "nil")
    }

    @Test("arrays are injective")
    func arrays() {
        #expect(CacheKey.part(["a,b"]) != CacheKey.part(["a", "b"]))
        #expect(CacheKey.part(["a", "b"]) == "a,b")
    }

    @Test("RawRepresentable opt-in")
    func rawRepresentable() {
        #expect(CacheKey.part(Region.eu) == "eu")
    }
}

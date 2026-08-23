import Foundation

/// What identifies a value for caching purposes.
///
/// Every key-contributing parameter of a `@Cacheable`/`@CachePut`/
/// `@CacheEvict` method must conform — checked at compile time by the
/// generic constraint on `CacheKey.part(_:)` that the expansion generates.
/// Conformances ship for the obvious primitives; custom types conform
/// explicitly, which forces a deliberate answer to "what identifies this
/// value" instead of Spring's reflective default.
public protocol CacheKeyContributing {
    /// Stable across processes and releases. NOT `Hashable`'s `hashValue` —
    /// Swift's hashing is seeded per-process and would produce different
    /// keys on every restart and on every node.
    var cacheKeyRepresentation: String { get }
}

extension String: CacheKeyContributing {
    public var cacheKeyRepresentation: String { self }
}

extension Substring: CacheKeyContributing {
    public var cacheKeyRepresentation: String { String(self) }
}

extension Character: CacheKeyContributing {
    public var cacheKeyRepresentation: String { String(self) }
}

extension Bool: CacheKeyContributing {
    public var cacheKeyRepresentation: String { self ? "true" : "false" }
}

extension Int: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension Int8: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension Int16: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension Int32: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension Int64: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension UInt: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension UInt8: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension UInt16: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension UInt32: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension UInt64: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }

/// Floating-point `description` round-trips exactly in Swift (shortest
/// representation that parses back to the same value), so it is stable
/// across processes. Whether float identity is a *good* cache key is the
/// caller's judgment call.
extension Double: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }
extension Float: CacheKeyContributing { public var cacheKeyRepresentation: String { description } }

extension UUID: CacheKeyContributing {
    public var cacheKeyRepresentation: String { uuidString }
}

/// `nil` contributes the literal `nil`; a wrapped value contributes its own
/// representation. Note the deliberate simplicity: `String?.none` and the
/// string `"nil"` render identically. If a parameter's domain includes the
/// literal string "nil", give the type its own conformance.
extension Optional: CacheKeyContributing where Wrapped: CacheKeyContributing {
    public var cacheKeyRepresentation: String {
        switch self {
        case .none: return "nil"
        case .some(let wrapped): return wrapped.cacheKeyRepresentation
        }
    }
}

/// Elements joined with `,` after escaping `,` and `\` in each — injective
/// among arrays of the same element type.
extension Array: CacheKeyContributing where Element: CacheKeyContributing {
    public var cacheKeyRepresentation: String {
        map { element -> String in
            let representation = element.cacheKeyRepresentation
            guard representation.contains(",") || representation.contains("\\") else {
                return representation
            }
            var escaped = ""
            for character in representation {
                switch character {
                case "\\": escaped += #"\\"#
                case ",": escaped += #"\,"#
                default: escaped.append(character)
                }
            }
            return escaped
        }
        .joined(separator: ",")
    }
}

/// RawRepresentable types (string/int-backed enums, typed identifiers) get
/// their raw value's representation — opt-in via explicit conformance
/// declaration (`extension Region: CacheKeyContributing {}`), keeping the
/// "deliberate answer" posture while sparing the boilerplate.
extension CacheKeyContributing where Self: RawRepresentable, RawValue: CacheKeyContributing {
    public var cacheKeyRepresentation: String { rawValue.cacheKeyRepresentation }
}

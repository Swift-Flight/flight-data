/// A cache entry's identity (design §2, §4): a namespace plus the
/// key-contributing argument representations, in declaration order. The
/// method's name is deliberately NOT part of it — that is what lets
/// `@CachePut`/`@CacheEvict` methods target entries a `@Cacheable` method
/// wrote (§4's cross-method key contract).
public struct CacheKey: Sendable, Hashable {
    /// The §6 namespace — the grouping and bulk-eviction unit.
    public let namespace: String
    /// Stable representations of the key-contributing arguments (§4).
    public let parts: [String]

    public init(namespace: String, parts: [String]) {
        self.namespace = namespace
        self.parts = parts
    }

    /// The single-string form adapters key their storage by. Injective and
    /// prefix-safe (§2): every segment is escaped (`\` → `\\`, `:` → `\:`,
    /// the empty segment → `\e`) and segments join with `:`, so
    /// `["ab","c"]`/`["a","bc"]` cannot collide and an escaped segment can
    /// never contain a raw `:` — which makes `storagePrefix(namespace:)` an
    /// unambiguous namespace prefix.
    public var storageKey: String {
        var rendered = Self.escape(namespace)
        rendered += ":"
        rendered += parts.map(Self.escape).joined(separator: ":")
        return rendered
    }

    /// The prefix every `storageKey` in `namespace` starts with — and that
    /// no other namespace's keys can start with. The Valkey adapter's §10.2
    /// prefix eviction matches on exactly this.
    public static func storagePrefix(namespace: String) -> String {
        escape(namespace) + ":"
    }

    /// One argument's key contribution — the call the §3.1 expansions
    /// generate per key-contributing parameter. The generic constraint is
    /// the §4 compile-time conformance check: a parameter type that isn't
    /// `CacheKeyContributing` fails to compile here, at the annotated
    /// method, not at runtime.
    public static func part<T: CacheKeyContributing>(_ value: T) -> String {
        value.cacheKeyRepresentation
    }

    private static func escape(_ segment: String) -> String {
        if segment.isEmpty { return #"\e"# }
        guard segment.contains(":") || segment.contains("\\") else { return segment }
        var escaped = ""
        escaped.reserveCapacity(segment.count + 2)
        for character in segment {
            switch character {
            case "\\": escaped += #"\\"#
            case ":": escaped += #"\:"#
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

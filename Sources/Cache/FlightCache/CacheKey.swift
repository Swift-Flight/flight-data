/// A cache entry's identity: a namespace plus the
/// key-contributing argument representations, in declaration order. The
/// method's name is deliberately NOT part of it — that is what lets
/// `@CachePut`/`@CacheEvict` methods target entries a `@Cacheable` method
/// wrote (cross-method key contract).
public struct CacheKey: Sendable, Hashable {
    /// The namespace — the grouping and bulk-eviction unit.
    public let namespace: String
    /// Stable representations of the key-contributing arguments.
    public let parts: [String]

    /// The single-string form adapters key their storage by. Injective and
    /// prefix-safe: every segment is escaped (`\` → `\\`, `:` → `\:`,
    /// the empty segment → `\e`) and segments join with `:`, so
    /// `["ab","c"]`/`["a","bc"]` cannot collide and an escaped segment can
    /// never contain a raw `:` — which makes `storagePrefix(namespace:)` an
    /// unambiguous namespace prefix.
    ///
    /// Rendered once at construction. The key is immutable and every miss
    /// asks for this several times over — the store lookup, the flight key,
    /// the store write, and any log line — so re-escaping it each time was
    /// paying for the same string four times on the path that is already the
    /// slow one.
    public let storageKey: String

    public init(namespace: String, parts: [String]) {
        self.namespace = namespace
        self.parts = parts
        var rendered = Self.escape(namespace)
        rendered += ":"
        rendered += parts.map(Self.escape).joined(separator: ":")
        self.storageKey = rendered
    }


    /// The prefix every `storageKey` in `namespace` starts with — and that
    /// no other namespace's keys can start with. The Valkey adapter's
    /// prefix eviction matches on exactly this.
    public static func storagePrefix(namespace: String) -> String {
        escape(namespace) + ":"
    }

    /// One argument's key contribution — the call the expansions
    /// generate per key-contributing parameter. The generic constraint is
    /// the compile-time conformance check: a parameter type that isn't
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

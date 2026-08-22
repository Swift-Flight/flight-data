import Foundation

/// The entire cross-store contract (design §2). Deliberately tiny, and
/// deliberately `Data`-valued: the cache moves opaque bytes and has no
/// opinion about serialization (§5) — the same choice PubSub §4 makes.
///
/// **No method throws, ever.** A miss is normal; an errored `get` is a miss;
/// an errored `set` is dropped (and logged by the adapter). The correct
/// behavior on any cache failure — the backing store being entirely down
/// included — is to fall through to the real computation (§7). A cache that
/// can fail your request is worse than no cache.
public protocol Cache: Sendable {
    /// Returns nil on miss. A miss is NORMAL, never an error.
    func get(_ key: CacheKey) async -> Data?

    /// Store with an optional time-to-live. `ttl: nil` means "no expiry" —
    /// the caller (`CacheRuntime`, §11) has already resolved the §6 TTL
    /// policy before this call; adapters never consult config themselves.
    func set(_ key: CacheKey, value: Data, ttl: Duration?) async

    /// Remove one entry. Idempotent — removing an absent key is not an error.
    func evict(_ key: CacheKey) async

    /// Remove every entry under a namespace (§6). The namespace is the raw
    /// (unescaped) name; adapters match on `CacheKey.storagePrefix(namespace:)`.
    func evictNamespace(_ namespace: String) async
}

/// The always-miss store behind the `FlightCaches` no-op fallback (§11): a
/// `@Cacheable` method in an app that never installed `FlightCacheModule`
/// computes every call — degraded, not broken (§7).
public struct NoopCache: Cache {
    public init() {}
    public func get(_ key: CacheKey) async -> Data? { nil }
    public func set(_ key: CacheKey, value: Data, ttl: Duration?) async {}
    public func evict(_ key: CacheKey) async {}
    public func evictNamespace(_ namespace: String) async {}
}

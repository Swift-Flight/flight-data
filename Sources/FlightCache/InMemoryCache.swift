import Foundation
import OrderedCollections

/// The default adapter (design §10.1): an actor-guarded ordered dictionary
/// with TTL expiry and a bounded size using LRU eviction. Bounded by
/// default — an unbounded in-memory cache is a memory leak wearing a hat.
///
/// Correct for single-instance deployments, development, and tests; its
/// limits stated plainly: not shared across instances, and lost on restart.
///
/// Expiry is lazy: an expired entry is dropped when touched, and expired
/// entries are swept before LRU eviction when the bound is hit — so the
/// bound, not a background timer, is what caps memory.
public actor InMemoryCache: Cache {
    public static let defaultMaxEntries = 10_000

    private struct Entry {
        let namespace: String
        let data: Data
        let expiresAt: ContinuousClock.Instant?
    }

    /// Keyed by `CacheKey.storageKey`; order is recency, oldest first.
    private var entries: OrderedDictionary<String, Entry> = [:]
    private let clock = ContinuousClock()
    public nonisolated let maxEntries: Int

    public init(maxEntries: Int = InMemoryCache.defaultMaxEntries) {
        precondition(maxEntries > 0, "InMemoryCache is bounded by design (§10.1) — maxEntries must be positive.")
        self.maxEntries = maxEntries
    }

    public func get(_ key: CacheKey) async -> Data? {
        let storageKey = key.storageKey
        guard let entry = entries[storageKey] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= clock.now {
            entries.removeValue(forKey: storageKey)
            return nil
        }
        // Refresh recency: move to the end of the order.
        entries.removeValue(forKey: storageKey)
        entries[storageKey] = entry
        return entry.data
    }

    public func set(_ key: CacheKey, value: Data, ttl: Duration?) async {
        let storageKey = key.storageKey
        entries.removeValue(forKey: storageKey)
        entries[storageKey] = Entry(
            namespace: key.namespace,
            data: value,
            expiresAt: ttl.map { clock.now.advanced(by: $0) }
        )
        enforceBound()
    }

    public func evict(_ key: CacheKey) async {
        entries.removeValue(forKey: key.storageKey)
    }

    public func evictNamespace(_ namespace: String) async {
        let doomed = entries.compactMap { key, entry in
            entry.namespace == namespace ? key : nil
        }
        for key in doomed {
            entries.removeValue(forKey: key)
        }
    }

    /// Live entry count, expired entries included until touched or swept —
    /// introspection for tests.
    public var count: Int { entries.count }

    private func enforceBound() {
        guard entries.count > maxEntries else { return }
        // Expired entries go first — evicting a live entry while dead ones
        // occupy capacity would be wrong twice over.
        let now = clock.now
        let expired = entries.compactMap { key, entry in
            (entry.expiresAt.map { $0 <= now } ?? false) ? key : nil
        }
        for key in expired {
            entries.removeValue(forKey: key)
        }
        while entries.count > maxEntries {
            entries.removeFirst()
        }
    }
}

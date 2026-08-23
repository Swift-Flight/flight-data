import Foundation
import OrderedCollections

/// The default adapter: an actor-guarded ordered dictionary
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
        precondition(maxEntries > 0, "InMemoryCache is bounded by design — maxEntries must be positive.")
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

    /// Writes since the last full sweep for expired entries.
    private var writesSinceSweep = 0

    /// How often a full sweep is worth its cost, as a fraction of capacity.
    /// A sweep is O(n); amortized over n/8 writes it adds a constant.
    private var sweepInterval: Int { max(64, maxEntries / 8) }

    private func enforceBound() {
        writesSinceSweep += 1

        // A full scan for expired entries used to run on *every* write once
        // the cache was full: O(n) per `set` at n = maxEntries, which made a
        // cache 100x slower exactly when it started doing its job. It is
        // amortized now — expired entries are still reclaimed on `get`, and
        // they drift toward the eviction end on their own, because an entry
        // nobody reads is by definition least-recently-used.
        if writesSinceSweep >= sweepInterval {
            writesSinceSweep = 0
            sweepExpired()
        }

        guard entries.count > maxEntries else { return }

        // The eviction candidate is the least-recently-used entry, and if it
        // happens to be expired it is being removed for two reasons at once.
        // Either way this is O(1) per evicted entry.
        while entries.count > maxEntries {
            entries.removeFirst()
        }
    }

    /// Drops every entry whose TTL has passed. O(n), so callers amortize it.
    private func sweepExpired() {
        let now = clock.now
        let expired = entries.compactMap { key, entry in
            (entry.expiresAt.map { $0 <= now } ?? false) ? key : nil
        }
        for key in expired {
            entries.removeValue(forKey: key)
        }
    }
}

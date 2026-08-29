import Foundation

/// The default adapter: an actor-guarded dictionary with TTL expiry and a
/// bounded size using LRU eviction. Bounded by default — an unbounded
/// in-memory cache is a memory leak wearing a hat.
///
/// Correct for single-instance deployments, development, and tests; its
/// limits stated plainly: not shared across instances, and lost on restart.
///
/// Expiry is lazy: an expired entry is dropped when touched, and expired
/// entries are swept periodically before LRU eviction — so the bound, not a
/// background timer, is what caps memory.
///
/// ## Why the recency list is hand-rolled (design delta C7)
///
/// This was an `OrderedDictionary`, with recency refreshed by removing the key
/// and reinserting it at the end. That reads as O(1) and is not: an ordered
/// dictionary stores its keys and values in dense arrays, so removing anything
/// but the last element shifts every element after it. At the default bound of
/// 10,000 entries, **every cache hit** performed a ~10,000-element double-array
/// shift — and `entries.removeFirst()` in eviction did the same, under a
/// comment claiming O(1) per evicted entry.
///
/// The perf suite could not see it: it measured fresh-key *writes* at a bound
/// of 2,000 and never measured the cost of a hit, which is the operation a
/// cache performs most.
///
/// So the order is an intrusive doubly-linked list threaded through the
/// entries themselves, keyed by storage key. Touch, insert, evict and remove
/// are all pointer rewrites: genuinely O(1), at every bound.
public actor InMemoryCache: Cache {
    public static let defaultMaxEntries = 10_000

    /// A node in the recency list. `previous`/`next` are storage keys rather
    /// than references, so the whole structure stays a value type inside the
    /// actor and there is no retain traffic on the hot path.
    private struct Entry {
        let namespace: String
        var data: Data
        var expiresAt: ContinuousClock.Instant?
        var previous: String?
        var next: String?
    }

    /// Keyed by `CacheKey.storageKey`.
    private var entries: [String: Entry] = [:]
    /// Least recently used — the eviction end.
    private var head: String?
    /// Most recently used — where a touch moves an entry to.
    private var tail: String?

    private let clock = ContinuousClock()
    public nonisolated let maxEntries: Int

    public init(maxEntries: Int = InMemoryCache.defaultMaxEntries) {
        precondition(maxEntries > 0, "InMemoryCache is bounded by design — maxEntries must be positive.")
        self.maxEntries = maxEntries
        entries.reserveCapacity(min(maxEntries, 1024))
    }

    public func get(_ key: CacheKey) async -> Data? {
        let storageKey = key.storageKey
        guard let entry = entries[storageKey] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= clock.now {
            remove(storageKey)
            return nil
        }
        touch(storageKey)
        return entry.data
    }

    public func set(_ key: CacheKey, value: Data, ttl: Duration?) async {
        let storageKey = key.storageKey
        let expiresAt = ttl.map { clock.now.advanced(by: $0) }

        if entries[storageKey] != nil {
            entries[storageKey]!.data = value
            entries[storageKey]!.expiresAt = expiresAt
            touch(storageKey)
            return
        }

        entries[storageKey] = Entry(
            namespace: key.namespace, data: value, expiresAt: expiresAt,
            previous: tail, next: nil)
        if let tail {
            entries[tail]!.next = storageKey
        } else {
            head = storageKey
        }
        tail = storageKey
        enforceBound()
    }

    public func evict(_ key: CacheKey) async {
        remove(key.storageKey)
    }

    public func evictNamespace(_ namespace: String) async {
        let doomed = entries.compactMap { key, entry in
            entry.namespace == namespace ? key : nil
        }
        for key in doomed {
            remove(key)
        }
    }

    /// Live entry count, expired entries included until touched or swept —
    /// introspection for tests.
    public var count: Int { entries.count }

    // MARK: - The recency list

    /// Moves `storageKey` to the most-recently-used end. Pointer rewrites
    /// only: this is what every cache hit pays, so it has to be free.
    private func touch(_ storageKey: String) {
        guard tail != storageKey, let entry = entries[storageKey] else { return }
        unlink(storageKey, entry)
        entries[storageKey]!.previous = tail
        entries[storageKey]!.next = nil
        if let tail { entries[tail]!.next = storageKey }
        tail = storageKey
        if head == nil { head = storageKey }
    }

    private func remove(_ storageKey: String) {
        guard let entry = entries.removeValue(forKey: storageKey) else { return }
        unlink(storageKey, entry)
    }

    /// Takes `storageKey` out of the order, leaving its dictionary slot alone.
    private func unlink(_ storageKey: String, _ entry: Entry) {
        if let previous = entry.previous {
            entries[previous]?.next = entry.next
        } else if head == storageKey {
            head = entry.next
        }
        if let next = entry.next {
            entries[next]?.previous = entry.previous
        } else if tail == storageKey {
            tail = entry.previous
        }
    }

    // MARK: - Bounding

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

        // The eviction candidate is the least-recently-used entry, and if it
        // happens to be expired it is being removed for two reasons at once.
        // O(1) per evicted entry, and now that is true rather than asserted.
        while entries.count > maxEntries, let oldest = head {
            remove(oldest)
        }
    }

    /// Drops every entry whose TTL has passed. O(n), so callers amortize it.
    private func sweepExpired() {
        let now = clock.now
        let expired = entries.compactMap { key, entry in
            (entry.expiresAt.map { $0 <= now } ?? false) ? key : nil
        }
        for key in expired {
            remove(key)
        }
    }
}

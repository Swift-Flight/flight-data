import FlightCache
import Foundation
import Synchronization

/// A `Cache` that records every operation and serves from a plain
/// dictionary — for consumers (and this package's own suites) to assert
/// cache interactions without a real store. The §7 analogue of PubSub's
/// `RecordingAdapter`.
///
/// `misbehave()` turns every subsequent `get` into a miss and drops every
/// `set` — the observable behavior of a downed backing store behind a
/// fail-open adapter — for exercising degraded paths.
public final class RecordingCache: Cache, Sendable {
    public enum Operation: Sendable, Equatable {
        case get(String)
        case set(String, ttl: Duration?)
        case evict(String)
        case evictNamespace(String)
    }

    private struct State {
        var entries: [String: (namespace: String, data: Data)] = [:]
        var ttls: [String: Duration?] = [:]
        var operations: [Operation] = []
        var misbehaving = false
    }

    private let state = Mutex<State>(State())

    public init() {}

    public func get(_ key: CacheKey) async -> Data? {
        state.withLock { state in
            state.operations.append(.get(key.storageKey))
            guard !state.misbehaving else { return nil }
            return state.entries[key.storageKey]?.data
        }
    }

    public func set(_ key: CacheKey, value: Data, ttl: Duration?) async {
        state.withLock { state in
            state.operations.append(.set(key.storageKey, ttl: ttl))
            guard !state.misbehaving else { return }
            state.entries[key.storageKey] = (key.namespace, value)
            state.ttls[key.storageKey] = ttl
        }
    }

    public func evict(_ key: CacheKey) async {
        state.withLock { state in
            state.operations.append(.evict(key.storageKey))
            state.entries.removeValue(forKey: key.storageKey)
            state.ttls.removeValue(forKey: key.storageKey)
        }
    }

    public func evictNamespace(_ namespace: String) async {
        state.withLock { state in
            state.operations.append(.evictNamespace(namespace))
            for (storageKey, entry) in state.entries where entry.namespace == namespace {
                state.entries.removeValue(forKey: storageKey)
                state.ttls.removeValue(forKey: storageKey)
            }
        }
    }

    // MARK: - Seeding and inspection

    /// Seeds an entry directly — for staging hits and stale bytes.
    public func seed(_ key: CacheKey, data: Data, ttl: Duration? = nil) {
        state.withLock { state in
            state.entries[key.storageKey] = (key.namespace, data)
            state.ttls[key.storageKey] = ttl
        }
    }

    /// From now on: every get misses, every set is dropped.
    public func misbehave() {
        state.withLock { $0.misbehaving = true }
    }

    public var operations: [Operation] {
        state.withLock { $0.operations }
    }

    public func data(for key: CacheKey) -> Data? {
        state.withLock { $0.entries[key.storageKey]?.data }
    }

    /// The TTL the last `set` for this key carried (nil = stored with no
    /// expiry; absent = never stored).
    public func ttl(for key: CacheKey) -> Duration?? {
        state.withLock { $0.ttls[key.storageKey] }
    }

    public var entryCount: Int {
        state.withLock { $0.entries.count }
    }
}

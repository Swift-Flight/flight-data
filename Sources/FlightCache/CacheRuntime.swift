import FlightCore
import Foundation
import Logging
import Metrics
import Synchronization

/// The runtime entry points the §3.1 expansions call — key assembly, `get`,
/// decode, single-flight (§8), the body call, encode, `set`, and metrics
/// all live here, so the macro expansions stay small and the behavior is
/// testable without macros.
///
/// Every operation upholds §7's invariant through the `Cache` protocol's
/// own shape: no store method throws, a decode failure is a miss (§5), an
/// encode failure skips the `set` and still returns the computed value.
public final class CacheRuntime: Sendable {
    public let store: any Cache
    let codec: any CacheCodec
    let ttls: CacheTTLPolicy
    let flights: SingleFlight
    let logger: Logger

    private let namespaceMetrics = Mutex<[String: NamespaceMetrics]>([:])

    /// How many times a waiter whose leader was cancelled re-enters the
    /// flow before computing directly (§8).
    private static let leaderCancelledRetries = 3

    public init(
        store: any Cache,
        configuration: Configuration? = nil,
        codec: any CacheCodec = JSONCacheCodec(),
        logger: Logger = Logger(label: "flight.cache")
    ) throws {
        self.store = store
        self.codec = codec
        self.logger = logger
        self.ttls = try CacheTTLPolicy(configuration: configuration, logger: logger)
        self.flights = SingleFlight()
    }

    // MARK: - @Cacheable (throwing)

    /// Check cache; on hit return it; on miss coalesce concurrent callers
    /// (§8) and compute once. The `as:` parameter pins `Value` for
    /// expansion-site clarity.
    public func cacheable<Value: Codable & Sendable>(
        namespace: String,
        parts: [String],
        ttl: Duration?,
        as type: Value.Type = Value.self,
        _ body: () async throws -> Value
    ) async throws -> Value {
        let key = CacheKey(namespace: namespace, parts: parts)
        if let value: Value = await fetch(key, recordMetrics: true) {
            return value
        }

        var attempts = 0
        while true {
            switch await flights.join(key) {
            case .lead:
                do {
                    // Double-check after winning leadership (§8): between
                    // this caller's miss and its flight entry, a previous
                    // flight may have completed and populated the entry.
                    if let data = await store.get(key), let value: Value = decodeOrNil(data, for: key) {
                        await flights.complete(key, with: .success(data))
                        counters(for: namespace).hits.increment()
                        return value
                    }
                    let value = try await body()
                    let encoded = await storeIfCacheable(value, key: key, namespace: namespace, annotationTTL: ttl)
                    await flights.complete(key, with: .success(encoded))
                    return value
                } catch {
                    await flights.complete(
                        key, with: error is CancellationError ? .leaderCancelled : .failure(error))
                    throw error
                }

            case .wait(let outcome):
                counters(for: namespace).coalesced.increment()
                switch outcome {
                case .success(let data):
                    if let data, let value: Value = decodeOrNil(data, for: key) {
                        return value
                    }
                    // The leader had nothing publishable (nil result,
                    // encode failure, or a cross-method type mismatch on
                    // decode) — compute independently, without re-joining:
                    // a second coalescing round on bytes that already
                    // failed once would loop.
                    let value = try await body()
                    _ = await storeIfCacheable(value, key: key, namespace: namespace, annotationTTL: ttl)
                    return value
                case .failure(let error):
                    throw error
                case .leaderCancelled:
                    attempts += 1
                    if attempts < Self.leaderCancelledRetries { continue }
                    let value = try await body()
                    _ = await storeIfCacheable(value, key: key, namespace: namespace, annotationTTL: ttl)
                    return value
                }
            }
        }
    }

    // MARK: - @Cacheable (non-throwing)

    /// The non-throwing twin — a non-throwing method body cannot `try`, and
    /// a waiter here cannot rethrow a throwing leader's error (possible
    /// only via a cross-method shared key), so every failure path computes
    /// directly instead.
    public func cacheable<Value: Codable & Sendable>(
        namespace: String,
        parts: [String],
        ttl: Duration?,
        as type: Value.Type = Value.self,
        _ body: () async -> Value
    ) async -> Value {
        let key = CacheKey(namespace: namespace, parts: parts)
        if let value: Value = await fetch(key, recordMetrics: true) {
            return value
        }

        switch await flights.join(key) {
        case .lead:
            if let data = await store.get(key), let value: Value = decodeOrNil(data, for: key) {
                await flights.complete(key, with: .success(data))
                counters(for: namespace).hits.increment()
                return value
            }
            let value = await body()
            let encoded = await storeIfCacheable(value, key: key, namespace: namespace, annotationTTL: ttl)
            await flights.complete(key, with: .success(encoded))
            return value

        case .wait(let outcome):
            counters(for: namespace).coalesced.increment()
            if case .success(let data) = outcome, let data,
                let value: Value = decodeOrNil(data, for: key)
            {
                return value
            }
            let value = await body()
            _ = await storeIfCacheable(value, key: key, namespace: namespace, annotationTTL: ttl)
            return value
        }
    }

    // MARK: - @CachePut

    /// Always overwrite (§3): the annotated body has already run; store its
    /// result. Never short-circuits, never coalesces.
    public func cachePut<Value: Codable & Sendable>(
        namespace: String,
        parts: [String],
        ttl: Duration?,
        value: Value
    ) async {
        let key = CacheKey(namespace: namespace, parts: parts)
        if await storeIfCacheable(value, key: key, namespace: namespace, annotationTTL: ttl) != nil {
            counters(for: namespace).puts.increment()
        }
    }

    // MARK: - @CacheEvict

    /// Remove one entry (`parts` given) or the whole namespace (`parts:
    /// nil`, the annotation's `allEntries: true`).
    public func evict(namespace: String, parts: [String]?) async {
        if let parts {
            await store.evict(CacheKey(namespace: namespace, parts: parts))
        } else {
            await store.evictNamespace(namespace)
        }
        counters(for: namespace).evictions.increment()
    }

    // MARK: - Shared plumbing

    private func fetch<Value: Decodable>(_ key: CacheKey, recordMetrics: Bool) async -> Value? {
        guard let data = await store.get(key) else {
            if recordMetrics { counters(for: key.namespace).misses.increment() }
            return nil
        }
        guard let value: Value = decodeOrNil(data, for: key) else {
            if recordMetrics { counters(for: key.namespace).misses.increment() }
            return nil
        }
        if recordMetrics { counters(for: key.namespace).hits.increment() }
        return value
    }

    /// §5's fail-open decode: a decode failure is a miss, never an error —
    /// old entries that no longer decode are ignored and overwritten.
    private func decodeOrNil<Value: Decodable>(_ data: Data, for key: CacheKey) -> Value? {
        do {
            return try codec.decode(Value.self, from: data)
        } catch {
            logger.debug("cached entry no longer decodes; treating as miss", metadata: [
                "key": "\(key.storageKey)", "type": "\(Value.self)", "error": "\(error)",
            ])
            return nil
        }
    }

    /// Encodes and stores `value` unless it is a `nil` result (§5: absence
    /// is not cached) or encoding fails (§5: logged, skipped). Returns the
    /// encoded bytes when stored — what the leader publishes to waiters.
    private func storeIfCacheable<Value: Codable & Sendable>(
        _ value: Value, key: CacheKey, namespace: String, annotationTTL: Duration?
    ) async -> Data? {
        if case Optional<Any>.none = (value as Any) {
            return nil
        }
        let encoded: Data
        do {
            encoded = try codec.encode(value)
        } catch {
            logger.warning("cache value failed to encode; result returned uncached", metadata: [
                "key": "\(key.storageKey)", "type": "\(Value.self)", "error": "\(error)",
            ])
            return nil
        }
        let ttl = ttls.effectiveTTL(namespace: namespace, annotation: annotationTTL)
        await store.set(key, value: encoded, ttl: ttl)
        return encoded
    }

    // MARK: - Metrics (§7)

    private struct NamespaceMetrics {
        let hits: Counter
        let misses: Counter
        let puts: Counter
        let evictions: Counter
        let coalesced: Counter

        init(namespace: String) {
            let dimensions = [("namespace", namespace)]
            hits = Counter(label: "flight.cache.hits", dimensions: dimensions)
            misses = Counter(label: "flight.cache.misses", dimensions: dimensions)
            puts = Counter(label: "flight.cache.puts", dimensions: dimensions)
            evictions = Counter(label: "flight.cache.evictions", dimensions: dimensions)
            coalesced = Counter(label: "flight.cache.coalesced", dimensions: dimensions)
        }
    }

    private func counters(for namespace: String) -> NamespaceMetrics {
        namespaceMetrics.withLock { memo in
            if let existing = memo[namespace] { return existing }
            let created = NamespaceMetrics(namespace: namespace)
            memo[namespace] = created
            return created
        }
    }
}

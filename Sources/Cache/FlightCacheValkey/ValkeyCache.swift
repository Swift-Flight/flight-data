import FlightCache
import Foundation
import Logging
import Metrics
import Synchronization
import Valkey

/// The Valkey/Redis-backed `Cache` — working against either
/// server unchanged. Namespaces map to key prefixes, TTL maps to native
/// expiry (`SET` with `PX`), so the store handles expiration rather than
/// Flight polling for it.
///
/// Unlike Flight Data Valkey's pool, this adapter holds a `ValkeyClient` —
/// the driver's own pool, already a ServiceLifecycle `Service` — because
/// the cache seam is async end to end (none of Data Valkey delta V1's
/// synchronous-checkout tension applies).
///
/// invariant, upheld here: every operation fails open. Errors are
/// caught, logged, counted (`flight.cache.store_errors`), and answered with
/// a miss/no-op.
///
/// ## The two timeout phases, and who owns each (delta CV1)
///
/// A cache call spends time in two places, and the driver bounds them with
/// two different settings — configuring only one leaves the other unbounded:
///
/// 1. **Obtaining a connection.** Bounded by the pool's
///    `circuitBreakerTripAfter`, set here from `unreachable_after_ms`. At
///    the driver's 60-second default, the first call against a downed
///    server hangs for a *minute* — measured, and precisely the hung lookup
///    forbids. Configured short, the pool declares the server
///    unreachable quickly and every later call fails in microseconds until
///    it recovers.
/// 2. **Executing the command.** Bounded by `commandTimeout`, which starts
///    only once a connection is leased and so never fires in case 1.
///
/// ## Two breakers, two jobs
///
/// The driver's pool breaker owns *connection* health — it is authoritative,
/// self-healing, and already fails in microseconds once open, so this
/// adapter neither duplicates nor second-guesses it. This adapter's own
/// `Breaker` owns what the pool cannot see: a server that accepts
/// connections but whose commands fail or time out, where asks us to
/// stop paying the timeout on every request. `classify(_:)` keeps that
/// division honest — see it for which failures count.
public final class ValkeyCache: Cache, Sendable {
    /// Every stored key: `flight-cache:` + `CacheKey.storageKey` — one
    /// recognizable, greppable prefix in a store that may hold non-cache
    /// data too.
    public static let keyPrefix = "flight-cache:"
    /// breaker: consecutive failures before the store is skipped…
    public static let defaultBreakerThreshold = 5
    /// …and for how long.
    public static let defaultBreakerCoolOff: Duration = .seconds(3)
    /// SCAN batch size for namespace eviction.
    static let scanBatchSize = 500

    /// The underlying client, for commands this adapter does not wrap.
    ///
    /// **Nothing sent through here passes the circuit breaker**, and no
    /// failure it produces counts toward tripping one. That is the point of
    /// an escape hatch, but it means a caller leaning on it during an outage
    /// gets none of the fail-open behaviour the `Cache` methods have — the
    /// call throws instead of degrading, and the breaker never learns the
    /// store is unwell.
    public let client: ValkeyClient
    private let logger: Logger
    private let breaker: Breaker
    private let storeErrors = Counter(label: "flight.cache.store_errors", dimensions: [("store", "valkey")])

    public init(
        settings: ValkeyCacheSettings,
        breakerThreshold: Int = ValkeyCache.defaultBreakerThreshold,
        breakerCoolOff: Duration = ValkeyCache.defaultBreakerCoolOff,
        logger: Logger? = nil
    ) throws {
        let logger = logger ?? Logger(label: "flight.cache.valkey")
        self.client = ValkeyClient(
            settings.url.address,
            configuration: try settings.clientConfiguration(),
            logger: logger
        )
        self.logger = logger
        self.breaker = Breaker(threshold: breakerThreshold, coolOff: breakerCoolOff)
    }

    // MARK: - Cache

    public func get(_ key: CacheKey) async -> Data? {
        guard breaker.admit() else { return nil }
        do {
            let response = try await client.get(storageKey(key))
            breaker.recordSuccess()
            return response.map { Data($0) }
        } catch {
            noteFailure("get", error: error)
            return nil
        }
    }

    public func set(_ key: CacheKey, value: Data, ttl: Duration?) async {
        guard breaker.admit() else { return }
        // A TTL that has already run out is not a set with a negative expiry —
        // that would tell the server to delete the key — it is a value not
        // worth caching. Nothing to do, locally, without a round trip.
        if let ttl, ttl.wholeMillisecondsIfPositive == nil { return }
        do {
            try await client.set(
                storageKey(key),
                value: value,
                expiration: ttl.flatMap { $0.wholeMillisecondsIfPositive }.map { .milliseconds($0) }
            )
            breaker.recordSuccess()
        } catch {
            noteFailure("set", error: error)
        }
    }

    public func evict(_ key: CacheKey) async {
        guard breaker.admit() else { return }
        do {
            _ = try await client.unlink(keys: [storageKey(key)])
            breaker.recordSuccess()
        } catch {
            noteFailure("evict", error: error)
        }
    }

    ///: `SCAN MATCH <prefix>* + UNLINK`, honest about being O(keys)
    /// and non-atomic — entries written concurrently with the scan may
    /// survive it. Acceptable for the blunt instrument says this is.
    public func evictNamespace(_ namespace: String) async {
        guard breaker.admit() else { return }
        let pattern = Self.globEscaped(Self.keyPrefix + CacheKey.storagePrefix(namespace: namespace)) + "*"
        do {
            var cursor = 0
            repeat {
                let reply = try await client.scan(
                    cursor: cursor, pattern: pattern, count: Self.scanBatchSize)
                cursor = reply.cursor
                // Decoded straight to `ValkeyKey` rather than to `[String]`
                // and re-wrapped one at a time — the round trip through String
                // bought nothing but an allocation per key.
                let keys = try reply.keys.decode(as: [ValkeyKey].self)
                if !keys.isEmpty {
                    _ = try await client.unlink(keys: keys)
                }
            } while cursor != 0
            breaker.recordSuccess()
        } catch {
            noteFailure("evictNamespace", error: error)
        }
    }

    // MARK: - Introspection (tests, diagnostics)

    /// Whether the breaker is currently skipping the store.
    public var isCoolingOff: Bool { breaker.isCoolingOff }

    // MARK: - Plumbing

    private func storageKey(_ key: CacheKey) -> ValkeyKey {
        ValkeyKey(Self.keyPrefix + key.storageKey)
    }

    /// What a failure says about the *store's* health — a different
    /// question from "did this call fail", and the distinction the adapter
    /// breaker depends on.
    enum Failure: Equatable {
        /// Evidence the store is unhealthy in a way the pool cannot see —
        /// chiefly `.timeout`: the server accepted a connection and then
        /// failed to answer. This is exactly what means by "stop paying
        /// the timeout on every request".
        case storeUnhealthy
        /// A real failure, but no evidence about store health, so it must
        /// not push the breaker toward tripping:
        ///
        /// - `.connectionCreationCircuitBreakerTripped` — the pool's own
        ///   breaker is already open. It is authoritative for connection
        ///   health, already fails in microseconds, and self-heals;
        ///   shadowing it with our cool-off would only delay recovery.
        /// - `.cancelled` / `.connectionClosedDueToCancellation` — the
        ///   *caller's* task went away. Counting these would let a burst of
        ///   client disconnects darken the cache for everyone else.
        /// - `.clientIsShutDown` — orderly shutdown, not ill health.
        case notStoreHealth
    }

    /// Whether a failure is evidence the *store* is unwell, or just evidence
    /// that one command did not work.
    ///
    /// This used to answer `.storeUnhealthy` for everything but a short list
    /// of connectivity codes, which put command errors in the same bucket as
    /// a dead server. They are not the same thing at all: a server that
    /// answers `WRONGTYPE` is a healthy server declining one command.
    ///
    /// Counting those toward the breaker made a single poisoned key — one
    /// entry holding a value of the wrong type, one value large enough to be
    /// refused — black out **the entire cache, every namespace**. Worse, it
    /// stayed out: the half-open probe is whatever request arrives next,
    /// which for a hot key is very often the same poisoned one, so the
    /// breaker re-tripped on the same key indefinitely. Nothing recovered it
    /// but a restart, and nothing in the logs pointed at the key.
    ///
    /// The breaker exists for a store that is unreachable or failing wholesale.
    /// A per-command refusal fails that one operation open and nothing else.
    static func classify(_ error: any Error) -> Failure {
        if error is CancellationError { return .notStoreHealth }
        guard let clientError = error as? ValkeyClientError else { return .storeUnhealthy }
        switch clientError.errorCode {
        case .connectionCreationCircuitBreakerTripped, .clientIsShutDown,
            .cancelled, .connectionClosedDueToCancellation:
            return .notStoreHealth

        // The server answered. It said no to this command — wrong type for
        // the key, a value it will not store, a rejected argument — which
        // says nothing about whether it can serve the next one.
        case .commandError, .subscriptionError, .respDecodeError:
            return .notStoreHealth

        // Everything else — connection closed, timeout, parse failure,
        // cluster/sentinel trouble — is the store not working.
        default:
            return .storeUnhealthy
        }
    }

    private func noteFailure(_ operation: String, error: any Error) {
        storeErrors.increment()
        guard Self.classify(error) == .storeUnhealthy else {
            logger.debug("valkey cache operation failed open", metadata: [
                "operation": "\(operation)", "error": "\(error)",
            ])
            return
        }
        if breaker.recordFailure() {
            logger.warning("valkey cache breaker tripped; skipping the store during cool-off", metadata: [
                "operation": "\(operation)", "error": "\(error)",
            ])
        } else {
            logger.debug("valkey cache operation failed open", metadata: [
                "operation": "\(operation)", "error": "\(error)",
            ])
        }
    }

    /// Escapes glob metacharacters so an exotic (escaped) namespace can
    /// never widen the MATCH pattern.
    static func globEscaped(_ literal: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(literal.count)
        for character in literal {
            if character == "*" || character == "?" || character == "[" || character == "]"
                || character == "\\"
            {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// The consecutive-failure breaker: after `threshold` failures in a
    /// row, `admit()` answers false until `coolOff` has elapsed. One probe
    /// re-closes it on success (or restarts the cool-off on failure).
    final class Breaker: Sendable {
        private struct State {
            var consecutiveFailures = 0
            var reopenAt: ContinuousClock.Instant?
            /// A half-open probe is out. Holds the gate shut for everyone
            /// else until it reports back.
            var probeInFlight = false
        }

        private let threshold: Int
        private let coolOff: Duration
        private let clock = ContinuousClock()
        private let state = Mutex(State())

        init(threshold: Int, coolOff: Duration) {
            precondition(threshold > 0)
            self.threshold = threshold
            self.coolOff = coolOff
        }

        func admit() -> Bool {
            state.withLock { state in
                guard let reopenAt = state.reopenAt else { return true }  // closed
                guard reopenAt <= clock.now else { return false }         // open, cooling off
                // Half-open: exactly one probe.
                //
                // This used to clear `reopenAt` before returning, so every
                // caller arriving in the same window found the breaker closed
                // and went to the store — a hundred concurrent callers meant
                // a hundred probes against a server that had just been
                // failing, which is the stampede a breaker exists to prevent.
                // The flag is what makes "one" true.
                guard !state.probeInFlight else { return false }
                state.probeInFlight = true
                return true
            }
        }

        func recordSuccess() {
            state.withLock { state in
                state.consecutiveFailures = 0
                state.reopenAt = nil
                state.probeInFlight = false
            }
        }

        /// Returns true when this failure tripped the breaker.
        func recordFailure() -> Bool {
            state.withLock { state in
                let wasProbe = state.probeInFlight
                state.probeInFlight = false
                state.consecutiveFailures += 1

                if wasProbe {
                    // The half-open probe failed: straight back to cooling
                    // off, and reported as a trip, because the store going
                    // from "maybe recovered" to "still down" is worth a line.
                    state.reopenAt = clock.now.advanced(by: coolOff)
                    return true
                }
                guard state.consecutiveFailures >= threshold, state.reopenAt == nil else {
                    return false
                }
                state.reopenAt = clock.now.advanced(by: coolOff)
                return true
            }
        }

        var isCoolingOff: Bool {
            state.withLock { state in
                guard let reopenAt = state.reopenAt else { return false }
                return reopenAt > clock.now
            }
        }
    }
}

extension Duration {
    /// Whole milliseconds for `PX`, clamped up so a positive sub-millisecond
    /// TTL never becomes "delete now" — the same rule as Flight Data Valkey's
    /// delta V3.
    ///
    /// `nil` for a duration that is not positive. A negative TTL means the
    /// caller's arithmetic ran off the end of a deadline that has already
    /// passed, and `PX` with a negative timeout **deletes the key**: the guard
    /// used to test `attoseconds > 0`, which a negative duration passes
    /// (`-0.5s` is seconds `0`, attoseconds negative — and `-1.5s` is seconds
    /// `-1`, attoseconds `-5e17`, so the sign lives in whichever component is
    /// non-zero). The result went to the server and the set failed open per
    /// call instead of no-opping locally.
    var wholeMillisecondsIfPositive: Int? {
        guard self > .zero else { return nil }
        let milliseconds =
            components.seconds * 1000 + Int64(components.attoseconds / 1_000_000_000_000_000)
        return milliseconds <= 0 ? 1 : Int(milliseconds)
    }
}

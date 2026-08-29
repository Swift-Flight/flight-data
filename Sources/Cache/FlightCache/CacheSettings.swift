import FlightCore
import Logging
import Synchronization

/// The `cache.*` config vocabulary, following Flight Data
/// Core's `DataSourceConfigKey` shape. TTL values are integer seconds —
/// flight-config numbers are plain `Int`s; no duration syntax is invented
/// here. Namespace names should stick to lowercase letters, digits,
/// underscores, and dots: the env-var override layer maps keys
/// through `FLIGHT_` + uppercase + `.`→`_`, and a hyphenated name produces
/// a variable shells cannot set.
public enum CacheConfigKey {
    public static let root = "cache"
    /// `cache.default_ttl` — integer seconds; the fallback when neither the
    /// annotation nor the namespace names a TTL. 0 means "no default".
    public static let defaultTTL = "cache.default_ttl"
    /// `cache.namespaces.<name>` — integer seconds for one namespace.
    ///
    /// `0` here means "this namespace names no TTL of its own", so
    /// ``defaultTTL`` applies — which is *not* what `0` means at
    /// `cache.default_ttl`, where it means there is no default and entries
    /// never expire. The asymmetry is deliberate: a zero typed under a
    /// namespace almost always means "I have not decided", and a zero typed
    /// at the root almost always means "nothing expires unless it says so".
    public static func namespaceTTL(_ namespace: String) -> String {
        "cache.namespaces.\(namespace)"
    }
    /// `cache.memory.max_entries` — the in-memory adapter's LRU bound.
    public static let memoryMaxEntries = "cache.memory.max_entries"
}

/// Semantic rejections of values that were present and readable — distinct
/// from `ConfigError` (missing/undecodable), same split as
/// `DataSourceConfigurationError`.
public enum CacheConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case negativeDefaultTTL(Int)
    case invalidMaxEntries(Int)

    public var description: String {
        switch self {
        case .negativeDefaultTTL(let seconds):
            return "\(CacheConfigKey.defaultTTL) is \(seconds) — a TTL cannot be negative. Use 0 for \"no default TTL\"."
        case .invalidMaxEntries(let count):
            return "\(CacheConfigKey.memoryMaxEntries) is \(count) — the in-memory cache is bounded by design; use a positive entry count."
        }
    }
}

/// The TTL policy: annotation `ttl:` > `cache.namespaces.<name>` >
/// `cache.default_ttl` > no expiry.
///
/// The default is read (and validated) eagerly — at `CacheRuntime`
/// construction, which the module runs at `freeze()`, so a bad value fails
/// bootstrap. Per-namespace values load lazily per namespace and memoize:
/// `Configuration` exposes point lookups only (no enumeration under
/// `cache.namespaces.*`), and the namespace set is known at the annotation
/// sites, not in config. A malformed per-namespace value is logged and
/// ignored (the default applies) — a config typo must not become a runtime
/// error on a hot path.
public final class CacheTTLPolicy: Sendable {
    private let configuration: Configuration?
    private let defaultTTL: Duration?
    private let logger: Logger
    private let memoizedNamespaceTTLs = Mutex<[String: Duration?]>([:])

    /// Reads and validates `cache.default_ttl`. Throws — callers run at
    /// bootstrap, where failing loudly is correct.
    public init(configuration: Configuration?, logger: Logger) throws {
        self.configuration = configuration
        self.logger = logger
        if let configuration,
            let seconds = try configuration.getIfPresent(CacheConfigKey.defaultTTL, as: Int.self)
        {
            guard seconds >= 0 else { throw CacheConfigurationError.negativeDefaultTTL(seconds) }
            self.defaultTTL = seconds == 0 ? nil : .seconds(seconds)
        } else {
            self.defaultTTL = nil
        }
    }

    /// The effective TTL for one entry. `annotation` is the macro's `ttl:`
    /// argument; nil means "consult the policy".
    public func effectiveTTL(namespace: String, annotation: Duration?) -> Duration? {
        if let annotation { return annotation }
        let namespaceTTL = memoizedNamespaceTTLs.withLock { memo -> Duration?? in
            memo[namespace]
        }
        if let namespaceTTL { return namespaceTTL ?? defaultTTL }
        let loaded = loadNamespaceTTL(namespace)
        memoizedNamespaceTTLs.withLock { memo in
            memo[namespace] = loaded
        }
        return loaded ?? defaultTTL
    }

    private func loadNamespaceTTL(_ namespace: String) -> Duration? {
        guard let configuration else { return nil }
        let key = CacheConfigKey.namespaceTTL(namespace)
        do {
            guard let seconds = try configuration.getIfPresent(key, as: Int.self) else { return nil }
            // Note that `0` here is not what `0` means at `cache.default_ttl`.
            // There it means "no default, entries never expire"; here it falls
            // through to the default, because "this namespace has no TTL of its
            // own" is the far more likely reading of a zero someone typed under
            // a namespace. Same value, two meanings, so: said out loud, and
            // logged at debug rather than silently.
            guard seconds > 0 else {
                if seconds < 0 {
                    logger.error("ignoring negative per-namespace TTL; the default applies", metadata: [
                        "key": "\(key)", "value": "\(seconds)",
                    ])
                } else {
                    logger.debug(
                        "per-namespace TTL of 0 means 'no TTL of its own', so the default applies — unlike cache.default_ttl: 0, which means no default at all",
                        metadata: ["key": "\(key)"])
                }
                return nil
            }
            return .seconds(seconds)
        } catch {
            logger.error("ignoring undecodable per-namespace TTL; the default applies", metadata: [
                "key": "\(key)", "error": "\(error)",
            ])
            return nil
        }
    }
}

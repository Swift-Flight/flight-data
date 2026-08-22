import FlightCache
import Foundation
import NIOSSL
import Valkey

/// The `cache.valkey.*` config vocabulary — this package's own root, NOT
/// the `datasource.*` convention: choosing Valkey for caching does not
/// require adopting it as a data store (design §2.1, Data Valkey §1.1).
public enum ValkeyCacheConfigKey {
    public static let root = "cache.valkey"
    /// `cache.valkey.url` — required. `valkey://` and `redis://` are exact
    /// synonyms (`valkeys://`/`rediss://` for TLS), same as Data Valkey §3.
    public static let url = "cache.valkey.url"
    /// `cache.valkey.command_timeout_ms` — §7's short operation timeout,
    /// bounding a command that is already executing on a leased
    /// connection. Integer milliseconds; optional.
    public static let commandTimeoutMilliseconds = "cache.valkey.command_timeout_ms"
    /// `cache.valkey.unreachable_after_ms` — the other half of §7's
    /// timeout story, and the one that actually matters when the server is
    /// down: how long the pool may keep trying to establish a connection
    /// before declaring the server unreachable and failing operations
    /// immediately. Maps to the driver's
    /// `connectionPool.circuitBreakerTripAfter`. Defaults to the command
    /// timeout, so one knob covers both phases unless you split them.
    public static let unreachableAfterMilliseconds = "cache.valkey.unreachable_after_ms"
    /// `cache.valkey.pool_size` — maximum connections. The ceiling on
    /// concurrent in-flight cache commands; lease requests beyond it queue.
    public static let poolSize = "cache.valkey.pool_size"
    /// `cache.valkey.min_connections` — connections kept warm, so a cache
    /// read on a cold path does not pay a dial and the pool discovers an
    /// unreachable server at startup rather than on a request. Defaults
    /// to 1; 0 restores the driver's lazy behavior.
    public static let minimumConnections = "cache.valkey.min_connections"
}

/// Loaded, validated settings — read at the module factory, which runs at
/// `freeze()`, so a bad value fails bootstrap, never the first request.
public struct ValkeyCacheSettings: Sendable, Equatable {
    /// §7: short by default. Deliberately tighter than a data-store
    /// timeout — the fallback here is a computation the caller was prepared
    /// to run anyway.
    public static let defaultCommandTimeout: Duration = .milliseconds(250)
    /// The driver's own default is 20; kept, and now explicit and tunable
    /// because it is the ceiling on concurrent in-flight cache commands.
    public static let defaultPoolSize = 20
    /// One connection kept warm, unlike the driver's default of zero. Two
    /// reasons: a cache read on a cold path should not pay a dial, and —
    /// more importantly for §7 — the pool starts dialing when the service
    /// starts rather than when the first request arrives, so if the server
    /// is unreachable the pool has usually already given up (delta CV1)
    /// before any request can queue behind it.
    public static let defaultMinimumConnections = 1

    public let url: ValkeyCacheURL
    public let commandTimeout: Duration
    /// How long the pool may keep trying to connect before declaring the
    /// server unreachable (delta CV1). This — not `commandTimeout` — is
    /// what bounds an operation when the server is down.
    public let unreachableAfter: Duration
    public let poolSize: Int
    public let minimumConnections: Int

    public init(
        url: ValkeyCacheURL,
        commandTimeout: Duration = ValkeyCacheSettings.defaultCommandTimeout,
        unreachableAfter: Duration? = nil,
        poolSize: Int = ValkeyCacheSettings.defaultPoolSize,
        minimumConnections: Int = ValkeyCacheSettings.defaultMinimumConnections
    ) {
        self.url = url
        self.commandTimeout = commandTimeout
        self.unreachableAfter = unreachableAfter ?? commandTimeout
        self.poolSize = poolSize
        self.minimumConnections = minimumConnections
    }

    public static func load(from configuration: Configuration) throws -> ValkeyCacheSettings {
        let urlString: String = try configuration.get(ValkeyCacheConfigKey.url)
        let url = try ValkeyCacheURL.parse(urlString)

        let commandTimeout = try positiveDuration(
            ValkeyCacheConfigKey.commandTimeoutMilliseconds, from: configuration)
            ?? Self.defaultCommandTimeout
        let unreachableAfter = try positiveDuration(
            ValkeyCacheConfigKey.unreachableAfterMilliseconds, from: configuration)

        let poolSize =
            try configuration.getIfPresent(ValkeyCacheConfigKey.poolSize, as: Int.self)
            ?? Self.defaultPoolSize
        guard poolSize > 0 else {
            throw ValkeyCacheConfigurationError.invalidPoolSize(poolSize)
        }
        let minimumConnections =
            try configuration.getIfPresent(ValkeyCacheConfigKey.minimumConnections, as: Int.self)
            ?? min(Self.defaultMinimumConnections, poolSize)
        guard minimumConnections >= 0, minimumConnections <= poolSize else {
            throw ValkeyCacheConfigurationError.invalidMinimumConnections(
                minimumConnections, poolSize: poolSize)
        }

        return ValkeyCacheSettings(
            url: url,
            commandTimeout: commandTimeout,
            unreachableAfter: unreachableAfter,
            poolSize: poolSize,
            minimumConnections: minimumConnections
        )
    }

    private static func positiveDuration(
        _ key: String, from configuration: Configuration
    ) throws -> Duration? {
        guard let milliseconds = try configuration.getIfPresent(key, as: Int.self) else {
            return nil
        }
        guard milliseconds > 0 else {
            throw ValkeyCacheConfigurationError.invalidTimeout(key: key, milliseconds: milliseconds)
        }
        return .milliseconds(milliseconds)
    }

    /// The driver's client-level configuration: auth, database, TLS, and —
    /// the point of delta CV1 — both halves of the §7 timeout budget.
    ///
    /// `commandTimeout` bounds a command once a connection is leased. It
    /// does **nothing** while the pool is trying to obtain a connection, so
    /// against a downed server it never fires; the pool queues lease
    /// requests until its connection-creation circuit breaker trips, which
    /// at the driver's 60-second default is precisely the hung cache lookup
    /// §7 forbids. `circuitBreakerTripAfter` is therefore set from
    /// `unreachableAfter`: the pool gives up quickly, and every subsequent
    /// call fails in microseconds until the server comes back.
    public func clientConfiguration() throws -> ValkeyClientConfiguration {
        var configuration = ValkeyClientConfiguration()
        if let username = url.username, let password = url.password {
            configuration.authentication = .init(username: username, password: password)
        }
        configuration.databaseNumber = url.database
        configuration.commandTimeout = commandTimeout
        configuration.connectionPool = .init(
            minimumConnectionCount: minimumConnections,
            maximumConnectionSoftLimit: poolSize,
            maximumConnectionHardLimit: poolSize,
            circuitBreakerTripAfter: unreachableAfter
        )
        if url.useTLS {
            configuration.tls = try .enable(.makeClientConfiguration(), tlsServerName: url.host)
        }
        return configuration
    }
}

public enum ValkeyCacheConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidTimeout(key: String, milliseconds: Int)
    case invalidPoolSize(Int)
    case invalidMinimumConnections(Int, poolSize: Int)

    public var description: String {
        switch self {
        case .invalidTimeout(let key, let milliseconds):
            return "\(key) is \(milliseconds) — a §7 timeout must be a positive millisecond count."
        case .invalidPoolSize(let size):
            return "\(ValkeyCacheConfigKey.poolSize) is \(size) — the cache connection pool needs at least one connection."
        case .invalidMinimumConnections(let minimum, let poolSize):
            return "\(ValkeyCacheConfigKey.minimumConnections) is \(minimum), which must be between 0 and \(ValkeyCacheConfigKey.poolSize) (\(poolSize))."
        }
    }
}

/// The parsed `cache.valkey.url` — the same accepted shapes as Flight Data
/// Valkey's URL (§3.2 there), re-owned here because this package
/// deliberately does not depend on that one (§2.1):
///
///     valkey://localhost:6379
///     redis://localhost:6379            // same client, same behavior
///     valkey://:secret@host:6379/2      // password-only auth, database 2
///     rediss://user:secret@host:6380    // TLS (valkeys:// likewise)
public struct ValkeyCacheURL: Sendable, Equatable {
    public static let plainSchemes: Set<String> = ["valkey", "redis"]
    public static let tlsSchemes: Set<String> = ["valkeys", "rediss"]

    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?
    public let database: Int
    public let useTLS: Bool

    public static func parse(_ string: String) throws -> ValkeyCacheURL {
        guard let components = URLComponents(string: string), let scheme = components.scheme else {
            throw ValkeyCacheURLError.unparseable(url: string)
        }
        let useTLS: Bool
        if plainSchemes.contains(scheme) {
            useTLS = false
        } else if tlsSchemes.contains(scheme) {
            useTLS = true
        } else {
            throw ValkeyCacheURLError.unsupportedScheme(scheme: scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValkeyCacheURLError.missingHost
        }

        let database: Int
        let path = components.path
        if path.isEmpty || path == "/" {
            database = 0
        } else {
            let segment = String(path.dropFirst())
            guard !segment.contains("/"), let parsed = Int(segment), parsed >= 0 else {
                throw ValkeyCacheURLError.invalidDatabase(path: path)
            }
            database = parsed
        }

        // A username with no password can never authenticate (RESP AUTH is
        // a pair); silently dropping it would mask a typo.
        let password = components.password
        var username = components.user
        if username?.isEmpty == true { username = nil }
        if username != nil && password == nil {
            throw ValkeyCacheURLError.usernameWithoutPassword
        }

        return ValkeyCacheURL(
            host: host,
            port: components.port ?? 6379,
            username: password != nil ? (username ?? "default") : nil,
            password: password,
            database: database,
            useTLS: useTLS
        )
    }

    public var address: ValkeyServerAddress {
        .hostname(host, port: port)
    }
}

public enum ValkeyCacheURLError: Error, Sendable, Equatable, CustomStringConvertible {
    case unparseable(url: String)
    case unsupportedScheme(scheme: String)
    case missingHost
    case invalidDatabase(path: String)
    case usernameWithoutPassword

    public var description: String {
        switch self {
        case .unparseable(let url):
            return "\(ValkeyCacheConfigKey.url) '\(url)' is not a parseable URL."
        case .unsupportedScheme(let scheme):
            return "\(ValkeyCacheConfigKey.url) scheme '\(scheme)' is not supported — use valkey:// or redis:// (valkeys:///rediss:// for TLS)."
        case .missingHost:
            return "\(ValkeyCacheConfigKey.url) names no host."
        case .invalidDatabase(let path):
            return "\(ValkeyCacheConfigKey.url) path '\(path)' is not a database number — use a single non-negative integer segment, e.g. valkey://host:6379/2."
        case .usernameWithoutPassword:
            return "\(ValkeyCacheConfigKey.url) has a username but no password — RESP authentication needs both (or omit userinfo entirely)."
        }
    }
}

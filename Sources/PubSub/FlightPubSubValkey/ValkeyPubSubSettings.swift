import FlightCore
import Foundation
import NIOSSL
import Valkey

/// The `pubsub.valkey.*` config vocabulary — this package's own root, NOT the
/// `datasource.*` convention: choosing Valkey to carry PubSub between nodes
/// does not mean adopting it as a data store.
public enum ValkeyPubSubConfigKey {
    public static let root = "pubsub.valkey"
    /// `pubsub.valkey.url` — required. `valkey://` and `redis://` are exact
    /// synonyms; `valkeys://`/`rediss://` are the same with TLS.
    public static let url = "pubsub.valkey.url"
    /// `pubsub.valkey.channel` — the one channel every node publishes to and
    /// subscribes to. Optional.
    public static let channel = "pubsub.valkey.channel"
    /// `pubsub.valkey.command_timeout_ms` — bounds a command already
    /// executing on a leased connection. Optional.
    public static let commandTimeoutMilliseconds = "pubsub.valkey.command_timeout_ms"
    /// `pubsub.valkey.unreachable_after_ms` — the other half of the timeout
    /// story, and the one that matters when the server is down: how long the
    /// pool may keep trying to connect before failing operations immediately
    /// rather than queueing them behind a dial that will not complete.
    /// Optional; defaults to the command timeout.
    public static let unreachableAfterMilliseconds = "pubsub.valkey.unreachable_after_ms"
    /// `pubsub.valkey.retry_delay_ms` — the first delay before re-subscribing
    /// after the connection drops. It grows and is jittered from there.
    public static let retryDelayMilliseconds = "pubsub.valkey.retry_delay_ms"
}

/// Where the adapter connects, and on which channel.
///
/// ```yaml
/// pubsub:
///   valkey:
///     url: valkeys://user:secret@localhost:6379/0
///     channel: flight-pubsub        # optional
/// ```
///
/// Parsed at the component factory, which runs at `freeze()` — so a malformed
/// URL fails bootstrap rather than the first broadcast. Same posture as every
/// other driver here.
///
/// ## Why this shares the cache adapter's shapes (delta PV1)
///
/// This started as its own smaller URL parser and its own bare client
/// configuration, and both were wrong in ways the cache adapter had already
/// got right. `rediss://` was accepted and TLS was never enabled, so a
/// deployment that asked for encryption sent `AUTH` over plaintext RESP —
/// the credential leaked on exactly the path the operator asked to protect.
/// `valkey://:secret@host` set a password with no username and the
/// `if let username, let password` guard then skipped authentication
/// altogether. And none of the cache adapter's timeout hardening was here, so
/// a downed server meant a publish queued behind the driver's 60-second
/// connection-creation breaker.
///
/// The accepted URL shapes and the client configuration are therefore the same
/// as `ValkeyCacheSettings`', deliberately. The two are not shared in code
/// because this target does not depend on FlightCacheValkey; they are kept the
/// same by saying so here and by the tests below each of them.
public struct ValkeyPubSubSettings: Sendable, Equatable {
    /// Short by default: PubSub is at-most-once and fire-and-forget, so a slow
    /// publish is worth abandoning rather than waiting out.
    public static let defaultCommandTimeout: Duration = .milliseconds(250)
    public static let defaultRetryDelay: Duration = .seconds(1)
    public static let defaultChannel = "flight-pubsub"

    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?
    public let database: Int
    public let useTLS: Bool
    public let commandTimeout: Duration
    public let unreachableAfter: Duration
    public let retryDelay: Duration

    /// The channel every node publishes to and subscribes to.
    ///
    /// One channel carries every topic: a Flight `Message` names its own
    /// topic, and a channel per topic would mean re-subscribing every time a
    /// socket joined a room. Override it to run two independent Flight
    /// clusters against one Valkey.
    public let channel: String

    public init(
        host: String, port: Int = 6379,
        username: String? = nil, password: String? = nil,
        database: Int = 0,
        useTLS: Bool = false,
        commandTimeout: Duration = ValkeyPubSubSettings.defaultCommandTimeout,
        unreachableAfter: Duration? = nil,
        retryDelay: Duration = ValkeyPubSubSettings.defaultRetryDelay,
        channel: String = ValkeyPubSubSettings.defaultChannel
    ) throws {
        guard !channel.isEmpty else { throw ValkeyPubSubConfigurationError.emptyChannel }
        guard commandTimeout > .zero else {
            throw ValkeyPubSubConfigurationError.invalidTimeout(
                key: ValkeyPubSubConfigKey.commandTimeoutMilliseconds, value: commandTimeout)
        }
        guard retryDelay > .zero else {
            throw ValkeyPubSubConfigurationError.invalidTimeout(
                key: ValkeyPubSubConfigKey.retryDelayMilliseconds, value: retryDelay)
        }
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.useTLS = useTLS
        self.commandTimeout = commandTimeout
        self.unreachableAfter = unreachableAfter ?? commandTimeout
        self.retryDelay = retryDelay
        self.channel = channel
    }

    /// Reads `pubsub.valkey.*`.
    public static func load(from configuration: Configuration) throws -> ValkeyPubSubSettings {
        guard let raw = try configuration.getIfPresent(
            ValkeyPubSubConfigKey.url, as: String.self)
        else {
            throw ValkeyPubSubConfigurationError.missingURL
        }
        let url = try parse(raw)

        return try ValkeyPubSubSettings(
            host: url.host,
            port: url.port,
            username: url.username,
            password: url.password,
            database: url.database,
            useTLS: url.useTLS,
            commandTimeout: try positiveDuration(
                ValkeyPubSubConfigKey.commandTimeoutMilliseconds, from: configuration)
                ?? defaultCommandTimeout,
            unreachableAfter: try positiveDuration(
                ValkeyPubSubConfigKey.unreachableAfterMilliseconds, from: configuration),
            retryDelay: try positiveDuration(
                ValkeyPubSubConfigKey.retryDelayMilliseconds, from: configuration)
                ?? defaultRetryDelay,
            channel: try configuration.getIfPresent(
                ValkeyPubSubConfigKey.channel, as: String.self) ?? defaultChannel)
    }

    private static func positiveDuration(
        _ key: String, from configuration: Configuration
    ) throws -> Duration? {
        guard let milliseconds = try configuration.getIfPresent(key, as: Int.self) else {
            return nil
        }
        guard milliseconds > 0 else {
            throw ValkeyPubSubConfigurationError.invalidTimeout(
                key: key, value: .milliseconds(milliseconds))
        }
        return .milliseconds(milliseconds)
    }

    // MARK: - URL

    public static let plainSchemes: Set<String> = ["valkey", "redis"]
    public static let tlsSchemes: Set<String> = ["valkeys", "rediss"]

    /// The parsed `pubsub.valkey.url` — the same accepted shapes as the cache
    /// adapter's and Flight Data Valkey's:
    ///
    ///     valkey://localhost:6379
    ///     redis://localhost:6379            // same client, same behavior
    ///     valkey://:secret@host:6379/2      // password-only auth, database 2
    ///     rediss://user:secret@host:6380    // TLS (valkeys:// likewise)
    public struct URLParts: Sendable, Equatable {
        public let host: String
        public let port: Int
        public let username: String?
        public let password: String?
        public let database: Int
        public let useTLS: Bool
    }

    public static func parse(_ string: String) throws -> URLParts {
        guard let components = URLComponents(string: string), let scheme = components.scheme?.lowercased()
        else {
            throw ValkeyPubSubConfigurationError.malformedURL(string)
        }
        let useTLS: Bool
        if plainSchemes.contains(scheme) {
            useTLS = false
        } else if tlsSchemes.contains(scheme) {
            useTLS = true
        } else {
            throw ValkeyPubSubConfigurationError.unsupportedScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValkeyPubSubConfigurationError.malformedURL(string)
        }

        // A database path used to be accepted and silently ignored, so
        // `valkey://host/3` published to database 0 and the operator's two
        // clusters were one.
        let database: Int
        let path = components.path
        if path.isEmpty || path == "/" {
            database = 0
        } else {
            let segment = String(path.dropFirst())
            guard !segment.contains("/"), let parsed = Int(segment), parsed >= 0 else {
                throw ValkeyPubSubConfigurationError.invalidDatabase(path)
            }
            database = parsed
        }

        // A username with no password can never authenticate (RESP AUTH is a
        // pair); silently dropping it would mask a typo. A password with no
        // username is the `valkey://:secret@host` spelling and means the
        // default user — dropping *that* skipped authentication entirely and
        // failed later with something that named neither cause.
        let password = components.password
        var username = components.user
        if username?.isEmpty == true { username = nil }
        if username != nil && password == nil {
            throw ValkeyPubSubConfigurationError.usernameWithoutPassword
        }

        return URLParts(
            host: host,
            port: components.port ?? 6379,
            username: password != nil ? (username ?? "default") : nil,
            password: password,
            database: database,
            useTLS: useTLS)
    }

    // MARK: - Client

    /// The driver's client-level configuration: auth, database, TLS, and both
    /// halves of the timeout budget.
    ///
    /// `commandTimeout` bounds a command once a connection is leased. It does
    /// nothing while the pool is trying to obtain one, so against a downed
    /// server it never fires and lease requests queue until the driver's
    /// connection-creation circuit breaker trips — at its 60-second default,
    /// that is a minute of a publisher hanging on a fire-and-forget broadcast.
    /// `circuitBreakerTripAfter` is therefore set from `unreachableAfter`.
    public func clientConfiguration() throws -> ValkeyClientConfiguration {
        var configuration = ValkeyClientConfiguration()
        if let username, let password {
            configuration.authentication = .init(username: username, password: password)
        }
        configuration.databaseNumber = database
        configuration.commandTimeout = commandTimeout
        configuration.connectionPool = .init(circuitBreakerTripAfter: unreachableAfter)
        if useTLS {
            configuration.tls = try .enable(.makeClientConfiguration(), tlsServerName: host)
        }
        return configuration
    }
}

/// Configuration problems, raised during bootstrap.
public enum ValkeyPubSubConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingURL
    case malformedURL(String)
    case unsupportedScheme(String)
    case invalidDatabase(String)
    case usernameWithoutPassword
    case emptyChannel
    case invalidTimeout(key: String, value: Duration)

    public var description: String {
        switch self {
        case .missingURL:
            return """
                FlightPubSubValkeyModule needs \(ValkeyPubSubConfigKey.url). Set it in flight.yaml \
                or as FLIGHT_PUBSUB_VALKEY_URL, e.g. valkey://localhost:6379.
                """
        case .malformedURL(let raw):
            return "\(ValkeyPubSubConfigKey.url) is not a URL with a host: \"\(raw)\"."
        case .unsupportedScheme(let scheme):
            return "\(ValkeyPubSubConfigKey.url) scheme \"\(scheme)\" is not supported — use valkey:// or redis:// (valkeys:///rediss:// for TLS)."
        case .invalidDatabase(let path):
            return "\(ValkeyPubSubConfigKey.url) path '\(path)' is not a database number — use a single non-negative integer segment, e.g. valkey://host:6379/2."
        case .usernameWithoutPassword:
            return "\(ValkeyPubSubConfigKey.url) has a username but no password — RESP authentication needs both (or omit userinfo entirely)."
        case .emptyChannel:
            return "\(ValkeyPubSubConfigKey.channel) is empty — every node must agree on one non-empty channel name, or they are silently deaf to each other."
        case .invalidTimeout(let key, let value):
            return "\(key) is \(value) — it must be a positive millisecond count."
        }
    }
}

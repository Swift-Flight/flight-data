import FlightCore
import Foundation
import Valkey

/// Where the adapter connects, and on which channel.
///
/// ```yaml
/// pubsub:
///   valkey:
///     url: valkey://localhost:6379
///     channel: flight-pubsub        # optional
/// ```
///
/// Parsed at the component factory, which runs at `freeze()` — so a
/// malformed URL fails bootstrap rather than the first broadcast. Same
/// posture as every other driver here.
public struct ValkeyPubSubSettings: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?

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
        channel: String = "flight-pubsub"
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.channel = channel
    }

    /// Reads `pubsub.valkey.*`.
    public static func load(from configuration: Configuration) throws -> ValkeyPubSubSettings {
        guard let raw = try configuration.getIfPresent("pubsub.valkey.url", as: String.self) else {
            throw ValkeyPubSubConfigurationError.missingURL
        }
        guard let url = URL(string: raw), let host = url.host else {
            throw ValkeyPubSubConfigurationError.malformedURL(raw)
        }
        guard ["valkey", "redis", "rediss"].contains(url.scheme?.lowercased() ?? "") else {
            throw ValkeyPubSubConfigurationError.unsupportedScheme(url.scheme ?? "")
        }
        return ValkeyPubSubSettings(
            host: host,
            port: url.port ?? 6379,
            username: url.user,
            password: url.password,
            channel: try configuration.getIfPresent("pubsub.valkey.channel", as: String.self)
                ?? "flight-pubsub")
    }

    public func clientConfiguration() -> ValkeyClientConfiguration {
        var configuration = ValkeyClientConfiguration()
        if let username, let password {
            configuration.authentication = .init(username: username, password: password)
        }
        return configuration
    }
}

/// Configuration problems, raised during bootstrap.
public enum ValkeyPubSubConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingURL
    case malformedURL(String)
    case unsupportedScheme(String)

    public var description: String {
        switch self {
        case .missingURL:
            return """
                FlightPubSubValkeyModule needs pubsub.valkey.url. Set it in flight.yaml or as \
                FLIGHT_PUBSUB_VALKEY_URL, e.g. valkey://localhost:6379.
                """
        case .malformedURL(let raw):
            return "pubsub.valkey.url is not a URL with a host: \"\(raw)\"."
        case .unsupportedScheme(let scheme):
            return "pubsub.valkey.url scheme \"\(scheme)\" is not one of valkey, redis, rediss."
        }
    }
}

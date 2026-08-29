import FlightCore

/// The configuration key convention, in one place. Every store package
/// reads its settings under `datasource.<name>.…` so multiple stores can
/// coexist in one `flight.yaml`:
///
/// ```yaml
/// datasource:
///   primary:
///     url: "postgres://localhost:5432/app"
///     pool_size: 10
///   analytics:
///     url: "postgres://localhost:5432/warehouse"
///     pool_size: 4
/// ```
///
/// Store-specific keys (credentials, TLS, timeouts…) live under the same
/// prefix via `key(_:datasource:)`; the two spelled out here are the ones
/// whose names this package standardizes.
public enum DataSourceConfigKey {
    /// The shared key root: `datasource`.
    public static let root = "datasource"

    /// `datasource.<name>.<suffix>` — for store packages adding their own
    /// keys under the shared convention.
    public static func key(_ suffix: String, datasource name: String) -> String {
        "\(root).\(name).\(suffix)"
    }

    /// `datasource.<name>.url` — required for any store that connects to
    /// something. Flight Data Core has no opinion about the URL's format;
    /// the store package parses it.
    public static func url(datasource name: String) -> String {
        key("url", datasource: name)
    }

    /// `datasource.<name>.pool_size` — optional, default
    /// `DataSourceSettings.defaultPoolSize`.
    public static func poolSize(datasource name: String) -> String {
        key("pool_size", datasource: name)
    }

    /// `datasource.<name>.checkout_timeout_ms` — how long an async caller
    /// queues for a connection before giving up. Optional, default
    /// `DataSourceSettings.defaultCheckoutTimeout`.
    public static func checkoutTimeout(datasource name: String) -> String {
        key("checkout_timeout_ms", datasource: name)
    }
}

/// The store-agnostic slice of a named datasource's configuration,
/// resolved once at bootstrap.
///
/// Per, absence fails loudly at bootstrap, not silently at first query:
/// `load` runs inside a module's registered factory, so a missing
/// `datasource.<name>.url` surfaces as `ConfigError.missingKey` during
/// `freeze()`'s eager singleton construction — before any request is served.
/// (The *compile-time* half of validation belongs to `@ConfigValue`
/// sites and the build plugin, exactly as in Flight Config)
public struct DataSourceSettings: Sendable, Equatable {
    /// Applied when `datasource.<name>.pool_size` is absent from every source.
    public static let defaultPoolSize = 10

    /// Applied when `datasource.<name>.checkout_timeout_ms` is absent.
    ///
    /// Five seconds is chosen against the thing that actually goes wrong: a
    /// burst of concurrent requests against a pool sized for the steady state.
    /// Those clear in milliseconds, so the queue is invisible; a wait that
    /// reaches five seconds is not a burst, it is a leak or a stuck query, and
    /// failing is the honest answer — nobody is still watching the browser.
    public static let defaultCheckoutTimeout: Duration = .seconds(5)

    /// The datasource's name — config key segment and registration qualifier.
    public let name: String
    /// The store URL, uninterpreted. The store package parses it; a malformed
    /// URL is the store's error to raise, at pool construction.
    public let url: String
    /// Maximum pooled connections. Always ≥ 1 — the initializer enforces it.
    public let poolSize: Int
    /// How long an async caller queues for a connection before
    /// `poolExhausted`. `.zero` restores the old fail-immediately behaviour.
    public let checkoutTimeout: Duration

    public init(
        name: String,
        url: String,
        poolSize: Int = DataSourceSettings.defaultPoolSize,
        checkoutTimeout: Duration = DataSourceSettings.defaultCheckoutTimeout
    ) throws {
        // stdlib rather than `trimmingCharacters(in: .whitespaces)`: that one
        // call was this target's only reason to import Foundation, in a
        // package that advertises depending on FlightCore alone.
        guard url.contains(where: { !$0.isWhitespace }) else {
            throw DataSourceConfigurationError.emptyURL(datasource: name)
        }
        guard poolSize >= 1 else {
            throw DataSourceConfigurationError.invalidPoolSize(datasource: name, value: poolSize)
        }
        guard checkoutTimeout >= .zero else {
            throw DataSourceConfigurationError.invalidCheckoutTimeout(
                datasource: name, value: checkoutTimeout)
        }
        self.name = name
        self.url = url
        self.poolSize = poolSize
        self.checkoutTimeout = checkoutTimeout
    }

    /// Resolves the convention keys for one named datasource.
    ///
    /// - `url` is required: absent from every source throws
    ///   `ConfigError.missingKey` naming the key and active environment.
    /// - `pool_size` is optional with `defaultPoolSize`; present-but-malformed
    ///   throws rather than silently applying the default (Flight Config).
    /// - `checkout_timeout_ms` is optional with `defaultCheckoutTimeout`.
    public static func load(
        name: String = PrimaryDataSource.name,
        from configuration: Configuration
    ) throws -> DataSourceSettings {
        let url: String = try configuration.get(DataSourceConfigKey.url(datasource: name))
        let poolSize = try configuration.getIfPresent(
            DataSourceConfigKey.poolSize(datasource: name), as: Int.self
        ) ?? defaultPoolSize
        let checkoutTimeout = try configuration.getIfPresent(
            DataSourceConfigKey.checkoutTimeout(datasource: name), as: Int.self
        ).map { Duration.milliseconds($0) } ?? defaultCheckoutTimeout
        return try DataSourceSettings(
            name: name, url: url, poolSize: poolSize, checkoutTimeout: checkoutTimeout)
    }
}

/// Configuration that resolved but cannot describe a working pool. Distinct
/// from `ConfigError` (absent/undecodable keys — Flight Config's domain):
/// these are *semantic* rejections of values that decoded fine.
public enum DataSourceConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyURL(datasource: String)
    case invalidPoolSize(datasource: String, value: Int)
    case invalidCheckoutTimeout(datasource: String, value: Duration)

    public var description: String {
        switch self {
        case .emptyURL(let datasource):
            return "Configuration key '\(DataSourceConfigKey.url(datasource: datasource))' is empty — a datasource URL must point at something."
        case .invalidPoolSize(let datasource, let value):
            return "Configuration key '\(DataSourceConfigKey.poolSize(datasource: datasource))' is \(value); a pool needs at least 1 connection."
        case .invalidCheckoutTimeout(let datasource, let value):
            return "Configuration key '\(DataSourceConfigKey.checkoutTimeout(datasource: datasource))' is \(value); a checkout timeout cannot be negative (0 means do not queue at all)."
        }
    }
}

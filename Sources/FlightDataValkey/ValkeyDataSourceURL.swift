import Foundation
import NIOSSL
import Valkey

/// The parsed form of `datasource.<name>.url` — Flight Data
/// Core hands the URL over uninterpreted; this package parses it, and a
/// malformed URL fails at pool construction (freeze()'s eager singleton
/// construction), never at the first command.
///
/// Accepted shapes:
///
///     valkey://localhost:6379
///     redis://localhost:6379            // same client, same behavior
///     valkey://:secret@host:6379/2      // password-only auth, database 2
///     rediss://user:secret@host:6380    // TLS variant (valkeys:// likewise)
///
/// `valkey://` and `redis://` are exact synonyms, as are `valkeys://` and
/// `rediss://` — the seamlessness story is precisely that the scheme
/// names a *compatible pair*, not a behavior switch. No detection logic, no
/// dual code paths.
public struct ValkeyDataSourceURL: Sendable, Equatable {
    /// Plaintext schemes, either vendor spelling.
    public static let plainSchemes: Set<String> = ["valkey", "redis"]
    /// TLS schemes, either vendor spelling.
    public static let tlsSchemes: Set<String> = ["valkeys", "rediss"]

    /// The host to dial.
    public let host: String
    /// The port to dial; 6379 when the URL names none.
    public let port: Int
    /// ACL username. A password-only URL (`valkey://:secret@host`) gets the
    /// server's conventional `default` user.
    public let username: String?
    /// Password, when the URL carries userinfo.
    public let password: String?
    /// Database number from the URL path (`/2`); 0 when absent.
    public let database: Int
    /// Whether the scheme was a TLS variant.
    public let useTLS: Bool

    /// Parses `datasource.<name>.url`. Every rejection names the datasource
    /// — a bootstrap failure message must say which pool it belongs to.
    public static func parse(_ string: String, datasource name: String) throws -> ValkeyDataSourceURL {
        guard let components = URLComponents(string: string), let scheme = components.scheme else {
            throw ValkeyDataSourceURLError.unparseable(datasource: name, url: string)
        }
        let useTLS: Bool
        if plainSchemes.contains(scheme) {
            useTLS = false
        } else if tlsSchemes.contains(scheme) {
            useTLS = true
        } else {
            throw ValkeyDataSourceURLError.unsupportedScheme(datasource: name, scheme: scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValkeyDataSourceURLError.missingHost(datasource: name)
        }

        let database: Int
        let path = components.path
        if path.isEmpty || path == "/" {
            database = 0
        } else {
            let segment = String(path.dropFirst())
            guard !segment.contains("/"), let parsed = Int(segment), parsed >= 0 else {
                throw ValkeyDataSourceURLError.invalidDatabase(datasource: name, path: path)
            }
            database = parsed
        }

        // Userinfo: `user:pass@` or `:pass@`. A username with no password is
        // rejected — RESP AUTH is (username, password); a lone username can
        // never authenticate and silently dropping it would mask a typo.
        let password = components.password
        var username = components.user
        if username?.isEmpty == true { username = nil }
        if username != nil && password == nil {
            throw ValkeyDataSourceURLError.usernameWithoutPassword(datasource: name)
        }

        return ValkeyDataSourceURL(
            host: host,
            port: components.port ?? 6379,
            username: password != nil ? (username ?? "default") : nil,
            password: password,
            database: database,
            useTLS: useTLS
        )
    }

    /// The driver's address for this URL.
    public var address: ValkeyServerAddress {
        .hostname(host, port: port)
    }

    /// The driver's per-connection configuration: auth, database and TLS
    /// from the URL. TLS uses NIOSSL's default client configuration with the
    /// host as SNI server name; apps needing custom trust roots construct
    /// their `ValkeyDataSource` by hand with their own configuration.
    public func connectionConfiguration() throws -> ValkeyConnectionConfiguration {
        var configuration = ValkeyConnectionConfiguration()
        if let username, let password {
            configuration.authentication = .init(username: username, password: password)
        }
        configuration.databaseNumber = database
        if useTLS {
            let context = try NIOSSLContext(configuration: .makeClientConfiguration())
            configuration.tls = try .enable(context, tlsServerName: host)
        }
        return configuration
    }
}

/// URL strings that cannot describe a connection. Semantic parse errors,
/// distinct from `ConfigError` (the key was present and readable — its
/// value is what's wrong).
public enum ValkeyDataSourceURLError: Error, Sendable, Equatable, CustomStringConvertible {
    case unparseable(datasource: String, url: String)
    case unsupportedScheme(datasource: String, scheme: String)
    case missingHost(datasource: String)
    case invalidDatabase(datasource: String, path: String)
    case usernameWithoutPassword(datasource: String)

    public var description: String {
        switch self {
        case .unparseable(let datasource, let url):
            return "Datasource '\(datasource)' URL '\(url)' is not a parseable URL."
        case .unsupportedScheme(let datasource, let scheme):
            return "Datasource '\(datasource)' URL scheme '\(scheme)' is not supported — use valkey:// or redis:// (valkeys:///rediss:// for TLS)."
        case .missingHost(let datasource):
            return "Datasource '\(datasource)' URL names no host."
        case .invalidDatabase(let datasource, let path):
            return "Datasource '\(datasource)' URL path '\(path)' is not a database number — use a single non-negative integer segment, e.g. valkey://host:6379/2."
        case .usernameWithoutPassword(let datasource):
            return "Datasource '\(datasource)' URL has a username but no password — RESP authentication needs both (or omit userinfo entirely)."
        }
    }
}

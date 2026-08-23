import Foundation
import NIOSSL
import PostgresNIO

/// Parses `postgres://` connection URLs into `PostgresClient` configurations (
/// the CLI reads a connection URL directly — env var or flag — precisely so Flight Migrate
/// stays standalone).
struct DatabaseURL: Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var database: String
    var sslMode: SSLMode

    /// libpq-compatible `sslmode` values.
    enum SSLMode: String, Equatable {
        case disable
        case allow
        case prefer
        case require
        case verifyCA = "verify-ca"
        case verifyFull = "verify-full"
    }

    /// Resolution order: explicit flag, then `$FLIGHT_DATABASE_URL`, then `$DATABASE_URL`.
    static func resolve(
        flag: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DatabaseURL {
        guard
            let raw = flag ?? environment["FLIGHT_DATABASE_URL"] ?? environment["DATABASE_URL"]
        else {
            throw CLIError.missingDatabaseURL
        }
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> DatabaseURL {
        guard let components = URLComponents(string: raw) else {
            throw CLIError.invalidDatabaseURL(raw, reason: "not a valid URL")
        }
        guard let scheme = components.scheme, scheme == "postgres" || scheme == "postgresql"
        else {
            throw CLIError.invalidDatabaseURL(
                raw, reason: "scheme must be postgres:// or postgresql://")
        }
        guard let username = components.user, !username.isEmpty else {
            throw CLIError.invalidDatabaseURL(
                raw, reason: "a username is required (postgres://USER@host/db)")
        }
        let host = components.host.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost"
        if host.hasPrefix("/") || host.hasPrefix("%2F") {
            throw CLIError.invalidDatabaseURL(
                raw,
                reason: """
                    unix domain socket hosts are not supported by the CLI; use the library API \
                    with a hand-built PostgresClient.Configuration instead
                    """)
        }

        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        if database.isEmpty { database = username }

        var sslMode = SSLMode.prefer
        for item in components.queryItems ?? [] where item.name == "sslmode" {
            guard let value = item.value, let mode = SSLMode(rawValue: value) else {
                throw CLIError.invalidDatabaseURL(
                    raw,
                    reason: """
                        unknown sslmode '\(item.value ?? "")' (expected disable, allow, prefer, \
                        require, verify-ca, or verify-full)
                        """)
            }
            sslMode = mode
        }

        return DatabaseURL(
            host: host,
            port: components.port ?? 5432,
            username: username,
            password: components.password,
            database: database,
            sslMode: sslMode
        )
    }

    /// Maps to a `PostgresClient.Configuration`, with libpq-parity TLS semantics:
    /// `prefer`/`require` encrypt without verifying certificates; use `verify-full` for
    /// certificate and hostname verification in production over untrusted networks.
    func postgresConfiguration() throws -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        switch sslMode {
        case .disable:
            tls = .disable
        case .allow, .prefer:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            tls = .prefer(tlsConfig)
        case .require:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            tls = .require(tlsConfig)
        case .verifyCA:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .noHostnameVerification
            tls = .require(tlsConfig)
        case .verifyFull:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .fullVerification
            tls = .require(tlsConfig)
        }
        return PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tls
        )
    }
}

import FlightCore
import FlightDataCore
import PostgresNIO

/// Makes design §3.3's repository shape work as written:
///
/// ```swift
/// @Repository(scope: .scoped)
/// struct UserRepository {
///     @Autowired var connection: PostgresConnection
///     …
/// }
/// ```
///
/// `@Autowired` expands to plain `container.resolve(PostgresConnection.self)`
/// (Flight Core §5.1), and Core's generic `resolve` refuses scoped components —
/// scoped resolution needs a scope. These overloads are *more specific* than
/// the generic one, so in any module that imports FlightDataPostgres they win
/// overload resolution for exactly the two connection-shaped types this
/// package owns, and route through the ambient scope (Flight Core delta 11)
/// that is bound whenever a scoped repository is being constructed.
///
/// Outside any scoped resolution the ambient scope is nil and this throws
/// `ResolutionError.noActiveScope`, preserving Core's captive-dependency
/// guarantee: a singleton trying to capture a scope's connection still fails
/// loudly at `freeze()`.
extension Container {
    /// Resolves the ambient scope's Postgres connection — the same one every
    /// other repository in the scope shares.
    public func resolve(
        _ type: PostgresConnection.Type = PostgresConnection.self,
        qualifier: String? = nil
    ) throws -> PostgresConnection {
        try resolveInActiveScope(PostgresConnection.self, qualifier: qualifier)
    }

    /// Resolves the ambient scope's connection lease. Prefer holding the
    /// lease (rather than the raw connection) in code that wants the
    /// datasource name alongside the connection.
    public func resolve(
        _ type: ScopedConnection<PostgresDataSource>.Type = ScopedConnection<PostgresDataSource>.self,
        qualifier: String? = nil
    ) throws -> ScopedConnection<PostgresDataSource> {
        try resolveInActiveScope(ScopedConnection<PostgresDataSource>.self, qualifier: qualifier)
    }
}

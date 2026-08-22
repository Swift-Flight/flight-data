import FlightCore
import FlightDataCore

/// The reference store module (§5, §7): the exact shape every real store
/// package's `FlightModule` follows, minus the parts that need a real store.
///
/// - `configure(_:)` registers the datasource (pool as singleton, scoped
///   connection, liveness probe) via `register(dataSource:name:factory:)`.
///   The factory body — where `Configuration` is read — runs at `freeze()`,
///   after config resolves and before any service starts, so a bad
///   configuration fails bootstrap, not the first query (§4, §5).
/// - `service` is nil: an in-memory pool has no long-running work. A real
///   store module returns its pool's service here and bootstrap ordering
///   guarantees no request is served before the pool is live (§5).
///
/// The name is carried in the type (§4): one module type instantiation per
/// named datasource —
///
/// ```swift
/// let container = try TestContainer.build {
///     InMemoryDataModule<PrimaryDataSource>()
/// }
/// ```
///
/// Configuration is optional for the in-memory store — it is "backed by
/// nothing" (§7), so there is no URL to require; `datasource.<name>.pool_size`
/// is honored when present and defaults to 4 connections. Real store modules
/// load `DataSourceSettings` instead, whose `url` is required.
public final class InMemoryDataModule<Name: DataSourceName>: FlightModule {
    /// The pool size used when `datasource.<name>.pool_size` is absent.
    /// Small on purpose: exhaustion bugs should be reachable in tests.
    public static var defaultPoolSize: Int { 4 }

    public init() {}

    public func configure(_ container: Container) throws {
        let name = Name.name
        container.register(dataSource: InMemoryDataSource.self, name: name) { container in
            let configuration = try container.resolve(Configuration.self)
            let poolSize = try configuration.getIfPresent(
                DataSourceConfigKey.poolSize(datasource: name), as: Int.self
            ) ?? Self.defaultPoolSize
            guard poolSize >= 1 else {
                throw DataSourceConfigurationError.invalidPoolSize(datasource: name, value: poolSize)
            }
            return InMemoryDataSource(name: name, poolSize: poolSize)
        }
    }
}

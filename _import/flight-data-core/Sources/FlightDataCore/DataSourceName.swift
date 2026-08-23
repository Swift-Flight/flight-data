/// A compile-time datasource name.
///
/// Named datasources are the mechanism for multiple stores (or multiple
/// databases of the same store): a store package's `FlightModule` is
/// instantiated per named datasource, registering its components under a qualifier
/// matching the name. `FlightModule` requires `init()` (Flight Core), so
/// the name cannot be passed to a module instance — it is carried in the
/// module's *type* instead, exactly as `FlightWebModule<Transport>` carries
/// its transport:
///
/// ```swift
/// enum Analytics: DataSourceName { static let name = "analytics" }
///
/// try await Flight.bootstrap(
///     configuration: .load(),
///     modules: [
///         PostgresDataModule<PrimaryDataSource>.self,
///         PostgresDataModule<Analytics>.self,
///     ]
/// )
/// ```
///
/// Each generic instantiation is a distinct module type, so the module DAG,
/// health tracking, and `ComponentDescriptor.sourceModule` all distinguish the
/// two datasources with no extra machinery.
public protocol DataSourceName {
    /// The name as it appears in configuration (`datasource.<name>.…`) and
    /// as the registration qualifier for the datasource's components.
    static var name: String { get }
}

/// The conventional default datasource (`primary`). Apps with one
/// database never need to define their own `DataSourceName`.
public enum PrimaryDataSource: DataSourceName {
    public static let name = "primary"
}

import FlightCore
import FlightDataCore
import Logging
import ServiceLifecycle
import Valkey

/// The Valkey store module (design §6): one generic instantiation per named
/// datasource, exactly as `PostgresDataModule<Name>` models it —
///
/// ```swift
/// try await bootstrap(configuration: .load(), modules: [
///     ValkeyDataModule<PrimaryDataSource>.self,
///     PostgresDataModule<PrimaryDataSource>.self,   // coexists under §4 names
/// ])
/// ```
///
/// `configure(_:)` registers, all qualified by `Name.name`:
///
/// 1. the pool — `ValkeyDataSource`, `.singleton`, plus the scope-bound
///    `ScopedConnection<ValkeyDataSource>` lease and the
///    `DataSourceLiveness` probe (via `register(dataSource:)`, Flight Data
///    Core §3/§5);
/// 2. the raw connection — `ValkeyConnection`, `.scoped`, borrowed from the
///    scope's lease so repositories can say
///    `@Autowired var valkey: ValkeyConnection` (design §4.3). For the
///    `primary` datasource it is *also* registered unqualified, so the
///    single-store app never writes a qualifier.
///
/// Deliberately absent (§5): no migration runner (§5.1 — schemaless store)
/// and **no transaction coordinator** (§5.2 — `MULTI`/`EXEC` is not a
/// transaction in the `@Transactional` sense; the capability ships as
/// `multi` under its own honest name).
///
/// `service` is the pool's `run()`: dial at start (Flight Core §7 — no
/// request served before the pool is live), replace broken connections while
/// running, drain on graceful shutdown.
public final class ValkeyDataModule<Name: DataSourceName>: FlightModule {
    /// Stashed during `configure` so `service` can resolve the pool lazily —
    /// the same pattern as `PostgresDataModule` (modules cannot resolve
    /// during the registration phase, Flight Core §2.1).
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container
        let name = Name.name

        // The pool + lease + liveness triple. The factory runs at freeze(),
        // where Configuration is readable — a bad URL or pool size fails
        // bootstrap, never the first command (Flight Data Core §4).
        container.register(dataSource: ValkeyDataSource.self, name: name) { container in
            let configuration = try container.resolve(Configuration.self)
            let settings = try DataSourceSettings.load(name: name, from: configuration)
            return try ValkeyDataSource(settings: settings)
        }

        // The scope's raw connection, borrowed from the lease (design §4.3's
        // `@Autowired var valkey: ValkeyConnection`). The lease owns
        // return-to-pool (Flight Data Core D2); this component is a view
        // into it, living exactly as long as the same scope.
        let connectionFactory: @Sendable (Container) throws -> ValkeyConnection = { container in
            try container.resolveInActiveScope(
                ScopedConnection<ValkeyDataSource>.self, qualifier: name
            ).connection
        }
        container.register(ValkeyConnection.self, qualifier: name, scope: .scoped, factory: connectionFactory)

        // The conventional default datasource also answers unqualified
        // resolution, so `@Autowired var valkey: ValkeyConnection` works
        // without ceremony in the one-store app. Named datasources must be
        // asked for by name — with several pools, silence would be guessing
        // (Flight Core §5.4's qualifier posture).
        if name == PrimaryDataSource.name {
            container.register(ValkeyConnection.self, scope: .scoped, factory: connectionFactory)
        }
    }

    public var service: (any Service)? {
        container.map { ValkeyPoolService<Name>(container: $0) }
    }
}

/// The pool's ServiceLifecycle wrapper: resolves the datasource post-freeze
/// and runs it (dial → maintain → drain).
struct ValkeyPoolService<Name: DataSourceName>: Service {
    let container: Container

    func run() async throws {
        let source = try container.resolve(ValkeyDataSource.self, qualifier: Name.name)
        try await source.run()
    }
}

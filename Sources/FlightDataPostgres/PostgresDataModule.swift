import FlightCore
import FlightDataCore
import Logging
import PostgresNIO
import ServiceLifecycle

/// The Postgres store module (design §5): one generic instantiation per named
/// datasource, exactly as `InMemoryDataModule<Name>` models it —
///
/// ```swift
/// try await bootstrap(configuration: .load(), modules: [
///     PostgresDataModule<PrimaryDataSource>.self,
///     PostgresDataModule<Analytics>.self,
/// ])
/// ```
///
/// `configure(_:)` registers, all qualified by `Name.name`:
///
/// 1. the pool — `PostgresDataSource`, `.singleton`, plus the scope-bound
///    `ScopedConnection<PostgresDataSource>` lease and the
///    `DataSourceLiveness` probe (via `register(dataSource:)`, Flight Data
///    Core §3/§5);
/// 2. the raw connection — `PostgresConnection`, `.scoped`, borrowed from
///    the scope's lease so repositories can say
///    `@Autowired var connection: PostgresConnection` (design §3.3). For the
///    `primary` datasource it is *also* registered unqualified, so the
///    single-database app never writes a qualifier;
/// 3. the transaction coordinator — `PostgresTransactionCoordinator`,
///    `.singleton` (§6), unqualified alias for `primary` likewise.
///
/// `service` is the pool's `run()`: dial at start (Flight Core §7 step 9 —
/// no request served before the pool is live), replace broken connections
/// while running, drain on graceful shutdown.
public final class PostgresDataModule<Name: DataSourceName>: FlightModule {
    /// Stashed during `configure` so `service` can resolve the pool lazily —
    /// the same pattern as `FlightWebModule` (modules cannot resolve during
    /// the registration phase, Flight Core §2.1).
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container
        let name = Name.name

        // The pool + lease + liveness triple. The factory runs at freeze(),
        // where Configuration is readable — a bad URL or pool size fails
        // bootstrap, never the first query (Flight Data Core §4).
        container.register(dataSource: PostgresDataSource.self, name: name) { container in
            let configuration = try container.resolve(Configuration.self)
            let settings = try DataSourceSettings.load(name: name, from: configuration)
            return try PostgresDataSource(settings: settings)
        }

        // The scope's raw connection, borrowed from the lease (design §3.3's
        // `@Autowired var connection: PostgresConnection`). The lease owns
        // return-to-pool (Flight Data Core D2); this component is a view into it,
        // living exactly as long as the same scope.
        let connectionFactory: @Sendable (Container) throws -> PostgresConnection = { container in
            try container.resolveInActiveScope(
                ScopedConnection<PostgresDataSource>.self, qualifier: name
            ).connection
        }
        container.register(PostgresConnection.self, qualifier: name, scope: .scoped, factory: connectionFactory)

        // The §6 coordinator: singleton per datasource; finds the scope's
        // connection at begin() through the ambient scope.
        let coordinatorFactory: @Sendable (Container) throws -> PostgresTransactionCoordinator = { container in
            PostgresTransactionCoordinator(container: container, datasource: name)
        }
        container.register(
            PostgresTransactionCoordinator.self, qualifier: name, scope: .singleton,
            factory: coordinatorFactory)

        // The scope's Hangar `Repo` (hangar-design §11), bound to the same
        // connection as everything above — see HangarIntegration.swift for
        // why scoped-and-connection-bound rather than the sketch's
        // singleton.
        registerRepo(container, name: name)

        // The conventional default datasource also answers unqualified
        // resolution, so `@Autowired var connection: PostgresConnection`
        // works without ceremony in the one-database app. Named datasources
        // must be asked for by name — with several pools, silence would be
        // guessing (Flight Core §5.4's qualifier posture).
        if name == PrimaryDataSource.name {
            container.register(PostgresConnection.self, scope: .scoped, factory: connectionFactory)
            container.register(
                PostgresTransactionCoordinator.self, scope: .singleton, factory: coordinatorFactory)
        }
    }

    public var service: (any Service)? {
        container.map { PostgresPoolService<Name>(container: $0) }
    }
}

/// The pool's ServiceLifecycle wrapper: resolves the datasource post-freeze
/// and runs it (dial → maintain → drain).
struct PostgresPoolService<Name: DataSourceName>: Service {
    let container: Container

    func run() async throws {
        let source = try container.resolve(PostgresDataSource.self, qualifier: Name.name)
        try await source.run()
    }
}

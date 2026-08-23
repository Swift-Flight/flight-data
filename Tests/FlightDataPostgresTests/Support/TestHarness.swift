import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightDataTesting
import PostgresNIO
import Testing

/// Umbrella for every suite that touches the shared fixture tables.
/// `.serialized` is recursive, so nested suites never interleave — each test
/// TRUNCATEs and reseeds, which only works single-file.
@Suite(.serialized, .enabled(if: TestDatabase.isConfigured))
enum PostgresIntegrationSuite {}

/// Ensures the test schema exists — once per process, through the same
/// `flight migrate` path production uses, so the migrations are
/// exercised on every test run.
actor TestSchema {
    static let shared = TestSchema()
    private var prepared = false

    func ensure() async throws {
        guard !prepared else { return }
        try await PostgresMigrations.migrate(
            configuration: try TestDatabase.configuration(),
            migrations: TestMigrations.all
        )
        prepared = true
    }
}

/// Builds a frozen container (module DAG order, real macro-registered
/// repositories), starts the pool by hand — tests drive the lifecycle a
/// `ServiceGroup` would — runs `body`, and drains the pool.
func withPostgresContainer<T>(
    poolSize: Int = 4,
    resetOnRelease: Bool = true,
    _ body: (Container, PostgresDataSource) async throws -> T
) async throws -> T {
    try await TestSchema.shared.ensure()
    let container = try TestContainer.build(
        configuration: try TestDatabase.configuration(
            poolSize: poolSize, resetOnRelease: resetOnRelease)
    ) {
        TestAppModule()
    }
    let source = try container.resolve(PostgresDataSource.self, qualifier: PrimaryDataSource.name)
    try await source.start()
    do {
        let result = try await body(container, source)
        await source.shutdown()
        return result
    } catch {
        await source.shutdown()
        throw error
    }
}

/// Empties the fixture tables so each test starts from a known state.
func cleanTables(_ source: PostgresDataSource) async throws {
    try await source.withConnection { connection in
        _ = try await connection.query(
            #"TRUNCATE "fdp_transfers", "fdp_accounts", "fdp_users""#,
            logger: .init(label: "test.clean")
        )
    }
}

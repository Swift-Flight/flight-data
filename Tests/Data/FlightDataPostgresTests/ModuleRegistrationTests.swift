import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightDataTesting
import PostgresNIO
import Testing

/// Registration and bootstrap behavior that needs no server: the module's
/// components, the fail-at-freeze posture, and the scope requirement.
@Suite("PostgresDataModule registration")
struct ModuleRegistrationTests {
    /// A syntactically valid URL for a server that is never dialed —
    /// construction parses eagerly but connects only when the service runs.
    static let offlineConfiguration = Configuration(values: [
        DataSourceConfigKey.url(datasource: "primary"): "postgres://postgres@localhost:5/nowhere?sslmode=disable",
        DataSourceConfigKey.url(datasource: "analytics"): "postgres://postgres@localhost:5/elsewhere?sslmode=disable",
        DataSourceConfigKey.poolSize(datasource: "analytics"): "2",
    ])

    enum Analytics: DataSourceName {
        static let name = "analytics"
    }

    private func build() throws -> Container {
        try TestContainer.build(configuration: Self.offlineConfiguration) {
            TestAppModule()
            PostgresDataModule<Analytics>()
        }
    }

    @Test func registersPoolLeaseAndLivenessPerDatasource() throws {
        let container = try build()

        let primary = try container.resolve(PostgresDataSource.self, qualifier: "primary")
        #expect(primary.name == "primary")
        #expect(primary.poolSize == DataSourceSettings.defaultPoolSize)

        let analytics = try container.resolve(PostgresDataSource.self, qualifier: "analytics")
        #expect(analytics.name == "analytics")
        #expect(analytics.poolSize == 2)

        let probes = try DataSourceLiveness.all(in: container)
        #expect(Set(probes.map(\.datasourceName)) == ["primary", "analytics"])
    }

    @Test func primaryDatasourceAnswersUnqualifiedResolution() throws {
        let container = try build()
        let coordinator = try container.resolve(PostgresTransactionCoordinator.self)
        #expect(coordinator.datasource == "primary")

        // The named datasource must be asked for by name.
        let analytics = try container.resolve(PostgresTransactionCoordinator.self, qualifier: "analytics")
        #expect(analytics.datasource == "analytics")
    }

    @Test func repositoriesRegisterWithRepositoryStereotype() throws {
        let container = try build()
        let repositories = container.allRegistrations().filter { $0.stereotype == .repository }
        #expect(repositories.contains { $0.typeName.contains("UserRepository") })
        #expect(repositories.contains { $0.typeName.contains("LedgerRepository") })
        #expect(repositories.allSatisfy { $0.scope == .scoped })
    }

    @Test func malformedURLFailsAtFreeze() {
        // posture: a bad URL is a bootstrap failure, not a first-query one.
        let configuration = Configuration(values: [
            DataSourceConfigKey.url(datasource: "primary"): "postgres://localhost:5432"
        ])
        #expect(throws: PostgresDataSourceURLError.missingDatabase(datasource: "primary")) {
            try TestContainer.build(configuration: configuration) {
                PostgresDataModule<PrimaryDataSource>()
            }
        }
    }

    @Test func missingURLFailsAtFreeze() {
        #expect(throws: (any Error).self) {
            try TestContainer.build(configuration: Configuration()) {
                PostgresDataModule<PrimaryDataSource>()
            }
        }
    }

    @Test func checkoutBeforeServiceStartThrows() throws {
        let container = try build()
        let source = try container.resolve(PostgresDataSource.self, qualifier: "primary")
        #expect(throws: PostgresDataSourceError.notStarted(datasource: "primary")) {
            _ = try source.checkout()
        }
    }

    @Test func resolvingConnectionOutsideScopeThrows() throws {
        let container = try build()
        // Our concrete resolve overload preserves the captive-dependency
        // guarantee: no ambient scope → loud error, not a pinned connection.
        #expect(throws: ResolutionError.self) {
            _ = try container.resolve(PostgresConnection.self)
        }
    }

    @Test func moduleProvidesPoolService() throws {
        let module = PostgresDataModule<PrimaryDataSource>()
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in Self.offlineConfiguration }
        try module.configure(container)
        #expect(module.service != nil)
    }
}

@Suite("Transaction coordinator without a scope")
struct TransactionScopeRequirementTests {
    @Test func beginOutsideScopeThrowsNoActiveScope() throws {
        let container = try TestContainer.build(
            configuration: ModuleRegistrationTests.offlineConfiguration
        ) {
            PostgresDataModule<PrimaryDataSource>()
        }
        let coordinator = try container.resolve(PostgresTransactionCoordinator.self)
        // "A @Transactional method must execute inside an active Scope" —
        // and this is a throw, not a compile error, because the information
        // genuinely does not exist at compile time.
        do {
            _ = try coordinator.begin()
            Issue.record("begin() outside a scope must throw")
        } catch let error as ResolutionError {
            guard case .noActiveScope = error else {
                Issue.record("expected noActiveScope, got \(error)")
                return
            }
        }
    }

    @Test func completingUnknownTokenThrows() throws {
        let container = try TestContainer.build(
            configuration: ModuleRegistrationTests.offlineConfiguration
        ) {
            PostgresDataModule<PrimaryDataSource>()
        }
        let coordinator = try container.resolve(PostgresTransactionCoordinator.self)
        #expect(throws: PostgresTransactionError.unknownToken(99)) {
            try coordinator.commit(FlightTransactionToken(id: 99))
        }
    }
}

import FlightCore
import FlightDataCore
import FlightDataTesting
import FlightDataValkey
import Testing

/// Registration and bootstrap behavior that needs no server: the module's
/// components, the fail-at-freeze posture (Flight Data Core §4), and §5.2's
/// deliberate absences.
@Suite("ValkeyDataModule registration (§6)")
struct ModuleRegistrationTests {
    /// A syntactically valid URL for a server that is never dialed —
    /// construction parses eagerly but connects only when the service runs.
    static let offlineConfiguration = Configuration(values: [
        DataSourceConfigKey.url(datasource: "primary"): "valkey://localhost:5",
        DataSourceConfigKey.url(datasource: "ephemeral"): "redis://localhost:5/2",
        DataSourceConfigKey.poolSize(datasource: "ephemeral"): "2",
    ])

    enum Ephemeral: DataSourceName {
        static let name = "ephemeral"
    }

    private func build() throws -> Container {
        try TestContainer.build(configuration: Self.offlineConfiguration) {
            ValkeyTestAppModule()
            ValkeyDataModule<Ephemeral>()
        }
    }

    @Test func registersPoolLeaseAndLivenessPerDatasource() throws {
        let container = try build()

        let primary = try container.resolve(ValkeyDataSource.self, qualifier: "primary")
        #expect(primary.name == "primary")
        #expect(primary.poolSize == DataSourceSettings.defaultPoolSize)
        #expect(primary.url.database == 0)

        let ephemeral = try container.resolve(ValkeyDataSource.self, qualifier: "ephemeral")
        #expect(ephemeral.name == "ephemeral")
        #expect(ephemeral.poolSize == 2)
        #expect(ephemeral.url.database == 2)

        let probes = try DataSourceLiveness.all(in: container)
        #expect(Set(probes.map(\.datasourceName)) == ["primary", "ephemeral"])
    }

    @Test func scopedConnectionComponentsAreRegistered() throws {
        let container = try build()
        let leases = container.allRegistrations().filter {
            $0.typeName.contains("ScopedConnection") && $0.typeName.contains("ValkeyDataSource")
        }
        #expect(Set(leases.compactMap(\.qualifier)) == ["primary", "ephemeral"])

        let connections = container.allRegistrations().filter { $0.typeName.contains("ValkeyConnection") }
        // Qualified for both datasources, plus the unqualified primary alias.
        #expect(connections.count == 3)
        #expect(connections.contains { $0.qualifier == nil })
        #expect(connections.allSatisfy { $0.scope == .scoped })
    }

    @Test func scopedConnectionRefusesResolutionOutsideAScope() throws {
        let container = try build()
        // Core's captive-dependency guarantee, preserved by the resolution
        // overloads: no ambient scope → loud failure, not a leaked lease.
        #expect(throws: (any Error).self) {
            try container.resolve(ValkeyConnection.self)
        }
    }

    @Test func repositoriesRegisterWithRepositoryStereotype() throws {
        let container = try build()
        let repositories = container.allRegistrations().filter { $0.stereotype == .repository }
        #expect(repositories.contains { $0.typeName.contains("SessionRepository") })
        #expect(repositories.allSatisfy { $0.scope == .scoped })
    }

    @Test func checkoutBeforeServiceStartFailsLoudly() throws {
        let container = try build()
        let source = try container.resolve(ValkeyDataSource.self, qualifier: "primary")
        #expect(throws: ValkeyDataSourceError.notStarted(datasource: "primary")) {
            _ = try source.checkout()
        }
    }

    @Test func malformedURLFailsAtFreeze() {
        // Flight Data Core §4 posture: a bad URL is a bootstrap failure, not
        // a first-command one.
        let configuration = Configuration(values: [
            DataSourceConfigKey.url(datasource: "primary"): "postgres://localhost:5432/app"
        ])
        #expect(throws: ValkeyDataSourceURLError.unsupportedScheme(datasource: "primary", scheme: "postgres")) {
            try TestContainer.build(configuration: configuration) {
                ValkeyDataModule<PrimaryDataSource>()
            }
        }
    }

    @Test func missingURLFailsAtFreeze() {
        #expect(throws: (any Error).self) {
            try TestContainer.build(configuration: Configuration()) {
                ValkeyDataModule<PrimaryDataSource>()
            }
        }
    }

    /// §5.2 made structural: the module registers no transaction
    /// coordinator. (`@Transactional` on a Valkey-only repository has no
    /// coordinator to find and fails at runtime resolution — the honest
    /// alternative, `multi`, lives on the connection.)
    @Test func noTransactionCoordinatorIsRegistered() throws {
        let container = try build()
        let coordinators = container.allRegistrations().filter {
            $0.typeName.localizedCaseInsensitiveContains("TransactionCoordinator")
        }
        #expect(coordinators.isEmpty)
    }
}

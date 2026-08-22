import FlightCore
import FlightDataCore
import FlightDataTesting

// MARK: - The §7 repository fixture
//
// The design doc's `UserRepository`: a @Repository-stereotyped component holding
// its scope's connection. Hand-registered (like Core's own container tests)
// so these results say nothing about macro correctness — the macro layer has
// its own suites in flight-core.

final class UserRepository: Sendable {
    let lease: ScopedConnection<InMemoryDataSource>
    var connection: InMemoryConnection { lease.connection }

    init(lease: ScopedConnection<InMemoryDataSource>) {
        self.lease = lease
    }

    func save(_ user: String) {
        connection.perform("INSERT \(user)")
    }
}

/// Registers `UserRepository` as `.scoped`, its factory reaching the scope's
/// connection through the ambient scope (Flight Core delta 11) — the pattern
/// every store package's repositories follow.
struct UserRepositoryModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [InMemoryDataModule<PrimaryDataSource>.self]
    }

    func configure(_ container: Container) throws {
        container.register(UserRepository.self, scope: .scoped, stereotype: .repository) { c in
            UserRepository(lease: try c.resolveInActiveScope(
                ScopedConnection<InMemoryDataSource>.self,
                qualifier: PrimaryDataSource.name
            ))
        }
    }
}

// MARK: - Named datasources (§4)

enum Analytics: DataSourceName {
    static let name = "analytics"
}

import FlightCore
import FlightDataCore
import Hangar
import PostgresNIO

// The Hangar adapter (hangar-design §11): what makes `repo.all(...)` work
// inside a Flight application. Deliberately thin — Hangar knows nothing
// about Flight; this file is the entire coupling.
//
// The central decision: the scope's `Repo` is **bound to the scope's
// connection** (Hangar's `Repo(connection:)`), not to a pool. Every
// repository in a scope therefore shares one connection with
// `@Transactional`'s coordinator — a Hangar query inside a
// `@Transactional` method runs *inside* that transaction, not beside it on
// a different pool connection. Transactional coherence is the reason the
// design's §11 sketch ("register Repo as a singleton") is implemented
// scoped here; the sketch predates this package's scoped-connection model.
//
// One caution follows from sharing the connection: within a single unit of
// work, drive transactions through ONE mechanism — `@Transactional` (token
// nesting, `flight_sp_N` savepoints) or `repo.transaction { }`
// (`hangar_sp_N`) — not both interleaved, since neither coordinator sees
// the other's nesting.

extension Container {
    /// Resolves the ambient scope's `Repo` — the same trick as the
    /// `PostgresConnection` overload above it: more specific than Core's
    /// generic `resolve`, so `@Autowired var repo: Repo` routes through the
    /// ambient scope that is bound whenever a scoped repository is being
    /// constructed.
    public func resolve(
        _ type: Repo.Type = Repo.self,
        qualifier: String? = nil
    ) throws -> Repo {
        try resolveInActiveScope(Repo.self, qualifier: qualifier)
    }
}

extension PostgresDataModule {
    /// Registers the scoped `Repo` for this datasource — called from
    /// `configure(_:)`. Factory borrows the scope's connection lease, so
    /// the repo lives exactly as long as the scope and its connection.
    func registerRepo(_ container: Container, name: String) {
        let factory: @Sendable (Container) throws -> Repo = { container in
            let connection = try container.resolveInActiveScope(
                ScopedConnection<PostgresDataSource>.self, qualifier: name
            ).connection
            // If a @Transactional method already opened a transaction on this
            // connection, the repo must nest as a savepoint. Told otherwise it
            // would emit a literal BEGIN/COMMIT, and that COMMIT would end the
            // enclosing transaction — making writes the caller intended to roll
            // back durable instead. Hangar cannot detect this itself; the
            // coordinator can, because it opened it.
            let coordinator = try? container.resolve(PostgresTransactionCoordinator.self)
            let inTransaction = coordinator?.isTransactionOpen(on: connection) ?? false
            return Repo(connection: connection, inTransaction: inTransaction)
        }
        container.register(Repo.self, qualifier: name, scope: .scoped, factory: factory)
        if name == PrimaryDataSource.name {
            container.register(Repo.self, scope: .scoped, factory: factory)
        }
    }
}

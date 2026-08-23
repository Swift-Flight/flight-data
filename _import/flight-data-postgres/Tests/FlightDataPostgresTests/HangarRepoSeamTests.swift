import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres
import Hangar
import Testing

/// The seam between this package and Hangar: the scoped `Repo` is told
/// whether its connection is *already* inside a transaction, and gets that
/// answer from the coordinator. Getting it wrong is silent and total — a repo
/// that wrongly believes it is nested emits `SAVEPOINT` with no enclosing
/// `BEGIN`, and Postgres rejects every write with 25P01.
///
/// These tests pin the answer in both directions. They exist because the
/// "no transaction open" direction regressed to `true` under a Swift 6.2.3
/// `-Onone` code-generation bug (`dictionary[key]?.field ?? default` reading
/// uninitialized memory on the missing-key path when the value is a
/// multi-field struct), which made every `repo.transaction { }` inside a
/// request scope fail on its first statement. See the comment on
/// `PostgresTransactionCoordinator.isTransactionOpen`.
extension PostgresIntegrationSuite {
@Suite("Scoped Repo ↔ transaction coordinator seam")
struct HangarRepoSeamTests {

    @Test("a scope with no open transaction hands Hangar a non-nested repo")
    func freshScopeIsNotNested() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await container.withPostgresScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                let coordinator = try container.resolve(PostgresTransactionCoordinator.self)

                #expect(coordinator.isTransactionOpen(on: connection) == false)
                #expect(try container.resolve(Repo.self, in: scope).isInTransaction == false)
            }
        }
    }

    @Test("repo.transaction commits inside a request scope")
    func hangarTransactionCommits() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            let id = "hangar-tx"

            // The failing case before the fix: BEGIN was rendered as
            // SAVEPOINT, and this threw 25P01 instead of committing.
            try await container.withPostgresScope { scope in
                let repo = try container.resolve(Repo.self, in: scope)
                try await repo.transaction { tx in
                    _ = try await tx.insert(Account(id: id, balance: 10))
                }
            }

            // A different scope, hence a different connection: the commit
            // really reached the server.
            try await container.withPostgresScope { scope in
                let repo = try container.resolve(Repo.self, in: scope)
                let stored = try await repo.one(Account.where { $0.id == id })
                #expect(stored?.balance == 10)
            }
        }
    }

    @Test("a @Transactional method's open transaction makes the repo nest")
    func openTransactionIsNested() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await container.withPostgresScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                let coordinator = try container.resolve(PostgresTransactionCoordinator.self)

                // The async-native conformance — the path an async
                // @Transactional method takes.
                let token = try await (coordinator as any FlightAsyncTransactionCoordinator).begin()
                #expect(coordinator.isTransactionOpen(on: connection) == true)
                try await (coordinator as any FlightAsyncTransactionCoordinator).commit(token)
                #expect(coordinator.isTransactionOpen(on: connection) == false)
            }
        }
    }
}
}

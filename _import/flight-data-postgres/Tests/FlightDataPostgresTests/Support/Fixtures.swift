import Foundation
import FlightDataPostgres

// MARK: - Entities (design, now Hangar @Entity — hangar-design)
//
// Column names are camelCase via @Column overrides because the migrated
// fdp_* schema predates Hangar's snake_case default (it matched
// StructuredQueries' no-conversion mapping).

struct Profile: Codable, Equatable, Sendable {
    var bio: String
    var loginCount: Int
}

/// The design doc's example entity, against the migrated fdp_users table.
@Entity("fdp_users")
struct User: Equatable, Sendable {
    @ID var id: UUID
    var email: String
    @Column("lastName") var lastName: String
    var age: Int
    @Column("createdAt") var createdAt: Date
    @JSONB var profile: Profile?
    var nickname: String?
    @Column("isActive") var isActive: Bool = true
}

@Entity("fdp_accounts")
struct Account: Equatable, Sendable {
    @ID let id: String
    var balance: Int
}

@Entity("fdp_transfers")
struct Transfer: Equatable, Sendable {
    @ID let id: String
    var origin: String
    var destination: String
    var amount: Int
}

// MARK: - Repositories (design, queries through the scoped Repo)

@Repository(scope: .scoped)
struct UserRepository {
    // Both faces of the scope: the Hangar repo for queries, and the raw
    // connection (same one underneath) for the identity assertions the
    // scoping suite makes.
    @Autowired var repo: Repo
    @Autowired var connection: PostgresConnection

    func find(byEmail email: String) async throws -> User? {
        try await repo.one(User.where { $0.email == email })
    }

    func recentlyActive(since: Date, limit: Int) async throws -> [User] {
        try await repo.all(
            User.where { $0.createdAt > since }
                .order { $0.createdAt.desc() }
                .limit(limit))
    }

    func insert(_ user: User) async throws {
        try await repo.insert(user)
    }
}

enum LedgerError: Error, Equatable {
    case insufficientFunds(account: String)
}

/// The design doc's transaction example, executable: `@Transactional`
/// expands to BEGIN/COMMIT/ROLLBACK (savepoints when nested) against the
/// scope's connection — and the scoped `Repo` shares that connection, so
/// every Hangar query below runs inside the method's transaction.
@Repository(scope: .scoped)
struct LedgerRepository {
    @Autowired var repo: Repo
    @Autowired var connection: PostgresConnection

    func balance(of account: String) async throws -> Int? {
        try await repo.one(Account.where { $0.id == account }.select { $0.balance })
    }

    @Transactional
    func transfer(_ amount: Int, from origin: String, to destination: String) async throws {
        // Read-then-write is safe here because the whole method is one
        // transaction on one connection.
        guard var debited = try await repo.one(Account.where { $0.id == origin }),
            debited.balance >= amount
        else {
            throw LedgerError.insufficientFunds(account: origin)
        }
        guard var credited = try await repo.one(Account.where { $0.id == destination }) else {
            throw LedgerError.insufficientFunds(account: destination)
        }
        debited.balance -= amount
        credited.balance += amount
        try await repo.update(debited)
        try await repo.update(credited)
        try await repo.insert(
            Transfer(id: UUID().uuidString, origin: origin, destination: destination, amount: amount))
    }

    /// Nested transactions: each inner `transfer` runs under a
    /// savepoint; a failed one rolls back to its savepoint without
    /// disturbing transfers already made in this batch.
    @Transactional
    func batchTransfer(
        _ transfers: [(amount: Int, from: String, to: String)]
    ) async throws -> Int {
        var applied = 0
        for transfer in transfers {
            do {
                try await self.transfer(transfer.amount, from: transfer.from, to: transfer.to)
                applied += 1
            } catch LedgerError.insufficientFunds {
                continue
            }
        }
        return applied
    }

    /// Transfers, then fails — rollback demonstration.
    @Transactional
    func transferThenFail(_ amount: Int, from origin: String, to destination: String) async throws {
        try await transfer(amount, from: origin, to: destination)
        throw LedgerError.insufficientFunds(account: "deliberate-failure")
    }

    func allTransfers() async throws -> [Transfer] {
        try await repo.all(Transfer.all)
    }

    /// Unwrapped debit — for tests that drive transaction control by hand
    /// through the coordinator; runs on the scope's connection either way.
    func debit(_ amount: Int, from account: String) async throws {
        guard var debited = try await repo.one(Account.where { $0.id == account }) else {
            throw LedgerError.insufficientFunds(account: account)
        }
        debited.balance -= amount
        try await repo.update(debited)
    }

    func seed(_ account: Account) async throws {
        try await repo.insert(account)
    }
}

// MARK: - The test application module

final class TestAppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [PostgresDataModule<PrimaryDataSource>.self]
    }

    init() {}

    func configure(_ container: Container) throws {
        try UserRepository._flightRegister(container)
        try LedgerRepository._flightRegister(container)
    }
}

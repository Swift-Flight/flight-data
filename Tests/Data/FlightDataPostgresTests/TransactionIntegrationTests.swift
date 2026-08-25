import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres
import Testing

/// against a real server: `@Transactional`'s expansion driving
/// BEGIN/COMMIT/ROLLBACK — and SAVEPOINTs when nested — on the scope's
/// connection.
extension PostgresIntegrationSuite {
@Suite("@Transactional against Postgres")
struct TransactionIntegrationTests {
    private func seedAccounts(_ container: Container, balances: [String: Int]) async throws {
        try await container.withPostgresScope { scope in
            let ledger = try container.resolve(LedgerRepository.self, in: scope)
            for (id, balance) in balances {
                try await ledger.seed(Account(id: id, balance: balance))
            }
        }
    }

    @Test func successfulTransferCommits() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await seedAccounts(container, balances: ["checking": 100, "savings": 0])

            try await container.withPostgresScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                try await ledger.transfer(40, from: "checking", to: "savings")
            }

            // Visible from a different scope (hence different connection):
            // the commit really reached the server.
            try await container.withPostgresScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                #expect(try await ledger.balance(of: "checking") == 60)
                #expect(try await ledger.balance(of: "savings") == 40)
            }
        }
    }

    @Test func thrownErrorRollsBackEverything() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await seedAccounts(container, balances: ["checking": 100, "savings": 0])

            await #expect(throws: LedgerError.insufficientFunds(account: "deliberate-failure")) {
                try await container.withPostgresScope { scope in
                    let ledger = try container.resolve(LedgerRepository.self, in: scope)
                    try await ledger.transferThenFail(40, from: "checking", to: "savings")
                }
            }

            try await container.withPostgresScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                #expect(try await ledger.balance(of: "checking") == 100)
                #expect(try await ledger.balance(of: "savings") == 0)
                let transfers = try await ledger.allTransfers()
                #expect(transfers.isEmpty)
            }
        }
    }

    @Test func nestedFailureRollsBackToSavepointOnly() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await seedAccounts(container, balances: ["checking": 100, "savings": 0])

            let applied = try await container.withPostgresScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                // Middle transfer exceeds the balance: its savepoint rolls
                // back; the outer transaction and sibling transfers commit.
                return try await ledger.batchTransfer([
                    (amount: 30, from: "checking", to: "savings"),
                    (amount: 1_000, from: "checking", to: "savings"),
                    (amount: 20, from: "checking", to: "savings"),
                ])
            }
            #expect(applied == 2)

            try await container.withPostgresScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                #expect(try await ledger.balance(of: "checking") == 50)
                #expect(try await ledger.balance(of: "savings") == 50)
                let transfers = try await ledger.allTransfers()
                #expect(transfers.count == 2)
            }
        }
    }

    @Test func uncommittedWorkIsInvisibleToOtherConnections() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await seedAccounts(container, balances: ["checking": 100, "savings": 0])

            try await container.withPostgresScope { outer in
                // Hand-driven through the SYNC conformance deliberately (the
                // existential cast forces the sync witness in this async
                // context) — keeps the delta-P2 blocking bridge covered now
                // that async @Transactional methods take the async-native
                // path (Core delta 14).
                let coordinator: any FlightTransactionCoordinator =
                    try container.resolve(PostgresTransactionCoordinator.self)
                let token = try coordinator.begin()
                let ledger = try container.resolve(LedgerRepository.self, in: outer)
                try await ledger.debit(40, from: "checking")

                // A second scope = a second pooled connection: must not see
                // the uncommitted debit.
                try await container.withScope { observer in
                    let observed = try container.resolve(LedgerRepository.self, in: observer)
                    #expect(try await observed.balance(of: "checking") == 100)
                }

                coordinator.rollback(token)
                #expect(try await ledger.balance(of: "checking") == 100)
            }
        }
    }

    @Test func leakedTransactionIsRolledBackOnRelease() async throws {
        try await withPostgresContainer(poolSize: 2) { container, source in
            try await cleanTables(source)
            try await seedAccounts(container, balances: ["checking": 100])

            // A scope dies with an open transaction (begin without
            // commit/rollback — a torn unit of work). The pool must roll the
            // connection back before anyone reuses it.
            try await container.withPostgresScope { scope in
                let coordinator = try container.resolve(PostgresTransactionCoordinator.self)
                _ = try await coordinator.begin()   // async-native path (delta 14)
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                try await ledger.debit(99, from: "checking")
            }

            // The rollback rides the release path asynchronously; poll
            // briefly until the single connection is pooled again.
            for _ in 0..<50 where source.availableConnections == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(source.availableConnections == 1)

            try await container.withPostgresScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                #expect(try await ledger.balance(of: "checking") == 100)
            }
        }
    }

    @Test func transactionalWithoutCoordinatorBindingIsInert() async throws {
        // Without withPostgresScope/withPostgresTransactions the task-local
        // coordinator is Core's no-op — @Transactional must throw loudly
        // rather than silently skip transaction semantics? No: Core's
        // documented contract is that the default coordinator is a no-op, so
        // the method runs untransacted. This pins that behavior so it is a
        // documented choice, not an accident.
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await seedAccounts(container, balances: ["checking": 100, "savings": 0])
            try await container.withScope { scope in
                let ledger = try container.resolve(LedgerRepository.self, in: scope)
                try await ledger.transfer(10, from: "checking", to: "savings")
                #expect(try await ledger.balance(of: "savings") == 10)
            }
        }
    }
}
}

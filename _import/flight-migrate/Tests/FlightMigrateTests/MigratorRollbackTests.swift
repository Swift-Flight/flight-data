import Testing

@testable import FlightMigrate

@Suite("FlightMigrator.rollback")
struct MigratorRollbackTests {
    let lockKey = FlightMigrator.defaultAdvisoryLockKey

    private func threeApplied() -> ([MigrationEntry], FakeDatabase) {
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(2, "CreateBeta", CreateBeta.self),
            entry(3, "CreateGamma", CreateGamma.self),
        ]
        let db = FakeDatabase(
            tableCreated: true,
            seededRows: [
                appliedRow(1, "CreateAlpha"),
                appliedRow(2, "CreateBeta"),
                appliedRow(3, "CreateGamma"),
            ])
        return (migrations, db)
    }

    @Test func defaultRollsBackOnlyTheLatest() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)

        let rolledBack = try await migrator.rollback()

        #expect(rolledBack.map(\.version) == [3])
        #expect(await db.appliedVersions() == [1, 2])

        let ops = await db.transcript
        #expect(
            ops == [
                .acquireLock(lockKey),
                .tableExists,
                .fetchApplied,
                // down + bookkeeping delete in one transaction
                .begin,
                .execute("DROP TABLE \"gamma\""),
                .delete(3),
                .commit,
                .releaseLock(lockKey),
            ])
    }

    @Test func stepsRollBackNewestFirst() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)

        let rolledBack = try await migrator.rollback(steps: 2)

        #expect(rolledBack.map(\.version) == [3, 2])
        #expect(await db.appliedVersions() == [1])
    }

    @Test func stepsBeyondAppliedRevertsEverything() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)

        let rolledBack = try await migrator.rollback(steps: 10)

        #expect(rolledBack.map(\.version) == [3, 2, 1])
        #expect(await db.appliedVersions() == [])
    }

    @Test func toVersionLeavesTargetApplied() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)

        let rolledBack = try await migrator.rollback(to: 1)

        #expect(rolledBack.map(\.version) == [3, 2])
        #expect(await db.appliedVersions() == [1])
    }

    @Test func toZeroRevertsEverything() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)

        let rolledBack = try await migrator.rollback(to: 0)

        #expect(rolledBack.map(\.version) == [3, 2, 1])
        #expect(await db.appliedVersions() == [])
    }

    @Test func toUnknownVersionFails() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)

        do {
            try await migrator.rollback(to: 42)
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .rollbackTargetNotApplied(42) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(await db.appliedVersions() == [1, 2, 3])
        #expect(await db.transcript.contains(.releaseLock(lockKey)))
    }

    @Test func zeroStepsIsInvalid() async throws {
        let (migrations, db) = threeApplied()
        let migrator = makeMigrator(database: db, migrations: migrations)
        await #expect(throws: MigrationError.self) {
            try await migrator.rollback(steps: 0)
        }
        #expect(await db.transcript.isEmpty)
    }

    @Test func nothingAppliedIsANoOp() async throws {
        let db = FakeDatabase()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        let rolledBack = try await migrator.rollback()

        #expect(rolledBack.isEmpty)
        // Ledger absent: no fetch, nothing created — rollback never creates the table.
        let ops = await db.transcript
        #expect(ops == [.acquireLock(lockKey), .tableExists, .releaseLock(lockKey)])
        #expect(await db.tableCreated == false)
    }

    @Test func rollingBackUnknownMigrationFails() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(9, "Mystery")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        do {
            try await migrator.rollback()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .cannotRollBackUnknownMigration(9, "Mystery") = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(error.description.contains("'down' is unavailable"))
        }
        #expect(await db.appliedVersions() == [9])
    }

    @Test func rollingBackDriftedMigrationFails() async throws {
        // A drifted migration's `down` no longer matches what was applied — hard error,
        // same as migrate; repair first if the edit was safe.
        let db = FakeDatabase(
            tableCreated: true, seededRows: [appliedRow(1, "CreateAlpha", checksum: "tampered")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        do {
            try await migrator.rollback()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .checksumMismatch = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(await db.appliedVersions() == [1])
    }

    @Test func failingDownRollsBackTransactionAndKeepsRow() async throws {
        let migrations = [entry(1, "FailsSecondStatement", FailsSecondStatement.self)]
        let db = FakeDatabase(
            tableCreated: true, seededRows: [appliedRow(1, "FailsSecondStatement")])
        await db.failOnExecute(containing: "SELECT unboom()", error: FakeDatabase.StubError(id: 3))
        let migrator = makeMigrator(database: db, migrations: migrations)

        do {
            try await migrator.rollback()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .migrationFailed(1, _, .down, true, _, _, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(error.description.contains("rolling back"))
        }

        let ops = await db.transcript
        #expect(ops.contains(.rollback))
        #expect(!ops.contains(.delete(1)))
        // Still recorded as applied: the down never completed.
        #expect(await db.appliedVersions() == [1])
        #expect(ops.contains(.releaseLock(lockKey)))
    }

    @Test func unwrappedDownDeletesRowWithoutTransaction() async throws {
        let db = FakeDatabase(
            tableCreated: true, seededRows: [appliedRow(1, "UnwrappedConcurrent")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "UnwrappedConcurrent", UnwrappedConcurrent.self)])

        let rolledBack = try await migrator.rollback()

        #expect(rolledBack.map(\.version) == [1])
        let ops = await db.transcript
        #expect(
            ops == [
                .acquireLock(lockKey),
                .tableExists,
                .fetchApplied,
                .execute("DROP INDEX CONCURRENTLY one"),
                .delete(1),
                .releaseLock(lockKey),
            ])
    }
}

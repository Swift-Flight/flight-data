import Testing

@testable import FlightMigrate

@Suite("FlightMigrator.status")
struct MigratorStatusTests {
    @Test func mixedStates() async throws {
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),  // applied, ok
            entry(2, "CreateBeta", CreateBeta.self),  // applied, drifted
            entry(4, "CreateGamma", CreateGamma.self),  // pending
            entry(5, "UnwrappedConcurrent", UnwrappedConcurrent.self),  // pending, unwrapped
        ]
        let db = FakeDatabase(
            tableCreated: true,
            seededRows: [
                appliedRow(1, "CreateAlpha"),
                appliedRow(2, "CreateBeta", checksum: "tampered"),
                appliedRow(3, "Mystery"),  // missing locally
            ])
        let migrator = makeMigrator(database: db, migrations: migrations)

        let status = try await migrator.status()

        #expect(status.applied.count == 3)
        #expect(status.applied[0].state == .ok)
        #expect(
            status.applied[1].state
                == .checksumMismatch(recorded: "tampered", current: checksum(2, "CreateBeta")))
        #expect(status.applied[2].state == .missingLocally)
        #expect(status.pending.map(\.version) == [4, 5])
        #expect(status.pending.map(\.transactional) == [true, false])
        #expect(status.hasDrift)
        #expect(!status.isUpToDate)

        // Status is read-only: no lock, no transactions, no table creation.
        let ops = await db.transcript
        #expect(ops == [.tableExists, .fetchApplied])
    }

    @Test func missingLedgerMeansEverythingPending() async throws {
        let db = FakeDatabase()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        let status = try await migrator.status()

        #expect(status.applied.isEmpty)
        #expect(status.pending.map(\.version) == [1])
        #expect(await db.tableCreated == false)
    }
}

@Suite("FlightMigrator.repair")
struct MigratorRepairTests {
    @Test func rebaselinesDriftAtomicallyAndReportsMissing() async throws {
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(2, "CreateBeta", CreateBeta.self),
        ]
        let db = FakeDatabase(
            tableCreated: true,
            seededRows: [
                appliedRow(1, "CreateAlpha"),  // fine, untouched
                appliedRow(2, "CreateBeta", checksum: "tampered"),
                appliedRow(3, "Mystery"),  // unrepairable
            ])
        let events = EventCollector()
        let migrator = makeMigrator(database: db, migrations: migrations, onEvent: events.collect)

        let outcome = try await migrator.repair()

        #expect(outcome.repaired.count == 1)
        #expect(outcome.repaired[0].version == 2)
        #expect(outcome.repaired[0].oldChecksum == "tampered")
        #expect(outcome.repaired[0].newChecksum == checksum(2, "CreateBeta"))
        #expect(outcome.missingLocally == [UnknownApplied(version: 3, name: "Mystery")])

        let ops = await db.transcript
        let lockKey = FlightMigrator.defaultAdvisoryLockKey
        #expect(
            ops == [
                .acquireLock(lockKey),
                .tableExists,
                .fetchApplied,
                .begin, .update(2), .commit,
                .releaseLock(lockKey),
            ])
        #expect(
            events.events.contains {
                if case .repairedChecksum(2, "CreateBeta", "tampered", _) = $0 { return true }
                return false
            })

        // Migrate now passes verification.
        _ = try await migrator.migrate()
    }

    @Test func renamedMigrationIsRepaired() async throws {
        // Same version, renamed file: checksum embeds the name, so both change.
        let db = FakeDatabase(
            tableCreated: true,
            seededRows: [appliedRow(1, "OldName", checksum: checksum(1, "OldName"))])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        let outcome = try await migrator.repair()

        #expect(outcome.repaired.count == 1)
        let rows = await db.rows
        #expect(rows[0].name == "CreateAlpha")
        #expect(rows[0].checksum == checksum(1, "CreateAlpha"))
    }

    @Test func cleanLedgerNeedsNoRepair() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        let outcome = try await migrator.repair()

        #expect(outcome.repaired.isEmpty)
        #expect(outcome.missingLocally.isEmpty)
        let ops = await db.transcript
        #expect(!ops.contains(.begin))  // no transaction when there is nothing to update
    }

    @Test func missingLedgerIsANoOp() async throws {
        let db = FakeDatabase()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        let outcome = try await migrator.repair()

        #expect(outcome == RepairOutcome(repaired: [], missingLocally: []))
        #expect(await db.tableCreated == false)
    }
}

@Suite("FlightMigrator.plan")
struct MigratorPlanTests {
    @Test func planMigrateRendersPendingSQLWithoutExecuting() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(2, "CreateBeta", CreateBeta.self),
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        let plan = try await migrator.planMigrate()

        #expect(plan.direction == .up)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].version == 2)
        #expect(plan.steps[0].transactional)
        #expect(
            plan.steps[0].statements == [
                "CREATE TABLE \"beta\" (\n    \"x\" INTEGER\n)",
                "CREATE INDEX \"beta_x_idx\" ON \"beta\" (\"x\")",
            ])

        // Nothing executed, nothing locked, nothing recorded.
        let ops = await db.transcript
        #expect(ops == [.tableExists, .fetchApplied])
        #expect(await db.appliedVersions() == [1])
    }

    @Test func planMigrateStillFailsOnDrift() async throws {
        // A dry run mirrors the real run's verification: previewing against a drifted
        // ledger is an error, exactly as migrate() would be.
        let db = FakeDatabase(
            tableCreated: true, seededRows: [appliedRow(1, "CreateAlpha", checksum: "tampered")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        await #expect(throws: MigrationError.self) {
            try await migrator.planMigrate()
        }
    }

    @Test func planRollbackRendersDownSQL() async throws {
        let db = FakeDatabase(
            tableCreated: true,
            seededRows: [appliedRow(1, "CreateAlpha"), appliedRow(2, "CreateBeta")])
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(2, "CreateBeta", CreateBeta.self),
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        let plan = try await migrator.planRollback(steps: 2)

        #expect(plan.direction == .down)
        #expect(plan.steps.map(\.version) == [2, 1])
        #expect(plan.steps[0].statements == ["DROP TABLE \"beta\""])
        #expect(plan.steps[1].statements == ["DROP TABLE \"alpha\""])
        #expect(await db.appliedVersions() == [1, 2])
    }

    @Test func planRollbackToValidatesTarget() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        await #expect(throws: MigrationError.self) {
            try await migrator.planRollback(to: 7)
        }
    }
}

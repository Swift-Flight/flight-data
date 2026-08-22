import Testing

@testable import FlightMigrate

@Suite("FlightMigrator.migrate")
struct MigratorMigrateTests {
    let lockKey = FlightMigrator.defaultAdvisoryLockKey

    @Test func freshDatabaseAppliesEverythingInOrder() async throws {
        let db = FakeDatabase()
        let migrations = [
            entry(2, "CreateBeta", CreateBeta.self),
            entry(1, "CreateAlpha", CreateAlpha.self),  // deliberately unsorted input
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        let applied = try await migrator.migrate()

        #expect(applied.map(\.name) == ["CreateAlpha", "CreateBeta"])
        #expect(await db.appliedVersions() == [1, 2])

        let ops = await db.transcript
        #expect(
            ops == [
                .acquireLock(lockKey),
                .tableExists,
                .begin, .createTable, .commit,  // ledger creation, inside a transaction (§4)
                .fetchApplied,
                // CreateAlpha: body + bookkeeping inside one transaction (§3.1)
                .begin,
                .execute("CREATE TABLE \"alpha\" (\n    \"x\" INTEGER NOT NULL\n)"),
                .insert(1),
                .commit,
                // CreateBeta: two statements
                .begin,
                .execute("CREATE TABLE \"beta\" (\n    \"x\" INTEGER\n)"),
                .execute("CREATE INDEX \"beta_x_idx\" ON \"beta\" (\"x\")"),
                .insert(2),
                .commit,
                .releaseLock(lockKey),
            ])
    }

    @Test func upToDateDatabaseDoesNothing() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let events = EventCollector()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)],
            onEvent: events.collect)

        let applied = try await migrator.migrate()

        #expect(applied.isEmpty)
        let ops = await db.transcript
        #expect(ops == [.acquireLock(lockKey), .tableExists, .fetchApplied, .releaseLock(lockKey)])
        #expect(
            events.events.contains {
                if case .upToDate = $0 { return true }
                return false
            })
    }

    @Test func wrappedFailureRollsBackAndHalts() async throws {
        let db = FakeDatabase(tableCreated: true)
        await db.failOnExecute(containing: "SELECT boom()", error: FakeDatabase.StubError(id: 7))
        let migrations = [
            entry(1, "FailsSecondStatement", FailsSecondStatement.self),
            entry(2, "CreateGamma", CreateGamma.self),  // must never run
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        await #expect(throws: MigrationError.self) {
            try await migrator.migrate()
        }

        let ops = await db.transcript
        // The failing migration: BEGIN, first statement, failing statement, ROLLBACK.
        // No bookkeeping insert, no second migration, and the lock is still released.
        #expect(
            ops == [
                .acquireLock(lockKey),
                .tableExists,
                .fetchApplied,
                .begin,
                .execute("CREATE TABLE \"target\" (\n    \"x\" INTEGER\n)"),
                .execute("SELECT boom()"),
                .rollback,
                .releaseLock(lockKey),
            ])
        #expect(await db.appliedVersions() == [])
    }

    @Test func wrappedFailureErrorDescribesCleanRollback() async throws {
        let db = FakeDatabase(tableCreated: true)
        await db.failOnExecute(containing: "SELECT boom()", error: FakeDatabase.StubError(id: 7))
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "FailsSecondStatement", FailsSecondStatement.self)])

        do {
            try await migrator.migrate()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard
                case .migrationFailed(
                    let version, let name, let direction, let transactional, let phase,
                    let statementsApplied, _) = error
            else {
                Issue.record("unexpected error case: \(error)")
                return
            }
            #expect(version == 1)
            #expect(name == "FailsSecondStatement")
            #expect(direction == .up)
            #expect(transactional)
            #expect(statementsApplied == 1)
            guard case .statement(let index, let total, let sql) = phase else {
                Issue.record("unexpected phase")
                return
            }
            #expect(index == 1)
            #expect(total == 2)
            #expect(sql == "SELECT boom()")
            #expect(error.description.contains("statement 2 of 2"))
            #expect(error.description.contains("The transaction was rolled back"))
            #expect(error.description.contains("unchanged by this migration"))
        }
    }

    @Test func bookkeepingFailureRollsBackBody() async throws {
        let db = FakeDatabase(tableCreated: true)
        await db.fail(with: FakeDatabase.StubError(id: 1)) { op in
            if case .insert = op { return true }
            return false
        }
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        do {
            try await migrator.migrate()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .migrationFailed(_, _, _, _, .bookkeeping, _, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        let ops = await db.transcript
        #expect(ops.contains(.rollback))
        #expect(await db.appliedVersions() == [])
    }

    @Test func commitFailureIsReportedAsCommitPhase() async throws {
        let db = FakeDatabase(tableCreated: true)
        await db.fail(with: FakeDatabase.StubError(id: 2)) { $0 == .commit }
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        do {
            try await migrator.migrate()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .migrationFailed(_, _, _, _, .commit, _, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(await db.appliedVersions() == [])
    }

    @Test func unwrappedMigrationRunsWithoutTransaction() async throws {
        let db = FakeDatabase(tableCreated: true)
        let events = EventCollector()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "UnwrappedConcurrent", UnwrappedConcurrent.self)],
            onEvent: events.collect)

        _ = try await migrator.migrate()

        let ops = await db.transcript
        #expect(
            ops == [
                .acquireLock(lockKey),
                .tableExists,
                .fetchApplied,
                .execute("CREATE INDEX CONCURRENTLY one ON t (a)"),
                .execute("CREATE INDEX CONCURRENTLY two ON t (b)"),
                .insert(1),
                .releaseLock(lockKey),
            ])
        // Multi-statement unwrapped migration warns (§3.2).
        #expect(
            events.events.contains {
                if case .unwrappedMigrationHasMultipleStatements(_, _, 2, .up) = $0 { return true }
                return false
            })
    }

    @Test func unwrappedFailureExplainsManualIntervention() async throws {
        let db = FakeDatabase(tableCreated: true)
        await db.failOnExecute(
            containing: "CONCURRENTLY two", error: FakeDatabase.StubError(id: 9))
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "UnwrappedConcurrent", UnwrappedConcurrent.self)])

        do {
            try await migrator.migrate()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard
                case .migrationFailed(_, _, _, let transactional, _, let statementsApplied, _) =
                    error
            else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(!transactional)
            #expect(statementsApplied == 1)
            #expect(error.description.contains("NOT rolled back"))
            #expect(error.description.contains("Manual intervention may be required"))
            #expect(error.description.contains("The version was not recorded"))
        }

        let ops = await db.transcript
        #expect(!ops.contains(.begin))
        #expect(!ops.contains(.rollback))
        #expect(ops.contains(.releaseLock(lockKey)))  // lock released even on failure
        #expect(await db.appliedVersions() == [])  // version not recorded → re-run possible
    }

    @Test func checksumDriftHaltsWithDesignDocumentMessage() async throws {
        let db = FakeDatabase(
            tableCreated: true,
            seededRows: [appliedRow(1, "CreateAlpha", checksum: "tampered")])
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(2, "CreateBeta", CreateBeta.self),
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        do {
            try await migrator.migrate()
            Issue.record("expected drift error")
        } catch let error as MigrationError {
            guard case .checksumMismatch(let version, let name, _, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(version == 1)
            #expect(name == "CreateAlpha")
            // Design §5's exact wording.
            #expect(
                error.description.contains(
                    """
                    migration 1_CreateAlpha has been modified since it was applied (checksum \
                    mismatch). Applied migrations are immutable — create a new migration to make \
                    further changes.
                    """))
        }

        // Nothing ran: no BEGIN after ledger read, and pending migration 2 untouched.
        let ops = await db.transcript
        #expect(!ops.contains(.begin))
        #expect(await db.appliedVersions() == [1])
        #expect(ops.contains(.releaseLock(lockKey)))
    }

    @Test func unknownAppliedWarnsByDefault() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(99, "FromTheFuture")])
        let events = EventCollector()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)],
            onEvent: events.collect)

        let applied = try await migrator.migrate()

        #expect(applied.map(\.version) == [1])
        #expect(
            events.events.contains {
                if case .unknownAppliedVersions(let unknown) = $0 {
                    return unknown == [UnknownApplied(version: 99, name: "FromTheFuture")]
                }
                return false
            })
    }

    @Test func unknownAppliedFailsWhenStrict() async throws {
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(99, "FromTheFuture")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)],
            failOnUnknownApplied: true)

        do {
            try await migrator.migrate()
            Issue.record("expected failure")
        } catch let error as MigrationError {
            guard case .unknownAppliedMigrations(let unknown) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(unknown.map(\.version) == [99])
        }
        #expect(await db.appliedVersions() == [99])
    }

    @Test func outOfOrderPendingIsAppliedInVersionOrder() async throws {
        // A merged branch adds version 2 after version 3 was already applied:
        // pending = registered − applied, applied in ascending order (Ecto's model).
        let db = FakeDatabase(tableCreated: true, seededRows: [appliedRow(3, "CreateGamma")])
        let migrations = [
            entry(3, "CreateGamma", CreateGamma.self),
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(2, "CreateBeta", CreateBeta.self),
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        let applied = try await migrator.migrate()

        #expect(applied.map(\.version) == [1, 2])
        #expect(await db.appliedVersions() == [1, 2, 3])
    }

    @Test func emptyMigrationIsRecordedAndWarns() async throws {
        let db = FakeDatabase(tableCreated: true)
        let events = EventCollector()
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "EmptyMigration", EmptyMigration.self)],
            onEvent: events.collect)

        let applied = try await migrator.migrate()

        #expect(applied.count == 1)
        #expect(await db.appliedVersions() == [1])
        #expect(
            events.events.contains {
                if case .emptyMigration(1, "EmptyMigration", .up) = $0 { return true }
                return false
            })
    }

    @Test func duplicateVersionsRejected() async throws {
        let db = FakeDatabase()
        let migrations = [
            entry(1, "CreateAlpha", CreateAlpha.self),
            entry(1, "CreateBeta", CreateBeta.self),
        ]
        let migrator = makeMigrator(database: db, migrations: migrations)

        await #expect(throws: MigrationError.self) {
            try await migrator.migrate()
        }
        // Validation fails before any database work.
        #expect(await db.transcript.isEmpty)
    }

    @Test func nonPositiveVersionRejected() async throws {
        let db = FakeDatabase()
        let migrator = makeMigrator(
            database: db, migrations: [entry(0, "CreateAlpha", CreateAlpha.self)])
        await #expect(throws: MigrationError.self) {
            try await migrator.migrate()
        }
    }

    @Test func eventsCarryTimingAndStatementCounts() async throws {
        let db = FakeDatabase(tableCreated: true)
        let events = EventCollector()
        let migrator = makeMigrator(
            database: db, migrations: [entry(2, "CreateBeta", CreateBeta.self)],
            onEvent: events.collect)

        _ = try await migrator.migrate()

        var sawWill = false
        var sawDid = false
        for event in events.events {
            if case .willApply(2, "CreateBeta", true, 2) = event { sawWill = true }
            if case .didApply(2, "CreateBeta", _) = event { sawDid = true }
        }
        #expect(sawWill)
        #expect(sawDid)
    }
}

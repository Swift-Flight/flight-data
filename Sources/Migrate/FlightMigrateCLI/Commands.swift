import ArgumentParser
import FlightMigrate
import Foundation

/// Reported by `--version`.
///
/// Hand-maintained, and it has to be: a build-tool plugin cannot see the tag,
/// and reading the package manifest at runtime is not a thing a compiled
/// binary can do. It sat at "0.1.0" through two releases, so it is pinned by a
/// test that reads the changelog's most recent version.
let flightMigrateVersion = "0.4.0"

/// Options shared by every command that connects to the database.
struct DatabaseOptions: ParsableArguments {
    @Option(
        name: .customLong("database-url"),
        help: """
            Postgres connection URL (postgres://user:pass@host:port/db?sslmode=...). \
            Defaults to $FLIGHT_DATABASE_URL, then $DATABASE_URL.
            """)
    var databaseUrl: String?

    @Option(
        name: .customLong("migrations-table"),
        help: "Bookkeeping table name (may be schema-qualified).")
    var migrationsTable: String = "flight_migrations"

    @Option(
        name: .customLong("lock-timeout"),
        help: """
            Seconds to wait for the migration advisory lock before giving up;             0 waits indefinitely. Defaults to 30. An interactive run you are             watching is the case `0` is for — the doc comment on the setting has             said so since it was added, while the CLI offered no way to ask for it.
            """)
    var lockTimeout: Int = 30

    @Option(
        name: .customLong("advisory-lock-key"),
        help: """
            The advisory lock key held for the duration of a mutating run.             Change it only if it collides with a lock scheme the application             already uses.
            """)
    var advisoryLockKey: Int64?

    @Flag(
        name: .customLong("fail-on-unknown-applied"),
        help: """
            Treat applied versions this binary does not know about as an error.             Off by default: an older binary seeing a newer schema is normal             mid-deploy. On, it catches a deleted migration file.
            """)
    var failOnUnknownApplied = false

    @Flag(name: .shortAndLong, help: "Log SQL statements and connection details.")
    var verbose = false
}

struct RootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: commandName(),
        abstract: "Postgres-first SQL migrations for server-side Swift.",
        discussion: """
            Running with no subcommand applies all pending migrations. Each migration runs \
            inside its own transaction together with its bookkeeping record, so a failure \
            rolls back cleanly (Postgres transactional DDL). Concurrent runs are serialized \
            by a Postgres advisory lock.
            """,
        version: flightMigrateVersion,
        subcommands: [
            ApplyCommand.self, StatusCommand.self, RollbackCommand.self, CreateCommand.self,
            RepairCommand.self,
        ],
        defaultSubcommand: ApplyCommand.self
    )

    private static func commandName() -> String {
        guard let path = CommandLine.arguments.first, !path.isEmpty else {
            return "flight-migrate"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - apply

struct ApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply all pending migrations (the default subcommand)."
    )

    @OptionGroup var database: DatabaseOptions

    @Flag(help: "Print the SQL that would run, without executing anything.")
    var dryRun = false

    func run() async throws {
        if dryRun {
            let plan = try await Runtime.withMigrator(options: database) { migrator in
                try await migrator.planMigrate()
            }
            Printer.print(plan: plan)
            return
        }

        let applied = try await Runtime.withMigrator(
            options: database, onEvent: Printer.printEvent
        ) { migrator in
            try await migrator.migrate()
        }
        if !applied.isEmpty {
            print("Done — applied \(applied.count) migration\(applied.count == 1 ? "" : "s").")
        }
    }
}

// MARK: - status

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show applied and pending migrations without changing anything."
    )

    @OptionGroup var database: DatabaseOptions

    @Flag(help: "Emit machine-readable JSON.")
    var json = false

    func run() async throws {
        let status = try await Runtime.withMigrator(options: database) { migrator in
            try await migrator.status()
        }
        if json {
            try Printer.printJSON(status: status)
        } else {
            Printer.print(status: status)
        }
    }
}

// MARK: - rollback

struct RollbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Revert the most recently applied migration(s).",
        discussion: """
            With --to VERSION, reverts every migration applied after VERSION, leaving \
            VERSION itself applied; --to 0 reverts everything.
            """
    )

    @OptionGroup var database: DatabaseOptions

    @Option(help: "How many migrations to revert (default 1).")
    var steps: Int?

    @Option(help: "Roll back to this version (it stays applied). 0 reverts everything.")
    var to: Int64?

    @Flag(help: "Print the SQL that would run, without executing anything.")
    var dryRun = false

    func validate() throws {
        if steps != nil && to != nil {
            throw ValidationError("--steps and --to are mutually exclusive.")
        }
        if let steps, steps < 1 {
            throw ValidationError("--steps must be at least 1.")
        }
    }

    func run() async throws {
        let steps = self.steps
        let to = self.to
        if dryRun {
            let plan = try await Runtime.withMigrator(options: database) {
                migrator -> MigrationPlan in
                if let to {
                    return try await migrator.planRollback(to: to)
                }
                return try await migrator.planRollback(steps: steps ?? 1)
            }
            Printer.print(plan: plan)
            return
        }

        let rolledBack = try await Runtime.withMigrator(
            options: database, onEvent: Printer.printEvent
        ) { migrator -> [RolledBackMigration] in
            if let to {
                return try await migrator.rollback(to: to)
            }
            return try await migrator.rollback(steps: steps ?? 1)
        }
        if rolledBack.isEmpty {
            print("Nothing to roll back.")
        } else {
            print(
                "Done — rolled back \(rolledBack.count) migration\(rolledBack.count == 1 ? "" : "s")."
            )
        }
    }
}

// MARK: - create

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Generate a new migration file with a UTC timestamp prefix.",
        discussion: """
            The timestamp is always UTC (YYYYMMDDHHMMSS) and always generated — never \
            hand-typed — so ordering can't silently diverge across a team's timezones. The \
            name must be a valid Swift type name; it is used verbatim.
            """
    )

    @Argument(help: "The migration type name, e.g. CreateUsers.")
    var name: String

    @Option(
        help: """
            Directory for the new file. Defaults to Sources/Migrations or Migrations, \
            whichever exists.
            """)
    var directory: String?

    func run() async throws {
        let dir = try Scaffold.resolveDirectory(
            flag: directory,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let created = try Scaffold.makeMigration(name: name, date: Date(), directory: dir)
        print("Created \(created.url.path)")
    }
}

// MARK: - repair

struct RepairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Re-baseline recorded checksums after a confirmed-safe edit.",
        discussion: """
            Applied migrations are immutable; edits are normally a hard error. If an edit \
            is confirmed-safe (formatting, comments), repair updates the recorded checksums \
            to match the current source. It never touches the schema.
            """
    )

    @OptionGroup var database: DatabaseOptions

    func run() async throws {
        let outcome = try await Runtime.withMigrator(options: database) { migrator in
            try await migrator.repair()
        }
        for item in outcome.repaired {
            print(
                """
                Re-baselined \(item.version)_\(item.name): \
                \(item.oldChecksum.prefix(12))… → \(item.newChecksum.prefix(12))…
                """)
        }
        for item in outcome.missingLocally {
            print(
                """
                warning: \(item.version)_\(item.name) is applied in the database but not \
                registered in this binary; repair cannot help with that.
                """)
        }
        if outcome.repaired.isEmpty {
            print("No checksum repairs needed.")
        }
    }
}

// MARK: - Output

enum Printer {
    @Sendable static func printEvent(_ event: MigrationEvent) {
        switch event {
        case .upToDate:
            Swift.print("Database is up to date — nothing to apply.")
        case .willApply(let version, let name, let transactional, let statementCount):
            let mode = transactional ? "transactional" : "NOT wrapped in a transaction"
            let plural = statementCount == 1 ? "" : "s"
            Swift.print("→ \(version)_\(name) (\(mode), \(statementCount) statement\(plural))")
        case .didApply(let version, let name, let duration):
            Swift.print("✓ \(version)_\(name) (\(Runtime.format(duration)))")
        case .willRollBack(let version, let name, let transactional, let statementCount):
            let mode = transactional ? "transactional" : "NOT wrapped in a transaction"
            let plural = statementCount == 1 ? "" : "s"
            Swift.print("→ reverting \(version)_\(name) (\(mode), \(statementCount) statement\(plural))")
        case .didRollBack(let version, let name, let duration):
            Swift.print("✓ reverted \(version)_\(name) (\(Runtime.format(duration)))")
        case .unknownAppliedVersions(let unknown):
            for item in unknown {
                Swift.print(
                    """
                    warning: \(item.version)_\(item.name) is recorded as applied but not \
                    registered in this binary (older binary than schema, or a deleted file).
                    """)
            }
        case .unwrappedMigrationHasMultipleStatements(let version, let name, let count, _):
            Swift.print(
                """
                warning: \(version)_\(name) runs \(count) statements without a transaction; \
                a partial failure cannot be rolled back automatically. Prefer one statement \
                per unwrapped migration.
                """)
        case .emptyMigration(let version, let name, let direction):
            Swift.print("warning: \(version)_\(name) has no statements in '\(direction.rawValue)'.")
        case .repairedChecksum:
            break  // repair prints its own summary
        }
    }

    static func print(plan: MigrationPlan) {
        let verb = plan.direction == .up ? "apply" : "roll back"
        guard !plan.steps.isEmpty else {
            Swift.print("Nothing to \(verb).")
            return
        }
        Swift.print("Would \(verb) \(plan.steps.count) migration\(plan.steps.count == 1 ? "" : "s"):")
        for step in plan.steps {
            let mode = step.transactional ? "transactional" : "NOT wrapped in a transaction"
            Swift.print("\n-- \(step.version)_\(step.name) (\(mode))")
            for statement in step.statements {
                Swift.print("\(statement);")
            }
            if step.statements.isEmpty {
                Swift.print("-- (no statements)")
            }
        }
        Swift.print("\nDry run: no changes were made.")
    }

    static func print(status: MigrationStatus) {
        if status.applied.isEmpty {
            Swift.print("No applied migrations.")
        } else {
            Swift.print("Applied migrations:")
            for item in status.applied {
                let stateText: String
                switch item.state {
                case .ok:
                    stateText = "ok"
                case .checksumMismatch:
                    stateText = "MODIFIED since applied (checksum mismatch) — see 'repair'"
                case .missingLocally:
                    stateText = "missing locally (not registered in this binary)"
                }
                Swift.print(
                    "  \(item.version)_\(item.name)  applied \(iso8601(item.appliedAt))  \(stateText)"
                )
            }
        }
        if status.pending.isEmpty {
            Swift.print("No pending migrations — database is up to date.")
        } else {
            Swift.print("Pending migrations:")
            for item in status.pending {
                let mode = item.transactional ? "transactional" : "not wrapped in a transaction"
                Swift.print("  \(item.version)_\(item.name)  (\(mode))")
            }
        }
    }

    static func printJSON(status: MigrationStatus) throws {
        struct AppliedJSON: Codable {
            let version: Int64
            let name: String
            let appliedAt: String
            let state: String
            let recordedChecksum: String?
            let currentChecksum: String?
        }
        struct PendingJSON: Codable {
            let version: Int64
            let name: String
            let transactional: Bool
        }
        struct StatusJSON: Codable {
            let applied: [AppliedJSON]
            let pending: [PendingJSON]
            let upToDate: Bool
            let hasDrift: Bool
        }

        let payload = StatusJSON(
            applied: status.applied.map { item in
                switch item.state {
                case .ok:
                    return AppliedJSON(
                        version: item.version, name: item.name, appliedAt: iso8601(item.appliedAt),
                        state: "ok", recordedChecksum: nil, currentChecksum: nil)
                case .checksumMismatch(let recorded, let current):
                    return AppliedJSON(
                        version: item.version, name: item.name, appliedAt: iso8601(item.appliedAt),
                        state: "checksum_mismatch", recordedChecksum: recorded,
                        currentChecksum: current)
                case .missingLocally:
                    return AppliedJSON(
                        version: item.version, name: item.name, appliedAt: iso8601(item.appliedAt),
                        state: "missing_locally", recordedChecksum: nil, currentChecksum: nil)
                }
            },
            pending: status.pending.map {
                PendingJSON(version: $0.version, name: $0.name, transactional: $0.transactional)
            },
            upToDate: status.isUpToDate,
            hasDrift: status.hasDrift
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        Swift.print(String(decoding: data, as: UTF8.self))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

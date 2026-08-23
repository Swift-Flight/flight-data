import Foundation

/// Errors thrown by `FlightMigrator`. Messages are written for the operator at 2 a.m.:
/// they say what happened, what state the database is in, and what to do next.
public enum MigrationError: Error, CustomStringConvertible, LocalizedError, Sendable {
    /// The registered migration list itself is invalid (duplicate or non-positive versions).
    case invalidMigrationSet(reason: String)

    /// An already-applied migration's source no longer matches its recorded checksum
    ///. Halts the run.
    case checksumMismatch(version: Int64, name: String, recorded: String, current: String)

    /// The bookkeeping table records versions this binary doesn't know about, and the
    /// migrator was configured with `failOnUnknownApplied = true`.
    case unknownAppliedMigrations([UnknownApplied])

    /// A migration failed while running. `statementsApplied` counts body statements that
    /// had already executed; for a transactional migration these were all rolled back.
    case migrationFailed(
        version: Int64,
        name: String,
        direction: MigrationDirection,
        transactional: Bool,
        phase: FailurePhase,
        statementsApplied: Int,
        underlying: any Error
    )

    /// `rollback(to:)` was given a version that is neither 0 nor an applied migration.
    case rollbackTargetNotApplied(version: Int64)

    /// A rollback needs a migration's `down`, but the version isn't in the registered list
    /// (e.g. the binary predates it, or the file was deleted).
    case cannotRollBackUnknownMigration(version: Int64, name: String)

    /// A request that is invalid regardless of database state (e.g. `rollback(steps: 0)`).
    /// The advisory lock could not be acquired within the configured timeout.
    ///
    /// Another migration run holds it, or a session leaked it. Check for a
    /// wedged deploy before raising the timeout.
    case lockTimeout(key: Int64, waited: Duration)

    case invalidRequest(String)

    /// Where within a run a migration failed.
    public enum FailurePhase: Sendable {
        /// Opening the wrapping transaction.
        case begin
        /// A body statement (0-based index into the migration's statements).
        case statement(index: Int, total: Int, sql: String)
        /// The bookkeeping insert/delete.
        case bookkeeping
        /// The final `COMMIT`.
        case commit
    }

    public var description: String {
        switch self {
        case .invalidMigrationSet(let reason):
            return "invalid migration set: \(reason)"

        case .checksumMismatch(let version, let name, let recorded, let current):
            // Lead with the condition; details follow.
            return """
                migration \(version)_\(name) has been modified since it was applied (checksum \
                mismatch). Applied migrations are immutable — create a new migration to make \
                further changes.
                  recorded checksum: \(recorded)
                  current checksum:  \(current)
                If the edit is confirmed-safe (formatting or comments only), run 'flight-migrate \
                repair' to re-baseline the recorded checksum.
                """

        case .unknownAppliedMigrations(let unknown):
            let list = unknown.map { "  \($0.version)_\($0.name)" }.joined(separator: "\n")
            return """
                the database records applied migrations that this binary does not know about:
                \(list)
                This usually means the binary is older than the schema (a rolling deploy), or \
                migration files were deleted. Deploy a binary that includes these migrations, or \
                set failOnUnknownApplied = false to proceed anyway.
                """

        case .migrationFailed(
            let version, let name, let direction, let transactional, let phase,
            let statementsApplied, let underlying):
            let verb = direction == .up ? "applying" : "rolling back"
            var message = "migration \(version)_\(name) failed while \(verb)"
            switch phase {
            case .begin:
                message += " (could not open its transaction)"
            case .statement(let index, let total, let sql):
                message += " statement \(index + 1) of \(total):\n\n    \(sql)\n"
            case .bookkeeping:
                message += " (its statements succeeded, but recording it in the bookkeeping table failed)"
            case .commit:
                message += " (its statements succeeded, but the final COMMIT failed)"
            }
            message += "\nunderlying error: \(underlying)\n\n"
            if transactional {
                message += """
                    The transaction was rolled back: the database is unchanged by this migration \
                    and the version was not recorded as \(direction == .up ? "applied" : "reverted"). \
                    Fix the problem and re-run.
                    """
            } else {
                let applied =
                    statementsApplied == 0
                    ? "No statements from this migration had been applied."
                    : """
                    Statements 1\(statementsApplied > 1 ? "–\(statementsApplied)" : "") had already \
                    been applied and were NOT rolled back.
                    """
                message += """
                    This migration runs with wrapInTransaction = false, so there was no transaction \
                    to roll back. \(applied) The version was not recorded, so the migration can \
                    re-run once the database state is repaired. Manual intervention may be required \
                    — for example, a failed CREATE INDEX CONCURRENTLY leaves an INVALID index that \
                    must be dropped before retrying.
                    """
            }
            return message

        case .rollbackTargetNotApplied(let version):
            return """
                cannot roll back to version \(version): it is not an applied migration. Pass the \
                version of an applied migration (which stays applied), or 0 to revert everything.
                """

        case .cannotRollBackUnknownMigration(let version, let name):
            return """
                cannot roll back \(version)_\(name): this binary has no migration registered for \
                that version, so its 'down' is unavailable. Use a binary that includes the \
                migration.
                """

        case .lockTimeout(let key, let waited):
            return """
            Timed out after \(waited) waiting for the migration advisory lock \
            (key \(key)). Another migration run is holding it, or a session leaked it. \
            Check for a deploy that is stuck mid-migration before raising the timeout; \
            `SELECT * FROM pg_locks WHERE locktype = 'advisory'` shows who holds it.
            """
        case .invalidRequest(let reason):
            return reason
        }
    }

    public var errorDescription: String? { description }
}

/// A version recorded as applied in the database with no matching registered migration.
public struct UnknownApplied: Sendable, Equatable {
    public let version: Int64
    public let name: String

    public init(version: Int64, name: String) {
        self.version = version
        self.name = name
    }
}

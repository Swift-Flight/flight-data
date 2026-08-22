/// Progress events emitted during a run, for CLI output, structured logging, or metrics.
/// Delivered synchronously via `FlightMigrator.Configuration.onEvent`, in addition to
/// (not instead of) the configured `Logger`.
public enum MigrationEvent: Sendable {
    /// A `migrate()` found nothing pending.
    case upToDate

    /// About to run a migration's `up`.
    case willApply(version: Int64, name: String, transactional: Bool, statementCount: Int)

    /// A migration's `up` completed and (for transactional migrations) committed.
    case didApply(version: Int64, name: String, duration: Duration)

    /// About to run a migration's `down`.
    case willRollBack(version: Int64, name: String, transactional: Bool, statementCount: Int)

    /// A migration's `down` completed.
    case didRollBack(version: Int64, name: String, duration: Duration)

    /// The bookkeeping table records versions this binary doesn't know about (and the
    /// migrator is configured to proceed anyway — see `failOnUnknownApplied`).
    case unknownAppliedVersions([UnknownApplied])

    /// A `wrapInTransaction = false` migration has multiple statements. Discouraged
    /// (design §3.2): a partial failure cannot be rolled back.
    case unwrappedMigrationHasMultipleStatements(
        version: Int64, name: String, statementCount: Int, direction: MigrationDirection)

    /// A migration recorded no statements in the direction being run.
    case emptyMigration(version: Int64, name: String, direction: MigrationDirection)

    /// `repair()` re-baselined a recorded checksum (design §5).
    case repairedChecksum(version: Int64, name: String, oldChecksum: String, newChecksum: String)
}

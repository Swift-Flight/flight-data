import Foundation

/// One migration applied by `migrate()`.
public struct AppliedMigration: Sendable {
    public let version: Int64
    public let name: String
    public let duration: Duration

    public init(version: Int64, name: String, duration: Duration) {
        self.version = version
        self.name = name
        self.duration = duration
    }
}

/// One migration reverted by `rollback(...)`.
public struct RolledBackMigration: Sendable {
    public let version: Int64
    public let name: String
    public let duration: Duration

    public init(version: Int64, name: String, duration: Duration) {
        self.version = version
        self.name = name
        self.duration = duration
    }
}

/// The result of `status()`: applied + pending, with per-migration checksum state (§7).
public struct MigrationStatus: Sendable {
    public enum AppliedState: Sendable, Equatable {
        /// Recorded checksum matches the registered migration.
        case ok
        /// Source drift (design §5): the run-blocking state `repair()` fixes.
        case checksumMismatch(recorded: String, current: String)
        /// Applied in the database, but not registered in this binary.
        case missingLocally
    }

    public struct Applied: Sendable {
        public let version: Int64
        public let name: String
        public let appliedAt: Date
        public let state: AppliedState

        public init(version: Int64, name: String, appliedAt: Date, state: AppliedState) {
            self.version = version
            self.name = name
            self.appliedAt = appliedAt
            self.state = state
        }
    }

    public struct Pending: Sendable {
        public let version: Int64
        public let name: String
        public let transactional: Bool

        public init(version: Int64, name: String, transactional: Bool) {
            self.version = version
            self.name = name
            self.transactional = transactional
        }
    }

    public let applied: [Applied]
    public let pending: [Pending]

    public init(applied: [Applied], pending: [Pending]) {
        self.applied = applied
        self.pending = pending
    }

    /// Whether any applied migration has drifted from its recorded checksum.
    public var hasDrift: Bool {
        applied.contains {
            if case .checksumMismatch = $0.state { return true }
            return false
        }
    }

    /// Whether the database is fully migrated for this binary.
    public var isUpToDate: Bool { pending.isEmpty }
}

/// The result of `repair()` (design §5, §7).
public struct RepairOutcome: Sendable, Equatable {
    public struct Repaired: Sendable, Equatable {
        public let version: Int64
        public let name: String
        public let oldChecksum: String
        public let newChecksum: String

        public init(version: Int64, name: String, oldChecksum: String, newChecksum: String) {
            self.version = version
            self.name = name
            self.oldChecksum = oldChecksum
            self.newChecksum = newChecksum
        }
    }

    /// Rows whose recorded checksum (and name, if renamed) was re-baselined.
    public let repaired: [Repaired]
    /// Applied rows with no registered migration — repair cannot help; reported for visibility.
    public let missingLocally: [UnknownApplied]

    public init(repaired: [Repaired], missingLocally: [UnknownApplied]) {
        self.repaired = repaired
        self.missingLocally = missingLocally
    }
}

/// A preview of what `migrate()`/`rollback(...)` would execute, with rendered SQL.
/// Produced by `planMigrate()` / `planRollback(...)`; used by the CLI's `--dry-run`.
public struct MigrationPlan: Sendable {
    public struct Step: Sendable {
        public let version: Int64
        public let name: String
        public let transactional: Bool
        /// The statements that would run, in order (bookkeeping writes not included).
        public let statements: [String]

        public init(version: Int64, name: String, transactional: Bool, statements: [String]) {
            self.version = version
            self.name = name
            self.transactional = transactional
            self.statements = statements
        }
    }

    public let direction: MigrationDirection
    public let steps: [Step]

    public init(direction: MigrationDirection, steps: [Step]) {
        self.direction = direction
        self.steps = steps
    }
}

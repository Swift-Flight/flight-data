import FlightDataCore
import FlightDataPostgres
import FlightScheduler
import Foundation
import Logging
import PostgresNIO

/// Makes a scheduled job's `JobScope.once` mean once across every server,
/// using a lease row in Postgres.
///
/// ## Why a lease row and not an advisory lock
///
/// `pg_try_advisory_lock` is the obvious choice and the wrong one here. It is
/// **session**-scoped: the lock lives on the connection that took it, and
/// must be released on that same connection. This package hands out *pooled*
/// connections, so a claim and its release would routinely land on different
/// ones — the release silently failing and the lock surviving until the
/// session ends. Holding one connection for a job's whole duration to avoid
/// that trades a correctness bug for a pool-exhaustion bug.
///
/// A lease row has neither problem. `INSERT … ON CONFLICT DO NOTHING` is
/// atomic, needs no connection affinity, and the row doubles as run history:
/// the table answers "did last night's billing job run, and where" without
/// any additional bookkeeping.
///
/// ## The contract
///
/// The primary key is `(job, scheduled_for)`, so contention is per *firing*
/// rather than per job. Two servers whose clocks differ by a second still
/// agree about which firing they are competing for, because the scheduler
/// passes the schedule's own instant rather than a local `now`.
///
/// Exactly one insert can succeed, so exactly one process runs the job. A
/// process that loses does nothing, which is the intended outcome and not an
/// error.
public struct PostgresJobCoordinator: JobCoordinator {
    private let dataSource: PostgresDataSource
    private let table: String
    private let owner: String
    private let logger: Logger

    /// - Parameters:
    ///   - dataSource: The pool to claim through. Usually the application's
    ///     primary — the leases are small and infrequent.
    ///   - table: Where leases live. Overridable for a deployment that
    ///     partitions by schema.
    ///   - owner: Recorded on the winning row so an operator can see *which*
    ///     server ran a job. Defaults to the host name.
    ///   - logger: Where claim failures are reported.
    public init(
        dataSource: PostgresDataSource,
        table: String = "flight_job_leases",
        owner: String = ProcessInfo.processInfo.hostName,
        logger: Logger = Logger(label: "flight.scheduler.postgres")
    ) {
        self.dataSource = dataSource
        self.table = table
        self.owner = owner
        self.logger = logger
    }

    public var describedKind: String { "postgres lease (\(table))" }

    public func claim(job: String, scheduledFor: Date) async throws -> Bool {
        try await dataSource.withConnection { connection in
            // ON CONFLICT DO NOTHING makes the race resolve in the database
            // rather than in the application: exactly one INSERT sees no
            // conflicting row, and every other returns zero rows.
            let rows = try await connection.query(
                """
                INSERT INTO \(unescaped: quoted(table)) (job, scheduled_for, claimed_by, claimed_at)
                VALUES (\(job), \(scheduledFor), \(owner), \(Date()))
                ON CONFLICT (job, scheduled_for) DO NOTHING
                RETURNING job
                """,
                logger: logger)
            for try await _ in rows.decode(String.self, context: .default) {
                return true
            }
            return false
        }
    }

    /// A no-op: the lease *is* the record of the firing, and deleting it
    /// would let a restarted process re-run the same firing. Old rows are
    /// removed by ``prune(olderThan:)`` on whatever schedule suits the
    /// deployment — including, appropriately, a scheduled job.
    public func release(job: String, scheduledFor: Date) async {}

    /// Deletes leases older than `age`, returning how many were removed.
    ///
    /// The table grows by one row per job per firing, which is small but not
    /// bounded. What "old enough" means is a deployment's call — a week keeps
    /// enough history to answer "did it run last night" while keeping the
    /// table trivial.
    @discardableResult
    public func prune(olderThan age: Duration) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(age.components.seconds))
        return try await dataSource.withConnection { connection in
            let rows = try await connection.query(
                """
                DELETE FROM \(unescaped: quoted(table)) WHERE scheduled_for < \(cutoff)
                RETURNING job
                """,
                logger: logger)
            var deleted = 0
            for try await _ in rows.decode(String.self, context: .default) { deleted += 1 }
            return deleted
        }
    }

    /// Creates the lease table if it is absent.
    ///
    /// Offered for tests and for deployments that do not use `flight migrate`;
    /// a migrated application should own this table in a migration like any
    /// other, so the schema is versioned rather than conjured at boot.
    public func createTableIfNeeded() async throws {
        try await dataSource.withConnection { connection in
            _ = try await connection.query(
                """
                CREATE TABLE IF NOT EXISTS \(unescaped: quoted(table)) (
                    job text NOT NULL,
                    scheduled_for timestamptz NOT NULL,
                    claimed_by text NOT NULL,
                    claimed_at timestamptz NOT NULL,
                    PRIMARY KEY (job, scheduled_for)
                )
                """,
                logger: logger)
        }
    }

    /// Identifier quoting, so a configured table name cannot become an
    /// injection point. Doubling an embedded quote is Postgres' own rule.
    private func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

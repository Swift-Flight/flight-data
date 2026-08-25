import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightScheduler
import Foundation
import Logging
import PostgresNIO
import Testing

@testable import FlightSchedulerPostgres

/// The claim rule, against a real database.
///
/// There is nothing worth asserting here against a fake: the whole property
/// — that exactly one of several concurrent claimants wins — is the
/// database's `ON CONFLICT` behaviour, not this package's.
@Suite("Postgres job coordination", .serialized, .enabled(if: SchedulerTestDatabase.isConfigured))
struct PostgresJobCoordinatorTests {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func withCoordinator<T>(
        _ body: (PostgresJobCoordinator) async throws -> T
    ) async throws -> T {
        let dataSource = try await SchedulerTestDatabase.shared()
        let coordinator = PostgresJobCoordinator(
            dataSource: dataSource, table: "flight_job_leases_test", owner: "test")
        try await coordinator.createTableIfNeeded()
        // Empty the table rather than pruning by age: these tests use a fixed
        // instant that is deliberately in the future, so "older than now"
        // would leave every one of their leases behind and the first claim of
        // the next test would find one already there.
        try await emptyLeases(dataSource)
        return try await body(coordinator)
    }

    private func emptyLeases(_ dataSource: PostgresDataSource) async throws {
        try await dataSource.withConnection { connection in
            _ = try await connection.query(
                #"TRUNCATE "flight_job_leases_test""#, logger: .init(label: "test"))
        }
    }

    @Test("the first claimant wins")
    func firstClaimWins() async throws {
        try await withCoordinator { coordinator in
            let won = try await coordinator.claim(job: "nightly", scheduledFor: epoch)
            #expect(won)
        }
    }

    @Test("a second claim for the same firing loses")
    func secondClaimLoses() async throws {
        // The property the whole type exists for: a nightly billing run on
        // three servers must bill once.
        try await withCoordinator { coordinator in
            let result1 = try await coordinator.claim(job: "nightly", scheduledFor: epoch)
            #expect(result1)
            let result2 = try await coordinator.claim(job: "nightly", scheduledFor: epoch)
            #expect(result2 == false)
            let result3 = try await coordinator.claim(job: "nightly", scheduledFor: epoch)
            #expect(result3 == false)
        }
    }

    @Test("the next firing of the same job is claimable again")
    func laterFiringIsSeparate() async throws {
        // Contention is per firing, not per job — otherwise a job would run
        // once and never again.
        try await withCoordinator { coordinator in
            let result4 = try await coordinator.claim(job: "nightly", scheduledFor: epoch)
            #expect(result4)
            #expect(
                try await coordinator.claim(
                    job: "nightly", scheduledFor: epoch.addingTimeInterval(86_400)))
        }
    }

    @Test("different jobs at the same instant do not contend")
    func differentJobsIndependent() async throws {
        try await withCoordinator { coordinator in
            let result5 = try await coordinator.claim(job: "a", scheduledFor: epoch)
            #expect(result5)
            let result6 = try await coordinator.claim(job: "b", scheduledFor: epoch)
            #expect(result6)
        }
    }

    @Test("concurrent claimants: exactly one wins")
    func concurrentClaimsElectOne() async throws {
        // The real shape of the problem — several servers reaching the same
        // firing at the same moment.
        try await withCoordinator { coordinator in
            let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await coordinator.claim(job: "contended", scheduledFor: epoch)
                    }
                }
                var count = 0
                for try await won in group where won { count += 1 }
                return count
            }
            #expect(winners == 1, "exactly one of eight claimants must win, got \(winners)")
        }
    }

    @Test("prune removes old leases and leaves recent ones")
    func pruneKeepsRecent() async throws {
        try await withCoordinator { coordinator in
            let old = Date().addingTimeInterval(-86_400 * 30)
            let recent = Date()
            let result7 = try await coordinator.claim(job: "old", scheduledFor: old)
            #expect(result7)
            let result8 = try await coordinator.claim(job: "recent", scheduledFor: recent)
            #expect(result8)

            let removed = try await coordinator.prune(olderThan: .days(7))
            #expect(removed == 1)
            // The recent lease survived, so its firing is still not re-runnable.
            let result9 = try await coordinator.claim(job: "recent", scheduledFor: recent)
            #expect(result9 == false)
        }
    }

    @Test("a table name with a quote in it cannot break out of the identifier")
    func tableNameIsQuoted() async throws {
        // The table name is configuration, and configuration reaches SQL as
        // an identifier rather than a bind — so the quoting rule is the only
        // thing between it and injection.
        let dataSource = try await SchedulerTestDatabase.shared()
        let coordinator = PostgresJobCoordinator(
            dataSource: dataSource, table: "odd\"name", owner: "test")
        try await coordinator.createTableIfNeeded()
        let result10 = try await coordinator.claim(job: "j", scheduledFor: epoch)
        #expect(result10)
        _ = try await coordinator.prune(olderThan: .seconds(0))
    }
}

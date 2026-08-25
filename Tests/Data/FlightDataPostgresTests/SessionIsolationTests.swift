import FlightCore
import FlightDataCore
import FlightDataPostgres
import Foundation
import Testing

/// What one scope can learn about the previous one.
///
/// A pooled connection is a *session*, and a session remembers. `SET ROLE`,
/// `SET search_path`, session GUCs, prepared statements, temporary tables —
/// all of it survived being returned to the pool and greeted whoever checked
/// the connection out next.
///
/// For the row-level-security pattern this package invites — set a tenant on
/// the session, let Postgres filter — that is a cross-tenant read: request A
/// sets a tenant, request B inherits it and sees rows it must not.

/// Waits until the pool has a connection to give.
///
/// With the session reset on, a released connection is unavailable until its
/// `DISCARD ALL` completes — it is checked out by nobody and available to
/// nobody in between. That window is the price of the reset; a pool of one
/// makes it unmissable, which is also what makes this the right pool size for
/// proving the connection really is reused.
private func waitForFreeConnection(_ source: PostgresDataSource) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while source.availableConnections == 0 {
        guard ContinuousClock.now < deadline else {
            Issue.record("pool never returned a connection")
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

extension PostgresIntegrationSuite {
@Suite("Session state does not cross scopes")
struct SessionIsolationTests {

    @Test("a session GUC set in one scope is not visible in the next")
    func sessionGUCDoesNotLeak() async throws {
        try await withPostgresContainer(poolSize: 1) { container, source in
            // Pool of one: the second scope necessarily gets the same
            // connection, which is the whole point.
            try await container.withScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                _ = try await connection.query("SET app.tenant_id = 'tenant-a'", logger: .init(label: "t"))
            }

            try await waitForFreeConnection(source)
            try await container.withScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                let rows = try await connection.query(
                    "SELECT current_setting('app.tenant_id', true)", logger: .init(label: "t"))
                var seen: String?
                for try await row in rows.decode(String?.self) { seen = row }
                #expect(
                    seen == nil || seen?.isEmpty == true,
                    "the next scope inherited tenant \(seen ?? "nil") from the previous one")
            }
        }
    }

    @Test("search_path does not leak either")
    func searchPathDoesNotLeak() async throws {
        try await withPostgresContainer(poolSize: 1) { container, source in
            try await container.withScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                _ = try await connection.query(
                    "SET search_path = pg_catalog", logger: .init(label: "t"))
            }

            try await waitForFreeConnection(source)
            try await container.withScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                let rows = try await connection.query(
                    "SELECT current_setting('search_path')", logger: .init(label: "t"))
                var seen = ""
                for try await row in rows.decode(String.self) { seen = row }
                #expect(seen != "pg_catalog", "search_path carried into the next scope")
            }
        }
    }

    @Test("turning the reset off is possible, and says so by leaking")
    func resetCanBeDisabled() async throws {
        // Documented escape hatch: a deployment certain it never mutates
        // session state can skip the round trip. This pins that the setting
        // does what it says, and what it costs.
        try await withPostgresContainer(poolSize: 1, resetOnRelease: false) { container, source in
            try await container.withScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                _ = try await connection.query("SET app.tenant_id = 'tenant-b'", logger: .init(label: "t"))
            }
            try await container.withScope { scope in
                let connection = try container.resolve(
                    ScopedConnection<PostgresDataSource>.self, qualifier: "primary", in: scope
                ).connection
                let rows = try await connection.query(
                    "SELECT current_setting('app.tenant_id', true)", logger: .init(label: "t"))
                var seen: String?
                for try await row in rows.decode(String?.self) { seen = row }
                #expect(seen == "tenant-b", "without the reset, the session is shared as-is")
            }
        }
    }
}
}

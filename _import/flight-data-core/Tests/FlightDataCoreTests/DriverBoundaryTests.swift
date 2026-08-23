import Testing
import FlightCore
import FlightDataCore
import FlightDataTesting

/// — the changeset/driver boundary: one neutral `ValidatedChanges`, a
/// per-driver `apply(_:)` translation, zero shared write logic. The InMemory
/// "driver" journals its writes, which is exactly enough to prove the
/// boundary carries everything a real driver needs.
@Suite("Driver boundary")
struct DriverBoundaryTests {

    private func connection() -> InMemoryConnection {
        // A standalone connection is fine here; the test below goes
        // through the full scoped checkout.
        let source = InMemoryDataSource(poolSize: 1)
        return try! source.checkout()
    }

    @Test("an update writes only the changed columns, addressed by identity")
    func minimalUpdate() throws {
        let changes = try Changeset(original: User.ada)
            .change(\.email, "ada@lovelace.dev")
            .change(\.displayName, "Ada")       // equal → clean → absent from SET
            .validatedChanges()

        let connection = connection()
        connection.apply(changes, to: User.self)
        #expect(connection.journal == ["UPDATE users SET email = ada@lovelace.dev WHERE id = 1"])
    }

    @Test("an insert writes the changed fields with no identity")
    func insert() throws {
        let changes = try Changeset(User.self)
            .change(\.displayName, "Grace")
            .change(\.age, 46)
            .validatedChanges()

        let connection = connection()
        connection.apply(changes, to: User.self)
        #expect(connection.journal == ["INSERT users SET age = 46, display_name = Grace"])
    }

    @Test("a set-to-nil crosses the boundary as an explicit NULL, not an absence")
    func nullSet() throws {
        let changes = try Changeset(original: User.ada)
            .change(\.email, nil)
            .validatedChanges()

        let connection = connection()
        connection.apply(changes, to: User.self)
        #expect(connection.journal == ["UPDATE users SET email = NULL WHERE id = 1"])
    }

    @Test("a composite identity addresses the row with every key column")
    func compositeIdentity() throws {
        let changes = try Changeset(original: Membership(userID: 3, teamID: 9, role: "member"))
            .change(\.role, "admin")
            .validatedChanges()

        let connection = connection()
        connection.apply(changes, to: Membership.self)
        #expect(connection.journal == ["UPDATE membership SET role = admin WHERE team_id = 9 AND user_id = 3"])
    }

    @Test("a clean changeset produces no write at all — dirty tracking pays off")
    func noOpSkipsTheStore() throws {
        let changes = try Changeset(original: User.ada)
            .change(\.age, 36)
            .validatedChanges()

        let connection = connection()
        connection.apply(changes, to: User.self)
        #expect(connection.journal.isEmpty)
    }

    /// The whole flow, end to end: scoped connection out of the
    /// container, changeset validation, guard on isValid, apply — with the
    /// invalid path never reaching the store.
    @Test("end to end: validate, guard, apply through the scope's connection")
    func endToEnd() throws {
        let container = try TestContainer.build {
            InMemoryDataModule<PrimaryDataSource>()
        }
        let source = try container.resolve(InMemoryDataSource.self, qualifier: "primary")

        func update(_ user: User, email: String, in scope: Scope) throws -> [ChangesetError] {
            let changeset = Changeset(original: user)
                .change(\.email, email)
                .validate(\.email, .email)
            guard changeset.isValid else { return changeset.errors }
            let lease = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            lease.connection.apply(try changeset.validatedChanges(), to: User.self)
            return []
        }

        try container.withScope { scope in
            let rejected = try update(.ada, email: "not-an-email", in: scope)
            #expect(rejected == [ChangesetError(field: "email", message: "is not a valid email address")])

            let accepted = try update(.ada, email: "ada@lovelace.dev", in: scope)
            #expect(accepted.isEmpty)

            let lease = try container.resolve(
                ScopedConnection<InMemoryDataSource>.self, qualifier: "primary", in: scope)
            #expect(lease.connection.journal == ["UPDATE users SET email = ada@lovelace.dev WHERE id = 1"],
                    "exactly one write reached the store — the invalid changeset never did")
        }
        #expect(source.activeCheckouts == 0)
    }
}

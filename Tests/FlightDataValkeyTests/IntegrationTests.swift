import Foundation
import FlightCore
import FlightDataCore
import FlightDataValkey
import Testing
import Valkey

/// Umbrella for every suite that talks to a live server (design §8). Every
/// test is parameterized over each configured server — the same code runs
/// against Valkey *and* Redis, which is what keeps §3.1's compatibility
/// policy honest. `.serialized` is recursive, so nested suites never
/// interleave — each test flushes the test database, which only works
/// single-file.
@Suite(.serialized, .enabled(if: !TestServer.available.isEmpty))
enum ValkeyIntegrationSuite {}

// MARK: - Pool lifecycle

extension ValkeyIntegrationSuite {
    @Suite("Pool lifecycle (§6, delta V1)")
    struct PoolLifecycleTests {
        @Test(arguments: TestServer.available)
        func startEstablishesThePoolEagerly(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                #expect(source.isRunning)
                #expect(source.establishedConnections == source.poolSize)
                #expect(source.availableConnections == source.poolSize)
                #expect(source.activeCheckouts == 0)
            }
        }

        @Test(arguments: TestServer.available)
        func pingAnswers(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { container, source in
                try await source.ping()
                // The same probe Actuator reads, through the store-agnostic
                // component (§4.1).
                let probes = try DataSourceLiveness.all(in: container)
                #expect(probes.count == 1)
                try await probes[0].ping()
            }
        }

        @Test(arguments: TestServer.available)
        func checkoutReleaseReusesConnections(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                let before = source.totalCheckouts
                let connection = try source.checkout()
                #expect(source.activeCheckouts == 1)
                _ = try await connection.ping()
                source.release(connection)
                #expect(source.activeCheckouts == 0)
                #expect(source.availableConnections == source.poolSize)

                let again = try source.checkout()
                defer { source.release(again) }
                #expect(source.totalCheckouts == before + 2)
                #expect(source.establishedConnections == source.poolSize)
            }
        }

        @Test(arguments: TestServer.available)
        func exhaustedPoolThrowsPromptly(_ server: TestServer) async throws {
            try await withValkeyContainer(server, poolSize: 2) { _, source in
                let first = try source.checkout()
                let second = try source.checkout()
                #expect(throws: DataSourceError.poolExhausted(datasource: "primary", poolSize: 2)) {
                    _ = try source.checkout()
                }
                source.release(first)
                source.release(second)
            }
        }

        @Test(arguments: TestServer.available)
        func shutdownDrainsAndRefusesFurtherCheckouts(_ server: TestServer) async throws {
            let source = try ValkeyDataSource(settings: try server.settings(poolSize: 2))
            try await source.start()
            let held = try source.checkout()
            await source.shutdown()

            #expect(source.isClosed)
            #expect(throws: DataSourceError.closed(datasource: "primary")) {
                _ = try source.checkout()
            }
            // An in-flight connection is retired as it comes back, not repooled.
            source.release(held)
            #expect(source.activeCheckouts == 0)
            #expect(source.availableConnections == 0)
            try await waitUntil("held connection retired after shutdown") {
                source.establishedConnections == 0
            }
        }

        @Test(arguments: TestServer.available)
        func unreachableServerFailsStartPromptly(_ server: TestServer) async throws {
            // Port 1 answers nothing; §6's posture is that bootstrap fails
            // before any request is served, not at first command.
            let settings = try DataSourceSettings(name: "primary", url: "valkey://127.0.0.1:1", poolSize: 2)
            let source = try ValkeyDataSource(settings: settings)
            await #expect(throws: (any Error).self) {
                try await source.start()
            }
            #expect(source.isClosed)
        }

        @Test(arguments: TestServer.available)
        func runServicesThePoolUntilCancelled(_ server: TestServer) async throws {
            // The production path: run() as the module's service body.
            let source = try ValkeyDataSource(settings: try server.settings(poolSize: 2))
            let service = Task { try await source.run() }
            try await waitUntil("pool started") {
                source.isRunning && source.establishedConnections == 2
            }
            let connection = try source.checkout()
            _ = try await connection.ping()
            source.release(connection)

            service.cancel()
            try await service.value
            #expect(source.isClosed)
            try await waitUntil("pool drained") { source.establishedConnections == 0 }
        }
    }
}

// MARK: - Scope-bound connections

extension ValkeyIntegrationSuite {
    /// §4.2's properties, which only a live pool can prove: scope-bound
    /// checkout, connection identity within a scope, return-to-pool at scope
    /// close, and repositories wired through the real `@Repository`/
    /// `@Autowired` macro path.
    @Suite("Scoped connections (§4.2)")
    struct ScopingTests {
        @Test(arguments: TestServer.available)
        func scopeSharesOneConnection(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { container, source in
                try container.withScope { scope in
                    let a = try container.resolve(SessionRepository.self, in: scope).valkey
                    let b = try container.resolve(ValkeyConnection.self, qualifier: "primary", in: scope)
                    let c = try container.resolve(
                        ScopedConnection<ValkeyDataSource>.self, qualifier: "primary", in: scope
                    ).connection
                    #expect(a === b)
                    #expect(a === c)
                    #expect(source.activeCheckouts == 1)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func scopeCloseReturnsConnectionToPool(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { container, source in
                try container.withScope { scope in
                    _ = try container.resolve(SessionRepository.self, in: scope)
                    #expect(source.activeCheckouts == 1)
                }
                #expect(source.activeCheckouts == 0)

                // The returned connection is reused, not replaced.
                let before = source.totalCheckouts
                try container.withScope { scope in
                    _ = try container.resolve(SessionRepository.self, in: scope)
                }
                #expect(source.totalCheckouts == before + 1)
                #expect(source.establishedConnections == source.poolSize)
            }
        }

        @Test(arguments: TestServer.available)
        func distinctScopesGetDistinctConnections(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { container, source in
                try container.withScope { outer in
                    let first = try container.resolve(SessionRepository.self, in: outer).valkey
                    try container.withScope { inner in
                        let second = try container.resolve(SessionRepository.self, in: inner).valkey
                        #expect(first !== second)
                        #expect(source.activeCheckouts == 2)
                    }
                }
            }
        }

        @Test(arguments: TestServer.available)
        func repositoryStoresAndFindsSessions(_ server: TestServer) async throws {
            // The design doc's §4.3 repository, end to end.
            try await withValkeyContainer(server) { container, source in
                try await container.withScope { scope in
                    let repo = try container.resolve(SessionRepository.self, in: scope)
                    let session = Session(id: "s1", userID: 7, ipAddress: nil, loginCount: 3)
                    try await repo.store(session, ttl: .seconds(3600))

                    let fields = try await repo.find("s1")
                    #expect(fields == ["user_id": "7", "login_count": "3", "active": "1"])
                    #expect(try await repo.find("missing").isEmpty)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func leaderboardReadsBestFirst(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { container, source in
                try await container.withScope { scope in
                    let repo = try container.resolve(SessionRepository.self, in: scope)
                    try await repo.recordScore("ada", 420)
                    try await repo.recordScore("grace", 990)
                    try await repo.recordScore("edsger", 700)

                    let top = try await repo.leaderboard(top: 2)
                    #expect(top.count == 2)
                    #expect(top[0] == ("grace", 990))
                    #expect(top[1] == ("edsger", 700))
                }
            }
        }
    }
}

// MARK: - Typed commands, sugar, escape hatch

extension ValkeyIntegrationSuite {
    @Suite("Command surface (§4.3)")
    struct CommandSurfaceTests {
        @Test(arguments: TestServer.available)
        func typedCommandsRoundTrip(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    try await valkey.set("greeting", value: "hello")
                    let read = try await valkey.get("greeting")
                    #expect(read.map { String(decoding: $0, as: UTF8.self) } == "hello")

                    _ = try await valkey.sadd("tags", members: ["a", "b"])
                    #expect(try await valkey.scard("tags") == 2)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func expireAfterDurationSetsPreciseTTL(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    try await valkey.set("ttl-key", value: "v")
                    #expect(try await valkey.expire("ttl-key", after: .milliseconds(90_500)))
                    let remaining = try await valkey.pttl("ttl-key")
                    #expect(remaining > 89_000 && remaining <= 90_500)
                    // A key that does not exist reports false, not an error.
                    #expect(!(try await valkey.expire("missing", after: .seconds(5))))
                }
            }
        }

        @Test(arguments: TestServer.available)
        func rawCommandEscapeHatch(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    // Common-set commands through the raw path — the §4.3
                    // hatch itself is compatibility-neutral; what you send
                    // through it is your informed choice.
                    let payload = #"{"answer":42}"#
                    _ = try await valkey.command("SET", "doc:1", payload, keys: ["doc:1"])
                    let read = try await valkey.command("GET", "doc:1", keys: ["doc:1"])
                    #expect(try read.decode(as: String.self) == payload)

                    let encoding = try await valkey.command("OBJECT", "ENCODING", "doc:1")
                    #expect(!(try encoding.decode(as: String.self)).isEmpty)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func unknownRawCommandSurfacesTheServerError(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    await #expect(throws: (any Error).self) {
                        _ = try await valkey.command("FLIGHT.NOSUCHCOMMAND", "x")
                    }
                    return ()
                }
            }
        }
    }
}

// MARK: - multi (§5.2)

extension ValkeyIntegrationSuite {
    @Suite("multi — atomic batches, not transactions (§5.2)")
    struct MultiTests {
        @Test(arguments: TestServer.available)
        func designDocBatchExecutesAtomically(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    let results = try await valkey.multi { batch in
                        batch.incr("counter")
                        batch.expire("counter", after: .seconds(3600))
                    }
                    #expect(results.count == 2)
                    #expect(try results.decode(0, as: Int.self) == 1)
                    #expect(try results.decode(1, as: Int.self) == 1)  // PEXPIRE: timeout set

                    #expect(try await valkey.get("counter").map { String(decoding: $0, as: UTF8.self) } == "1")
                    #expect(try await valkey.pttl("counter") > 3_599_000)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func executionFailureLandsInItsSlotAndNeighborsStillRan(_ server: TestServer) async throws {
            // THE §5.2 semantics: no rollback. A command that fails at EXEC
            // time fails alone; the commands around it are not undone.
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    try await valkey.set("text", value: "not-a-number")
                    let results = try await valkey.multi { batch in
                        batch.incr("survivor")
                        batch.incr("text")     // WRONGTYPE-ish: fails in its slot
                        batch.incr("survivor")
                    }
                    #expect(results.count == 3)
                    #expect(try results.decode(0, as: Int.self) == 1)
                    #expect(throws: (any Error).self) { try results[1].get() }
                    #expect(try results.decode(2, as: Int.self) == 2)

                    // Nothing rolled back: both INCRs stuck.
                    #expect(
                        try await valkey.get("survivor").map { String(decoding: $0, as: UTF8.self) } == "2")
                }
            }
        }

        @Test(arguments: TestServer.available)
        func emptyBatchSendsNothing(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    let results = try await valkey.multi { _ in }
                    #expect(results.isEmpty)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func rawCommandsRideInBatches(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    let results = try await valkey.multi { batch in
                        batch.command("SET", "raw-in-multi", "yes", keys: ["raw-in-multi"])
                        batch.command("GET", "raw-in-multi", keys: ["raw-in-multi"])
                    }
                    #expect(try results.decode(1, as: String.self) == "yes")
                }
            }
        }
    }
}

// MARK: - Changeset apply (§5.3)

extension ValkeyIntegrationSuite {
    @Suite("Changeset apply (§5.3)")
    struct ChangesetApplyTests {
        @Test(arguments: TestServer.available)
        func insertChangesetCreatesTheHash(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    let changeset = Changeset(Session.self)
                        .change(\.id, "s9")
                        .change(\.userID, 12)
                        .change(\.loginCount, 1)
                    try await valkey.apply(try changeset.validatedChanges(), to: Session.self)

                    let stored = try await valkey.hgetall("session:s9")
                        .decode(as: [String: String].self)
                    #expect(stored == ["id": "s9", "user_id": "12", "login_count": "1"])
                }
            }
        }

        @Test(arguments: TestServer.available)
        func updateChangesetWritesOnlyDirtyFields(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    let original = Session(id: "s1", userID: 7, ipAddress: "10.0.0.1", loginCount: 3)
                    try await valkey.hset(
                        "session:s1",
                        data: [
                            .init(field: "user_id", value: "7"),
                            .init(field: "ip_address", value: "10.0.0.1"),
                            .init(field: "login_count", value: "3"),
                            .init(field: "untouched", value: "still-here"),
                        ])

                    let changeset = Changeset(original: original)
                        .change(\.loginCount, 4)
                        .change(\.ipAddress, nil)  // → HDEL
                    try await valkey.apply(try changeset.validatedChanges(), to: Session.self)

                    let stored = try await valkey.hgetall("session:s1")
                        .decode(as: [String: String].self)
                    // Changed field written, nil field deleted, everything
                    // else — including fields the changeset never saw —
                    // untouched: the minimal write §5.3 promises.
                    #expect(
                        stored == [
                            "user_id": "7", "login_count": "4", "untouched": "still-here",
                        ])
                }
            }
        }

        @Test(arguments: TestServer.available)
        func noChangeApplyWritesNothing(_ server: TestServer) async throws {
            try await withValkeyContainer(server) { _, source in
                try await source.withConnection { valkey in
                    let original = Session(id: "s1", userID: 7, ipAddress: nil, loginCount: 3)
                    let changeset = Changeset(original: original).change(\.loginCount, 3)
                    try await valkey.apply(try changeset.validatedChanges(), to: Session.self)
                    #expect(try await valkey.exists(keys: ["session:s1"]) == 0)
                }
            }
        }

        @Test(arguments: TestServer.available)
        func invalidChangesetCannotReachTheDriver(_ server: TestServer) async throws {
            // The §5.3 boundary is structural: validatedChanges() throws, so
            // there is no ValidatedChanges to apply.
            let changeset = Changeset(Session.self)
                .change(\.id, "x")
                .change(\.loginCount, -1)
                .validate(\.loginCount, .range(0...Int.max))
            #expect(throws: ChangesetValidationError.self) {
                _ = try changeset.validatedChanges()
            }
        }
    }
}

// MARK: - Resilience (delta V1's replacement loop)

extension ValkeyIntegrationSuite {
    @Suite("Broken-connection replacement (delta V1)")
    struct ResilienceTests {
        @Test(arguments: TestServer.available)
        func brokenCheckedOutConnectionIsRetiredAndReplaced(_ server: TestServer) async throws {
            try await withValkeyContainer(server, poolSize: 2) { _, source in
                let maintenance = Task { await source.maintainPool() }
                defer { maintenance.cancel() }

                let connection = try source.checkout()
                connection.close()  // the server "drops" the connection mid-lease
                // Depending on when the close event lands, the connection is
                // retired at release (marked broken) or just after being
                // repooled — either way it must be noticed and replaced.
                source.release(connection)
                #expect(source.activeCheckouts == 0)

                try await waitUntil("pool re-established after broken lease") {
                    source.retiredConnections == 1
                        && source.establishedConnections == 2
                        && source.availableConnections == 2
                }
                // And the replacement actually works.
                try await source.ping()
            }
        }

        @Test(arguments: TestServer.available)
        func brokenPooledConnectionIsReplacedInPlace(_ server: TestServer) async throws {
            try await withValkeyContainer(server, poolSize: 2) { _, source in
                let maintenance = Task { await source.maintainPool() }
                defer { maintenance.cancel() }

                // Close a connection while it sits in the free list.
                let victim = try source.checkout()
                source.release(victim)
                victim.close()

                try await waitUntil("pool re-established after pooled break") {
                    source.retiredConnections == 1
                        && source.establishedConnections == 2
                        && source.availableConnections == 2
                }
                try await source.ping()
            }
        }
    }
}

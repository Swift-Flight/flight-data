import Foundation
import FlightDataValkey

// MARK: - Model (changeset design §5.3)

/// The design doc's example entity, as a hand-conformed `TableModel` —
/// exactly the metadata the changeset seam needs, nothing more (Flight Data
/// Core's TableModel doc: hand-conformance is a handful of lines).
struct Session: TableModel, Equatable {
    var id: String
    var userID: Int
    var ipAddress: String?
    var loginCount: Int
    var active: Bool = true

    static let tableName = "session"

    static let columns: [TableColumn<Session>] = [
        TableColumn("id", \Session.id, primaryKey: true),
        TableColumn("user_id", \Session.userID),
        TableColumn("ip_address", \Session.ipAddress),
        TableColumn("login_count", \Session.loginCount),
        TableColumn("active", \Session.active),
    ]
}

// MARK: - Repository (design §4.3)

/// The design doc's §4.3 repository, executable: typed commands against the
/// scope's connection, resolved through the real `@Repository`/`@Autowired`
/// macro path.
@Repository(scope: .scoped)
struct SessionRepository {
    @Autowired var valkey: ValkeyConnection

    func store(_ session: Session, ttl: Duration) async throws {
        let key = ValkeyKey("session:\(session.id)")
        try await valkey.hset(
            key,
            data: [
                .init(field: "user_id", value: "\(session.userID)"),
                .init(field: "login_count", value: "\(session.loginCount)"),
                .init(field: "active", value: session.active ? "1" : "0"),
            ])
        try await valkey.expire(key, after: ttl)
    }

    func find(_ id: String) async throws -> [String: String] {
        var fields: [String: String] = [:]
        for entry in try await valkey.hgetall(ValkeyKey("session:\(id)")) {
            fields[try entry.key.decode(as: String.self)] = try entry.value.decode(as: String.self)
        }
        return fields
    }

    func recordScore(_ member: String, _ score: Double) async throws {
        try await valkey.zadd("leaderboard", data: [.init(score: score, member: member)])
    }

    func leaderboard(top n: Int) async throws -> [(String, Double)] {
        try await valkey.zrevrange("leaderboard", 0, n - 1, withScores: true)
    }
}

// MARK: - Module wiring

/// The application module a real app would write: repositories registered by
/// their macro-generated thunks, depending on the Valkey module.
final class ValkeyTestAppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [ValkeyDataModule<PrimaryDataSource>.self]
    }

    init() {}

    func configure(_ container: Container) throws {
        try SessionRepository._flightRegister(container)
    }
}

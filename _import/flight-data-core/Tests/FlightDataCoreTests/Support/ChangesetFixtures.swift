import Foundation
import FlightDataCore

// NOTE: swift-changeset's test suite carries a copy of these fixtures —
// the changeset tests moved there with the 2026-08-21 extraction;
// DriverBoundaryTests here still exercises the driver side against the
// same models.

// MARK: - TableModel fixtures
//
// Hand conformances, exactly what the Postgres package's @Table bridge (or a
// future @TableModel macro) would generate. Column names are snake_case
// deliberately — proving the keypath→column mapping is real, not a property
// name echo.

struct User: TableModel, Equatable {
    var id: Int?
    var email: String?
    var displayName: String
    var age: Int

    static let tableName = "users"
    static let columns: [TableColumn<User>] = [
        TableColumn("id", \User.id, primaryKey: true),
        TableColumn("email", \User.email),
        TableColumn("display_name", \User.displayName),
        TableColumn("age", \User.age),
    ]
}

extension User {
    /// A canonical persisted row for update-changeset tests.
    static let ada = User(id: 1, email: "ada@example.com", displayName: "Ada", age: 36)
}

/// Cross-field fixture: the canonical "endDate after startDate" shape.
struct Event: TableModel, Equatable {
    var id: Int?
    var title: String
    var startsAt: Date?
    var endsAt: Date?

    static let columns: [TableColumn<Event>] = [
        TableColumn("id", \Event.id, primaryKey: true),
        TableColumn("title", \Event.title),
        TableColumn("starts_at", \Event.startsAt),
        TableColumn("ends_at", \Event.endsAt),
    ]
}

/// Composite-primary-key fixture; also exercises the defaulted tableName.
struct Membership: TableModel, Equatable {
    var userID: Int
    var teamID: Int
    var role: String

    static let columns: [TableColumn<Membership>] = [
        TableColumn("user_id", \Membership.userID, primaryKey: true),
        TableColumn("team_id", \Membership.teamID, primaryKey: true),
        TableColumn("role", \Membership.role),
    ]
}

/// Deliberately not Equatable: exercises the always-dirty `change` overload.
struct Payload: Sendable {
    var lines: [String]
}

struct Document: TableModel {
    var id: Int?
    var payload: Payload

    static let columns: [TableColumn<Document>] = [
        TableColumn("id", \Document.id, primaryKey: true),
        TableColumn("payload", \Document.payload),
    ]
}

import Foundation
import FlightDataCore
import FlightDataValkey
import Testing

/// The translation, no server required: `ValidatedChanges` → hash-write
/// plan. Validation and dirty-tracking live in Flight Data Core and are
/// tested there; these tests cover only this driver's obligation.
@Suite("Changeset translation")
struct ChangesetTranslationTests {
    @Test func updateChangesetPlansHSETOfChangedFieldsOnly() throws {
        let original = Session(id: "abc", userID: 7, ipAddress: "10.0.0.1", loginCount: 3)
        let changeset = Changeset(original: original)
            .change(\.loginCount, 4)
            .change(\.userID, 7)  // unchanged — dirty tracking drops it

        let plan = try #require(
            try ValkeyChangesetTranslation.plan(changeset.validatedChanges(), for: Session.self))
        #expect(plan.key == "session:abc")
        #expect(plan.sets == [.init(field: "login_count", value: .string("4"))])
        #expect(plan.deletes.isEmpty)
    }

    @Test func nilChangeBecomesHDEL() throws {
        let original = Session(id: "abc", userID: 7, ipAddress: "10.0.0.1", loginCount: 3)
        let changeset = Changeset(original: original)
            .change(\.ipAddress, nil)
            .change(\.loginCount, 4)

        let plan = try #require(
            try ValkeyChangesetTranslation.plan(changeset.validatedChanges(), for: Session.self))
        #expect(plan.sets == [.init(field: "login_count", value: .string("4"))])
        #expect(plan.deletes == ["ip_address"])
    }

    @Test func insertChangesetDerivesKeyFromChangedPrimaryKey() throws {
        let changeset = Changeset(Session.self)
            .change(\.id, "fresh")
            .change(\.userID, 1)
            .change(\.active, false)

        let plan = try #require(
            try ValkeyChangesetTranslation.plan(changeset.validatedChanges(), for: Session.self))
        #expect(plan.key == "session:fresh")
        // Sorted field order — deterministic plans.
        #expect(plan.sets.map(\.field) == ["active", "id", "user_id"])
        #expect(plan.sets.map(\.value) == [.string("0"), .string("fresh"), .string("1")])
    }

    @Test func insertWithoutPrimaryKeyFieldIsRejected() throws {
        let changes = try Changeset(Session.self).change(\.userID, 1).validatedChanges()
        #expect(throws: ValkeyChangesetError.missingKeyField(model: "Session", column: "id")) {
            try ValkeyChangesetTranslation.plan(changes, for: Session.self)
        }
    }

    @Test func explicitKeyOverridesDerivation() throws {
        let changes = try Changeset(Session.self).change(\.userID, 1).validatedChanges()
        let plan = try #require(
            try ValkeyChangesetTranslation.plan(changes, for: Session.self, key: "custom:key"))
        #expect(plan.key == "custom:key")
    }

    @Test func noChangesMeansNoPlan() throws {
        let original = Session(id: "abc", userID: 7, ipAddress: nil, loginCount: 3)
        let changes = try Changeset(original: original).change(\.loginCount, 3).validatedChanges()
        #expect(try ValkeyChangesetTranslation.plan(changes, for: Session.self) == nil)
    }

    @Test func valueRenderings() throws {
        func render(_ value: any Sendable) throws -> ValkeyChangesetValue? {
            try ValkeyChangesetValue(value, field: "f")
        }
        #expect(try render("text") == .string("text"))
        #expect(try render(42) == .string("42"))
        #expect(try render(Int64(-9)) == .string("-9"))
        #expect(try render(3.5) == .string("3.5"))
        #expect(try render(true) == .string("1"))
        #expect(try render(false) == .string("0"))
        #expect(
            try render(UUID(uuidString: "0EC1D370-9C5C-4CFA-8B7C-4B4B5FDD9DB8")!)
                == .string("0EC1D370-9C5C-4CFA-8B7C-4B4B5FDD9DB8"))
        #expect(try render(Date(timeIntervalSince1970: 1_700_000_000)) == .string("2023-11-14T22:13:20.000Z"))
        #expect(try render(Decimal(string: "12.34")!) == .string("12.34"))
        #expect(try render(Data([0xDE, 0xAD])) == .bytes([0xDE, 0xAD]))
        #expect(try render([UInt8]([1, 2, 3])) == .bytes([1, 2, 3]))
        // Boxed nils (either depth) mean HDEL.
        #expect(try render(String?.none) == nil)
    }

    @Test func unrenderableValueIsRejected() {
        struct Opaque: Sendable {}
        #expect(throws: (any Error).self) {
            try ValkeyChangesetValue(Opaque(), field: "f")
        }
    }
}

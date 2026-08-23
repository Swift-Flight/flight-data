import Foundation
import FlightDataCore
import NIOCore
import Valkey

/// The Valkey driver obligation of the changeset design: one
/// `apply(_:to:)` translating the neutral `ValidatedChanges` into this
/// store's native write — an `HSET` of exactly the changed fields (plus an
/// `HDEL` for fields set to nil, since a hash expresses "no value" by
/// absence). Validation and dirty-tracking stay entirely in Flight Data
/// Core; an invalid changeset structurally cannot reach this code
/// (`validatedChanges()` throws).
///
/// This is the evidence in code: the same `ValidatedChanges` that the
/// Postgres driver turns into `UPDATE … SET` becomes an `HSET` here, with no
/// shared write logic and no per-store changeset variant.
extension ValkeyClientProtocol {
    /// Applies validated changes to the model's hash.
    ///
    /// The hash key is `key` when given, else derived from the model's
    /// primary-key metadata as `<tableName>:<pk>[:<pk>…]` — identity columns
    /// for an update changeset, the changed fields' values for an insert
    /// (which must therefore include every primary-key column).
    ///
    /// Changed fields become `HSET` pairs; fields changed *to nil* become an
    /// `HDEL` (hash fields have no NULL). When both are needed they go in
    /// one `MULTI`/`EXEC` batch, so no other client observes the write
    /// half-applied. Empty `changedFields` is a no-op — dirty tracking
    /// already proved there is no write to make.
    ///
    /// Unlike SQL, `HSET` cannot distinguish insert from update — both are
    /// "set these fields". The insert/update distinction only picks where
    /// the key's identity values come from.
    public func apply<M: TableModel>(
        _ changes: ValidatedChanges,
        to model: M.Type,
        key: ValkeyKey? = nil
    ) async throws {
        guard let plan = try ValkeyChangesetTranslation.plan(changes, for: M.self, key: key) else {
            return
        }
        let hashKey = ValkeyKey(plan.key)
        let sets = plan.sets.map { HSET<String, ByteBuffer>.Data(field: $0.field, value: $0.value.buffer) }
        switch (sets.isEmpty, plan.deletes.isEmpty) {
        case (false, true):
            _ = try await execute(HSET(hashKey, data: sets))
        case (true, false):
            _ = try await execute(HDEL(hashKey, fields: plan.deletes))
        case (false, false):
            // `transaction` reports per-command outcomes: a MULTI that a
            // server accepts can still have individual commands fail inside
            // it. Discarding that array — which is what `_ = try await` did
            // — made this path return success while writing nothing.
            //
            // The asymmetry was the worst part. The single-command paths
            // above surface a failure by throwing, so the *same* logical
            // write threw or vanished silently depending only on whether the
            // changeset happened to contain a nil, which is what decides
            // whether there are deletes and therefore whether the write goes
            // through MULTI at all.
            let results = try await transaction([
                HSET(hashKey, data: sets), HDEL(hashKey, fields: plan.deletes),
            ])
            try Self.requireAllSucceeded(results, key: plan.key)
        case (true, true):
            return  // unreachable: plan is nil when nothing changed
        }
    }

    /// Throws on the first failed command in a transaction's results.
    ///
    /// Reports which command index failed, because "the write did not happen"
    /// is a much less useful thing to learn than "the HDEL failed".
    static func requireAllSucceeded(
        _ results: [Result<RESPToken, ValkeyClientError>], key: String
    ) throws {
        for (index, result) in results.enumerated() {
            if case .failure(let error) = result {
                throw ValkeyChangesetError.commandFailed(
                    key: key, commandIndex: index, reason: String(describing: error))
            }
        }
    }
}

/// The `ValidatedChanges` → hash-write translation, separated from the
/// connection so it is testable without a server.
public enum ValkeyChangesetTranslation {
    /// One planned hash write. Fields are sorted, so the plan (and the
    /// commands rendered from it) is deterministic for tests and logs.
    public struct Plan: Sendable, Equatable {
        /// The hash key, e.g. `sessions:7d2f…`.
        public let key: String
        /// Fields to `HSET`, in sorted field order.
        public let sets: [FieldValue]
        /// Fields to `HDEL` (changed to nil), in sorted order.
        public let deletes: [String]
    }

    public struct FieldValue: Sendable, Equatable {
        public let field: String
        public let value: ValkeyChangesetValue

        public init(field: String, value: ValkeyChangesetValue) {
            self.field = field
            self.value = value
        }
    }

    /// Builds the write plan, or nil when there is nothing to write.
    public static func plan<M: TableModel>(
        _ changes: ValidatedChanges,
        for model: M.Type,
        key: ValkeyKey? = nil
    ) throws -> Plan? {
        guard !changes.changedFields.isEmpty else { return nil }

        let keyString: String
        if let key {
            keyString = "\(key)"
        } else {
            keyString = try deriveKey(changes, for: M.self)
        }

        var sets: [FieldValue] = []
        var deletes: [String] = []
        for field in changes.changedFields.keys.sorted() {
            if let value = try ValkeyChangesetValue(changes.changedFields[field]!, field: field) {
                sets.append(FieldValue(field: field, value: value))
            } else {
                deletes.append(field)
            }
        }
        return Plan(key: keyString, sets: sets, deletes: deletes)
    }

    /// `<tableName>:<pk>[:<pk>…]`, pk values in the model's declared
    /// primary-key column order. Update changesets carry identity; insert
    /// changesets must have changed every primary-key column.
    private static func deriveKey<M: TableModel>(
        _ changes: ValidatedChanges, for model: M.Type
    ) throws -> String {
        let primaryKey = M.primaryKey
        precondition(!primaryKey.isEmpty, """
        \(M.self) has no primary-key column, so a hash key cannot be derived. \
        Flag identity columns with TableColumn(_, _, primaryKey: true), or pass an explicit key.
        """)
        let identity = changes.identity ?? changes.changedFields
        let segments = try primaryKey.map { column -> String in
            guard let boxed = identity[column.name],
                let value = try ValkeyChangesetValue(boxed, field: column.name)
            else {
                throw ValkeyChangesetError.missingKeyField(
                    model: String(describing: M.self), column: column.name)
            }
            return value.keySegment
        }
        return ([M.tableName] + segments).joined(separator: ":")
    }
}

/// One changeset value rendered for the store. `ValidatedChanges` values are
/// `any Sendable` by design (the seam is store-neutral); this is where the
/// Valkey driver enumerates what it can write, mirroring the Postgres
/// driver's bindable set. Everything becomes a RESP bulk string — hashes
/// store strings; typed decode on read-back is the application's concern.
public enum ValkeyChangesetValue: Sendable, Equatable {
    /// Text renderings: String/Substring verbatim, integers and
    /// Double/Float/Decimal via `description`, Bool as `1`/`0`, UUID as its
    /// uuidString, Date as ISO 8601 with fractional seconds.
    case string(String)
    /// `Data`/`[UInt8]`/`ByteBuffer` pass through binary-safe.
    case bytes([UInt8])

    /// Nil for a boxed nil (→ `HDEL`); throws for an unrenderable type.
    /// Public so driver-level tests can assert renderings directly.
    public init?(_ boxed: any Sendable, field: String) throws {
        switch flattenOptional(boxed) {
        case .none:
            return nil
        case .some(let wrapped):
            switch wrapped {
            case let value as String: self = .string(value)
            case let value as Substring: self = .string(String(value))
            case let value as Int: self = .string("\(value)")
            case let value as Int64: self = .string("\(value)")
            case let value as Int32: self = .string("\(value)")
            case let value as Int16: self = .string("\(value)")
            case let value as Int8: self = .string("\(value)")
            case let value as UInt: self = .string("\(value)")
            case let value as UInt64: self = .string("\(value)")
            case let value as UInt32: self = .string("\(value)")
            case let value as Double: self = .string("\(value)")
            case let value as Float: self = .string("\(value)")
            case let value as Bool: self = .string(value ? "1" : "0")
            case let value as UUID: self = .string(value.uuidString)
            case let value as Date:
                self = .string(value.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            case let value as Decimal: self = .string("\(value)")
            case let value as [UInt8]: self = .bytes(value)
            case let value as Data: self = .bytes([UInt8](value))
            case let value as ByteBuffer: self = .bytes([UInt8](buffer: value))
            default:
                throw ValkeyChangesetError.unrenderableValue(
                    field: field, type: String(reflecting: type(of: wrapped)))
            }
        }
    }

    var buffer: ByteBuffer {
        switch self {
        case .string(let string): return ByteBuffer(string: string)
        case .bytes(let bytes): return ByteBuffer(bytes: bytes)
        }
    }

    /// The rendering used inside a derived hash key.
    var keySegment: String {
        switch self {
        case .string(let string): return string
        case .bytes(let bytes): return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// `ValidatedChanges` boxes optionals as `any Sendable`; unwrap (possibly
/// nested) optionality reflectively, as the in-memory reference driver does.
private func flattenOptional(_ value: any Sendable) -> Any? {
    var current: Any = value
    while true {
        let mirror = Mirror(reflecting: current)
        guard mirror.displayStyle == .optional else {
            return current
        }
        guard let child = mirror.children.first?.value else {
            return nil
        }
        current = child
    }
}

public enum ValkeyChangesetError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A changed field carried a value type this driver cannot render. The
    /// supported set: String, fixed-width integers, Double/Float, Bool,
    /// UUID, Date, Decimal, Data/[UInt8]/ByteBuffer, and optionals thereof.
    case unrenderableValue(field: String, type: String)
    /// An insert changeset (no identity) did not change some primary-key
    /// column, so no hash key can be derived.
    case missingKeyField(model: String, column: String)
    /// One command inside a transaction failed. The transaction as a whole
    /// was accepted by the server; this command within it was not, so the
    /// write did not fully land.
    case commandFailed(key: String, commandIndex: Int, reason: String)

    public var description: String {
        switch self {
        case .unrenderableValue(let field, let type):
            return "Changeset field '\(field)' has type \(type), which the Valkey driver cannot render. Store it as one of the supported column types (String, integers, Double, Bool, UUID, Date, Decimal, Data)."
        case .missingKeyField(let model, let column):
            return "Cannot derive a hash key for \(model): primary-key column '\(column)' is neither in the changeset's identity nor among its changed fields. Set it in the changeset, or pass an explicit key to apply(_:to:key:)."
        case .commandFailed(let key, let index, let reason):
            return "Writing changes to '\(key)' failed: command \(index) in the transaction reported \(reason). The write did not fully land."
        }
    }
}

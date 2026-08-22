import FlightMigrateCore

/// One registered migration: version, name, build-time source checksum, and the type to
/// instantiate. Produced by the generated `_allMigrations()` registry (design §6.1); can
/// also be constructed by hand for tests or custom discovery.
public struct MigrationEntry: Sendable {
    /// The 14-digit UTC timestamp prefix, e.g. `20260714120000`. Version and ordering key.
    public let version: Int64

    /// The migration type name, e.g. `CreateUsers`.
    public let name: String

    /// SHA-256 checksum of the migration's source, captured at build time (design §5).
    /// See `MigrationChecksum` in `FlightMigrateCore` for the exact definition.
    public let checksum: String

    /// The migration type; instantiated when the migration runs.
    public let type: any Migration.Type

    public init(version: Int64, name: String, checksum: String, type: any Migration.Type) {
        self.version = version
        self.name = name
        self.checksum = checksum
        self.type = type
    }

    /// Convenience for hand-built entries: derives the checksum from the given source text
    /// exactly as the build-time generator would.
    public init(version: Int64, name: String, source: String, type: any Migration.Type) {
        self.init(
            version: version,
            name: name,
            checksum: MigrationChecksum.compute(version: version, name: name, source: source),
            type: type
        )
    }

    /// `20260714120000_CreateUsers` — the identity used in logs and error messages.
    public var qualifiedName: String {
        "\(version)_\(name)"
    }

    /// Whether this migration's body runs inside a transaction (design §3).
    public var wrapInTransaction: Bool {
        type.wrapInTransaction
    }
}

/// A single schema migration: `up` and `down` together in one file (design §2.1).
///
/// Migrations are discovered at build time by `FlightMigratePlugin`, which generates an
/// ordered `_allMigrations()` registry for the target. A migration's identity is its
/// filename: `20260714120000_CreateUsers.swift` must declare a type named `CreateUsers`
/// conforming to `Migration`; the timestamp prefix is the version and ordering key.
///
/// ```swift
/// struct CreateUsers: Migration {
///     func up(_ schema: SchemaBuilder) {
///         schema.createTable("users") { t in
///             t.uuid("id").primaryKey().default(.raw("gen_random_uuid()"))
///             t.text("email").notNull().unique()
///             t.timestamptz("created_at").notNull().default(.now)
///         }
///     }
///
///     func down(_ schema: SchemaBuilder) {
///         schema.dropTable("users")
///     }
/// }
/// ```
///
/// `up`/`down` do not touch the database: they *describe* the migration by recording
/// statements on the ``SchemaBuilder``. `FlightMigrator` renders and executes those
/// statements — by default inside a transaction together with the bookkeeping write, so
/// a failed migration rolls back completely (design §3.1).
public protocol Migration: Sendable {
    /// Migrations must be trivially constructible; the runner instantiates them on demand.
    /// Stateless structs satisfy this automatically.
    init()

    /// Whether the migration body runs inside a transaction (default `true`).
    ///
    /// Set to `false` only for operations Postgres refuses to run in a transaction block —
    /// `CREATE INDEX CONCURRENTLY`, `ALTER TYPE ... ADD VALUE`, and friends (design §3.2).
    /// An unwrapped migration that fails partway **cannot** be rolled back automatically;
    /// keep such migrations to a single statement.
    static var wrapInTransaction: Bool { get }

    /// Describe the forward migration.
    func up(_ schema: SchemaBuilder)

    /// Describe how to revert `up`. Flight Migrate runs whatever you write here and does
    /// not pretend irreversible changes (e.g. a dropped column's data) are reversible
    /// (design §9). Leave empty for deliberately irreversible migrations.
    func down(_ schema: SchemaBuilder)
}

extension Migration {
    public static var wrapInTransaction: Bool { true }
}

/// The direction a migration is being run in.
public enum MigrationDirection: String, Sendable {
    case up
    case down
}

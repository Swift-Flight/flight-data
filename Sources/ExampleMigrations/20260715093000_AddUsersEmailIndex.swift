import FlightMigrate

// The design document's unwrapped example (§2.3, §3.2): CREATE INDEX CONCURRENTLY cannot
// run inside a transaction block, so this migration opts out of the wrapper. One
// statement per direction, as §3.2 advises — a partial failure here cannot auto-rollback.
struct AddUsersEmailIndex: Migration {
    // This migration cannot run in a transaction — see design §3.2.
    static let wrapInTransaction = false

    func up(_ schema: SchemaBuilder) {
        schema.raw("CREATE INDEX CONCURRENTLY idx_users_email ON users (email)")
    }

    func down(_ schema: SchemaBuilder) {
        schema.raw("DROP INDEX CONCURRENTLY idx_users_email")
    }
}

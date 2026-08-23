import FlightMigrate

// The integration suite's schema, defined and applied through Flight Migrate
//: "no separate schema-setup mechanism, so the migrations
// themselves are exercised on every test run." Tables carry an fdp_ prefix
// to stay clear of other suites sharing the database.

struct FDPCreateUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("fdp_users") { t in
            t.uuid("id").primaryKey()
            t.text("email").notNull().unique()
            t.text("lastName").notNull()
            t.bigint("age").notNull()
            t.timestamptz("createdAt").notNull()
            t.jsonb("profile")
            t.text("nickname")
            t.boolean("isActive").notNull().default(true)
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("fdp_users")
    }
}

struct FDPCreateAccounts: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("fdp_accounts") { t in
            t.text("id").primaryKey()
            t.bigint("balance").notNull()
        }
        schema.createTable("fdp_transfers") { t in
            t.text("id").primaryKey()
            t.text("origin").notNull().references("fdp_accounts")
            t.text("destination").notNull().references("fdp_accounts")
            t.bigint("amount").notNull()
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("fdp_transfers")
        schema.dropTable("fdp_accounts")
    }
}

enum TestMigrations {
    static let all: [MigrationEntry] = [
        MigrationEntry(
            version: 20_260_716_100_000, name: "FDPCreateUsers",
            source: "fdp-create-users-v1", type: FDPCreateUsers.self),
        MigrationEntry(
            version: 20_260_716_100_100, name: "FDPCreateAccounts",
            source: "fdp-create-accounts-v1", type: FDPCreateAccounts.self),
    ]
}

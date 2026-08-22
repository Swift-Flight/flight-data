import FlightMigrate

// ALTER TABLE actions plus a raw-SQL data backfill in the same migration — the
// add-nullable → backfill → set-default → set-not-null pattern.
struct AddUserProfile: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.alterTable("users") { t in
            t.text("bio")
            t.jsonb("preferences").notNull().default(.raw("'{}'::jsonb"))
            t.integer("login_count").notNull().default(0)
        }
        schema.raw("UPDATE users SET bio = '' WHERE bio IS NULL")
        schema.alterTable("users") { t in
            t.setDefault("bio", .string(""))
            t.setNotNull("bio")
        }
    }

    func down(_ schema: SchemaBuilder) {
        schema.alterTable("users") { t in
            t.dropColumn("login_count")
            t.dropColumn("preferences")
            t.dropColumn("bio")
        }
    }
}

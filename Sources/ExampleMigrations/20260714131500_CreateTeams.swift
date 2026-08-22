import FlightMigrate

// Wider DSL exercise: composite primary key, foreign keys with referential actions,
// timestamps() sugar, and an index.
struct CreateTeams: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("teams") { t in
            t.uuid("id").primaryKey().default(.raw("gen_random_uuid()"))
            t.text("name").notNull().unique()
            t.timestamps()
        }
        schema.createTable("team_members") { t in
            t.uuid("team_id").notNull().references("teams", onDelete: .cascade)
            t.uuid("user_id").notNull().references("users", onDelete: .cascade)
            t.text("role").notNull().default("member")
            t.primaryKey(["team_id", "user_id"])
        }
        schema.createIndex(on: "team_members", columns: ["user_id"])
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("team_members")
        schema.dropTable("teams")
    }
}

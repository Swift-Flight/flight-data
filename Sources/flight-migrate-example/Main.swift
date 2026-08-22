import ExampleMigrations
import FlightMigrate
import FlightMigrateCLI

// A complete migrate executable — this is all a consumer writes (design §7).
// `_allMigrations()` is generated at build time by FlightMigratePlugin from the
// ExampleMigrations target.
@main
struct ExampleMigrateTool: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}

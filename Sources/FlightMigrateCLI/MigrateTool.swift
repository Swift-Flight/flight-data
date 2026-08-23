import FlightMigrate

/// The entry point for a project's migrate executable.
///
/// A consumer's whole `main.swift` is:
///
/// ```swift
/// import FlightMigrateCLI
/// import Migrations   // the target with FlightMigratePlugin attached
///
/// @main
/// struct Migrate: MigrateTool {
///     static var migrations: [MigrationEntry] { _allMigrations() }
/// }
/// ```
///
/// which yields the full CLI:
///
/// ```
/// migrate                      # apply all pending
/// migrate status [--json]
/// migrate rollback [--steps N | --to VERSION]
/// migrate create CreateUsers
/// migrate repair
/// ```
///
/// The database URL comes from `--database-url`, `$FLIGHT_DATABASE_URL`, or
/// `$DATABASE_URL`. Migrations are **not** run automatically at boot; running
/// this binary is a deliberate, observable deploy step.
public protocol MigrateTool {
    /// The registered migrations — normally the generated `_allMigrations()`.
    static var migrations: [MigrationEntry] { get }
}

extension MigrateTool {
    public static func main() async {
        MigrationRegistry.set(migrations)
        await RootCommand.main()
    }
}

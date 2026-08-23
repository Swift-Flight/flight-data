import Foundation

/// Errors raised by the CLI layer itself (configuration and scaffolding; execution errors
/// come from `FlightMigrate.MigrationError`).
enum CLIError: Error, CustomStringConvertible, LocalizedError {
    case missingDatabaseURL
    case invalidDatabaseURL(String, reason: String)
    case invalidMigrationName(String, reason: String)
    case migrationsDirectoryNotFound(searched: [String])

    var description: String {
        switch self {
        case .missingDatabaseURL:
            return """
                no database URL. Pass --database-url, or set FLIGHT_DATABASE_URL or \
                DATABASE_URL (e.g. postgres://user:pass@localhost:5432/mydb).
                """
        case .invalidDatabaseURL(let url, let reason):
            return "invalid database URL '\(url)': \(reason)"
        case .invalidMigrationName(let name, let reason):
            return """
                invalid migration name '\(name)': \(reason). Names must be valid Swift type \
                names, e.g. 'CreateUsers'; they are used verbatim, never mangled.
                """
        case .migrationsDirectoryNotFound(let searched):
            return """
                no migrations directory found (looked for \(searched.joined(separator: ", "))). \
                Pass --directory to say where migration files live; it will be created if needed.
                """
        }
    }

    var errorDescription: String? { description }
}

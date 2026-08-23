import FlightMigrateCore
import Foundation

/// Generates new migration files for `create`. The timestamp is always UTC,
/// always generated — never hand-typed. Names are validated and used verbatim.
enum Scaffold {
    struct Created {
        let url: URL
        let version: Int64
    }

    /// Creates `<version>_<name>.swift` in `directory`, bumping the timestamp forward by
    /// one second if a file with the same version already exists (two creates within one
    /// second, or a re-used clock).
    static func makeMigration(
        name: String,
        date: Date,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> Created {
        guard SwiftIdentifier.isValid(name) else {
            let reason: String
            if SwiftIdentifier.reservedKeywords.contains(name) {
                reason = "'\(name)' is a Swift keyword"
            } else {
                reason = "must start with a letter or underscore and contain only letters, digits, and underscores"
            }
            throw CLIError.invalidMigrationName(name, reason: reason)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var candidate = date
        var version = utcVersion(of: candidate)
        while try versionExists(version, in: directory, fileManager: fileManager) {
            candidate = candidate.addingTimeInterval(1)
            version = utcVersion(of: candidate)
        }

        let url = directory.appendingPathComponent("\(version)_\(name).swift")
        let contents = template(name: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return Created(url: url, version: version)
    }

    /// The 14-digit `YYYYMMDDHHMMSS` version for a date, in UTC. Not configurable
    ///: local-time prefixes from a distributed team would sort differently
    /// than they were authored.
    static func utcVersion(of date: Date) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return MigrationTimestamp.version(
            year: c.year!, month: c.month!, day: c.day!,
            hour: c.hour!, minute: c.minute!, second: c.second!)
    }

    /// Whether any migration file in `directory` already uses `version` — same-name or
    /// not, a duplicate version would fail the build, so creation avoids it.
    private static func versionExists(
        _ version: Int64, in directory: URL, fileManager: FileManager
    ) throws -> Bool {
        let entries = try fileManager.contentsOfDirectory(atPath: directory.path)
        let prefix = "\(version)_"
        return entries.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".swift") }
    }

    /// Locates the migrations directory: an explicit `--directory`, else the conventional
    /// `Sources/Migrations`, else `Migrations`.
    static func resolveDirectory(
        flag: String?,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let flag {
            return URL(fileURLWithPath: flag, relativeTo: currentDirectory)
        }
        let conventional = ["Sources/Migrations", "Migrations"]
        for relative in conventional {
            let candidate = currentDirectory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
        }
        throw CLIError.migrationsDirectoryNotFound(searched: conventional)
    }

    static func template(name: String) -> String {
        """
        import FlightMigrate

        struct \(name): Migration {
            // Postgres runs this migration inside a transaction together with its
            // bookkeeping, so a failure rolls back cleanly. For statements that cannot
            // run in a transaction (CREATE INDEX CONCURRENTLY, ALTER TYPE ... ADD VALUE):
            //
            //     static let wrapInTransaction = false

            func up(_ schema: SchemaBuilder) {

            }

            func down(_ schema: SchemaBuilder) {

            }
        }

        """
    }
}

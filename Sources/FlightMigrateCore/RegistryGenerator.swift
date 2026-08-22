/// Build-time generation of the `_allMigrations()` registry (design §6.1).
///
/// The generator receives every `.swift` source in the migrations target, classifies each
/// file, validates the set as a whole, and emits a single Swift file containing an ordered
/// registry. All the properties §6.1/§7.1 promise are enforced here, which makes them
/// **build-time** errors:
///
/// - malformed timestamp prefixes,
/// - duplicate versions (including across differently-named files),
/// - a file that does not declare the migration type its filename names,
/// - more than one `Migration` type in a single file.
public enum RegistryGenerator {
    /// One input source file.
    public struct InputFile: Sendable {
        /// Path as shown in diagnostics (any form the build system provides).
        public let path: String
        /// The filename component, e.g. `20260714120000_CreateUsers.swift`.
        public let filename: String
        /// Full UTF-8 contents.
        public let contents: String

        public init(path: String, filename: String, contents: String) {
            self.path = path
            self.filename = filename
            self.contents = contents
        }
    }

    /// A discovered, validated migration.
    public struct DiscoveredMigration: Equatable, Sendable {
        public let version: Int64
        public let name: String
        public let checksum: String
        public let path: String
    }

    public struct GeneratorError: Error, CustomStringConvertible, Sendable {
        public let problems: [String]

        public var description: String {
            problems.map { "error: [FlightMigrate] \($0)" }.joined(separator: "\n")
        }
    }

    /// Scans and validates the input files, returning discovered migrations sorted by version.
    public static func discover(files: [InputFile]) throws -> [DiscoveredMigration] {
        var discovered: [DiscoveredMigration] = []
        var problems: [String] = []

        for file in files {
            switch MigrationFilename.classify(file.filename) {
            case .notAMigration:
                continue
            case .malformed(let reason):
                problems.append("\(file.path): invalid migration filename: \(reason)")
            case .migration(let parsed):
                let conformers = SourceScanner.migrationTypeNames(in: file.contents)
                if conformers.isEmpty {
                    problems.append(
                        """
                        \(file.path): no Migration type found. Expected a declaration like \
                        'struct \(parsed.name): Migration { ... }'. Note that the conformance must \
                        be declared at the type definition, not in an extension.
                        """)
                    continue
                }
                if conformers != [parsed.name] {
                    if conformers.count > 1 {
                        problems.append(
                            """
                            \(file.path): found multiple Migration types (\(conformers.joined(separator: ", "))). \
                            Each migration file must declare exactly one Migration type, named after the file.
                            """)
                    } else {
                        problems.append(
                            """
                            \(file.path): the filename promises a Migration type named '\(parsed.name)' but \
                            the file declares '\(conformers[0])'. Rename the file or the type so they match.
                            """)
                    }
                    continue
                }
                discovered.append(
                    DiscoveredMigration(
                        version: parsed.version,
                        name: parsed.name,
                        checksum: MigrationChecksum.compute(
                            version: parsed.version, name: parsed.name, source: file.contents),
                        path: file.path
                    ))
            }
        }

        // Duplicate version detection across the whole target.
        var byVersion: [Int64: [DiscoveredMigration]] = [:]
        for migration in discovered {
            byVersion[migration.version, default: []].append(migration)
        }
        for (version, group) in byVersion.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            let paths = group.map { "  - \($0.path)" }.sorted().joined(separator: "\n")
            problems.append(
                """
                duplicate migration version \(version):
                \(paths)
                Each migration must have a unique timestamp prefix (design §7.1). This usually \
                comes from a hand-edited or merge-conflicted filename; regenerate one of the \
                timestamps with 'flight-migrate create'.
                """)
        }

        guard problems.isEmpty else {
            throw GeneratorError(problems: problems)
        }
        return discovered.sorted { $0.version < $1.version }
    }

    /// Generates the registry source for a target. Throws ``GeneratorError`` on invalid input.
    public static func generate(targetName: String, files: [InputFile]) throws -> String {
        let migrations = try discover(files: files)

        var out = """
        // Generated by flight-migrate-gen for target '\(targetName)'. DO NOT EDIT.
        //
        // One entry per migration file, ordered by version (the UTC timestamp prefix).
        // Checksums are SHA-256 over the migration's source (see MigrationChecksum) and
        // are the values verified against the bookkeeping table on every run.

        import FlightMigrate

        /// All migrations discovered in this target, ordered by version.
        public func _allMigrations() -> [MigrationEntry] {
            [

        """

        for migration in migrations {
            out += """
                    MigrationEntry(
                        version: \(migration.version),
                        name: "\(migration.name)",
                        checksum: "\(migration.checksum)",
                        type: \(migration.name).self
                    ),

            """
        }

        out += """
            ]
        }
        """
        out += "\n"
        return out
    }
}

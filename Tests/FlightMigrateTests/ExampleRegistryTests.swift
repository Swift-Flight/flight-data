import ExampleMigrations
import FlightMigrate
import FlightMigrateCore
import Foundation
import Testing

/// End-to-end verification of the build plugin (design §6.1): the `_allMigrations()`
/// registry that `FlightMigratePlugin` generated during this test run's build must match
/// what we compute directly from the migration source files on disk.
@Suite("Plugin-generated registry")
struct ExampleRegistryTests {
    private var sourcesDirectory: URL {
        // Tests/FlightMigrateTests/ExampleRegistryTests.swift → package root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExampleMigrations")
    }

    @Test func registryIsOrderedAndComplete() {
        let registry = ExampleMigrations._allMigrations()
        #expect(
            registry.map(\.name) == [
                "CreateUsers", "CreateTeams", "AddUsersEmailIndex", "AddUserProfile",
            ])
        #expect(registry.map(\.version) == registry.map(\.version).sorted())
        #expect(registry.map(\.version) == [
            20260714120000, 20260714131500, 20260715093000, 20260716101500,
        ])
    }

    @Test func checksumsMatchSourceFiles() throws {
        let registry = ExampleMigrations._allMigrations()
        for entry in registry {
            let file = sourcesDirectory.appendingPathComponent(
                "\(entry.version)_\(entry.name).swift")
            let source = try String(contentsOf: file, encoding: .utf8)
            let expected = MigrationChecksum.compute(
                version: entry.version, name: entry.name, source: source)
            #expect(
                entry.checksum == expected,
                "build-time checksum for \(entry.qualifiedName) does not match its source file")
        }
    }

    @Test func wrapInTransactionSurvivesRegistration() {
        let registry = ExampleMigrations._allMigrations()
        let byName = Dictionary(uniqueKeysWithValues: registry.map { ($0.name, $0) })
        #expect(byName["CreateUsers"]?.wrapInTransaction == true)
        #expect(byName["AddUsersEmailIndex"]?.wrapInTransaction == false)
    }

    @Test func registryEntriesProduceRunnableStatements() {
        for entry in ExampleMigrations._allMigrations() {
            let schema = SchemaBuilder()
            entry.type.init().up(schema)
            #expect(!schema.statements.isEmpty, "\(entry.qualifiedName) up() has no statements")
        }
    }
}

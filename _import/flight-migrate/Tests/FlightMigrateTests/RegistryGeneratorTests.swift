import Testing

@testable import FlightMigrateCore

@Suite("RegistryGenerator")
struct RegistryGeneratorTests {
    private func file(_ name: String, _ contents: String) -> RegistryGenerator.InputFile {
        RegistryGenerator.InputFile(path: "Sources/Migrations/\(name)", filename: name, contents: contents)
    }

    @Test func discoversAndSortsByVersion() throws {
        let files = [
            file("20260716101500_Later.swift", "struct Later: Migration {}"),
            file("20260714120000_Earlier.swift", "struct Earlier: Migration {}"),
            file("Helpers.swift", "enum Helpers {}"),
        ]
        let discovered = try RegistryGenerator.discover(files: files)
        #expect(discovered.map(\.name) == ["Earlier", "Later"])
        #expect(discovered.map(\.version) == [20260714120000, 20260716101500])
    }

    @Test func checksumMatchesDirectComputation() throws {
        let contents = "struct M: Migration { /* body */ }"
        let discovered = try RegistryGenerator.discover(
            files: [file("20260714120000_M.swift", contents)])
        #expect(
            discovered[0].checksum
                == MigrationChecksum.compute(version: 20260714120000, name: "M", source: contents))
    }

    @Test func duplicateVersionsAreABuildError() {
        let files = [
            file("20260714120000_One.swift", "struct One: Migration {}"),
            file("20260714120000_Two.swift", "struct Two: Migration {}"),
        ]
        #expect(throws: RegistryGenerator.GeneratorError.self) {
            try RegistryGenerator.discover(files: files)
        }
        do {
            _ = try RegistryGenerator.discover(files: files)
        } catch let error as RegistryGenerator.GeneratorError {
            #expect(error.description.contains("duplicate migration version 20260714120000"))
            #expect(error.description.contains("One.swift"))
            #expect(error.description.contains("Two.swift"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func malformedTimestampIsABuildError() {
        let files = [file("2026071412000_M.swift", "struct M: Migration {}")]
        #expect(throws: RegistryGenerator.GeneratorError.self) {
            try RegistryGenerator.discover(files: files)
        }
    }

    @Test func filenameTypeMismatchIsABuildError() {
        let files = [file("20260714120000_CreateUsers.swift", "struct CreateTeams: Migration {}")]
        do {
            _ = try RegistryGenerator.discover(files: files)
            Issue.record("expected an error")
        } catch let error as RegistryGenerator.GeneratorError {
            #expect(error.description.contains("CreateUsers"))
            #expect(error.description.contains("CreateTeams"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func missingMigrationTypeIsABuildError() {
        let files = [file("20260714120000_CreateUsers.swift", "enum CreateUsers {}")]
        do {
            _ = try RegistryGenerator.discover(files: files)
            Issue.record("expected an error")
        } catch let error as RegistryGenerator.GeneratorError {
            #expect(error.description.contains("no Migration type found"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func multipleMigrationsInOneFileIsABuildError() {
        let files = [
            file(
                "20260714120000_CreateUsers.swift",
                "struct CreateUsers: Migration {}\nstruct Extra: Migration {}"),
        ]
        do {
            _ = try RegistryGenerator.discover(files: files)
            Issue.record("expected an error")
        } catch let error as RegistryGenerator.GeneratorError {
            #expect(error.description.contains("multiple Migration types"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func multipleProblemsAllReported() {
        let files = [
            file("2026_Bad.swift", "struct Bad: Migration {}"),
            file("20260714120000_Mismatch.swift", "struct Other: Migration {}"),
        ]
        do {
            _ = try RegistryGenerator.discover(files: files)
            Issue.record("expected an error")
        } catch let error as RegistryGenerator.GeneratorError {
            #expect(error.problems.count == 2)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func emptyTargetGeneratesEmptyRegistry() throws {
        let generated = try RegistryGenerator.generate(
            targetName: "Empty", files: [file("Helpers.swift", "enum Helpers {}")])
        #expect(generated.contains("public func _allMigrations() -> [MigrationEntry]"))
        #expect(!generated.contains("MigrationEntry("))
    }

    @Test func generatedSourceShape() throws {
        let generated = try RegistryGenerator.generate(
            targetName: "Migrations",
            files: [file("20260714120000_M.swift", "struct M: Migration {}")])
        #expect(generated.contains("import FlightMigrate"))
        #expect(generated.contains("version: 20260714120000"))
        #expect(generated.contains("name: \"M\""))
        #expect(generated.contains("type: M.self"))
        #expect(generated.contains("DO NOT EDIT"))
    }

    @Test func generationIsDeterministic() throws {
        let files = [
            file("20260716101500_B.swift", "struct B: Migration {}"),
            file("20260714120000_A.swift", "struct A: Migration {}"),
        ]
        let first = try RegistryGenerator.generate(targetName: "T", files: files)
        let second = try RegistryGenerator.generate(targetName: "T", files: files.reversed())
        #expect(first == second)
    }
}

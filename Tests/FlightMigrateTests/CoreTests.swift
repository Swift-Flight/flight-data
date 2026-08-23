import Testing

@testable import FlightMigrateCore

@Suite("SHA-256")
struct SHA256Tests {
    // NIST FIPS 180-2 test vectors.
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
        (
            "The quick brown fox jumps over the lazy dog",
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        ),
    ])
    func knownVectors(input: String, expected: String) {
        #expect(SHA256.hexDigest(of: input) == expected)
    }

    @Test func millionAs() {
        let input = String(repeating: "a", count: 1_000_000)
        #expect(
            SHA256.hexDigest(of: input)
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func multiBlockBoundaries() {
        // Lengths around the 55/56/64-byte padding boundaries must not crash and must
        // be distinct.
        var digests = Set<String>()
        for length in 50...70 {
            digests.insert(SHA256.hexDigest(of: String(repeating: "x", count: length)))
        }
        #expect(digests.count == 21)
    }
}

@Suite("MigrationChecksum")
struct ChecksumTests {
    @Test func goldenValue() {
        // Pins the checksum definition forever: domain prefix + identity line + source.
        // Independently computed: sha256("flight-migrate:v1\n20260714120000_CreateUsers\nhello\n").
        let checksum = MigrationChecksum.compute(
            version: 20260714120000, name: "CreateUsers", source: "hello\n")
        #expect(checksum == "a12bd720f0aab7da28bf1cf60314434863c4179c8953b3874601474d4b9eb1ce")
    }

    @Test func lineEndingsAreNormalized() {
        let lf = MigrationChecksum.compute(version: 1, name: "M", source: "a\nb\nc\n")
        let crlf = MigrationChecksum.compute(version: 1, name: "M", source: "a\r\nb\r\nc\r\n")
        let cr = MigrationChecksum.compute(version: 1, name: "M", source: "a\rb\rc\r")
        #expect(lf == crlf)
        #expect(lf == cr)
    }

    @Test func crlfDoesNotSwallowFollowingNewline() {
        #expect(MigrationChecksum.normalize("a\r\n\nb") == "a\n\nb")
    }

    @Test func contentChangesChangeChecksum() {
        let original = MigrationChecksum.compute(version: 1, name: "M", source: "a")
        #expect(MigrationChecksum.compute(version: 1, name: "M", source: "a ") != original)
        #expect(MigrationChecksum.compute(version: 1, name: "M", source: "b") != original)
    }

    @Test func identityIsPartOfTheChecksum() {
        // Renaming a file (same contents, new name or version) must read as drift.
        let original = MigrationChecksum.compute(version: 1, name: "M", source: "a")
        #expect(MigrationChecksum.compute(version: 2, name: "M", source: "a") != original)
        #expect(MigrationChecksum.compute(version: 1, name: "N", source: "a") != original)
    }
}

@Suite("MigrationFilename")
struct FilenameTests {
    @Test func validFilename() {
        let result = MigrationFilename.classify("20260714120000_CreateUsers.swift")
        #expect(
            result
                == .migration(.init(version: 20260714120000, name: "CreateUsers")))
    }

    @Test func underscoreAndDigitsInName() {
        let result = MigrationFilename.classify("20260714120000_Add_users_email_2.swift")
        #expect(
            result == .migration(.init(version: 20260714120000, name: "Add_users_email_2")))
    }

    @Test(arguments: [
        "Helpers.swift",  // no digit prefix: helper code
        "_20260714120000_CreateUsers.swift",  // leading underscore: not digit-first
        "README.md",  // not a Swift file
    ])
    func ignoredFiles(filename: String) {
        #expect(MigrationFilename.classify(filename) == .notAMigration)
    }

    @Test(arguments: [
        "2026071412000_CreateUsers.swift",  // 13 digits
        "202607141200000_CreateUsers.swift",  // 15 digits
        "20260714120000CreateUsers.swift",  // no underscore
        "20260714120000_.swift",  // empty name
        "20261314120000_CreateUsers.swift",  // month 13
        "20260732120000_CreateUsers.swift",  // day 32
        "20260714240000_CreateUsers.swift",  // hour 24
        "20260714126000_CreateUsers.swift",  // minute 60
        "20260714120060_CreateUsers.swift",  // second 60
        "20230229120000_CreateUsers.swift",  // Feb 29 in a non-leap year
        "20260714120000_Create-Users.swift",  // invalid identifier
        "20260714120000_class.swift",  // Swift keyword
        "20260714120000_9Users.swift",  // name starts with digit
    ])
    func malformedFilenames(filename: String) {
        guard case .malformed = MigrationFilename.classify(filename) else {
            Issue.record("expected .malformed for \(filename)")
            return
        }
    }

    @Test func leapYearFeb29IsValid() {
        let result = MigrationFilename.classify("20240229120000_LeapDay.swift")
        #expect(result == .migration(.init(version: 20240229120000, name: "LeapDay")))
    }

    @Test func centuryLeapYearRules() {
        // 2000 was a leap year (divisible by 400); 2100 is not.
        #expect(MigrationTimestamp.isLeapYear(2000))
        #expect(!MigrationTimestamp.isLeapYear(2100))
        #expect(MigrationTimestamp.daysIn(month: 2, year: 2000) == 29)
        #expect(MigrationTimestamp.daysIn(month: 2, year: 2100) == 28)
    }

    @Test func versionFormatting() {
        #expect(
            MigrationTimestamp.version(year: 2026, month: 7, day: 4, hour: 9, minute: 3, second: 0)
                == 20260704090300)
    }
}

@Suite("SwiftIdentifier")
struct SwiftIdentifierTests {
    @Test(arguments: ["CreateUsers", "add_email", "_Private", "M1", "lowercase"])
    func valid(name: String) {
        #expect(SwiftIdentifier.isValid(name))
    }

    @Test(arguments: ["", "9Lives", "Create-Users", "Create Users", "class", "struct", "Café"])
    func invalid(name: String) {
        #expect(!SwiftIdentifier.isValid(name))
    }
}

@Suite("SourceScanner")
struct SourceScannerTests {
    @Test func findsStructConformance() {
        let source = """
            import FlightMigrate

            struct CreateUsers: Migration {
                func up(_ schema: SchemaBuilder) {}
                func down(_ schema: SchemaBuilder) {}
            }
            """
        #expect(SourceScanner.migrationTypeNames(in: source) == ["CreateUsers"])
    }

    @Test(arguments: [
        "final class CreateUsers: Migration {}",
        "public struct CreateUsers: Migration {}",
        "struct CreateUsers: Sendable, Migration {}",
        "struct CreateUsers: Migration, Sendable {}",
        "actor CreateUsers: Migration {}",
        "struct CreateUsers : Migration {}",
        "struct CreateUsers:\n    Migration\n{}",
    ])
    func conformanceForms(source: String) {
        #expect(SourceScanner.migrationTypeNames(in: source) == ["CreateUsers"])
    }

    @Test(arguments: [
        "struct CreateUsers {}",  // no conformance
        "struct CreateUsers: MigrationHelper {}",  // not a word match
        "struct CreateUsers: My.Migration {}",  // qualified: not the marker protocol
        "// struct CreateUsers: Migration {}",  // inside a line comment
        "/* struct CreateUsers: Migration {} */",  // inside a block comment
        "/* outer /* struct CreateUsers: Migration {} */ still comment */",  // nested
        "let s = \"struct CreateUsers: Migration {}\"",  // inside a string literal
        "let s = \"\"\"\nstruct CreateUsers: Migration {}\n\"\"\"",  // multiline string
        "let s = #\"struct CreateUsers: Migration {}\"#",  // raw string
        "extension CreateUsers: Migration {}",  // extension conformance: not supported
    ])
    func nonMatches(source: String) {
        #expect(SourceScanner.migrationTypeNames(in: source).isEmpty)
    }

    @Test func multipleDeclarationsAllFound() {
        let source = """
            struct A: Migration {}
            struct Helper {}
            struct B: Migration {}
            """
        #expect(SourceScanner.migrationTypeNames(in: source) == ["A", "B"])
    }

    @Test func stringWithEscapedQuoteDoesNotDerailScanner() {
        let source = """
            let s = "he said \\"hi\\""
            struct C: Migration {}
            """
        #expect(SourceScanner.migrationTypeNames(in: source) == ["C"])
    }

    @Test func whereClauseIsNotSearched() {
        let source = "struct D<T>: Sendable where T: Migration {}"
        #expect(SourceScanner.migrationTypeNames(in: source).isEmpty)
    }

    @Test func genericMigrationConformance() {
        let source = "struct E<T>: Migration {}"
        #expect(SourceScanner.migrationTypeNames(in: source) == ["E"])
    }
}

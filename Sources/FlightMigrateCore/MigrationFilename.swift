/// Parsing and validation of migration filenames: `<14-digit UTC timestamp>_<TypeName>.swift`,
/// e.g. `20260714120000_CreateUsers.swift` (design §2, §7.1).
public enum MigrationFilename {
    /// A successfully parsed migration filename.
    public struct Parsed: Equatable, Sendable {
        /// The 14-digit timestamp prefix as an integer, e.g. `20260714120000`.
        public let version: Int64
        /// The migration type name, e.g. `CreateUsers`.
        public let name: String

        public init(version: Int64, name: String) {
            self.version = version
            self.name = name
        }
    }

    /// How a filename was classified by ``classify(_:)``.
    public enum Classification: Equatable, Sendable {
        /// A well-formed migration file.
        case migration(Parsed)
        /// Not a migration file (helper code in the same target); ignored by discovery.
        case notAMigration
        /// Starts with a digit — clearly *intended* to be a migration — but malformed.
        /// Discovery treats this as a hard build error rather than silently skipping it.
        case malformed(reason: String)
    }

    /// Classifies a filename (the last path component, e.g. `20260714120000_CreateUsers.swift`).
    ///
    /// The rule: a `.swift` file whose name starts with a digit **must** be a well-formed
    /// migration filename — anything else in the target is ignored as helper code. This is
    /// what makes a hand-mangled or merge-conflicted prefix a build-time error (§7.1)
    /// instead of a silently unregistered migration.
    public static func classify(_ filename: String) -> Classification {
        guard filename.hasSuffix(".swift") else { return .notAMigration }
        guard let first = filename.first, first.isASCII, first.isNumber else {
            return .notAMigration
        }

        let stem = String(filename.dropLast(".swift".count))
        let parts = stem.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else {
            return .malformed(reason: "expected '<14-digit UTC timestamp>_<TypeName>.swift'")
        }
        let timestampPart = String(parts[0])
        let namePart = String(parts[1])

        guard timestampPart.count == 14, timestampPart.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .malformed(
                reason: "timestamp prefix '\(timestampPart)' must be exactly 14 digits (YYYYMMDDHHMMSS, UTC)")
        }
        if let reason = MigrationTimestamp.validationFailure(timestampPart) {
            return .malformed(reason: reason)
        }
        guard SwiftIdentifier.isValid(namePart) else {
            return .malformed(
                reason: "'\(namePart)' is not a valid Swift type name")
        }
        // The 14-digit constraint keeps this well below Int64.max.
        let version = Int64(timestampPart)!
        return .migration(Parsed(version: version, name: namePart))
    }
}

/// Validation and formatting of the 14-digit `YYYYMMDDHHMMSS` UTC timestamp prefix.
public enum MigrationTimestamp {
    /// Returns a human-readable reason if the 14-digit string is not a plausible UTC
    /// calendar timestamp, or `nil` if it is valid. The input must already be 14 ASCII digits.
    public static func validationFailure(_ digits: String) -> String? {
        precondition(digits.count == 14 && digits.allSatisfy { $0.isASCII && $0.isNumber })
        let chars = Array(digits)
        func int(_ range: Range<Int>) -> Int {
            Int(String(chars[range]))!
        }
        let year = int(0..<4)
        let month = int(4..<6)
        let day = int(6..<8)
        let hour = int(8..<10)
        let minute = int(10..<12)
        let second = int(12..<14)

        guard year >= 1970 else { return "timestamp year \(year) is before 1970" }
        guard (1...12).contains(month) else { return "timestamp month \(month) is not in 1...12" }
        let maxDay = daysIn(month: month, year: year)
        guard (1...maxDay).contains(day) else {
            return "timestamp day \(day) is not valid for \(year)-\(String(format2: month))"
        }
        guard (0...23).contains(hour) else { return "timestamp hour \(hour) is not in 0...23" }
        guard (0...59).contains(minute) else { return "timestamp minute \(minute) is not in 0...59" }
        guard (0...59).contains(second) else { return "timestamp second \(second) is not in 0...59" }
        return nil
    }

    /// Formats calendar components as a 14-digit version. Components must form a valid date.
    public static func version(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) -> Int64 {
        var digits = String(format4: year)
        digits += String(format2: month)
        digits += String(format2: day)
        digits += String(format2: hour)
        digits += String(format2: minute)
        digits += String(format2: second)
        return Int64(digits)!
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}

// Zero-padded decimal formatting without Foundation.
extension String {
    fileprivate init(format2 value: Int) {
        self = value < 10 ? "0\(value)" : "\(value)"
    }

    fileprivate init(format4 value: Int) {
        var s = "\(value)"
        while s.count < 4 { s = "0" + s }
        self = s
    }
}

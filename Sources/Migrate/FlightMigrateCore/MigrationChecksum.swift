/// Computes the drift-detection checksum for a migration.
///
/// The checksum is captured at **build time** by `flight-migrate-gen` from the migration's
/// source file, embedded in the generated `_allMigrations()` registry, and stored in the
/// bookkeeping table when the migration is applied. On every subsequent run the stored
/// value is compared against the registry value; a mismatch halts the run.
///
/// Definition (fixed — changing it invalidates every recorded checksum):
///
///     sha256_hex("flight-migrate:v1\n" + "<version>_<name>\n" + normalized_source)
///
/// where `normalized_source` is the file's UTF-8 text with all line endings normalized
/// to `\n`. Line-ending normalization means a CRLF/LF difference between checkouts (for
/// example `git core.autocrlf` on different machines) is not reported as drift; any other
/// byte difference — including whitespace and comments — is. The design errs toward
/// halting and asking: semantic-equivalence cleverness is deliberately out of scope.
///
/// The `<version>_<name>` line ties the checksum to the migration's identity, so renaming
/// a migration file (which changes the recorded name without touching its contents) is
/// also surfaced as drift rather than passing silently.
public enum MigrationChecksum {
    /// The domain-separation prefix, versioned so a future algorithm change can coexist
    /// with recorded checksums.
    public static let domainPrefix = "flight-migrate:v1"

    /// Computes the checksum for a migration's source text.
    public static func compute(version: Int64, name: String, source: String) -> String {
        let preimage = "\(domainPrefix)\n\(version)_\(name)\n\(normalize(source))"
        return SHA256.hexDigest(of: preimage)
    }

    /// Normalizes line endings to `\n` (CRLF and lone CR both become LF).
    ///
    /// Note: Swift groups an adjacent CR+LF into the single `Character` `"\r\n"`, so a
    /// per-character map is sufficient — a bare `"\r"` character is always a *lone* CR.
    public static func normalize(_ source: String) -> String {
        // Scalar-level check: a CRLF pair is a *single* Character ("\r\n"), so a
        // Character-level contains("\r") would miss it.
        guard source.unicodeScalars.contains("\r") else { return source }
        var out = String()
        out.reserveCapacity(source.count)
        for character in source {
            switch character {
            case "\r\n", "\r":
                out.append("\n")
            default:
                out.append(character)
            }
        }
        return out
    }
}

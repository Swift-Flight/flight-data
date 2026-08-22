/// A deliberately small Swift source scanner used by the build-time generator to verify
/// that a migration file declares exactly the `Migration`-conforming type its filename
/// promises (design §6.1).
///
/// This is not a Swift parser. It strips comments and string literals, then looks for
/// type declarations (`struct`/`class`/`actor`/`enum`) whose inheritance clause names
/// `Migration`. That is enough to catch, at build time, the mistakes that matter:
/// a filename/type-name mismatch, a file declaring no migration, or two migrations in
/// one file. The declaration and its `Migration` conformance must appear at the type's
/// definition (not retroactively via `extension`) — the generator enforces this so that
/// discovery stays trivially auditable.
public enum SourceScanner {
    /// Returns the names of types declared in `source` whose inheritance clause contains
    /// `Migration` (as a whole word).
    public static func migrationTypeNames(in source: String) -> [String] {
        let stripped = strippingCommentsAndStrings(source)
        var names: [String] = []
        let chars = Array(stripped)
        let keywords: Set<String> = ["struct", "class", "actor", "enum"]

        var index = 0
        while index < chars.count {
            // Find the next identifier-ish token.
            guard isIdentifierStart(chars[index]) else {
                index += 1
                continue
            }
            let tokenStart = index
            while index < chars.count, isIdentifierContinuation(chars[index]) {
                index += 1
            }
            let token = String(chars[tokenStart..<index])
            guard keywords.contains(token) else { continue }
            // Word-boundary check on the left (e.g. don't match "subclass").
            if tokenStart > 0, isIdentifierContinuation(chars[tokenStart - 1]) { continue }

            // Read the declared type name.
            var cursor = skipWhitespace(chars, from: index)
            guard cursor < chars.count, isIdentifierStart(chars[cursor]) else { continue }
            let nameStart = cursor
            while cursor < chars.count, isIdentifierContinuation(chars[cursor]) {
                cursor += 1
            }
            let name = String(chars[nameStart..<cursor])

            // Skip generic parameters, if any.
            cursor = skipWhitespace(chars, from: cursor)
            if cursor < chars.count, chars[cursor] == "<" {
                var depth = 0
                while cursor < chars.count {
                    if chars[cursor] == "<" { depth += 1 }
                    if chars[cursor] == ">" {
                        depth -= 1
                        if depth == 0 {
                            cursor += 1
                            break
                        }
                    }
                    cursor += 1
                }
            }

            // Require an inheritance clause before the body.
            cursor = skipWhitespace(chars, from: cursor)
            guard cursor < chars.count, chars[cursor] == ":" else { continue }

            // Collect the clause text up to the opening brace (or a `where` clause).
            var clause = String()
            var scan = cursor + 1
            while scan < chars.count, chars[scan] != "{" {
                clause.append(chars[scan])
                scan += 1
            }

            if containsWord("Migration", in: clause) {
                names.append(name)
            }
        }
        return names
    }

    /// Whether `clause` contains `word` bounded by non-identifier characters, ignoring a
    /// trailing `where` constraint.
    static func containsWord(_ word: String, in clause: String) -> Bool {
        let effective: String
        if let whereRange = rangeOfWord("where", in: clause) {
            effective = String(clause[clause.startIndex..<whereRange.lowerBound])
        } else {
            effective = clause
        }
        return rangeOfWord(word, in: effective) != nil
    }

    private static func rangeOfWord(_ word: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let range = text[searchStart...].firstRange(of: word) {
            let beforeOK: Bool
            if range.lowerBound == text.startIndex {
                beforeOK = true
            } else {
                let before = text[text.index(before: range.lowerBound)]
                beforeOK = !isIdentifierContinuation(before) && before != "."
            }
            let afterOK: Bool
            if range.upperBound == text.endIndex {
                afterOK = true
            } else {
                afterOK = !isIdentifierContinuation(text[range.upperBound])
            }
            if beforeOK && afterOK { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    /// Removes comments (line and nested block) and string literals (regular, multiline,
    /// and raw `#"..."#` forms), replacing them with spaces so token positions stay sane.
    public static func strippingCommentsAndStrings(_ source: String) -> String {
        let chars = Array(source)
        var out = [Character]()
        out.reserveCapacity(chars.count)
        var i = 0

        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        while i < chars.count {
            let c = chars[i]

            // Line comment.
            if c == "/", peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }

            // Block comment (nested, per Swift).
            if c == "/", peek(1) == "*" {
                var depth = 0
                while i < chars.count {
                    if chars[i] == "/", peek(1) == "*" {
                        depth += 1
                        i += 2
                        continue
                    }
                    if chars[i] == "*", peek(1) == "/" {
                        depth -= 1
                        i += 2
                        if depth == 0 { break }
                        continue
                    }
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                out.append(" ")
                continue
            }

            // Raw string delimiters: count leading '#'s before a quote.
            if c == "#" || c == "\"" {
                var hashCount = 0
                var j = i
                while j < chars.count, chars[j] == "#" {
                    hashCount += 1
                    j += 1
                }
                if j < chars.count, chars[j] == "\"" {
                    let isMultiline = j + 2 < chars.count && chars[j + 1] == "\"" && chars[j + 2] == "\""
                    let openLength = (isMultiline ? 3 : 1)
                    var k = j + openLength
                    // Scan for the matching close quote (same multiline-ness, same hash count).
                    while k < chars.count {
                        if !isMultiline, hashCount == 0, chars[k] == "\\" {
                            k += 2  // skip escaped character in a plain string
                            continue
                        }
                        if chars[k] == "\"" {
                            let quotes = isMultiline ? 3 : 1
                            var allQuotes = true
                            for q in 0..<quotes where k + q >= chars.count || chars[k + q] != "\"" {
                                allQuotes = false
                            }
                            if allQuotes {
                                var m = k + quotes
                                var closingHashes = 0
                                while m < chars.count, chars[m] == "#", closingHashes < hashCount {
                                    closingHashes += 1
                                    m += 1
                                }
                                if closingHashes == hashCount {
                                    k = m
                                    break
                                }
                            }
                        }
                        if chars[k] == "\n" { out.append("\n") }
                        k += 1
                    }
                    out.append(" ")
                    i = k
                    continue
                }
                // A '#' not starting a raw string: emit and continue.
                out.append(c)
                i += 1
                continue
            }

            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static func skipWhitespace(_ chars: [Character], from index: Int) -> Int {
        var i = index
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return i
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || (c.isASCII && c.isLetter)
    }

    private static func isIdentifierContinuation(_ c: Character) -> Bool {
        c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
    }
}

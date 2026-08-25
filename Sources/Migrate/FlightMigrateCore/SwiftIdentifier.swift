/// Validation of migration type names ("the CLI rejects names that aren't
/// valid identifiers rather than silently mangling them").
public enum SwiftIdentifier {
    /// Swift reserved keywords that cannot be used as a bare type name. Contextual
    /// keywords that are legal as identifiers (`final`, `lazy`, `get`, ...) are not listed.
    public static let reservedKeywords: Set<String> = [
        "associatedtype", "borrowing", "class", "consuming", "deinit", "enum", "extension",
        "fileprivate", "func", "import", "init", "inout", "internal", "let", "operator",
        "precedencegroup", "private", "protocol", "public", "rethrows", "static", "struct",
        "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
        "switch", "throw", "where", "while", "as", "any", "false", "is", "nil", "self",
        "Self", "super", "throws", "true", "try", "Any", "Type", "Protocol",
    ]

    /// Whether `name` can be used verbatim as a Swift type name: ASCII letters, digits and
    /// underscores, not starting with a digit, and not a reserved keyword.
    ///
    /// Swift itself permits a much wider range of identifier characters; migrations keep to
    /// the portable ASCII subset because the name is also part of the filename and the
    /// bookkeeping ledger.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard let first = name.first, first == "_" || (first.isASCII && first.isLetter) else {
            return false
        }
        guard name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) else {
            return false
        }
        return !reservedKeywords.contains(name)
    }
}

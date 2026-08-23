import Foundation

/// A Postgres column type as rendered into DDL.
///
/// The provided constructors cover the common types; anything else is `.custom("...")`.
/// This mirrors the DSL's overall stance: common cases are typed,
/// exotic ones drop to strings — deliberately, not apologetically.
public struct ColumnType: Sendable, Equatable {
    /// The SQL rendering, e.g. `TIMESTAMPTZ` or `VARCHAR(255)`.
    public let sql: String

    private init(_ sql: String) {
        self.sql = sql
    }

    /// A type the constructors don't cover, rendered verbatim (e.g. `"tsvector"`).
    public static func custom(_ sql: String) -> ColumnType { ColumnType(sql) }

    public static let uuid = ColumnType("UUID")
    public static let text = ColumnType("TEXT")
    public static let smallint = ColumnType("SMALLINT")
    public static let integer = ColumnType("INTEGER")
    public static let bigint = ColumnType("BIGINT")
    public static let boolean = ColumnType("BOOLEAN")
    public static let real = ColumnType("REAL")
    public static let doublePrecision = ColumnType("DOUBLE PRECISION")
    public static let numeric = ColumnType("NUMERIC")
    public static let date = ColumnType("DATE")
    public static let time = ColumnType("TIME")
    public static let timestamp = ColumnType("TIMESTAMP")
    public static let timestamptz = ColumnType("TIMESTAMPTZ")
    public static let interval = ColumnType("INTERVAL")
    public static let json = ColumnType("JSON")
    public static let jsonb = ColumnType("JSONB")
    public static let bytea = ColumnType("BYTEA")
    public static let inet = ColumnType("INET")
    public static let varchar = ColumnType("VARCHAR")
    public static let char = ColumnType("CHAR")

    public static func varchar(_ limit: Int) -> ColumnType { ColumnType("VARCHAR(\(limit))") }
    public static func char(_ limit: Int) -> ColumnType { ColumnType("CHAR(\(limit))") }
    public static func numeric(_ precision: Int) -> ColumnType { ColumnType("NUMERIC(\(precision))") }
    public static func numeric(_ precision: Int, _ scale: Int) -> ColumnType {
        ColumnType("NUMERIC(\(precision), \(scale))")
    }

    /// An array of the given element type: `.array(of: .text)` → `TEXT[]`.
    public static func array(of element: ColumnType) -> ColumnType {
        ColumnType("\(element.sql)[]")
    }
}

/// A column `DEFAULT` expression.
public enum DefaultValue: Sendable, Equatable {
    /// A raw SQL expression rendered verbatim, e.g. `.raw("gen_random_uuid()")`.
    case raw(String)
    /// `now()`.
    case now
    /// `NULL`.
    case null
    /// A quoted string literal.
    case string(String)
    /// An integer literal.
    case int(Int64)
    /// A floating-point literal.
    case double(Double)
    /// `TRUE` / `FALSE`.
    case bool(Bool)
    /// `UUID`
    case uuid
    
    var sql: String {
        switch self {
        case .raw(let expression): return expression
        case .now: return "now()"
        case .null: return "NULL"
        case .string(let value): return SQL.stringLiteral(value)
        case .int(let value): return "\(value)"
        case .double(let value): return "\(value)"
        case .bool(let value): return value ? "TRUE" : "FALSE"
        case .uuid: return "gen_random_uuid()"
        }
    }
}

extension DefaultValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// `ON DELETE` / `ON UPDATE` referential actions.
public enum ForeignKeyAction: String, Sendable, Equatable {
    case noAction = "NO ACTION"
    case restrict = "RESTRICT"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case setDefault = "SET DEFAULT"
}

/// Index access methods (`USING ...`).
public enum IndexMethod: String, Sendable, Equatable {
    case btree = "BTREE"
    case hash = "HASH"
    case gist = "GIST"
    case spgist = "SPGIST"
    case gin = "GIN"
    case brin = "BRIN"
}

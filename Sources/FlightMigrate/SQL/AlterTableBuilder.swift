/// Builds `ALTER TABLE` statements inside `schema.alterTable("users") { t in ... }`.
///
/// Each action renders as its own `ALTER TABLE` statement, in declaration order. That
/// keeps the emitted SQL predictable and lets actions Postgres won't combine (like
/// `RENAME COLUMN`) sit next to ones it would; inside a wrapped migration they are all
/// atomic anyway.
///
/// Column constructors (`t.text("bio")`, `t.jsonb("prefs")`, ...) mean `ADD COLUMN` here:
///
/// ```swift
/// schema.alterTable("users") { t in
///     t.text("bio")                                // ADD COLUMN "bio" TEXT
///     t.dropColumn("legacy_flags")
///     t.renameColumn("email", to: "email_address")
///     t.setNotNull("bio")
/// }
/// ```
public final class AlterTableBuilder: ColumnDefining {
    let tableName: String

    private enum Action {
        case addColumn(ColumnBuilder, ifNotExists: Bool)
        case sql(String)  // rendered tail after "ALTER TABLE <name> "
    }

    private var actions: [Action] = []

    init(tableName: String) {
        self.tableName = tableName
    }

    // MARK: Columns

    /// `ADD COLUMN` — the shared typed constructors (`t.text(...)`, etc.) land here.
    @discardableResult
    public func column(_ name: String, _ type: ColumnType) -> ColumnBuilder {
        let builder = ColumnBuilder(name: name, type: type)
        actions.append(.addColumn(builder, ifNotExists: false))
        return builder
    }

    /// Explicit `ADD COLUMN`, with optional `IF NOT EXISTS`.
    @discardableResult
    public func addColumn(_ name: String, _ type: ColumnType, ifNotExists: Bool = false) -> ColumnBuilder {
        let builder = ColumnBuilder(name: name, type: type)
        actions.append(.addColumn(builder, ifNotExists: ifNotExists))
        return builder
    }

    /// `DROP COLUMN`.
    public func dropColumn(_ name: String, ifExists: Bool = false, cascade: Bool = false) {
        var sql = "DROP COLUMN "
        if ifExists { sql += "IF EXISTS " }
        sql += SQL.columnIdentifier(name)
        if cascade { sql += " CASCADE" }
        actions.append(.sql(sql))
    }

    /// `RENAME COLUMN <name> TO <newName>`.
    public func renameColumn(_ name: String, to newName: String) {
        actions.append(
            .sql("RENAME COLUMN \(SQL.columnIdentifier(name)) TO \(SQL.columnIdentifier(newName))"))
    }

    /// `ALTER COLUMN <name> SET DEFAULT <value>`.
    public func setDefault(_ column: String, _ value: DefaultValue) {
        actions.append(.sql("ALTER COLUMN \(SQL.columnIdentifier(column)) SET DEFAULT \(value.sql)"))
    }

    /// `ALTER COLUMN <name> DROP DEFAULT`.
    public func dropDefault(_ column: String) {
        actions.append(.sql("ALTER COLUMN \(SQL.columnIdentifier(column)) DROP DEFAULT"))
    }

    /// `ALTER COLUMN <name> SET NOT NULL`.
    public func setNotNull(_ column: String) {
        actions.append(.sql("ALTER COLUMN \(SQL.columnIdentifier(column)) SET NOT NULL"))
    }

    /// `ALTER COLUMN <name> DROP NOT NULL`.
    public func dropNotNull(_ column: String) {
        actions.append(.sql("ALTER COLUMN \(SQL.columnIdentifier(column)) DROP NOT NULL"))
    }

    /// `ALTER COLUMN <name> TYPE <type> [USING <expression>]`.
    public func setDataType(_ column: String, _ type: ColumnType, using expression: String? = nil) {
        var sql = "ALTER COLUMN \(SQL.columnIdentifier(column)) TYPE \(type.sql)"
        if let expression { sql += " USING \(expression)" }
        actions.append(.sql(sql))
    }

    // MARK: Constraints

    /// `ADD [CONSTRAINT <name>] UNIQUE (...)`.
    public func addUnique(_ columns: [String], name: String? = nil) {
        let list = columns.map(SQL.columnIdentifier).joined(separator: ", ")
        actions.append(.sql("ADD \(constraintPrefix(name))UNIQUE (\(list))"))
    }

    /// `ADD [CONSTRAINT <name>] CHECK (<expression>)`. The expression is raw SQL.
    public func addCheck(_ expression: String, name: String? = nil) {
        actions.append(.sql("ADD \(constraintPrefix(name))CHECK (\(expression))"))
    }

    /// `ADD [CONSTRAINT <name>] PRIMARY KEY (...)`.
    public func addPrimaryKey(_ columns: [String], name: String? = nil) {
        let list = columns.map(SQL.columnIdentifier).joined(separator: ", ")
        actions.append(.sql("ADD \(constraintPrefix(name))PRIMARY KEY (\(list))"))
    }

    /// `ADD [CONSTRAINT <name>] FOREIGN KEY (...) REFERENCES ... `.
    public func addForeignKey(
        _ columns: [String],
        references table: String,
        _ referencedColumns: [String] = ["id"],
        onDelete: ForeignKeyAction? = nil,
        onUpdate: ForeignKeyAction? = nil,
        name: String? = nil
    ) {
        let local = columns.map(SQL.columnIdentifier).joined(separator: ", ")
        let foreign = referencedColumns.map(SQL.columnIdentifier).joined(separator: ", ")
        var sql = "ADD \(constraintPrefix(name))"
            + "FOREIGN KEY (\(local)) REFERENCES \(SQL.identifier(table)) (\(foreign))"
        if let onDelete { sql += " ON DELETE \(onDelete.rawValue)" }
        if let onUpdate { sql += " ON UPDATE \(onUpdate.rawValue)" }
        actions.append(.sql(sql))
    }

    /// `DROP CONSTRAINT`.
    public func dropConstraint(_ name: String, ifExists: Bool = false) {
        var sql = "DROP CONSTRAINT "
        if ifExists { sql += "IF EXISTS " }
        sql += SQL.columnIdentifier(name)
        actions.append(.sql(sql))
    }

    private func constraintPrefix(_ name: String?) -> String {
        name.map { "CONSTRAINT \(SQL.columnIdentifier($0)) " } ?? ""
    }

    func render() -> [String] {
        let head = "ALTER TABLE \(SQL.identifier(tableName)) "
        return actions.map { action in
            switch action {
            case .addColumn(let builder, let ifNotExists):
                let keyword = ifNotExists ? "ADD COLUMN IF NOT EXISTS " : "ADD COLUMN "
                return head + keyword + builder.render()
            case .sql(let tail):
                return head + tail
            }
        }
    }
}

/// Builds a `CREATE TABLE` statement inside `schema.createTable("users") { t in ... }`.
public final class TableBuilder: ColumnDefining {
    let tableName: String
    private var columns: [ColumnBuilder] = []
    private var constraints: [String] = []

    init(tableName: String) {
        self.tableName = tableName
    }

    @discardableResult
    public func column(_ name: String, _ type: ColumnType) -> ColumnBuilder {
        let builder = ColumnBuilder(name: name, type: type)
        columns.append(builder)
        return builder
    }

    /// Adds `created_at` and `updated_at` (`TIMESTAMPTZ NOT NULL DEFAULT now()`).
    public func timestamps() {
        timestamptz("created_at").notNull().default(.now)
        timestamptz("updated_at").notNull().default(.now)
    }

    /// A composite primary key: `PRIMARY KEY ("a", "b")`. For a single-column key prefer
    /// the column modifier `.primaryKey()`.
    public func primaryKey(_ columns: [String]) {
        let list = columns.map(SQL.columnIdentifier).joined(separator: ", ")
        constraints.append("PRIMARY KEY (\(list))")
    }

    /// A table-level unique constraint. Postgres auto-names it unless `name` is given.
    public func unique(_ columns: [String], name: String? = nil) {
        let list = columns.map(SQL.columnIdentifier).joined(separator: ", ")
        constraints.append(prefixed(name) + "UNIQUE (\(list))")
    }

    /// A table-level `CHECK` constraint. The expression is raw SQL.
    public func check(_ expression: String, name: String? = nil) {
        constraints.append(prefixed(name) + "CHECK (\(expression))")
    }

    /// A table-level foreign key, for composite keys or when you want an explicit name.
    public func foreignKey(
        _ columns: [String],
        references table: String,
        _ referencedColumns: [String] = ["id"],
        onDelete: ForeignKeyAction? = nil,
        onUpdate: ForeignKeyAction? = nil,
        name: String? = nil
    ) {
        let local = columns.map(SQL.columnIdentifier).joined(separator: ", ")
        let foreign = referencedColumns.map(SQL.columnIdentifier).joined(separator: ", ")
        var sql = prefixed(name)
            + "FOREIGN KEY (\(local)) REFERENCES \(SQL.identifier(table)) (\(foreign))"
        if let onDelete { sql += " ON DELETE \(onDelete.rawValue)" }
        if let onUpdate { sql += " ON UPDATE \(onUpdate.rawValue)" }
        constraints.append(sql)
    }

    private func prefixed(_ name: String?) -> String {
        name.map { "CONSTRAINT \(SQL.columnIdentifier($0)) " } ?? ""
    }

    func render(ifNotExists: Bool) -> String {
        let head = ifNotExists ? "CREATE TABLE IF NOT EXISTS" : "CREATE TABLE"
        let body = (columns.map { $0.render() } + constraints)
            .map { "    \($0)" }
            .joined(separator: ",\n")
        return "\(head) \(SQL.identifier(tableName)) (\n\(body)\n)"
    }
}

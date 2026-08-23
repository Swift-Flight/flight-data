/// The migration DSL: a migration's `up`/`down` describe schema
/// changes by recording SQL statements on this builder; `FlightMigrator` executes them.
///
/// The DSL covers common DDL. Anything it doesn't express — `ALTER TYPE ADD VALUE`,
/// exclusion constraints, data backfills, any Postgres exotica — is ``raw(_:)``, which is
/// a first-class part of the API, not a leak. Table and column names are plain strings,
/// deliberately decoupled from any query-layer entity types, so old migrations stay
/// frozen in time.
public final class SchemaBuilder {
    /// The recorded statements, in order. Each is executed as a single SQL statement.
    public private(set) var statements: [String] = []

    public init() {}

    // MARK: Raw SQL — the escape hatch

    /// Records one raw SQL statement, verbatim.
    ///
    /// Exactly **one** statement per call: statements run over the Postgres extended
    /// query protocol, which rejects multiple commands in one query. Call `raw` once per
    /// statement instead of separating them with `;`. (A single trailing semicolon is
    /// tolerated and stripped; empty statements are ignored.)
    public func raw(_ sql: String) {
        var statement = sql.trimmed()
        while statement.hasSuffix(";") {
            statement.removeLast()
            statement = statement.trimmed()
        }
        guard !statement.isEmpty else { return }
        statements.append(statement)
    }

    // MARK: Tables

    /// `CREATE TABLE`, with columns and constraints defined in the closure.
    public func createTable(
        _ name: String, ifNotExists: Bool = false, _ build: (TableBuilder) -> Void
    ) {
        let builder = TableBuilder(tableName: name)
        build(builder)
        statements.append(builder.render(ifNotExists: ifNotExists))
    }

    /// `DROP TABLE`.
    public func dropTable(_ name: String, ifExists: Bool = false, cascade: Bool = false) {
        var sql = "DROP TABLE "
        if ifExists { sql += "IF EXISTS " }
        sql += SQL.identifier(name)
        if cascade { sql += " CASCADE" }
        statements.append(sql)
    }

    /// `ALTER TABLE ... RENAME TO ...`.
    public func renameTable(_ name: String, to newName: String) {
        statements.append("ALTER TABLE \(SQL.identifier(name)) RENAME TO \(SQL.identifier(newName))")
    }

    /// `ALTER TABLE`, with actions defined in the closure. Each action becomes its own
    /// statement — see ``AlterTableBuilder``.
    public func alterTable(_ name: String, _ build: (AlterTableBuilder) -> Void) {
        let builder = AlterTableBuilder(tableName: name)
        build(builder)
        statements.append(contentsOf: builder.render())
    }

    // MARK: Indexes

    /// `CREATE INDEX`.
    ///
    /// - Parameters:
    ///   - table: The table to index. May be schema-qualified.
    ///   - columns: Column names (quoted). For expression indexes use ``raw(_:)``.
    ///   - name: Index name; defaults to `<table>_<columns>_idx`.
    ///   - unique: Builds a `UNIQUE` index, rejecting duplicate values.
    ///   - concurrently: `CREATE INDEX CONCURRENTLY` — the production-safe build that
    ///     doesn't take a write lock. **Cannot run inside a transaction**: the migration
    ///     must set `static let wrapInTransaction = false`.
    ///   - ifNotExists: Defaults to whatever `concurrently` is. A concurrent build that
    ///     fails leaves an `INVALID` index behind under the same name, and because the
    ///     migration was not wrapped in a transaction there is nothing to roll it back.
    ///     Retrying then fails on `relation already exists` instead of making progress,
    ///     so `IF NOT EXISTS` is the only default that lets a retry work. Pass `false`
    ///     explicitly if you would rather the retry fail loudly.
    ///   - method: The index method — `btree`, `gin`, `gist` and so on. Postgres
    ///     picks `btree` when this is omitted.
    ///   - predicate: A `WHERE` clause, for a partial index covering only the rows
    ///     that match. Emitted verbatim.
    public func createIndex(
        on table: String,
        columns: [String],
        name: String? = nil,
        unique: Bool = false,
        concurrently: Bool = false,
        ifNotExists: Bool? = nil,
        using method: IndexMethod? = nil,
        where predicate: String? = nil
    ) {
        let indexName = name ?? defaultIndexName(table: table, columns: columns)
        var sql = "CREATE "
        if unique { sql += "UNIQUE " }
        sql += "INDEX "
        if concurrently { sql += "CONCURRENTLY " }
        if ifNotExists ?? concurrently { sql += "IF NOT EXISTS " }
        sql += SQL.columnIdentifier(indexName)
        sql += " ON \(SQL.identifier(table))"
        if let method { sql += " USING \(method.rawValue)" }
        sql += " (\(columns.map(SQL.columnIdentifier).joined(separator: ", ")))"
        if let predicate { sql += " WHERE \(predicate)" }
        statements.append(sql)
    }

    /// `DROP INDEX`.
    public func dropIndex(
        _ name: String, concurrently: Bool = false, ifExists: Bool = false, cascade: Bool = false
    ) {
        var sql = "DROP INDEX "
        if concurrently { sql += "CONCURRENTLY " }
        if ifExists { sql += "IF EXISTS " }
        sql += SQL.identifier(name)
        if cascade { sql += " CASCADE" }
        statements.append(sql)
    }

    // MARK: Extensions

    /// `CREATE EXTENSION` (e.g. `pgcrypto`, `citext`).
    public func createExtension(_ name: String, ifNotExists: Bool = true) {
        var sql = "CREATE EXTENSION "
        if ifNotExists { sql += "IF NOT EXISTS " }
        sql += SQL.columnIdentifier(name)
        statements.append(sql)
    }

    /// `DROP EXTENSION`.
    public func dropExtension(_ name: String, ifExists: Bool = false) {
        var sql = "DROP EXTENSION "
        if ifExists { sql += "IF EXISTS " }
        sql += SQL.columnIdentifier(name)
        statements.append(sql)
    }

    private func defaultIndexName(table: String, columns: [String]) -> String {
        // Strip any schema qualification from the table for the index name.
        let bareTable = table.split(separator: ".").last.map(String.init) ?? table
        return ([bareTable] + columns + ["idx"]).joined(separator: "_")
    }
}

extension String {
    fileprivate func trimmed() -> String {
        var s = Substring(self)
        while let first = s.first, first.isWhitespace { s.removeFirst() }
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}

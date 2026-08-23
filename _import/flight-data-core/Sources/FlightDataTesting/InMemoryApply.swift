import FlightDataCore

extension InMemoryConnection {
    /// The driver obligation, in miniature: one `apply(_:)` translating
    /// the neutral `ValidatedChanges` into this "store's" native write — a
    /// journal line. Real drivers are the same handful of lines against SQL
    /// or BSON; none of them touch validation or dirty-tracking, and an
    /// invalid changeset can't reach them (`validatedChanges()` throws).
    ///
    /// Journal shapes, deterministic (fields sorted) for test assertions:
    ///
    ///     INSERT users SET display_name = Ada, email = ada@example.com
    ///     UPDATE users SET email = ada@lovelace.dev WHERE id = 1
    ///
    /// Empty `changedFields` journals nothing — dirty tracking already
    /// proved there is no write to make.
    public func apply<M: TableModel>(_ changes: ValidatedChanges, to model: M.Type) {
        guard !changes.changedFields.isEmpty else { return }
        let assignments = renderFields(changes.changedFields, separator: ", ")
        if let identity = changes.identity {
            let predicate = renderFields(identity, separator: " AND ")
            perform("UPDATE \(M.tableName) SET \(assignments) WHERE \(predicate)")
        } else {
            perform("INSERT \(M.tableName) SET \(assignments)")
        }
    }

    private func renderFields(_ fields: [String: any Sendable], separator: String) -> String {
        fields.keys.sorted()
            .map { "\($0) = \(renderValue(fields[$0]!))" }
            .joined(separator: separator)
    }

    /// Flattens boxed optionals so a "set to nil" journals as NULL rather
    /// than `Optional(…)` noise.
    private func renderValue(_ value: any Sendable) -> String {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return String(describing: value)
        }
        guard let wrapped = mirror.children.first?.value else {
            return "NULL"
        }
        return String(describing: wrapped)
    }
}

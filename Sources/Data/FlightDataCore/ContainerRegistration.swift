import FlightCore

extension Container {
    /// Registers one named datasource — called by each store's
    /// `FlightModule` from `configure(_:)`. Three components, all qualified by
    /// `name`:
    ///
    /// 1. **The pool** — `D` as `.singleton`. `factory` runs at `freeze()`
    ///    (Flight Core's eager singleton construction), which is where
    ///    it reads `Configuration` — module `configure` bodies run during the
    ///    registration phase, where resolution is not yet legal.
    /// 2. **The scope-bound connection** — `ScopedConnection<D>` as
    ///    `.scoped`. First resolution within a `Scope` checks a connection
    ///    out of the pool; every further resolution in that scope yields the
    ///    same one; scope close returns it. A repository factory reaches
    ///    it with `resolveInActiveScope` (Flight Core delta 11):
    ///
    ///    ```swift
    ///    container.register(UserRepository.self, scope: .scoped, stereotype: .repository) { c in
    ///        UserRepository(lease: try c.resolveInActiveScope(
    ///            ScopedConnection<PostgresDataSource>.self, qualifier: "primary"))
    ///    }
    ///    ```
    ///
    /// 3. **The liveness probe** — `DataSourceLiveness` as `.singleton`,
    ///    wrapping the pool's `ping()` for Actuator.
    ///
    /// Names are always explicit qualifiers, including `"primary"` — one
    /// convention whether an app has one datasource or five; resolution
    /// disambiguates the same way any multi-binding does (Flight Core).
    public func register<D: DataSource>(
        dataSource type: D.Type,
        name: String = PrimaryDataSource.name,
        factory: @escaping @Sendable (Container) throws -> D
    ) {
        register(type, qualifier: name, scope: .singleton, factory: factory)

        register(ScopedConnection<D>.self, qualifier: name, scope: .scoped) { container in
            let source = try container.resolve(D.self, qualifier: name)
            // A caller that could await may have already taken a connection
            // out of the pool for this scope — waiting for one rather than
            // failing when the pool was full. This factory is synchronous and
            // cannot wait, so it takes that connection when one is on offer
            // and falls back to the non-waiting checkout otherwise.
            if let waited: D.Connection = PendingConnections.take(datasource: name) {
                return ScopedConnection(datasourceName: name, connection: waited, source: source)
            }
            return ScopedConnection(
                datasourceName: name,
                connection: try source.checkout(),
                source: source
            )
        }

        register(DataSourceLiveness.self, qualifier: name, scope: .singleton) { container in
            let source = try container.resolve(D.self, qualifier: name)
            return DataSourceLiveness(datasourceName: name) {
                try await source.ping()
            }
        }
    }

    /// Instance form, for callers that already hold a constructed pool —
    /// tests wiring an `InMemoryDataSource` by hand, or a module whose
    /// settings don't come from `Configuration`. Registers exactly the same
    /// three components.
    public func register<D: DataSource>(
        dataSource: D,
        name: String = PrimaryDataSource.name
    ) {
        register(dataSource: D.self, name: name) { _ in dataSource }
    }
}

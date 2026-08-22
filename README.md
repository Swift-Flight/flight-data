# Flight Data Postgres

Type-safe queries, a DI-registered repository layer, request-scoped
connections, and transactions — for Postgres. Implements
[`../flight-data-postgres-design.md`](../flight-data-postgres-design.md) on
top of Flight Core, Flight Data Core, and Flight Migrate.

This package is *composition plus stereotypes*, not a from-scratch data stack
(design §1): the driver and wire protocol are **PostgresNIO**, type-safe query
building is **StructuredQueries** (`@Table`), migrations are **Flight
Migrate**. What Flight builds is the seam between them:

| Product | Contents |
|---|---|
| `StructuredQueriesPostgres` | The §4 binding, usable **without Flight**: `QueryFragment → PostgresQuery` translation (`$1, $2, …`, all bindings parameterized), `PostgresQueryDecoder` over `PostgresRow`, and `execute(_:)` overloads on both `PostgresConnection` and `PostgresClient` |
| `FlightDataPostgres` | `PostgresDataSource` (the pool, behind Flight Data Core's `DataSource` seam), `PostgresDataModule<Name>` (§5), `PostgresTransactionCoordinator` + `withPostgresScope`/`withPostgresTransactions` (§6), changeset `apply(_:to:)` + the `PostgresTableModel` bridge, `PostgresMigrations` wiring (§7). Re-exports everything a repository file needs. |

## Build status

**Builds and passes all tests** — verified 2026-07-16 against Swift 6.2.3 on
Linux (x86_64): 55 tests green, including integration suites against a real
Postgres 16 (scoping, pool lifecycle and broken-connection replacement,
transactions with savepoint nesting, changeset apply, migrate wiring, and
every §4.3 dialect probe). The §4 spike **succeeded** — compile-time-checked
queries run against Postgres with three small decode/bind adaptations and no
fallback to SQLKit; see [SPIKE-FINDINGS.md](SPIKE-FINDINGS.md).

## Using it

Entities are StructuredQueries `@Table` types (§3.2) — a typo'd column, a
type-mismatched comparison, or a reference to a computed property is a
**compile error**:

```swift
@Table("users")
struct User: Equatable {
    var id: UUID
    var email: String
    var lastName: String
    var age: Int
    var createdAt: Date
}
```

Repositories are `@Repository` types holding the scope's connection (§3.3):

```swift
@Repository(scope: .scoped)
struct UserRepository {
    // flight:hand-registered — the registration generator can't see module
    // registrations; the marker acknowledges that and silences its warning.
    @Autowired var connection: PostgresConnection   // the scope's — NOT a singleton

    func find(byEmail email: String) async throws -> User? {
        try await connection.execute(User.where { $0.email.eq(email) }).first
    }

    func recentlyActive(since: Date, limit: Int) async throws -> [User] {
        try await connection.execute(
            User.where { $0.createdAt > since }
                .order { $0.createdAt.desc() }
                .limit(limit)
        )
    }
}
```

(Current StructuredQueries spells equality `.eq(_:)` — `==`/`!=` between
expressions were retired upstream; ordered comparisons are unchanged. The
`#sql` escape hatch is available at any granularity, parameters still bound.)

The module is one generic instantiation per named datasource (§5), reading
`datasource.<name>.url` / `pool_size` from Flight Config at freeze — a bad
URL fails bootstrap, never the first query:

```yaml
datasource:
  primary:
    url: "postgres://app:secret@localhost:5432/app?sslmode=prefer"
    pool_size: 10
```

```swift
try await bootstrap(configuration: .load(), modules: [
    PostgresDataModule<PrimaryDataSource>.self,
    AppModule.self,
])
```

Bootstrap ordering falls out for free (§5): the pool's `run()` dials every
connection under the `ServiceGroup` before any request is served, replaces
broken connections while running, and drains on graceful shutdown.

### Transactions (§6)

`@Transactional` expands at compile time to `BEGIN`/`COMMIT`/`ROLLBACK` — and
`SAVEPOINT`/`ROLLBACK TO SAVEPOINT` when nested — against **the scope's
connection**. The coordinator and scope are task-locals; bind them around a
unit of work:

```swift
@Repository(scope: .scoped)
struct LedgerRepository {
    @Autowired var connection: PostgresConnection

    @Transactional
    func transfer(_ amount: Int, from: String, to: String) async throws { … }
}

try await container.withPostgresScope { scope in
    let ledger = try container.resolve(LedgerRepository.self, in: scope)
    try await ledger.transfer(40, from: "checking", to: "savings")
}
```

A handler that already has a request scope binds it instead:
`try await container.withPostgresTransactions(in: context.scope) { … }`.
Calling a `@Transactional` method with no active scope throws
`ResolutionError.noActiveScope` (§6's deliberate runtime residue); calling it
without the coordinator bound runs it under Core's documented no-op default —
both behaviors are pinned by tests.

### Changesets

The one type serves queries and changesets via the `PostgresTableModel`
bridge (metadata spelled once, under a name `@Table`'s expansion doesn't
occupy — see delta P4):

```swift
extension User: PostgresTableModel {
    static let changesetColumns: [FlightDataCore.TableColumn<User>] = [
        FlightDataCore.TableColumn("id", \User.id, primaryKey: true),
        FlightDataCore.TableColumn("email", \User.email),
    ]
}

let changes = try Changeset(original: user)
    .change(\.email, input.email)
    .validate(\.email, .email)
    .validatedChanges()
try await connection.apply(changes, to: User.self)
// UPDATE only the dirty columns WHERE the primary key — or INSERT when identity is nil
```

### Migrations (§7)

Not implemented here — Flight Migrate's. This package only wires the
migrator to the config-resolved datasource URL:

```swift
try await PostgresMigrations.migrate(
    configuration: try container.resolve(Configuration.self),
    migrations: _allMigrations()      // the FlightMigratePlugin registry
)
```

Run from a migrate binary or CI step, **never at boot** (§7).

## Testing this package (§8)

Unit tests run bare. Integration tests need a real Postgres and are gated on
one environment variable:

```
$ docker run -d --name flight-data-pg -e POSTGRES_PASSWORD=flight \
    -e POSTGRES_DB=flight_data_test -p 127.0.0.1:55432:5432 postgres:16-alpine
$ export FLIGHT_POSTGRES_TEST_DATABASE_URL="postgres://postgres:flight@127.0.0.1:55432/flight_data_test?sslmode=disable"
$ swift test
```

The suite prepares its schema through `PostgresMigrations.migrate` — the same
path production uses — so the migrations are exercised on every run.

## Design deltas vs. the design doc (all deliberate, none silent)

| # | Delta | Why |
|---|---|---|
| P1 | This package owns a small fixed-size pool (`PostgresDataSource`) instead of leasing from `PostgresClient` | §5's sketch calls `PostgresClient.leaseConnection()` — which is **private**; the modern client only lends connections inside async closures. The `DataSource` seam requires *synchronous* checkout (Flight Data Core D1: scoped component factories and `FlightTransactionCoordinator.begin` are synchronous). The pool is deliberately thin — eager dial at service start, Mutex free list, prompt checkout-or-throw, replacement loop — and everything protocol-level stays PostgresNIO's. `PostgresClient` is still used where its shape fits: the migrate wiring, and the Flight-free binding product. |
| P2 | Transaction control statements bridge sync→async by blocking on PostgresNIO's `EventLoopFuture` API | Flight Core §5.2 makes the sync coordinator synchronous; Postgres I/O is not. Blocking on a future that completes on the connection's NIO event loop is deadlock-free (the event loop never depends on the blocked thread) — unlike bridging through a `Task`, which can exhaust the cooperative pool. Cost: one short round-trip per BEGIN/COMMIT/ROLLBACK. Calling from an event-loop thread is rejected loudly. **The recorded fix landed as Core delta 14 (2026-07-17)**: `PostgresTransactionCoordinator` also conforms to `FlightAsyncTransactionCoordinator`, and `withPostgresScope`/`withPostgresTransactions` bind it as both task-locals — async `@Transactional` methods (the common case) now *await* control statements natively, and the blocking bridge serves only sync `@Transactional` methods. |
| P3 | `resolve(PostgresConnection.self)` overloads route through the ambient scope | `@Autowired` expands to plain `container.resolve(…)`, which could not resolve scoped components (scoped resolution needs a scope). Concrete overloads in this package out-rank the generic in any module importing it, and consult `Scope.active` (Core delta 11) — making §3.3's `@Autowired var connection: PostgresConnection` work as written while preserving the captive-dependency guarantee (no ambient scope → loud error). **The proposed general fix landed as Core delta 12 (2026-07-17)**: plain `resolve` now falls back to the ambient scope for every scoped component, so `@Autowired` between app-defined scoped components (a scoped `@Service` over a scoped `@Repository`) works without hand registration. This package's overloads remain — they do type *mapping* (`PostgresConnection` is not itself a registered component; the overload unwraps the scope's `ScopedConnection`), not just scope bridging. |
| P4 | `PostgresTableModel` carries changeset metadata as `changesetColumns` | Flight Data Core C1 renamed the *type* collision away (`TableModel` vs `Table`), but the *member* collision remains: `@Table` generates `tableName` and `columns`, and Swift rejects a second same-name static of different type — so `TableModel.columns` cannot be declared on an `@Table` type directly. The bridge protocol forwards `changesetColumns` to `columns`; `tableName` is witnessed by `@Table`'s own property, so the name is spelled once. |
| P5 | The pool rolls back connections released with an open transaction | The `@Transactional` expansion pairs begin with commit/rollback on every code path, but a lease stashed past its scope or a torn task could return a connection mid-transaction. Reusing it would leak transaction state across scopes — so release detects it (via coordinator bookkeeping), issues `ROLLBACK` off the release path, and only then repools. Pinned by `leakedTransactionIsRolledBackOnRelease`. |
| P6 | The `primary` datasource also answers *unqualified* resolution | Flight Data Core's convention is "names are always explicit qualifiers, including `primary`". For the pool/lease/liveness triple this package follows it. But `@Autowired var connection: PostgresConnection` has nowhere to hang a qualifier in the common one-database app, so the primary module additionally registers unqualified aliases for the connection and coordinator. Named datasources must be asked for by name. |

Toolchain/upstream deltas (the `.eq()` spelling, the parameter-pack
miscompile workaround, the S1–S4 dialect adaptations) are recorded in
[SPIKE-FINDINGS.md](SPIKE-FINDINGS.md).

## Non-goals (§9)

No ORM semantics, no cross-database abstraction, no auto-migration at boot,
no query caching, no Timescale support — all deliberately absent, per the
design doc.

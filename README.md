# Flight Data Postgres

Request-scoped connections, transactions, and a DI-registered repository
layer — for Postgres, on top of Flight Core, Flight Data Core, and Hangar.

This package is *composition plus stereotypes*, not a from-scratch data
stack: the driver and wire protocol are **PostgresNIO**, the query layer is
**Hangar** (`@Entity`), migrations are **Flight Migrate**. What Flight builds
is the seam between them.

| Product | Contents |
|---|---|
| `FlightDataPostgres` | `PostgresDataSource` (the pool, behind Flight Data Core's `DataSource` seam), `PostgresDataModule<Name>`, `PostgresTransactionCoordinator` + `withPostgresScope`/`withPostgresTransactions`, and the Hangar integration that binds a `Repo` to the scope's connection. Re-exports `FlightCore`, `FlightDataCore`, and `Hangar`, so a repository file needs one import. |

## Build status

**Builds and passes all tests** — verified 2026-07-16 against Swift 6.2.3 on
Linux (x86_64): 55 tests green, including integration suites against a real
Postgres 16 (scoping, pool lifecycle and broken-connection replacement,
transactions with savepoint nesting, changeset apply, migrate wiring, and
every dialect probe). The spike **succeeded** — compile-time-checked
queries run against Postgres with three small decode/bind adaptations and no
fallback to SQLKit; see [SPIKE-FINDINGS.md](SPIKE-FINDINGS.md).

## Using it

Entities are Hangar `@Entity` types — a typo'd column, a type-mismatched
comparison, or a reference to a non-stored property is a **compile error**:

```swift
@Entity("users")
struct User: Encodable, Equatable, Sendable {
    @ID var id: UUID
    var email: String
    @Column("lastName") var lastName: String
    var age: Int
    @Column("createdAt") var createdAt: Date
}
```

Repositories are `@Repository` types holding the scope's `Repo` — Hangar's
query interface, bound to this scope's connection, so everything a
`@Transactional` method does shares one transaction:

```swift
@Repository(scope: .scoped)
struct UserRepository {
    // flight:hand-registered — the registration generator cannot see module
    // registrations; the marker acknowledges that and silences its warning.
    @Autowired var repo: Repo   // the scope's — NOT a singleton

    func find(byEmail email: String) async throws -> User? {
        try await repo.one(User.where { $0.email == email })
    }

    func recentlyActive(since: Date, limit: Int) async throws -> [User] {
        try await repo.all(
            User.where { $0.createdAt > since }
                .order { $0.createdAt.desc() }
                .limit(limit))
    }
}
```

The raw connection is available the same way (`@Autowired var connection:
PostgresConnection`) for anything Hangar does not express — `LISTEN`,
`COPY`, server-side cursors.

The module is one generic instantiation per named datasource, reading
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

Bootstrap ordering falls out for free: the pool's `run()` dials every
connection under the `ServiceGroup` before any request is served, replaces
broken connections while running, and drains on graceful shutdown.

### Transactions

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
`ResolutionError.noActiveScope` (deliberate runtime residue); calling it
without the coordinator bound runs it under Core's documented no-op default —
both behaviors are pinned by tests.

### Changesets

Nothing to wire here. Hangar's `@Entity` generates the `Changesets`
`TableModel` conformance itself, and `Repo` consumes changesets directly:

```swift
let changeset = Changeset(original: user)
    .change(\.email, input.email)
    .validate(\.email, .email)
try await repo.update(changeset)
// UPDATE only the dirty columns, addressed by the primary key —
// or INSERT when the changeset has no identity
```

Validation still throws before anything reaches the wire.

### Migrations

Not implemented here — Flight Migrate's. This package only wires the
migrator to the config-resolved datasource URL:

```swift
try await PostgresMigrations.migrate(
    configuration: try container.resolve(Configuration.self),
    migrations: _allMigrations()      // the FlightMigratePlugin registry
)
```

Run from a migrate binary or CI step, **never at boot**.

## Testing this package

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

## Design decisions worth knowing (all deliberate, none silent)

| # | Delta | Why |
|---|---|---|
| P1 | This package owns a small fixed-size pool (`PostgresDataSource`) instead of leasing from `PostgresClient` | sketch calls `PostgresClient.leaseConnection()` — which is **private**; the modern client only lends connections inside async closures. The `DataSource` seam requires *synchronous* checkout (Flight Data Core D1: scoped component factories and `FlightTransactionCoordinator.begin` are synchronous). The pool is deliberately thin — eager dial at service start, Mutex free list, prompt checkout-or-throw, replacement loop — and everything protocol-level stays PostgresNIO's. `PostgresClient` is still used where its shape fits: the migrate wiring, and the Flight-free binding product. |
| P2 | Transaction control statements bridge sync→async by blocking on PostgresNIO's `EventLoopFuture` API | Flight Core makes the sync coordinator synchronous; Postgres I/O is not. Blocking on a future that completes on the connection's NIO event loop is deadlock-free (the event loop never depends on the blocked thread) — unlike bridging through a `Task`, which can exhaust the cooperative pool. Cost: one short round-trip per BEGIN/COMMIT/ROLLBACK. Calling from an event-loop thread is rejected loudly. **The recorded fix landed as Core delta 14 (2026-07-17)**: `PostgresTransactionCoordinator` also conforms to `FlightAsyncTransactionCoordinator`, and `withPostgresScope`/`withPostgresTransactions` bind it as both task-locals — async `@Transactional` methods (the common case) now *await* control statements natively, and the blocking bridge serves only sync `@Transactional` methods. |
| P3 | `resolve(PostgresConnection.self)` overloads route through the ambient scope | `@Autowired` expands to plain `container.resolve(…)`, which could not resolve scoped components (scoped resolution needs a scope). Concrete overloads in this package out-rank the generic in any module importing it, and consult `Scope.active` (Core delta 11) — making `@Autowired var connection: PostgresConnection` work as written while preserving the captive-dependency guarantee (no ambient scope → loud error). **The proposed general fix landed as Core delta 12 (2026-07-17)**: plain `resolve` now falls back to the ambient scope for every scoped component, so `@Autowired` between app-defined scoped components (a scoped `@Service` over a scoped `@Repository`) works without hand registration. This package's overloads remain — they do type *mapping* (`PostgresConnection` is not itself a registered component; the overload unwraps the scope's `ScopedConnection`), not just scope bridging. |
| P5 | The pool rolls back connections released with an open transaction | The `@Transactional` expansion pairs begin with commit/rollback on every code path, but a lease stashed past its scope or a torn task could return a connection mid-transaction. Reusing it would leak transaction state across scopes — so release detects it (via coordinator bookkeeping), issues `ROLLBACK` off the release path, and only then repools. Pinned by `leakedTransactionIsRolledBackOnRelease`. |
| P6 | The `primary` datasource also answers *unqualified* resolution | Flight Data Core's convention is "names are always explicit qualifiers, including `primary`". For the pool/lease/liveness triple this package follows it. But `@Autowired var connection: PostgresConnection` has nowhere to hang a qualifier in the common one-database app, so the primary module additionally registers unqualified aliases for the connection and coordinator. Named datasources must be asked for by name. |

Toolchain/upstream deltas (the `.eq()` spelling, the parameter-pack
miscompile workaround, the S1–S4 dialect adaptations) are recorded in
[SPIKE-FINDINGS.md](SPIKE-FINDINGS.md).

## Non-goals

No ORM semantics, no cross-database abstraction, no auto-migration at boot,
no query caching, no Timescale support — all deliberately absent.

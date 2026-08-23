# Flight Data Core

The store-agnostic parts of persistence for Flight: the `DataSource` seam,
scope-bound connection checkout, the config/health/lifecycle conventions
every store package (Flight Data Postgres, and any future Mongo/Redis/
Timescale package) follows — and re-exports `Changeset`, the
validation/dirty-tracking layer, as one neutral result type a driver *may*
consume. Built on Flight Core's `Container`/`FlightModule`/`Scope`.

Note what "may" is doing there. Flight Data Valkey applies changesets
directly; Flight Data Postgres does not use them at all, because Hangar sits
above it and consumes changesets itself. A driver is free to ignore the
changeset layer entirely.

Deliberately tiny. The design doc's anti-goals are load-bearing and this
package honors them by *absence*:

- **No universal query API** (§1) — SQL joins, Mongo pipelines, and Redis
  commands are not reconcilable; a lowest-common-denominator would destroy
  Flight Data Postgres's compile-time-checked queries.
- **No shared transaction abstraction** (§6) — `@Transactional` is defined in
  Flight Data Postgres, on top of the one thing that *is* shared: scope-bound
  connection checkout.
- **No migrations, no ORM concepts, no caching layer** (§8).

## Build status

**Builds and passes all tests** against Swift 6.2.3 on Linux (x86_64):
`swift build` clean under strict Swift 6 concurrency; 54 tests green across
scoping, pool semantics, config conventions, registration, module lifecycle,
changeset dirty-tracking/validation, the driver boundary, and the
``DataSourceConformance`` suite run against the reference driver.

Dependencies are Flight Core, swift-changeset, and swift-service-lifecycle.

## What's here

| Product | Contents |
|---|---|
| `FlightDataCore` | `DataSource` (the entire cross-store contract: `checkout`/`release`, derived `withConnection`, `ping`), `ScopedConnection` (the `.scoped` lease component), `Container.register(dataSource:)`, `DataSourceName`/`PrimaryDataSource`, `DataSourceSettings` + `DataSourceConfigKey` (§4 key conventions), `DataSourceLiveness` (§5 Actuator surface), `DataSourceError` — plus the changeset layer: `Changeset<Model>`, `ValidationRule`/`CrossFieldRule`, `ValidatedChanges`/`ChangesetError`, and the `TableModel`/`TableColumn` metadata seam |
| `FlightDataTesting` | `InMemoryDataSource` (§7: a `DataSource` backed by nothing — real pool semantics, no store), `InMemoryDataModule<Name>` (the reference store module), `TestContainer`, and `InMemoryConnection.apply(_:to:)` (the changeset design's §5 driver translation, in miniature) |

## Using it

A store package's `FlightModule` follows one shape (§5) — `InMemoryDataModule`
is the reference implementation:

```swift
public final class PostgresDataModule<Name: DataSourceName>: FlightModule {
    public init() {}

    public func configure(_ container: Container) throws {
        // The factory runs at freeze(), where Configuration is readable —
        // a bad config fails bootstrap, never the first query (§4).
        container.register(dataSource: PostgresDataSource.self, name: Name.name) { c in
            let settings = try DataSourceSettings.load(name: Name.name,
                                                       from: c.resolve(Configuration.self))
            return try PostgresDataSource(settings: settings)
        }
    }

    public var service: (any Service)? { /* the pool's long-running task (§5) */ }
}
```

`register(dataSource:name:)` registers three components, all qualified by the
datasource's name (§4): the pool (`.singleton`), the scope-bound connection
(`ScopedConnection<D>`, `.scoped`), and the liveness probe
(`DataSourceLiveness`, for Actuator).

Named datasources are module *type* instantiations, exactly like
`FlightWebModule<Transport>`:

```yaml
datasource:
  primary:
    url: "postgres://localhost:5432/app"
    pool_size: 10
  analytics:
    url: "postgres://localhost:5432/warehouse"
    pool_size: 4
```

```swift
enum Analytics: DataSourceName { static let name = "analytics" }

try await bootstrap(configuration: .load(), modules: [
    FlightWebModule<FlightTransport>.self,
    PostgresDataModule<PrimaryDataSource>.self,
    PostgresDataModule<Analytics>.self,
    AppModule.self,
])
```

A repository holds its scope's connection through the lease, reached from its
factory via the ambient scope (Flight Core delta 11):

```swift
container.register(UserRepository.self, scope: .scoped, stereotype: .repository) { c in
    UserRepository(lease: try c.resolveInActiveScope(
        ScopedConnection<PostgresDataSource>.self, qualifier: "primary"))
}
```

The §3 property this buys: "request-scoped connection" is not a feature this
package implements — it is what falls out when Flight Web opens a `Scope` per
request and the connection is registered `.scoped`. A job runner or CLI
command gets the same correct lifetime, and none of the packages know about
each other.

Testing (§7) needs no live database and no `ServiceGroup`:

```swift
let container = try TestContainer.build { InMemoryDataModule<PrimaryDataSource>() }

try await container.withScope { scope in
    let repo = try container.resolve(UserRepository.self, in: scope)
    let a = repo.connection
    let b = try container.resolve(UserRepository.self, in: scope).connection
    #expect(a === b)   // same connection within one scope
}
```

## What a pool size actually means

`checkout()` is synchronous by contract — Flight Core's transaction
coordinator begins transactions synchronously, so a pool that parked the
caller would deadlock it. The consequence is worth stating plainly rather
than discovering under load:

**`pool_size` is a hard concurrency ceiling, not a queue depth.** A checkout
arriving with nothing free fails immediately with
`DataSourceError.poolExhausted`; it does not wait for a connection to come
back. There is no backpressure and no checkout timeout, because there is no
waiting to time out.

Size the pool for peak concurrent *work*, not average throughput, and keep
units of work short — every scope holds its connection for its whole
lifetime, so one slow handler occupies a slot for as long as it runs.

## Testing a driver

``DataSourceConformance`` is the contract as an executable suite. A driver
runs the whole thing in one test:

```swift
@Test func conformsToDataSourceContract() async throws {
    try await DataSourceConformance.verify {
        try await MyDataSource(settings: .test)
    } shutdown: { source in
        await source.shutdown()
    }
}
```

It checks the six properties that were previously re-derived by hand in each
driver's own tests: checkout yields a usable connection, release returns it,
`withConnection` releases on throw, `withConnection` is callable from
actor-isolated code, exhaustion is a typed error rather than a hang, and
checkout after shutdown is refused.

## Changesets

The thin layer (changeset design §2): semantic validation and dirty tracking
only — type casting stays with Swift/`Codable`, field existence stays with
keypaths. Errors accumulate; an invalid changeset structurally cannot reach a
driver (`validatedChanges()` throws).

```swift
let changeset = Changeset(original: user)          // Changeset(User.self) for inserts
    .change(\.email, input.email)                  // compile-checked; dirty only if it differs
    .change(\.displayName, input.displayName)
    .validate(\.email, .email)
    .validate(\.displayName, .length(1...80))
    .validate(.ordered(\.startsAt, before: \.endsAt))

guard changeset.isValid else { return .failure(changeset.errors) }
try await connection.apply(changeset.validatedChanges(), to: User.self)
// UPDATE … SET only the changed columns WHERE the primary key — or INSERT when identity is nil
```

Models provide column metadata through `TableModel` — the store-agnostic
keypath→column-name seam:

```swift
struct User: TableModel {
    var id: Int?
    var email: String?
    var displayName: String

    static let tableName = "users"
    static let columns: [TableColumn<User>] = [
        TableColumn("id", \User.id, primaryKey: true),
        TableColumn("email", \User.email),
        TableColumn("display_name", \User.displayName),
    ]
}
```

Rule catalog: `.matches`, `.email`, `.length`, `.range`, `.oneOf`,
`.custom`, cross-field `.ordered`/`.custom` — all with overridable messages,
all authorable from outside via `ValidationRule`'s public initializer.
Field rules validate *recorded changes* only (unchanged data was validated
when it was written); cross-field rules always run, against the effective
state; nil-ness is exclusively `validateRequired`'s job.

## Design deltas vs. the design doc (all deliberate, none silent)

| # | Delta | Why |
|---|-------|-----|
| D1 | `DataSource` gains `checkout()`/`release(_:)`; `withConnection` becomes a derived default on top | Scope-bound checkout (§3) runs inside Core's *synchronous* component factories; an async-only `withConnection` cannot be bridged from a synchronous factory without blocking a cooperative-pool thread (deadlock on a single-threaded executor). §2's own escape hatch — "extend it deliberately" — invoked once. Stores whose pools can wait for a free connection override `withConnection` with their async path. |
| D2 | The `.scoped` component is `ScopedConnection<D>` (a lease class), not the raw `Connection` | Core's `Scope` has no close hooks — close drops instances ("eligible for cleanup", Core §3). Return-to-pool therefore rides ARC: the lease's `deinit` releases the connection the moment the scope's storage drops it. A raw connection value (possibly a struct — Core has no opinion about the type, §2) has nowhere to hang that behavior. |
| D3 | Flight Core delta 11 (`Scope.active` task-local, `resolveInActiveScope`) | The gap §3 predicted the "second consumer" would find: factories receive only the `Container`, so a scoped repository had no path to the scope's connection. Fixed in Core, where it belongs — it is Scope semantics, not data semantics. Recorded as Core delta 11 with its own test suite. |
| D4 | `register(dataSource:)` has instance *and* factory forms, plus `name:` | Modules cannot read `Configuration` during `configure` (resolution begins at `freeze()`, Core §2.1), so the §5 "construct the DataSource from config" step happens inside a registered factory. The doc's instance form remains for tests and hand-wiring. |
| D5 | `DataSourceLiveness` component per datasource | §5 says stores "should register a liveness check surfaced by Actuator" but names no mechanism. A qualified component wrapping `ping()`, discoverable via `DataSourceLiveness.all(in:)` through Core §6 introspection, is that mechanism — Actuator needs zero store knowledge. |
| D6 | `TestContainer` duplicated from `FlightWebTesting` | A data test must not need the web package. Identical API; qualify by module if a target imports both. Follow-up: hoist into a shared flight-testing package. |
| D7 | `InMemoryDataModule` requires no `url` key | The in-memory store is "backed by nothing" (§7); requiring a URL it would ignore fails the doc's own `TestContainer.build { InMemoryDataModule() }` one-liner. `pool_size` is honored when present (default 4). Real store modules load `DataSourceSettings`, whose `url` is required. |

Changeset deltas (vs. [`../flight-changeset-design.md`](../flight-changeset-design.md)):

| # | Delta | Why |
|---|-------|-----|
| C1 | The model seam is `TableModel`, not `Table` | The Postgres design (its §3.2) commits to StructuredQueries, whose central protocol is already named `Table`; driver code juggling two `Table`s would need module qualification everywhere. Same seam, collision-free name. |
| C2 | `TableModel`/`TableColumn` are defined *here*, hand-conformable | The changeset doc consumes "`@Table` model types' column identifiers" as a given, but no model layer exists yet and this package must stay store-agnostic (no StructuredQueries dependency — that is the Postgres driver's choice). The Postgres package bridges its `@Table` metadata onto this protocol mechanically; a `@TableModel` conformance-generating macro is deliberate future sugar. |
| C3 | `change` requires `V: Equatable` (an always-dirty overload covers the rest) | §6's "only if actually changed" is uncomputable without comparison. Equal-to-original changes are discarded, and a change back to the original *removes* the recorded change — `changes` always means exactly "differs from the original" (Ecto's `put_change` semantics). |
| C4 | Validation semantics spelled out: field rules check *recorded changes* only; `validateRequired` checks the *effective* value; cross-field rules always run | The doc doesn't pin when rules fire. Ecto's answers are adopted: unchanged data was validated when written; requiredness must hold whether or not the field moved; consistency properties span the whole row. Nil changes skip format rules — nil-ness is `validateRequired`'s job. |
| C5 | `CrossFieldRule` reads the changeset (`changeset.value(\.field)`), not a materialized model | Insert changesets have no original to overlay changes onto, so no full `Model` value exists to hand a rule. Effective-value reads work identically for inserts and updates; `.ordered` ships as the canned canonical case. |

## Dependency policy

`FlightDataCore` depends on `FlightCore` alone (which re-exports
`FlightConfig`). `swift-service-lifecycle` appears only in the test target,
for service-owning module fixtures. Nothing else — this package is the seam,
not the plumbing.

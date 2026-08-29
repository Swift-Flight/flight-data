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

Deliberately tiny. The anti-goals below are load-bearing and this
package honors them by *absence*:

- **No universal query API** — SQL joins, Mongo pipelines, and Redis
  commands are not reconcilable; a lowest-common-denominator would destroy
  Flight Data Postgres's compile-time-checked queries.
- **No shared transaction abstraction** — `@Transactional` is defined in
  Flight Data Postgres, on top of the one thing that *is* shared: scope-bound
  connection checkout.
- **No migrations, no ORM concepts, no caching layer**.

## Build status

`swift test` covers this package with no server at all: scoping, pool
semantics, queueing and offered connections, config conventions, registration,
module lifecycle, changeset dirty-tracking and validation, the driver boundary,
and the `DataSourceConformance` suite run against the reference driver. Builds
clean under strict Swift 6 concurrency.

Exact test counts are deliberately not written down here. They were, and they
were wrong within a release — a number that has to be hand-updated is a number
that ends up lying.

Dependencies are Flight Core, swift-changeset, and swift-service-lifecycle.

## What's here

| Product | Contents |
|---|---|
| `FlightDataCore` | `DataSource` (the entire cross-store contract: `checkout`/`release`, `checkout(waitingUpTo:)`, derived `withConnection`, `ping`), `ConnectionWaiters` (the parked-caller machinery every queueing pool shares), `PendingConnections` (an async caller's connection offered to the scope it is about to open), `ScopedConnection` (the `.scoped` lease component), `Container.register(dataSource:)`, `DataSourceName`/`PrimaryDataSource`, `DataSourceSettings` + `DataSourceConfigKey` (key conventions), `DataSourceLiveness` (the Actuator surface), `DataSourceError` — plus the changeset layer: `Changeset<Model>`, `ValidationRule`/`CrossFieldRule`, `ValidatedChanges`/`ChangesetError`, and the `TableModel`/`TableColumn` metadata seam |
| `FlightDataTesting` | `InMemoryDataSource` (a `DataSource` backed by nothing — real pool semantics, no store), `InMemoryDataModule<Name>` (the reference store module), `TestContainer`, and `InMemoryConnection.apply(_:to:)` (the changeset design's driver translation, in miniature) |

## Using it

A store package's `FlightModule` follows one shape — `InMemoryDataModule`
is the reference implementation:

```swift
public final class PostgresDataModule<Name: DataSourceName>: FlightModule {
    public init() {}

    public func configure(_ container: Container) throws {
        // The factory runs at freeze(), where Configuration is readable —
        // a bad config fails bootstrap, never the first query.
        container.register(dataSource: PostgresDataSource.self, name: Name.name) { c in
            let settings = try DataSourceSettings.load(name: Name.name,
                                                       from: c.resolve(Configuration.self))
            return try PostgresDataSource(settings: settings)
        }
    }

    public var service: (any Service)? { /* the pool's long-running task */ }
}
```

`register(dataSource:name:)` registers three components, all qualified by the
datasource's name: the pool (`.singleton`), the scope-bound connection
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

The property this buys: "request-scoped connection" is not a feature this
package implements — it is what falls out when Flight Web opens a `Scope` per
request and the connection is registered `.scoped`. A job runner or CLI
command gets the same correct lifetime, and none of the packages know about
each other.

Testing needs no live database and no `ServiceGroup`:

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

**`pool_size` is a queue depth with a timeout, not a hard ceiling.** A caller
that can await queues for up to `datasource.<name>.checkout_timeout_ms`
(default 5 seconds) and fails with `DataSourceError.poolExhausted` only if
nothing comes back in that time.

This page used to say the opposite — "a hard concurrency ceiling … there is no
waiting to time out" — and that *was* true, and was a bug. `checkout()` is
synchronous by contract, because Flight Core's transaction coordinator begins
transactions synchronously and a pool that parked that caller would deadlock
it. But "the synchronous primitive cannot wait" was read as "the seam does not
queue", and so the (pool_size + 1)th concurrent request returned 500 instead of
waiting a few milliseconds for the one ahead of it. Found by an application
test that created eight issues at once against a pool of four: four succeeded,
four failed immediately.

So there are two checkouts:

| | Waits? | Who calls it |
|---|---|---|
| `checkout()` | No — throws the moment nothing is free | The synchronous `ScopedConnection` factory, and a transaction coordinator's `begin()` |
| `checkout(waitingUpTo:)` | Yes, to the timeout | `withConnection`, and anything else that can await |

`withConnection` is defined on the waiting one, so most callers queue without
doing anything. A store with no native wake path still queues: the protocol
ships a polling default, and both drivers here override it with a real handoff
(`ConnectionWaiters`, which is shared rather than written twice).

The synchronous factory is the one place that still fails fast, and it has an
escape: an async caller that wants a *scope's* connection queued takes one up
front and offers it through `PendingConnections.offering(_:connection:returning:)`,
which is what `withPostgresTransactions(in:acquiring: .waiting(timeout:))` does.

Sizing still matters. Every scope holds its connection for its whole lifetime,
so one slow handler occupies a slot for as long as it runs — queueing turns
that into latency rather than errors, which is better but not free. Watch
`waitingCallers.peak`: a pool that is too small says so there before it says so
as timeouts.

## Testing a driver

``DataSourceConformance`` is the contract as an executable suite. A driver
runs the whole thing in one test:

```swift
@Test func conformsToDataSourceContract() async throws {
    try await DataSourceConformance.verify(
        make: {
            let source = try MyDataSource(settings: .test)
            try await source.start()
            return source
        },
        shutdown: { await $0.shutdown() })
}
```

It checks the properties that were previously re-derived by hand in each
driver's own tests: checkout yields a usable connection, release makes it
available to the next caller *when the pool is genuinely empty* (rather than
after eight sequential checkout/release pairs, which proved nothing for any
pool of eight or more), `withConnection` releases on throw and is callable from
actor-isolated code, concurrent callers are never over-issued, exhaustion is a
typed error rather than a hang, the waiting checkout queues and then gives up at
its deadline, `ping()` answers on a live source including a saturated one, and
checkout after shutdown is refused with the vocabulary the protocol promises.

Run it. It is only worth having if drivers use it, and for a while neither of
the two in this package did — which is precisely the failure it was written to
end.

## Changesets

The thin layer (changeset design): semantic validation and dirty tracking
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

## Design decisions worth knowing (all deliberate, none silent)

| # | Delta | Why |
|---|-------|-----|
| D1 | `DataSource` gains `checkout()`/`release(_:)`; `withConnection` becomes a derived default on top | Scope-bound checkout runs inside Core's *synchronous* component factories; an async-only `withConnection` cannot be bridged from a synchronous factory without blocking a cooperative-pool thread (deadlock on a single-threaded executor). This is the contract's own escape hatch — "extend it deliberately" — invoked once. |
| D2 | The `.scoped` component is `ScopedConnection<D>` (a lease class), not the raw `Connection` | Core's `Scope` has no close hooks — close drops instances ("eligible for cleanup", Core). Return-to-pool therefore rides ARC: the lease's `deinit` releases the connection the moment the scope's storage drops it. A raw connection value (possibly a struct — Core has no opinion about the type) has nowhere to hang that behavior. |
| D3 | Flight Core delta 11 (`Scope.active` task-local, `resolveInActiveScope`) | The gap predicted the "second consumer" would find: factories receive only the `Container`, so a scoped repository had no path to the scope's connection. Fixed in Core, where it belongs — it is Scope semantics, not data semantics. Recorded as Core delta 11 with its own test suite. |
| D4 | `register(dataSource:)` has instance *and* factory forms, plus `name:` | Modules cannot read `Configuration` during `configure` (resolution begins at `freeze()`, Core), so the "construct the DataSource from config" step happens inside a registered factory. The instance form remains for tests and hand-wiring. |
| D5 | `DataSourceLiveness` component per datasource | The requirement was that stores "register a liveness check surfaced by Actuator", with no mechanism named. A qualified component wrapping `ping()`, discoverable via `DataSourceLiveness.all(in:)` through Core introspection, is that mechanism — Actuator needs zero store knowledge. |
| D6 | `TestContainer` duplicated from `FlightWebTesting` | A data test must not need the web package. Identical API; qualify by module if a target imports both. Follow-up: hoist into a shared flight-testing package. |
| D7 | `InMemoryDataModule` requires no `url` key | The in-memory store is "backed by nothing"; requiring a URL it would ignore breaks the `TestContainer.build { InMemoryDataModule() }` one-liner. `pool_size` is honored when present (default 4). Real store modules load `DataSourceSettings`, whose `url` is required. |
| D8 | `checkout(waitingUpTo:)` joins the contract; `withConnection` is defined on it, and `ConnectionWaiters` is shared | D1's synchronous checkout describes a *primitive*, and it got read as a policy: `pool_size` became a hard concurrency ceiling and a burst past it failed rather than queueing for a few milliseconds. A caller that can await should queue, so the async checkout is a protocol requirement with a polling default — every store queues — that a pool with a native wake path overrides. The parked-caller state machine lives in core rather than in each driver: the two pools here had already drifted apart on four separate fixes (outage backoff, ping under saturation, session reset, queueing itself), and a second copy of this would have been the fifth. |

Changeset decisions:

| # | Delta | Why |
|---|-------|-----|
| C1 | The model seam is `TableModel`, not `Table` | The Postgres design (its) commits to StructuredQueries, whose central protocol is already named `Table`; driver code juggling two `Table`s would need module qualification everywhere. Same seam, collision-free name. |
| C2 | `TableModel`/`TableColumn` are defined *here*, hand-conformable | The changeset doc consumes "`@Table` model types' column identifiers" as a given, but no model layer exists yet and this package must stay store-agnostic (no StructuredQueries dependency — that is the Postgres driver's choice). The Postgres package bridges its `@Table` metadata onto this protocol mechanically; a `@TableModel` conformance-generating macro is deliberate future sugar. |
| C3 | `change` requires `V: Equatable` (an always-dirty overload covers the rest) | "only if actually changed" is uncomputable without comparison. Equal-to-original changes are discarded, and a change back to the original *removes* the recorded change — `changes` always means exactly "differs from the original" (Ecto's `put_change` semantics). |
| C4 | Validation semantics spelled out: field rules check *recorded changes* only; `validateRequired` checks the *effective* value; cross-field rules always run | When rules fire needs pinning down, and Ecto's answers are adopted: unchanged data was validated when written; requiredness must hold whether or not the field moved; consistency properties span the whole row. Nil changes skip format rules — nil-ness is `validateRequired`'s job. |
| C5 | `CrossFieldRule` reads the changeset (`changeset.value(\.field)`), not a materialized model | Insert changesets have no original to overlay changes onto, so no full `Model` value exists to hand a rule. Effective-value reads work identically for inserts and updates; `.ordered` ships as the canned canonical case. |

## Dependency policy

`FlightDataCore` depends on `FlightCore` alone (which re-exports
`FlightConfig`). `swift-service-lifecycle` appears only in the test target,
for service-owning module fixtures. Nothing else — this package is the seam,
not the plumbing.

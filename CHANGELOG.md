# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-08-29

A source audit of every product in `Sources/` found two critical defects, a
cluster of moderate bugs, and — behind most of them — one structural cause:
the Postgres and Valkey pools are the same machine, and every fix had been
landing on exactly one of them. This release fixes the defects and removes
the thing that kept manufacturing them.

### Fixed

- **The Postgres pool wedged permanently after a total outage, and `ping()`
  reported it alive.** `replaceBrokenConnections` returned after a single
  failed dial, on the reasoning that the next checkout or release would
  re-trigger replacement. That holds while some connections survive; once an
  outage retires all of them there are no more releases, and a checkout
  finding an empty free list never reached the branch that yields the trigger.
  The pool sat at zero established connections, answering `poolExhausted` and
  blaming the operator's `pool_size`, until the process was restarted — a
  transient outage made permanent. Meanwhile `ping()` swallowed
  `poolExhausted` unconditionally, so the wedged pod reported healthy.

  The Valkey driver had already found this and fixed it with a backoff loop;
  that fix is ported, and the ping swallow is gated on there being connections
  to be busy. Both drivers now have an outage suite, and both are wired into
  `scripts/test.sh` — they were gated on environment variables nothing set, so
  the only coverage of the wedge never ran.

- **`FlightPubSubValkey` accepted `rediss://` and never enabled TLS**, so the
  client sent `AUTH` with the password over plaintext RESP: the credential
  leaked on the very path the operator asked to encrypt. Its URL parsing was
  re-implemented smaller than the cache adapter's and wrong in the ways that
  one had already fixed — no `valkeys://`; a database path segment accepted
  and silently ignored; and `valkey://:secret@host` setting a password with no
  username, which the auth guard then read as "no credentials" and **skipped
  authentication entirely**. It now takes the same shapes and produces the
  same client configuration, timeout hardening included.

- **`migrationsTableExists` could not find its own ledger.** `to_regclass`
  parses its argument as an identifier and was handed the raw configured
  name while the DDL rendered it quoted, so any quote-requiring name — such
  as `--migrations-table Ledger` — made `status()`, `planMigrate()`,
  `rollback()` and `repair()` see an empty ledger forever, while `migrate()`
  worked.

- **`@CachePut` returning nil left the stale value in cache.** It routed
  through the same don't-cache-absence rule `@Cacheable` needs, so the put
  neither overwrote nor removed and the next read served the pre-put value —
  from an annotation whose entire promise is that it always overwrites. A nil
  result now evicts.

- **Every `InMemoryCache` hit was O(n).** The recency order was an
  `OrderedDictionary` refreshed by remove-and-reinsert; that stores keys and
  values in dense arrays, so at the default 10,000-entry bound each hit shifted
  ~10,000 elements twice, under a comment claiming O(1). It is an intrusive
  linked list now, and the perf suite measures a hit at the real bound rather
  than only fresh-key writes at a smaller one.

- **The leaked-transaction recovery path skipped session reset.** A `ROLLBACK`
  undoes the transaction, not the `SET ROLE` that came with it, and repooling
  straight after it handed that role to the next scope — the exact cross-tenant
  read `DISCARD ALL` exists to prevent, on the path most likely to be carrying
  tenant state.

- **The Postgres URL parser percent-decoded credentials twice**, silently
  corrupting any password containing an escape.

- **The Valkey cache's TTL clamp let a negative duration through** to `PX`,
  which tells the server to delete the key. The guard tested `attoseconds > 0`,
  and a negative duration carries its sign in whichever component is non-zero.

- **Derived Valkey hash keys did not escape the separator**, so a String
  primary key containing `:` collided with a composite key — one row's writes
  landing on another's hash.

- **`PostgresJobCoordinator.prune` truncated sub-second ages to zero**, which
  prunes everything older than *now*, including the firing being claimed.

- The PubSub adapter's shutdown ordering was a 50 ms sleep that evaporates
  under cancellation; it waits for the subscribe loop now. `@Transactional`'s
  async `begin()` marked the connection after `BEGIN` rather than before,
  leaving a window where a cancelled task repooled a connection mid-transaction.
  A cancelled waiting checkout spun out the rest of its timeout.

### Added

- **A pool at capacity is a queue, not a wall.** `checkout()` returning
  promptly-or-throwing is a property of the *synchronous* primitive, and it had
  been read as the policy for the whole seam — so `pool_size` was a hard
  concurrency ceiling and the (pool_size + 1)th concurrent request failed
  rather than waiting a few milliseconds for the one ahead of it.

  `checkout(waitingUpTo:)` is now part of the `DataSource` contract with a
  polling default, so every store queues; `withConnection` is defined on it;
  and `datasource.<name>.checkout_timeout_ms` (default 5s) bounds the wait.
  Both drivers override it with a native handoff. The parked-waiter machinery
  lives in `ConnectionWaiters` in core — written once rather than once per
  driver, which is how the twins drifted apart in the first place.

- **Valkey clears session state on release**, matching Postgres:
  `DISCARD`/`UNWATCH`/`SELECT` in one pipelined round trip, under the same
  `datasource.<name>.reset_on_release` key. A scope that ran `SELECT 5` through
  the raw command hatch was handing the next scope the wrong database, and a
  leaked `WATCH` made an unrelated `MULTI` abort for no visible reason.

- **Valkey's `ping()` tolerates a saturated pool**, as Postgres's already did.

- `DataSourceConformance` gained the clauses it was missing — `ping`, a release
  check that means something for pools larger than eight, concurrent-checkout
  safety, and the queueing contract — and **both drivers now actually run it**,
  which is the failure mode its own doc comment says it exists to end.

- `PendingConnections.offering(_:connection:returning:)` replaces binding the
  task-local by hand. The old call site *replaced* the offers dictionary, so a
  nested unit of work on a second datasource erased the outer offer and sent
  that scope down the non-waiting path — failing beside its own reserved
  connection.

- CLI flags for `--lock-timeout`, `--advisory-lock-key` and
  `--fail-on-unknown-applied`; `--version` reports the real version and a test
  pins it to the changelog.

### Changed

- **The PubSub wire format changed.** `WireMessage` was `Codable` with a `Data`
  payload, and `JSONEncoder` renders `Data` as base64 — so a comment claiming
  the payload "crosses as bytes rather than being base64'd" was true only of
  the outer RESP frame, while chat fan-out paid a third more wire and an
  encode/decode on every hop. Frames are now a magic + length-prefixed JSON
  header followed by the payload verbatim. **Nodes must be upgraded together**;
  a node on the old build drops the new frames rather than misreading them.

- `DefaultValue.uuid` is `DefaultValue.generatedUUID`, named for what it
  produces rather than reading as a column type.

- `PostgresJobCoordinator`'s guarantee is documented as **at most once**, and
  the trade is stated: the lease is written before the job runs and `release`
  is a no-op, so a claimant that crashes mid-job consumes the firing. That is
  deliberate — a lease with an expiry runs a long job twice — but it was not
  written down anywhere.

- `Offer.isUnclaimed` is gone. It had no callers and invited the TOCTOU its one
  real consumer correctly avoided. `SingleFlight`'s coalescing instrumentation
  (`inFlightCount`, `coalescedCount`, `waitUntilCoalescing`) is internal rather
  than public — it exists for this package's own concurrency tests, and
  `@testable` reaches it.

- Both drivers throw `DataSourceError.notStarted` instead of shadowing it with
  a driver-local enum; `PostgresDataSourceError` and `ValkeyDataSourceError` are
  gone. A portable error vocabulary is only portable if the drivers use it.

- `PostgresDataSource(name:configuration:…)` takes a
  `PostgresConnection.Configuration` you built yourself — for a unix domain
  socket, or for `verify-ca`/`verify-full` with a CA bundle. Both the URL
  parser's doc comment and the migrate CLI's error message had been
  recommending this escape hatch, which did not exist.

- `@Cacheable(namespace:)` rejects a namespace outside lowercase letters,
  digits, underscores and dots. It becomes the config key
  `cache.namespaces.<name>`, which Flight's environment overrides render as
  `FLIGHT_CACHE_NAMESPACES_…` — so a hyphen produced a variable no shell can
  set and a TTL nobody could configure. The rule was documented and enforced
  nowhere; the macro already requires a literal, so it can check it.

- The `_`-named-parameter diagnostic said to "add it to `excluding:` by its
  external label", but matching is by internal name — so following the advice
  produced a second error. It says to name the parameter.

- The PubSub integration tests republish until delivery instead of sleeping a
  few hundred milliseconds and hoping the subscription had established. For an
  at-most-once transport a retry is the semantics, not a workaround, and a
  sleep long enough to be reliable is one every run pays. The suite is faster
  and no longer has a tuning knob between slow and flaky. The channel default
  is defined once rather than in two places, where a desync makes two nodes
  silently deaf to each other.

- `FakeDatabase` honours `lockTimeout`, so the contended-lock path has tests: a
  configured timeout reaches the acquisition, `nil` passes through as "wait
  indefinitely", and a run that cannot get the lock changes nothing.

## [0.3.0] - 2026-08-25

### Added

- **`FlightPubSubValkey` — the first distributed PubSub adapter.**
  `DistributedPubSubAdapter` had been a seam with nothing behind it, and three
  documented features rested on it. Registering this module makes all three
  work across servers, and nothing that publishes or subscribes changes:

  ```swift
  modules: [FlightPubSubValkeyModule.self, AppModule.self]
  ```

  ```yaml
  pubsub:
    valkey:
      url: valkey://localhost:6379
  ```

  - **Channels** — a broadcast reaches sockets on other servers
  - **Presence** — the membership mode has a transport to gossip over
  - **`ClusteredPubSub`** — reachable at all, rather than a type with no adapter

  Every node publishes to and subscribes to one channel; a Flight `Message`
  names its own topic inside the frame, because a channel per topic would mean
  re-subscribing every time a socket joined a room.

  **At-most-once and fire-and-forget**, which is Valkey's pub/sub and is
  stated rather than implied. A node disconnected at the moment of a publish
  does not get that message later. Right for presence diffs, chat fan-out and
  cache invalidation, where the next update supersedes the last; wrong for
  anything that must not be lost.

  Tested against real Valkey with two independent nodes — cross-node
  delivery, byte-exact binary payloads, channel isolation, an undecodable
  frame not killing the relay, and a local subscriber seeing an echoed
  message exactly once.

### Fixed

- **Ordered shutdown in the adapter's service.** Cancelling the client pool
  and the relay together releases a subscription connection that may still be
  initializing, which trips a fatal assertion inside valkey-swift and takes
  the process down during a graceful stop. The relay now stops first. Found by
  a test crashing at teardown; the same race was in the service.

## [0.2.0] - 2026-08-25

### Added

- **`FlightSchedulerPostgres` — makes a scheduled job's `.once` mean once
  across every server.** `FlightScheduler` (flight 0.2.0) runs a job once per
  firing; on more than one server that needs something for the servers to
  contend through, and this is it:

  ```swift
  container.register((any JobCoordinator).self, scope: .singleton) { c in
      PostgresJobCoordinator(dataSource: try c.resolve(PostgresDataSource.self))
  }
  ```

  A lease row rather than an advisory lock, and the reason matters:
  `pg_try_advisory_lock` is **session**-scoped, so with pooled connections a
  claim and its release routinely land on different connections and the
  release silently fails, leaving the lock alive until the session ends.
  Holding one connection for a job's whole duration would trade a correctness
  bug for a pool-exhaustion bug. `INSERT … ON CONFLICT DO NOTHING` is atomic,
  needs no connection affinity, and the row doubles as history — the table
  answers "did last night's billing job run, and on which server".

  Contention is keyed `(job, scheduled_for)`, and the scheduler passes the
  *schedule's* instant rather than a local clock, so two servers a second
  apart still agree which firing they are competing for. Verified with eight
  concurrent claimants electing exactly one, against real Postgres.

  Requires the `Postgres` trait, like every other Postgres-facing target here.

- **DocC catalogues for eight modules**, and a CI job that builds each with
  `--warnings-as-errors`. There was no docs job at all, so the one existing
  catalogue had never been verified.

- **`scripts/test.sh`** — starts throwaway Postgres and Valkey containers,
  runs the whole suite through `CI/run-tests.sh`, tears them down. It waits
  for both servers; it used to wait only for Postgres and let Valkey race the
  Swift build.

- **A macOS build job** (advisory — see known issues).

### Changed

- **Targets are grouped into family directories** — Data, Cache, Migrate,
  Scheduler — mirrored in `Tests/`. Product names are unchanged, so consumers
  see nothing.

### Fixed

- **The integration gate never ran.** CI had neither a Postgres nor a Valkey
  service, so every driver suite skipped on every push — in a package whose
  entire purpose is its drivers. Now armed, with a gate that fails rather
  than skipping; 49 integration tests run per push.
- **Two Valkey suites flushed each other's database.** `FlightCacheValkeyTests`
  and `FlightDataValkeyTests` both call `flushdb`, in two targets, each
  `.serialized` only against itself — so one could wipe the other mid-test.
  The symptom was a key that was set, read back successfully, and then
  reported `pttl == -2`, which reads as "the TTL logic is wrong" and was
  "somebody else emptied the database". Each suite now pins its own database
  index.
- **The process-global cache seam raced across test targets.**
  `FlightCaches` is installed by module assembly and torn down by tests in
  two targets; one suite's `uninstall()` could fire while the other asserted
  `isInstalled`. It passed locally and failed under CI load. Serialized
  through a lock in `FlightCacheTesting`.
- A test located the example migrations by deleting a fixed number of path
  components from `#filePath`, which silently pointed at the wrong directory
  once targets moved. It now walks up to the directory holding `Package.swift`.

### Known issues

- **This package does not build on macOS.** `apple/swift-configuration` 1.2.0
  calls `Data.bytes` in `FileProvider.swift`, which the current Darwin SDK
  does not provide. Tracked upstream as apple/swift-configuration#178 and
  swiftlang/swift#87196, where Apple describes it as an SDK gap affecting
  their own CI — Fluent, Hummingbird and eight Vapor projects fail
  identically. Nothing here can fix it; the macOS job is advisory until
  upstream ships a fix.

## [0.1.2] - 2026-08-24

### Added

- **Bounded advisory-lock acquisition.** A migration run holds a session
  advisory lock so two deploys cannot migrate one database at once. Previously
  a run that could not get the lock waited forever, and a deploy that never
  finishes is harder to diagnose than one that fails.
  `FlightMigrator.Configuration.lockTimeout` now defaults to 30 seconds and
  throws `MigrationError.lockTimeout` with the query to find the lock holder.
  Pass `nil` for the old unbounded behavior.
- DocC catalog with three guides: getting started, migrations that cannot run
  in a transaction, and an operational runbook covering every failure mode and
  its remedy.
- CI running the full suite — including all seven integration tests — against
  a Postgres service container, on Swift 6.0 and 6.2. The job fails rather
  than skips if the database is unreachable.

### Changed

- **`createIndex(concurrently: true)` now defaults to `IF NOT EXISTS`.** A
  failed concurrent build leaves an `INVALID` index occupying the name, and
  because such a migration is not wrapped in a transaction there is nothing to
  roll it back — so a retry previously failed on `relation already exists` and
  could never make progress. Pass `ifNotExists: false` to decline. Behavior
  for non-concurrent indexes is unchanged.
- **Rollback now applies the same integrity checks as a forward migration**,
  including `failOnUnknownApplied`. Reverting is as destructive as applying,
  and a ledger holding versions this binary does not know about means the
  local set and the database disagree either way.
- `MigrationDatabase.acquireAdvisoryLock` takes a `timeout` parameter. Custom
  adapters need updating; `nil` means wait indefinitely.

### Fixed

- **The integration suite no longer deadlocks when two runs share a database.**
  Ledger names and their derived advisory-lock keys are now unique per
  process, so concurrent runs never contend. Verified by running two full
  integration suites simultaneously against one server. Fixture tables are
  still shared, so a dedicated database is still the documented requirement —
  but an accidental overlap now fails in seconds with an actionable message
  instead of blocking indefinitely.

### Documentation

- All internal design-document references removed from source, tests, and
  README.
- Missing parameter documentation on `createIndex` filled in; DocC builds
  warning-free.

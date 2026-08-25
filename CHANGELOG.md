# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

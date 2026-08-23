# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

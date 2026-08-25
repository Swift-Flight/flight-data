# ``FlightSchedulerPostgres``

Makes a scheduled job's `.once` mean once across every server.

## Overview

`FlightScheduler` runs a job once per firing. On a single server that needs
nothing. On several it needs something the servers can contend through, and
this is that something:

```swift
container.register((any JobCoordinator).self, scope: .singleton) { c in
    PostgresJobCoordinator(dataSource: try c.resolve(PostgresDataSource.self))
}
```

Register it and the scheduler's startup line changes from `single-process`
to `postgres lease` — and the warning about run-once jobs with no coordinator
stops, because there now is one.

## Why a lease row rather than an advisory lock

`pg_try_advisory_lock` is the obvious choice and the wrong one here. It is
**session**-scoped: the lock belongs to the connection that took it and must
be released on that same connection. This package hands out *pooled*
connections, so a claim and its release would routinely land on different
ones — the release silently failing and the lock outliving the job. Holding a
single connection for the job's whole duration avoids that by trading a
correctness bug for a pool-exhaustion bug.

A lease row has neither problem. `INSERT … ON CONFLICT DO NOTHING` is atomic,
needs no connection affinity, and the row doubles as history: the table
answers "did last night's billing job run, and on which server" with no extra
bookkeeping.

## The claim is per firing, not per job

The primary key is `(job, scheduled_for)`, and the scheduler passes the
*schedule's* instant rather than a local `now`. Two servers whose clocks
differ by a second still agree about which firing they are competing for, and
tomorrow's firing of the same job is a separate row — otherwise a job would
run once and never again.

## The table

``PostgresJobCoordinator/createTableIfNeeded()`` exists for tests and for
deployments that do not use `flight migrate`. An application with migrations
should own this table in one, so the schema is versioned like the rest:

```sql
CREATE TABLE flight_job_leases (
    job text NOT NULL,
    scheduled_for timestamptz NOT NULL,
    claimed_by text NOT NULL,
    claimed_at timestamptz NOT NULL,
    PRIMARY KEY (job, scheduled_for)
);
```

It grows by one row per job per firing — small, but not bounded.
``PostgresJobCoordinator/prune(olderThan:)`` trims it, and the natural place
to call that is a scheduled job:

```swift
@Scheduled("0 0 4 * * *")
func pruneJobLeases() async throws {
    try await coordinator.prune(olderThan: .days(7))
}
```

## Topics

- ``PostgresJobCoordinator``

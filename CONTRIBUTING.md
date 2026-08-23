# Contributing

Thanks for your interest in flight-migrate.

## Getting set up

The unit suite needs nothing:

```bash
swift build
swift test          # 122 unit tests; the 7 integration tests skip
```

The integration suite needs a **dedicated, throwaway** PostgreSQL:

```bash
docker run -d --name flight-migrate-test \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=flight_migrate_test \
  -p 55432:5432 postgres:16-alpine

export FLIGHT_MIGRATE_TEST_DATABASE_URL=\
"postgres://postgres:postgres@localhost:55432/flight_migrate_test?sslmode=disable"

swift test          # all 129
```

> **Dedicated, genuinely.** The integration suite drops and recreates its
> fixture tables. Point it at a database you care about and it will delete
> things. Each run uses a ledger and advisory-lock key unique to its process,
> so two concurrent runs will not deadlock on each other — but they do share
> fixture tables, so give each run its own server.

## Before opening a pull request

```bash
swift build -Xswiftc -warnings-as-errors
swift test                                  # with the database URL set
FLIGHT_MIGRATE_BUILD_DOCS=1 swift package generate-documentation \
    --target FlightMigrate --warnings-as-errors
```

CI runs exactly these against Swift 6.0 and 6.2, with a Postgres service
container — and **fails rather than skips** if the database is unreachable. A
green run that quietly skipped every integration test proves almost nothing,
and this suite's entire value is what it proves against real Postgres.

## The rules that govern changes here

**A migration is either fully applied and recorded, or neither.** Every change
to the run path has to preserve that. If you are adding a step between the
migration's statements and its bookkeeping row, it belongs inside the same
transaction.

**Never record a version that did not fully apply.** A recorded version will
never run again, so recording one optimistically converts a recoverable
failure into a permanently skipped migration.

**Failures name the fix.** Every error in `MigrationError` tells an operator
what to do, not just what went wrong. A new one should too — there is usually
someone reading it during an incident.

**The unwrapped path does not get to pretend.** When `wrapInTransaction` is
false there is no rollback, and the code says so plainly rather than
implying safety it cannot provide.

## Testing

`FakeDatabase` records the exact operation sequence — `BEGIN`, each statement,
the bookkeeping write, `COMMIT` — and rejects nested transactions and commits
without a transaction. Assert against that transcript when you change
ordering; it is what makes the atomicity guarantees testable without a server.

Reserve the integration suite for things only real Postgres can prove:
transactional DDL rollback, `CONCURRENTLY` outside a transaction, advisory
lock behavior under contention.

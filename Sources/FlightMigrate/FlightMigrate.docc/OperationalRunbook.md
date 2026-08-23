# Operational runbook

What the failures look like, and what to do about each one.

## A migration failed

Read the error. It names the version, the statement, and whether the failure
was rolled back.

**If the migration was wrapped** (the default), nothing was applied and
nothing was recorded. Fix the migration and run again — the database is
exactly as it was.

**If it was unwrapped** (`wrapInTransaction = false`), the failure was not
rolled back and the version was not recorded. Inspect the database before
retrying. See <doc:UnwrappedMigrations>.

## Checksum mismatch

```
Migration 20260715093000 (AddEmailIndex) has changed since it was applied.
  recorded: 3f2a...
  current:  91be...
```

A migration file was edited after it ran. The database no longer matches the
code that claims to describe it, so the run halts rather than guessing.

**If the edit was a mistake** — restore the original file. `git log` on the
migration will show what changed.

**If the edit was deliberate and the database already reflects it** — for
instance you fixed a typo in a comment, or corrected a `down` that was never
run — re-baseline:

```bash
swift run migrate repair
```

`repair` records the current checksums as authoritative. It does not run
anything, and it does not make the database match the file; it asserts that
you have checked they already agree.

**If the edit was deliberate and the database does not reflect it** — write a
new migration. Editing an applied migration and re-baselining is how
environments drift apart.

## Advisory lock timeout

```
Timed out after 30 seconds waiting for the migration advisory lock (key
5064530418463322951). Another migration run is holding it, or a session
leaked it.
```

Another migration is running, or one died without releasing the lock. Check
before raising the timeout:

```sql
SELECT pid, granted, state, query_start, query
FROM pg_locks
JOIN pg_stat_activity USING (pid)
WHERE locktype = 'advisory';
```

A `granted` lock held by a live, working session is a concurrent deploy —
wait for it. A lock held by an idle session is a leak; that session can be
terminated with `pg_terminate_backend(pid)`, which releases it.

Set ``FlightMigrator/Configuration/lockTimeout`` to `nil` to wait
indefinitely, which is reasonable for an interactive run you are watching and
a poor idea in an automated deploy.

## Unknown applied migrations

```
The ledger contains versions this binary does not know about: 20260801120000
```

The database has been migrated by a newer build than the one running now.

Mid-deploy this is **normal** — an old pod sees a schema the new pods
created. That is why the default is to warn and proceed.

Outside a deploy it usually means a migration file was deleted. Turn on
``FlightMigrator/Configuration/failOnUnknownApplied`` once your deploys are
stable, and this becomes a hard error that catches exactly that.

## Rolling back

```bash
swift run migrate rollback --steps 1
swift run migrate rollback --to 20260714120000
```

Rollback runs each migration's `down` in reverse order, each in its own
transaction, and removes the ledger row in the same transaction.

Two things it will refuse to do:

- Roll back a migration whose checksum has drifted, since the `down` in the
  file may not undo the `up` that actually ran.
- Roll back a version the ledger records but this binary does not know about
  — there is no `down` to run.

Rollback applies the same integrity checks as a forward migration, including
``FlightMigrator/Configuration/failOnUnknownApplied``. Reverting is as
destructive as applying, so it is gated the same way.

## Before a destructive deploy

```bash
swift run migrate plan
```

Renders the exact SQL without running it. Review against that, not against
the Swift that generates it.

## A note on running migrations at boot

This library will not do it for you, and the omission is deliberate. A schema
change is a deploy step with a decision behind it — who runs it, when, what
happens if it fails, whether the old code can survive the new schema. Making
it a side effect of a process starting means N replicas racing to migrate,
and a failed migration becoming a crash loop.

Run migrations from a job, an init container, or a human. Then start the app.

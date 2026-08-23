# ``FlightMigrate``

Versioned, transactional schema migrations for PostgreSQL.

## Overview

Migrations are the one place where a bug is not a bug but a data loss event.
This library is organized around that: each migration runs inside a
transaction by default, so a failure anywhere in it leaves the database
exactly as it was, bookkeeping included.

```swift
struct CreateUsers: Migration {
    static func up(_ schema: SchemaBuilder) {
        schema.createTable("users") { t in
            t.uuid("id").primaryKey()
            t.text("email").notNull().unique()
            t.timestamps()
        }
    }

    static func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}
```

```bash
swift run migrate status
swift run migrate apply
swift run migrate rollback --steps 1
```

## What it guarantees

**Atomicity.** `BEGIN`, the migration's statements, the bookkeeping row,
`COMMIT` — one transaction. A failure at any point rolls back everything,
so a migration is either fully applied and recorded, or neither.

**Exactly once.** The ledger's `version` is a primary key, so re-applying is
structurally impossible rather than merely guarded against.

**One runner at a time.** A session-scoped advisory lock is held for the
duration of a mutating run, so two deploys cannot migrate the same database
concurrently. The wait is bounded — see ``FlightMigrator/Configuration/lockTimeout``.

**No silent drift.** Every applied migration's source is checksummed. If a
file changed after it was applied, the next run halts and names the version
rather than pretending the database matches your code.

## The one thing that is not atomic

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction — that is
Postgres, not this library. Such a migration opts out:

```swift
struct AddEmailIndex: Migration {
    static let wrapInTransaction = false

    static func up(_ schema: SchemaBuilder) {
        schema.createIndex(on: "users", columns: ["email"], concurrently: true)
    }
}
```

A failure there cannot be rolled back, and the library does not pretend
otherwise: it declines to record the version, names the failed statement, and
tells you what manual step is needed. Keep these to one statement per
direction. See <doc:UnwrappedMigrations>.

## Topics

### Writing migrations

- ``Migration``
- ``SchemaBuilder``
- ``MigrationEntry``

### Running them

- ``FlightMigrator``
- ``MigrationPlan``
- ``MigrationStatus``
- ``MigrationEvent``

### Errors

- ``MigrationError``

### Guides

- <doc:GettingStarted>
- <doc:UnwrappedMigrations>
- <doc:OperationalRunbook>

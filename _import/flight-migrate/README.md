# Flight Migrate

Postgres-first SQL migrations for server-side Swift, with **per-migration transactional
rollback**.

Postgres supports transactional DDL: `CREATE TABLE`, `ALTER TABLE`, index creation and
friends can run *inside a transaction* and roll back atomically. Database-agnostic tools
can't promise that (MySQL and older SQLite auto-commit DDL), so they don't. Flight
Migrate is Postgres-only on purpose and leans into it entirely: every migration runs in
its own transaction **together with its bookkeeping record**, so a migration that fails
partway leaves the database byte-for-byte where it started — no half-applied schema, no
manual cleanup, no "migration 14 half-ran and now everything is stuck."

- **Swift migrations, one file per migration**, `up` and `down` together, with a typed
  `SchemaBuilder` DSL for the common 90% and first-class raw SQL for the rest.
- **Build-time discovery**: a SwiftPM plugin generates the migration registry during
  compilation. Malformed or duplicate timestamps are *build* errors, not deploy surprises.
- **Checksummed ledger** (Flyway-style): editing an already-applied migration is a hard,
  loud error, caught before anything runs.
- **Concurrency-safe**: a Postgres advisory lock serializes simultaneous migrator
  instances across a fleet.
- **CLI-first, library-callable, and never runs at boot by default.**

Depends only on [PostgresNIO](https://github.com/vapor/postgres-nio) (plus
swift-argument-parser for the CLI pieces). Works with Vapor, Hummingbird, or a bare
Swift executable.

---

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/flight-server/flight-migrate.git", from: "0.1.0"),
],
targets: [
    // 1. A dedicated target for your migration files, with the discovery plugin attached.
    .target(
        name: "Migrations",
        dependencies: [.product(name: "FlightMigrate", package: "flight-migrate")],
        plugins: [.plugin(name: "FlightMigratePlugin", package: "flight-migrate")]
    ),
    // 2. Your migrate executable — three lines of code, full CLI.
    .executableTarget(
        name: "migrate",
        dependencies: [
            "Migrations",
            .product(name: "FlightMigrateCLI", package: "flight-migrate"),
        ]
    ),
]
```

```swift
// Sources/migrate/main.swift
import FlightMigrate
import FlightMigrateCLI
import Migrations

@main
struct Migrate: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}
```

`_allMigrations()` is generated at build time by the plugin from the `Migrations` target's
source files.

## Writing migrations

Generate a file (the timestamp is always UTC and always generated — never hand-typed):

```console
$ swift run migrate create CreateUsers
Created Sources/Migrations/20260715143022_CreateUsers.swift
```

```swift
// Sources/Migrations/20260715143022_CreateUsers.swift
import FlightMigrate

struct CreateUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("users") { t in
            t.uuid("id").primaryKey().default(.raw("gen_random_uuid()"))
            t.text("email").notNull().unique()
            t.timestamptz("created_at").notNull().default(.now)
        }
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}
```

The filename is the contract: `<14-digit UTC timestamp>_<TypeName>.swift` must declare a
type of exactly that name conforming to `Migration`. The timestamp prefix is the version
and ordering key. Files that don't start with a digit are ignored (helpers are fine);
files that start with a digit but are malformed **fail the build**, as do duplicate
versions.

### The DSL

```swift
schema.createTable("teams", ifNotExists: false) { t in
    t.bigint("id").generatedAlwaysAsIdentity().primaryKey()
    t.text("name").notNull().unique()
    t.uuid("owner_id").notNull().references("users", onDelete: .cascade)
    t.jsonb("settings").notNull().default(.raw("'{}'::jsonb"))
    t.integer("seats").notNull().default(5).check("seats > 0")
    t.timestamps()                                // created_at + updated_at
    t.primaryKey(["a", "b"])                      // composite keys
    t.unique(["a", "b"], name: "teams_ab_key")
    t.foreignKey(["a"], references: "other", ["x"], onDelete: .restrict)
}

schema.alterTable("users") { t in
    t.text("bio")                                 // ADD COLUMN
    t.dropColumn("legacy", ifExists: true)
    t.renameColumn("email", to: "email_address")
    t.setDefault("bio", .string(""))
    t.setNotNull("bio")
    t.setDataType("count", .bigint, using: "count::bigint")
    t.addUnique(["email_address"])
    t.dropConstraint("old_check", ifExists: true)
}

schema.createIndex(on: "users", columns: ["email"], unique: true)
schema.dropIndex("users_email_idx")
schema.renameTable("old", to: "new")
schema.dropTable("users", ifExists: true, cascade: true)
schema.createExtension("pgcrypto")
```

Column types: `uuid`, `text`, `varchar(limit:)`, `char(limit:)`, `smallint`, `integer`,
`bigint`, `boolean`, `real`, `doublePrecision`, `numeric(precision:scale:)`, `date`,
`time`, `timestamp`, `timestamptz`, `interval`, `json`, `jsonb`, `bytea`, `inet`, plus
`t.column("v", .array(of: .text))` and `t.column("v", .custom("tsvector"))`.

### Raw SQL is first-class, not a leak

The DSL deliberately does not chase full Postgres coverage. Anything it doesn't express —
`ALTER TYPE ... ADD VALUE`, exclusion constraints, data backfills — drops to raw SQL in
the same migration:

```swift
func up(_ schema: SchemaBuilder) {
    schema.alterTable("users") { t in t.text("plan") }
    schema.raw("UPDATE users SET plan = 'free' WHERE plan IS NULL")   // backfill
    schema.alterTable("users") { t in t.setNotNull("plan") }
}
```

One statement per `raw()` call (statements run over the extended query protocol, which
rejects multiple commands per query). Everything above still runs in one transaction —
DDL, backfill, and bookkeeping commit or roll back together.

### Migrations that can't run in a transaction

A few Postgres operations refuse to run inside a transaction block — most importantly
`CREATE INDEX CONCURRENTLY`, the production-safe index build. Opt out per migration:

```swift
struct AddUsersEmailIndex: Migration {
    static let wrapInTransaction = false   // default is true

    func up(_ schema: SchemaBuilder) {
        schema.createIndex(on: "users", columns: ["email"], concurrently: true)
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropIndex("users_email_idx", concurrently: true)
    }
}
```

**The sharp edge, stated plainly:** an unwrapped migration that fails partway cannot be
auto-rolled back — there's no transaction to abort. Flight Migrate therefore (a) warns
when an unwrapped migration bundles multiple statements, (b) reports precisely which
statement failed and that manual intervention may be required (e.g. a failed
`CREATE INDEX CONCURRENTLY` leaves an `INVALID` index to drop), and (c) still does not
record the version, so the migration re-runs once you've repaired the state.

## Running migrations

```console
$ swift run migrate                      # apply all pending
$ swift run migrate status [--json]      # applied + pending, read-only
$ swift run migrate apply --dry-run      # print the SQL, change nothing
$ swift run migrate rollback             # revert the most recent migration
$ swift run migrate rollback --steps 3
$ swift run migrate rollback --to 20260714120000   # that version stays applied
$ swift run migrate rollback --to 0      # revert everything
$ swift run migrate create AddTeams
$ swift run migrate repair               # re-baseline checksums after a safe edit
```

The connection URL comes from `--database-url`, `$FLIGHT_DATABASE_URL`, or
`$DATABASE_URL`:

```
postgres://user:password@host:5432/database?sslmode=verify-full
```

`sslmode` follows libpq semantics (`disable`, `allow`, `prefer` (default), `require`,
`verify-ca`, `verify-full`). Note that like libpq, `prefer`/`require` encrypt without
verifying certificates — use `verify-full` in production over untrusted networks.

### As a library

```swift
import FlightMigrate
import Migrations

let migrator = FlightMigrator(client: postgresClient, migrations: _allMigrations())
try await migrator.migrate()

// Also available:
let status  = try await migrator.status()
let plan    = try await migrator.planMigrate()          // rendered SQL, no execution
let undone  = try await migrator.rollback(steps: 1)
let repairs = try await migrator.repair()
```

`FlightMigrator.Configuration` exposes the bookkeeping table name, the advisory lock key,
a `Logger`, an `onEvent` callback for progress/metrics, and `failOnUnknownApplied` (see
below).

**Migrations are not run at boot by default, and we recommend keeping it that way.**
Auto-migration on startup couples "deploy new code" to "mutate schema" with no gate in
between; a bad migration then takes down the deploy. The advisory lock makes boot-time
migration safe *from races* if you choose to call `migrate()` at startup — safe-from-races
is not the same as advisable. Prefer a dedicated deploy step.

## The guarantees, precisely

**Transactional execution.** A wrapped migration executes as:

```
BEGIN;
  -- every statement of up()/down()
  INSERT INTO flight_migrations (version, name, checksum) VALUES (...);  -- or DELETE on rollback
COMMIT;
```

Body and bookkeeping share the transaction: a failure rolls back both. The error message
tells you which statement failed, that the database is unchanged, and that the version
was not recorded.

**Bookkeeping.** Created automatically on first run (itself inside a transaction):

```sql
CREATE TABLE flight_migrations (
    version     BIGINT PRIMARY KEY,      -- the timestamp prefix
    name        TEXT NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    checksum    TEXT NOT NULL
);
```

`version` as primary key makes double-application structurally impossible even without
the advisory lock.

**Checksums (Flyway-style drift detection).** Each migration's source is hashed at build
time (SHA-256 over the file with line endings normalized, bound to `version_name`) and
recorded on apply. Every subsequent run verifies applied migrations still match. If one
was edited:

```
error: migration 20260714120000_CreateUsers has been modified since it was applied
(checksum mismatch). Applied migrations are immutable — create a new migration to make
further changes.
```

Because the hash covers source text, a purely cosmetic edit (formatting, comments) also
trips it — deliberately erring toward halting and asking. After a confirmed-safe edit,
`migrate repair` re-baselines the recorded checksums. Rollbacks verify checksums too: a
drifted `down` no longer matches what was applied.

**Concurrency.** The whole run holds `pg_advisory_lock` on a constant key (the ASCII
bytes `"FLIGHTMG"`; configurable). N instances starting at once serialize; latecomers
find nothing pending.

**Unknown applied versions.** If the ledger records versions this binary doesn't know
(an older binary mid-rolling-deploy, or a deleted migration file), the default is to warn
and proceed — halting would break rolling deploys. Set `failOnUnknownApplied = true` to
make it a hard error. Out-of-order pending migrations (a merged branch with an older
timestamp than something already applied) are applied in version order, Ecto-style.

## Testing your migrations

`FlightMigrator` takes any `PostgresClient`, so a test harness can run the real
migrations against a scratch database or [Testcontainers](https://java.testcontainers.org)-style
throwaway Postgres:

```swift
let migrator = FlightMigrator(
    client: testClient,
    migrations: _allMigrations(),
    configuration: .init(migrationsTable: "test_ledger")
)
try await migrator.migrate()
```

## Developing this package

```console
$ swift build
$ swift test                     # unit tests only (fake database)

# Integration tests need a real Postgres:
$ docker run -d --name flight-migrate-pg -e POSTGRES_PASSWORD=flight \
    -e POSTGRES_DB=flight_test -p 127.0.0.1:55432:5432 postgres:16-alpine
$ export FLIGHT_MIGRATE_TEST_DATABASE_URL="postgres://postgres:flight@127.0.0.1:55432/flight_test?sslmode=disable"
$ swift test                     # now includes the integration suite
```

The `ExampleMigrations` target and `flight-migrate-example` executable in this package
are a complete, working consumer setup — the integration suite drives the built example
binary end to end.

## Non-goals

- **No schema diffing / autogeneration** from entity types. Migrations are hand-authored;
  generated DDL diverging from intent is exactly the trap this design avoids. For the
  same reason the DSL deliberately does **not** reuse query-layer `@Table` types: a query
  needs the table as it is *now*; a migration needs the schema as it changed *at one
  point in time*. Editing a live entity struct must never silently rewrite the meaning of
  an old migration.
- **No cross-database support.** Transactional DDL is what enables the core guarantee;
  abstracting over databases that lack it would forfeit it.
- **No exhaustive DSL.** `schema.raw(_:)` is the design, not a gap in it.
- **No data-migration framework.** `raw()` runs backfills; ORM-aware data migration is
  application code.
- **No pretending destructive changes are reversible.** A `down` for `dropColumn` can
  recreate the column, not the data it held. The tool runs what you wrote.

## License

MIT.

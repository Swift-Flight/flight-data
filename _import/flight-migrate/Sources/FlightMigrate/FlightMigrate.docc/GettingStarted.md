# Getting started

From an empty database to a versioned schema.

## Writing a migration

A migration is a type with an `up` and a `down`. Both take a
``SchemaBuilder``, which accumulates statements rather than executing them —
so a migration can be rendered and reviewed before it runs.

```swift
struct CreateUsers: Migration {
    static func up(_ schema: SchemaBuilder) {
        schema.createTable("users") { t in
            t.uuid("id").primaryKey()
            t.text("email").notNull().unique()
            t.text("display_name").notNull()
            t.timestamps()
        }
    }

    static func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}
```

The file name carries the version: `20260714120000_CreateUsers.swift`. A
14-digit UTC timestamp sorts correctly, reads unambiguously, and does not
collide when two people add a migration on the same day.

```bash
swift run migrate create CreateUsers
```

## Registering them

A build plugin scans your migrations directory and generates the registry, so
adding a file is all it takes — there is no list to keep in sync, and no way
for a migration to exist but never run because someone forgot to register it.

```swift
.target(
    name: "MyAppMigrations",
    dependencies: [.product(name: "FlightMigrate", package: "flight-migrate")],
    plugins: [.plugin(name: "FlightMigratePlugin", package: "flight-migrate")]
)
```

## Running them

```swift
let migrator = FlightMigrator(
    client: postgresClient,
    migrations: MyAppMigrations.all
)

let applied = try await migrator.migrate()
```

Or from the CLI, which is the more usual deploy step:

```bash
swift run migrate status            # what is applied, what is pending
swift run migrate plan              # the exact SQL, without running it
swift run migrate apply             # run everything pending
swift run migrate rollback --steps 1
```

`plan` is worth using before anything destructive. It renders the statements
a run would execute, so a review happens against the SQL rather than against
the Swift that generates it.

## Checking before you commit

`status` reports three things per migration: applied, pending, or drifted.

```
version         name              state
20260714120000  CreateUsers       applied
20260715093000  AddEmailIndex     applied (checksum mismatch)
20260716101500  AddTeams          pending
```

A checksum mismatch means the file changed after it was applied. The next
`apply` will refuse to run until you either restore the file or re-baseline
it with `repair` — see <doc:OperationalRunbook>.

## Configuring

```swift
FlightMigrator(
    client: client,
    migrations: MyAppMigrations.all,
    configuration: .init(
        migrationsTable: "ops.flight_migrations",
        lockTimeout: .seconds(60),
        failOnUnknownApplied: true
    )
)
```

``FlightMigrator/Configuration/failOnUnknownApplied`` is worth turning on once
your deploys are stable. It makes a ledger containing versions this binary
does not know about a hard error, which catches a deleted migration file — at
the cost of failing during the window where an old binary sees a new schema.

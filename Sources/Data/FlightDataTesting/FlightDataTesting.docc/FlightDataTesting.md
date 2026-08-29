# ``FlightDataTesting``

A datasource that needs no database, and a conformance suite for one that
does.

## Overview

``InMemoryDataSource`` conforms to `DataSource`, so anything written against
the seam — a repository, a service, a module's wiring — can be tested with
no container, no port, and no cleanup:

```swift
let container = try TestContainer.build {
    InMemoryDataModule()
    AppModule()
}
```

``InMemoryDataModule`` registers it, and ``InMemoryConnection`` is what a
checkout produces. What it does *not* do is execute SQL — it is a pool and a
connection lifecycle, not a database. Testing a query means testing against
Postgres, which is what `scripts/test.sh` is for.

## The conformance suite

``DataSourceConformance`` is the more interesting half. It is a set of
behavioural tests every `DataSource` implementation must pass — a checkout
returns a usable connection, a release makes it available to the next caller,
a throw inside `withConnection` still releases it, concurrent callers are never
over-issued, the waiting checkout queues and then gives up at its deadline,
`ping()` answers on a live source including a saturated one, and checkout after
shutdown is refused.

It takes two closures: one that produces a *started* source, and one that tears
it down. It is called more than once, so each call must yield an independent
pool.

```swift
@Test func conforms() async throws {
    try await DataSourceConformance.verify(
        make: {
            let source = try MyDataSource(settings: .test)
            try await source.start()
            return source
        },
        shutdown: { await $0.shutdown() })
}
```

Writing a new driver means running these rather than re-deriving what the
protocol implies, and it means the Postgres and Valkey drivers are held to
the same contract rather than each interpreting it. A driver that leaks a
connection on a thrown error is a bug that only shows up under load; this
catches it at desk speed.

Both drivers in this package run it. For a while neither did, which is exactly
the failure this suite exists to prevent — each driver testing what its author
remembered the contract to be.

## Topics

### The in-memory driver

- ``InMemoryDataSource``
- ``InMemoryDataModule``
- ``InMemoryConnection``

### Holding a driver to the contract

- ``DataSourceConformance``

### Wiring

- ``TestContainer``

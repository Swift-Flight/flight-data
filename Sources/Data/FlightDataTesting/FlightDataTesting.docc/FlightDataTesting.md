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
returns a usable connection, a release makes it available again, a throw
inside `withConnection` still releases it:

```swift
@Test func conforms() async throws {
    try await DataSourceConformance.verify(MyDataSource(...))
}
```

Writing a new driver means running these rather than re-deriving what the
protocol implies, and it means the Postgres and Valkey drivers are held to
the same contract rather than each interpreting it. A driver that leaks a
connection on a thrown error is a bug that only shows up under load; this
catches it at desk speed.

## Topics

### The in-memory driver

- ``InMemoryDataSource``
- ``InMemoryDataModule``
- ``InMemoryConnection``

### Holding a driver to the contract

- ``DataSourceConformance``

### Wiring

- ``TestContainer``

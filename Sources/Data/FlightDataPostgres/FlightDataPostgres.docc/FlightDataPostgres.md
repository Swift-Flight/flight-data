# ``FlightDataPostgres``

The Postgres driver: a pooled `DataSource`, request-scoped connections, and
declarative transactions.

## Overview

Registering ``PostgresDataModule`` gives the container a pooled
``PostgresDataSource``, and everything above it works in terms of
`FlightDataCore`'s seam rather than PostgresNIO:

```yaml
datasource:
  primary:                                    # the datasource NAME, not the store
    url: postgres://app@localhost:5432/app
    pool_size: 10
    checkout_timeout_ms: 5000                 # how long a caller queues before failing
    reset_on_release: true                    # DISCARD ALL between scopes
```

The key under `datasource:` is `Name.name` from the module's generic parameter
— `primary` for `PostgresDataModule<PrimaryDataSource>`. This page showed
`data: postgres:` for a while, which is not a prefix anything reads; copying it
produced a bootstrap failure about a missing `datasource.primary.url`.

``PostgresDataSourceURL`` parses and validates that URL during bootstrap, so
a typo is a startup failure with a message rather than a connection error on
the first request.

## Transactions are declarative

``PostgresTransactionCoordinator`` implements `FlightCore`'s transaction
seam, so `@Transactional` works on any component method:

```swift
@Service
final class OrderService: Sendable {
    @Transactional
    func place(_ input: OrderInput) async throws -> Order {
        let order = try await orders.insert(...)
        try await lines.insert(...)      // same connection, same transaction
        return order
    }
}
```

Every query inside runs on one connection. Throwing rolls back. Nesting
becomes a savepoint, so an inner failure can be handled without discarding
the outer work.

The connection binding is scope-based, not thread-based, and it does not
cross `Task.detached` — a background job launched from inside a transaction
must not silently become durable when that transaction commits.

## Migrations

`FlightMigrate` owns schema change; this module contributes
``PostgresMigrations``, the Postgres implementation of the migration
database. `flight migrate` is the command-line side.

## Topics

### The driver

- ``PostgresDataModule``
- ``PostgresDataSource``
- ``PostgresDataSourceURL``

### Transactions

- ``PostgresTransactionCoordinator``
- ``PostgresTransactionError``

### Migrations

- ``PostgresMigrations``

### Failure

- ``PostgresDataSourceURLError``

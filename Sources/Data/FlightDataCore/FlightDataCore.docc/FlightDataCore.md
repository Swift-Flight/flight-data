# ``FlightDataCore``

The store-neutral data seam: what a driver has to provide, and what
everything above it is allowed to assume.

## Overview

``DataSource`` is the whole contract. A driver — Postgres, Valkey, an
in-memory fake — implements it, registers itself, and everything that reads
or writes goes through it. Nothing above this module names a database.

That narrowness is the design. There is no cross-database query abstraction
here and there will not be: Postgres and Valkey do not answer the same
questions, and a layer pretending otherwise ends up serving neither well.
What *is* shared is connection acquisition, scoping, and liveness — which
genuinely are the same problem everywhere.

## Connections are scoped, not global

``ScopedConnection`` binds a connection to a scope — a request, a job, a
transaction — and releases it when that scope ends. A component resolves it
like anything else:

```swift
@Repository(scope: .scoped)
struct OrderRepository {
    // Generic in its pool, and qualified by the datasource name — the
    // unqualified, un-parameterized spelling this page used to show does not
    // compile, because `ScopedConnection` has nothing to bind to without both.
    @Autowired(qualifier: "primary")
    var connection: ScopedConnection<PostgresDataSource>
}
```

The scope is `FlightCore`'s, so a request-scoped connection is released when
the request is, whether the handler returned or threw. Nothing has to
remember to close anything.

## Naming a source

``DataSourceName`` and ``PrimaryDataSource`` are how an application with more
than one database says which is which. One source is the primary; the rest
are named, and a component asks for the one it wants by qualifier rather than
by hoping the right one was registered first.

## Configuration and failure

``DataSourceSettings`` and ``DataSourceConfigKey`` are the shared
configuration shape a driver reads. ``DataSourceConfigurationError`` fires
during bootstrap — a malformed URL or a missing password is a startup
failure, not a first-query surprise. ``DataSourceError`` is the runtime
half, and ``DataSourceLiveness`` is what the actuator's health endpoint
reports.

## Topics

### The seam

- ``DataSource``
- ``ScopedConnection``

### Naming

- ``DataSourceName``
- ``PrimaryDataSource``

### Configuration

- ``DataSourceSettings``
- ``DataSourceConfigKey``
- ``DataSourceConfigurationError``

### Health and failure

- ``DataSourceLiveness``
- ``DataSourceError``

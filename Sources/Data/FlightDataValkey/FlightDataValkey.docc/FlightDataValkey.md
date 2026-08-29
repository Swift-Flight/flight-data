# ``FlightDataValkey``

The Valkey driver: a pooled `DataSource`, valkey-swift's typed commands, and
`MULTI` batches.

## Overview

Registering ``ValkeyDataModule`` gives the container a pooled
``ValkeyDataSource``, so a component acquires a scoped connection the same
way it would for Postgres:

```yaml
datasource:
  primary:                             # the datasource NAME, not the store
    url: redis://localhost:6379/2      # the path segment is the database index
    pool_size: 10
    checkout_timeout_ms: 5000          # how long a caller queues before failing
    reset_on_release: true             # clear session state between scopes
```

The key under `datasource:` is `Name.name` from the module's generic parameter
— `primary` for `ValkeyDataModule<PrimaryDataSource>`. This page showed
`data: valkey:` for a while, which is not a prefix anything reads; copying it
produced a bootstrap failure about a missing `datasource.primary.url`.

``ValkeyDataSourceURL`` parses and validates that URL during bootstrap, so a
malformed one is a startup failure with a message rather than a connection
error on the first command.

## Commands are explicit, not abstracted

The command surface is **valkey-swift's own**, generated from Valkey's command
specifications — `connection.hset(...)`, `connection.zadd(...)`, and the rest
— reached directly on the scoped connection. This package does not re-wrap it,
and adds only two conveniences (`expire(_:after:)` and `zrevrange`) where a documented
reason exists.

``ValkeyRawCommand`` is the escape *hatch*, not the primary surface: anything
the typed surface does not cover — vendor-specific commands, newly-added server
commands, module commands. It is first-class rather than a leak, since no
client can wrap every command of two diverging servers, but it sits **outside**
this package's Valkey/Redis compatibility guarantee, which is the whole reason
it is named separately.

There is deliberately no query builder and no cross-store abstraction: Valkey
and Postgres do not answer the same questions, and a layer pretending otherwise
serves neither. What is shared is the connection pooling and scoping, which
genuinely is the same problem.

## Batches, not transactions

``ValkeyMultiBatch`` and ``ValkeyMultiResults`` wrap `MULTI`/`EXEC`. Read the
distinction carefully, because the word "transaction" invites a wrong
assumption: `MULTI` queues commands and runs them without interleaving. It
does **not** roll back. A command that fails inside the batch leaves the
earlier ones applied.

That is why this module does not implement `@Transactional`. Presenting
`MULTI` as a transaction would make `@Transactional` mean two different
things depending on which datasource happened to be registered, and the
failure would surface as data that quietly did not roll back.

## Changesets

``ValkeyChangesetTranslation`` maps a `Changeset` onto Valkey's data model —
``ValkeyChangesetValue`` is the set of shapes that survive the trip, and
``ValkeyChangesetError`` is what a field that does not translate produces
rather than being silently dropped.

## Topics

### The driver

- ``ValkeyDataModule``
- ``ValkeyDataSource``
- ``ValkeyDataSourceURL``

### Commands

- ``ValkeyRawCommand``
- ``ValkeyMultiBatch``
- ``ValkeyMultiResults``

### Changesets

- ``ValkeyChangesetTranslation``
- ``ValkeyChangesetValue``
- ``ValkeyChangesetError``

### Failure

- ``ValkeyDataSourceURLError``
- ``ValkeyCommandError``

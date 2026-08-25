# ``FlightDataValkey``

The Valkey driver: a pooled `DataSource`, raw commands, and `MULTI`
batches.

## Overview

Registering ``ValkeyDataModule`` gives the container a pooled
``ValkeyDataSource``, so a component acquires a scoped connection the same
way it would for Postgres:

```yaml
data:
  valkey:
    url: redis://localhost:6379
```

``ValkeyDataSourceURL`` parses and validates that URL during bootstrap, so a
malformed one is a startup failure with a message rather than a connection
error on the first command.

## Commands are explicit, not abstracted

``ValkeyRawCommand`` is how a command is issued. There is deliberately no
query builder and no cross-store abstraction: Valkey and Postgres do not
answer the same questions, and a layer pretending otherwise serves neither.
What is shared is the connection pooling and scoping, which genuinely is the
same problem.

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

- ``ValkeyDataSourceError``
- ``ValkeyDataSourceURLError``
- ``ValkeyCommandError``

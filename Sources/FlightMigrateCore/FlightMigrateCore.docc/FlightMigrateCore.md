# ``FlightMigrateCore``

The build-time half of migrations: naming, scanning, checksums, and the
generated registry.

## Overview

Nothing here runs at request time. This module is what turns a directory of
migration files into something `FlightMigrate` can execute in a defined
order, and what the `flight migrate` command and the code generator both
build on.

``MigrationFilename`` and ``MigrationTimestamp`` own the naming convention,
so ordering comes from the filename rather than from a hand-maintained list
that drifts. ``SourceScanner`` finds the migrations; ``RegistryGenerator``
emits the registry that enumerates them; ``SwiftIdentifier`` makes a
filename into a valid type name without collisions.

## Checksums are the safety property

``MigrationChecksum`` and ``SHA256`` exist so that editing an already-applied
migration is caught rather than ignored.

That failure is quiet and expensive without a checksum: the migration ran on
production last month with its old contents, it runs on a fresh developer
database this morning with its new contents, and the two schemas silently
diverge. Comparing the recorded checksum against the file turns that into an
error at the point of the change, when it is still a one-line fix.

## Topics

### Naming and ordering

- ``MigrationFilename``
- ``MigrationTimestamp``
- ``SwiftIdentifier``

### Discovery and generation

- ``SourceScanner``
- ``RegistryGenerator``

### Integrity

- ``MigrationChecksum``
- ``SHA256``

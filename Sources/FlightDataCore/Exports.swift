// The changeset layer — Changeset, ValidationRule/CrossFieldRule,
// TableModel/TableColumn, ValidatedChanges — was extracted to the
// standalone `swift-changeset` package (module `Changesets`) on 2026-08-21,
// per hangar-design §11.2: Hangar consumes changesets directly and cannot
// depend on Flight, so the layer now lives where both can reach it.
//
// FlightDataCore's own public API traffics in those types (the DataSource
// apply seam, FlightDataTesting's InMemory driver), so it re-exports the
// module: every existing consumer — flight-data-postgres,
// flight-data-valkey, the Demo app — keeps compiling with a single
// `import FlightDataCore`.
@_exported import Changesets

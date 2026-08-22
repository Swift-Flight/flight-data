// A repository file imports FlightDataPostgres and writes @Entity types,
// @Repository types, and repo.all(...) — one import covers the whole
// surface: Flight Core (Container/Scope/@Repository/@Transactional),
// Flight Data Core (DataSource seam), Hangar (the query layer: @Entity,
// Query, Repo, changesets via its Changesets re-export), and PostgresNIO's
// connection types (via Hangar's re-export).
@_exported import FlightCore
@_exported import FlightDataCore
@_exported import Hangar

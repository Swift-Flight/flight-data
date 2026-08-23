// A repository file imports FlightDataValkey and writes @Repository types,
// valkey.hset(...) / valkey.multi { ... } / apply(changeset) — one import
// covers the whole surface: Flight Core (Container/Scope/@Repository),
// Flight Data Core (DataSource seam, changesets), and valkey-swift's client,
// connection, command and RESP types.
@_exported import FlightCore
@_exported import FlightDataCore
@_exported import Valkey

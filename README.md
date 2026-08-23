# Flight Data

Persistence and caching for [Flight](https://github.com/Swift-Flight/flight):
the data-source and cache protocols, an in-memory cache, migrations, and the
PostgreSQL and Valkey drivers.

The abstractions and the drivers live together because they break together —
a change to the `DataSource` contract breaks every adapter at once, and one
package makes that a compile error in CI rather than a discovery weeks later
in whichever adapter nobody rebuilt.

## Traits

The drivers are heavy and mutually irrelevant: an application using the
in-memory cache should never resolve a Postgres driver. SwiftPM does not
prune a package's dependencies by which product you use, but it does prune
dependencies no enabled trait reaches — so the drivers are behind traits.

| Configuration | Products | Resolves |
| --- | --- | --- |
| default | `FlightCache`, `FlightCacheTesting`, `FlightDataCore`, `FlightDataTesting`, `FlightMigrateCore` | 8 packages |
| `Postgres` | + `FlightDataPostgres`, `FlightMigrate`, `FlightMigrateCLI` | + PostgresNIO, Hangar, ArgumentParser |
| `Valkey` | + `FlightCacheValkey`, `FlightDataValkey` | + valkey-swift, NIOSSL |

```swift
// In-memory cache only — no driver resolved at all.
.package(url: "https://github.com/Swift-Flight/flight-data.git", from: "0.1.0")

// With PostgreSQL.
.package(url: "https://github.com/Swift-Flight/flight-data.git",
         from: "0.1.0", traits: ["Postgres"])

// Both.
.package(url: "https://github.com/Swift-Flight/flight-data.git",
         from: "0.1.0", traits: ["Postgres", "Valkey"])
```

Taking a gated product without its trait is a compile error naming the trait
you need.

## Products

| Product | What it is |
| --- | --- |
| `FlightCache` | Cache protocol, in-memory implementation, single-flight coalescing, `@Cacheable`. |
| `FlightDataCore` | `DataSource`, connection and transaction protocols, changeset integration. |
| `FlightMigrateCore` | Migration discovery and ordering, plus the build tool plugin — no driver required. |
| `FlightDataPostgres` | PostgreSQL data source over PostgresNIO, with Hangar for queries. |
| `FlightMigrate` / `FlightMigrateCLI` | Migration runner and its command line interface. |
| `FlightCacheValkey` | Distributed cache over Valkey. |
| `FlightDataValkey` | Valkey data source. |
| `*Testing` | Conformance suites and fakes — including `DataSourceConformance`, the contract every data source must satisfy. |

Per-product documentation lives in [Docs/](Docs/).

## Building this repository

A root build compiles every target regardless of traits, so it needs them all:

```
swift build --enable-all-traits
swift test  --enable-all-traits
```

A plain `swift build` here fails by design. `CI/check-lean-consumer.sh`
verifies the pruning the only way that proves anything — by building a real
consumer and asserting no gated dependency reached it.

## Requirements

Swift 6.2+, macOS 15+ or Linux. Strict concurrency throughout.

## Testing

`swift test --enable-all-traits` — 375 tests. Postgres and Valkey integration
suites skip unless pointed at a live instance.

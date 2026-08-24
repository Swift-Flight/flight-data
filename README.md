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
in-memory cache should never resolve a Postgres driver. SwiftPM does not prune
a package's dependencies by which product you use, but it does prune
dependencies no enabled trait reaches — so the drivers sit behind traits.

| Configuration | Products | Resolves |
| --- | --- | --- |
| `traits: []` | `FlightCache`, `FlightCacheTesting`, `FlightDataCore`, `FlightDataTesting`, `FlightMigrateCore` | 10 packages, no driver |
| `traits: ["Postgres"]` | + `FlightDataPostgres`, `FlightMigrate`, `FlightMigrateCLI` | + PostgresNIO, Hangar, ArgumentParser |
| `traits: ["Valkey"]` | + `FlightCacheValkey`, `FlightDataValkey` | + valkey-swift, NIOSSL |
| unspecified | everything | both drivers |

**Both traits are default, and you subtract**, so naming nothing gives you
everything:

```swift
// In-memory cache and the data protocols only — no driver resolved at all.
.package(url: "https://github.com/Swift-Flight/flight-data.git",
         from: "0.1.0", traits: [])

// With PostgreSQL, and without Valkey.
.package(url: "https://github.com/Swift-Flight/flight-data.git",
         from: "0.1.0", traits: ["Postgres"])
```

Opt-in would be the better default, and this package tried it first. On
SwiftPM 6.2.3 a consumer enabling a **non-default** trait on a **versioned**
dependency does not get that trait's gated dependencies resolved — the build
fails with *"exhausted attempts to resolve the dependencies graph"*. Path
dependencies work, so this only appears once a package is tagged. Default
traits resolve correctly, hence opt-out. Revisit when the toolchain allows.

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

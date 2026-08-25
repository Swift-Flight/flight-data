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
| (none) | `FlightCache`, `FlightCacheTesting`, `FlightDataCore`, `FlightDataTesting`, `FlightMigrateCore` | 10 packages, no driver |
| `traits: ["Postgres"]` | + `FlightDataPostgres`, `FlightMigrate`, `FlightMigrateCLI` | + PostgresNIO, Hangar, ArgumentParser |
| `traits: ["Valkey"]` | + `FlightCacheValkey`, `FlightDataValkey` | + valkey-swift, NIOSSL |

Both are opt-in — name a driver to get it:

```swift
// In-memory cache and the data protocols. No driver resolved at all.
.package(url: "https://github.com/Swift-Flight/flight-data.git", from: "0.3.0")

// With PostgreSQL.
.package(url: "https://github.com/Swift-Flight/flight-data.git",
         from: "0.3.0", traits: ["Postgres"])
```

**Swift 6.3 or later is required**: through 6.2.x, SwiftPM did not resolve a
non-default trait's gated dependencies through a versioned dependency
([#9286](https://github.com/swiftlang/swift-package-manager/issues/9286)).

Taking a gated product without its trait is a compile error naming the trait
you need.

## Products

| Product | What it is |
| --- | --- |
| `FlightCache` | Cache protocol, in-memory implementation, single-flight coalescing, `@Cacheable`. |
| `FlightDataCore` | `DataSource`, connection and transaction protocols, changeset integration. |
| `FlightMigrateCore` | Migration discovery and ordering, plus the build tool plugin — no driver required. |
| `FlightDataPostgres` | PostgreSQL data source over PostgresNIO, with Hangar for queries. |
| `FlightPubSubValkey` | Carries Flight's PubSub between nodes over Valkey, which makes Channels broadcast, Presence membership, and `ClusteredPubSub` work across servers. Requires the `Valkey` trait. |
| `FlightSchedulerPostgres` | Makes a Flight scheduled job's `.once` mean once across every server, using a Postgres lease row. Requires the `Postgres` trait. |
| `FlightMigrate` / `FlightMigrateCLI` | Migration runner and its command line interface. |
| `FlightCacheValkey` | Distributed cache over Valkey. |
| `FlightDataValkey` | Valkey data source. |
| `*Testing` | Conformance suites and fakes — including `DataSourceConformance`, the contract every data source must satisfy. |

Per-product documentation lives in [Docs/](Docs/). How to test an application
built on Flight — including the cache and data-source fakes this package
ships — is covered in
[flight's testing guide](https://github.com/Swift-Flight/flight/blob/main/Docs/testing.md).

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

## Running the tests

```bash
./scripts/test.sh                 # everything, integration tests included
./scripts/test.sh --filter Foo    # arguments pass through to swift test
```

It starts throwaway servers, runs the suite, and removes them. The
integration suites skip without a database, and a skipped suite is not a
passing one — what this package proves against real infrastructure is most of
what it is for.

`FLIGHT_KEEP_SERVERS=1` leaves the containers up between runs.

## License

MIT. See [LICENSE](LICENSE).

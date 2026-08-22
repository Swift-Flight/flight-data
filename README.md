# Flight Cache Valkey

The Valkey/Redis-backed adapter for [Flight Cache](../flight-cache)
(design §10.2): namespaces as key prefixes, TTL as native expiry, required
for multi-instance deployments where an in-memory cache would give each
instance its own inconsistent copy.

Deliberately **not** built on Flight Data Valkey (design §2.1): a cache
adapter needs `GET`, `SET`, `UNLINK`, and expiry — not repositories,
`Scope`-bound checkout, or `DataSource` conformance. Shared *library*
dependency (valkey-swift), independent *package* dependency. And unlike the
data package's hand-rolled lender-task pool (its delta V1), this adapter
holds a `ValkeyClient` — the driver's own pool, already a ServiceLifecycle
`Service` — because the cache seam is async end to end.

| Piece | Contents |
|---|---|
| `ValkeyCache` | §10.2 + §7: fail-open `Cache` over `ValkeyClient` — every error is a logged, counted miss/no-op; consecutive-failure breaker with half-open probe, fed only by failures that actually indicate store ill-health (CV2) |
| `ValkeyCacheSettings` / `ValkeyCacheURL` | `cache.valkey.*` config (its own root — caching ≠ adopting Valkey as a data store); both §7 timeout phases (CV1), pool sizing; `valkey://`/`redis://` exact synonyms, TLS variants, auth, database |
| `FlightCacheValkeyModule` | §11: registers the store under `FlightCacheModule.storeQualifier` (compose-by-presence) and runs the client pool as its service |

Keys are stored as `flight-cache:` + `CacheKey.storageKey`
(`flight-cache:prices:123:eu`) — recognizable and greppable in a store that
may hold non-cache data. Namespace eviction is `SCAN MATCH <prefix>* +
UNLINK` in batches: O(keys) and non-atomic, per the design's stated §10.2
trade-off.

## Build status

**Builds and passes all tests** — verified 2026-08-22 against Swift 6.2.3 on
Linux (x86_64): 22 tests green in ~1.4 s, the integration suite running
against **both a real Valkey 8 and a real Redis 7** (the §3.1-compatibility
duality), covering round-trips under the documented key shape, native TTL
expiry, multi-batch namespace eviction (750 keys > one SCAN batch),
prefix-collision safety, both §7 timeout phases reaching the driver, the
failure classification that feeds the breaker, and the dead-server path
(every operation degrades to a miss/no-op in bounded time, and the
adapter's breaker correctly stays closed because the pool's owns that
case).

## Using it

```swift
try await bootstrap(configuration: .load(), modules: [
    FlightCacheValkeyModule.self,   // pulls in FlightCacheModule via dependencies
])
```

```yaml
cache:
  default_ttl: 300
  valkey:
    url: "valkey://localhost:6379"   # or redis:// — same client, same behavior
    command_timeout_ms: 250          # bounds a command already executing (default 250)
    unreachable_after_ms: 250        # bounds obtaining a connection; defaults to the above
    pool_size: 20                    # ceiling on concurrent in-flight commands
    min_connections: 1               # kept warm; 0 restores the driver's lazy dial
```

Both timeout keys matter and they cover different phases — see delta CV1
below for why setting only `command_timeout_ms` leaves a 60-second hang on
the table.

## Running the tests

Unit tests need nothing. Integration tests are gated per server and run the
same code against every server you configure:

```
$ docker run -d --name flight-cache-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
$ docker run -d --name flight-cache-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
$ export FLIGHT_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
$ export FLIGHT_REDIS_TEST_URL="redis://127.0.0.1:56380"
$ swift test
```

The suites `FLUSHDB` between tests — point them at throwaway servers only.

## Design deltas

- **CV1 — §7's timeout has two phases, and `commandTimeout` only covers
  one.** A cache call spends time obtaining a connection and then executing
  a command. `commandTimeout` starts *after* a connection is leased, so
  against a downed server it never fires. What bounds the first phase is
  the pool's connection-creation circuit breaker, `circuitBreakerTripAfter`
  — and the driver defaults it to **60 seconds**, so an unconfigured client
  hangs for a minute on the first `get` against a dead server. Measured:

  | Configuration | First call | Subsequent |
  |---|---|---|
  | Driver defaults + `commandTimeout: 250ms` | **67 s** | — |
  | `circuitBreakerTripAfter: 250ms` | **~380 ms** | **~0.1 ms** |

  So this adapter configures **both** phases: `command_timeout_ms` →
  `commandTimeout`, and `unreachable_after_ms` (defaulting to the same
  value) → `circuitBreakerTripAfter`. `min_connections` defaults to 1 so
  the pool discovers an unreachable server at service start rather than on
  a request, keeping the dial off the request path entirely.

  *An earlier revision instead raced every call against a hand-rolled
  `Task.sleep` deadline. That was a workaround for an undiagnosed
  symptom, and an actively harmful one: cancelling the operation task
  surfaces as `ValkeyClientError(.cancelled)`, which the adapter's breaker
  then counted as store ill-health — the guard manufacturing the failure
  signal it went on to misread. It also cost a `TaskGroup` per call and
  paid a fresh deadline on every request while down, where the pool
  breaker answers in microseconds.*

  **Known residual (upstream):** if an endpoint *blackholes* SYNs rather
  than refusing them, each dial burns NIO's 10-second `connectTimeout`,
  which valkey-swift does not expose (`ValkeyConnectionFactory`'s
  `customHandler` hook is `package`-scoped), so the breaker cannot trip
  before ~20 s. `min_connections: 1` moves that cost to startup for a
  server that is already unreachable, but a mid-flight blackhole can still
  stall calls. The fix belongs upstream — a `connectTimeout` on
  `ValkeyConnectionConfiguration` — not in a per-call guard here.

- **CV2 — the two breakers have separate jobs, and only one counts
  command failures.** The driver's pool breaker owns *connection* health:
  it is authoritative, self-healing, fails in microseconds once open, and
  provably cannot trip while any connection is alive (`idle + leased == 0`
  is required), so pool saturation under load never trips it. This
  adapter's breaker owns what the pool cannot see — a server that accepts
  connections but whose commands time out, §7's "stop paying the timeout
  on every request". `ValkeyCache.classify(_:)` enforces the split:
  `.connectionCreationCircuitBreakerTripped` (the pool already has it, and
  shadowing it would delay recovery), `.cancelled` /
  `.connectionClosedDueToCancellation` (the *caller* went away — a burst of
  client disconnects must not darken the cache for everyone else), and
  `.clientIsShutDown` do **not** count toward it.

- **CV3 — the adapter breaker is half-open, not just cool-off.** After the
  cool-off elapses, exactly one probe is admitted; success re-closes the
  breaker, failure re-arms the full cool-off immediately rather than
  letting a burst through at reopen.

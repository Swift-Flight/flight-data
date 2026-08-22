# Flight Data Valkey

Valkey (and Redis) as a first-class Flight **data store**: typed access to
its data structures, scope-bound connections, and repository-layer
integration. Implements
[`../flight-data-valkey-design.md`](../flight-data-valkey-design.md) on top
of Flight Core and Flight Data Core.

This package is *composition plus stereotypes*, not a from-scratch client
(design §2): the driver and wire protocol are **valkey-swift** — concurrency-
native, Valkey/Redis compatible, its command coverage generated from Valkey's
own command specifications. What Flight builds is the seam:

| Piece | Contents |
|---|---|
| `ValkeyDataSource` | The pool, behind Flight Data Core's `DataSource` seam (§4.1): synchronous checkout/release, eager dial at service start, broken-connection replacement, `PING` liveness |
| `ValkeyDataModule<Name>` | §6 module wiring: pool + scoped `ValkeyConnection` lease + `DataSourceLiveness`, one generic instantiation per named datasource |
| `ValkeyDataSourceURL` | §3.2 URL parsing — `valkey://` and `redis://` are exact synonyms (`valkeys://`/`rediss://` for TLS), auth, database number |
| `multi { … }` | §5.2: `MULTI`/`EXEC` under its own honest name — an atomic batch, deliberately **not** `@Transactional` |
| `command("…", …)` | §4.3 escape hatch: raw commands, outside the §3.1 compatibility guarantee |
| `apply(_:to:)` | §5.3: changeset `ValidatedChanges` → `HSET` of exactly the changed fields (`HDEL` for nil), same neutral seam the Postgres driver consumes |

The typed command surface (`hset`, `expire`, `zadd`, …) is the **driver's
own** generated `ValkeyClientProtocol` extension — this package adds only two
spelling conveniences (`expire(_:after:)` with a `Duration`, `zrevrange` with
typed scores) and deliberately does not re-wrap hundreds of commands.

## Build status

**Builds and passes all tests** — verified 2026-07-19 against Swift 6.2.3 on
Linux (x86_64): 59 tests green, the integration suites running against **both
a real Valkey 8 and a real Redis 7** (§8's compatibility check): pool
lifecycle and broken-connection replacement, scope-bound checkout through the
real `@Repository`/`@Autowired` macro path, the typed surface, `multi`
semantics (including the no-rollback per-slot failure test), the raw-command
hatch, and changeset apply.

## Using it

```swift
try await bootstrap(configuration: .load(), modules: [
    ValkeyDataModule<PrimaryDataSource>.self,
])
```

```yaml
datasource:
  valkey:
    url: "valkey://localhost:6379"   # or redis:// — same client, same behavior
    pool_size: 10
```

```swift
@Repository(scope: .scoped)
struct SessionRepository {
    @Autowired var valkey: ValkeyConnection

    func store(_ session: Session, ttl: Duration) async throws {
        try await valkey.hset("session:\(session.id)", data: session.fields)
        try await valkey.expire("session:\(session.id)", after: ttl)
    }

    func leaderboard(top n: Int) async throws -> [(String, Double)] {
        try await valkey.zrevrange("leaderboard", 0, n - 1, withScores: true)
    }
}
```

Atomic batches (not transactions — §5.2):

```swift
try await valkey.multi { batch in
    batch.incr("counter")
    batch.expire("counter", after: .seconds(3600))
}   // atomic batch — NOT a rollback-capable transaction
```

Escape hatch (§4.3 — informed choice, outside the compatibility guarantee):

```swift
try await valkey.command("JSON.SET", "doc:1", "$", jsonPayload)   // Redis-only; §3.1 applies
```

Changesets (§5.3):

```swift
let changeset = Changeset(original: session)
    .change(\.loginCount, 4)
    .change(\.ipAddress, nil)          // → HDEL
try await valkey.apply(changeset.validatedChanges(), to: Session.self)
// → MULTI { HSET session:<id> login_count 4; HDEL session:<id> ip_address } EXEC
```

## Running the tests

Unit tests need nothing. Integration tests are gated per server and run the
same code against every server you configure — that duality **is** the §3.1
compatibility test:

```
$ docker run -d --name flight-data-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
$ docker run -d --name flight-data-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
$ export FLIGHT_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
$ export FLIGHT_REDIS_TEST_URL="redis://127.0.0.1:56380"
$ swift test
```

CI should set both variables. The suites `FLUSHDB` between tests — point them
at throwaway servers only.

## Design deltas

Discovered while implementing; each is a deliberate deviation from (or
refinement of) the design doc, in its spirit.

- **V1 — the pool is lender tasks parked inside the driver's scoped lending.**
  The doc's §4.1 assumes connections can be checked out of the client.
  valkey-swift exposes *only* scoped lending (`withConnection`); its
  `connect()` is internal. The seam still needs synchronous `checkout()`
  (Flight Data Core delta D1), so — the same resolution as Data Postgres's
  delta P1 — this package owns a fixed pool: each slot is a task that dials
  through the public `ValkeyConnection.withConnection` and parks, leaving its
  connection in a Mutex-guarded free list; retiring a connection (broken, or
  shutdown) resumes the lender and the driver closes it. `onClose` (public)
  is the broken-connection signal; a replacement dial follows. Connections
  are dialed directly per-slot rather than through a `ValkeyClient`, because
  a scope-pinned connection cannot participate in cluster-mode per-command
  routing anyway (§9: no cluster orchestration in v1 — apps wanting cluster
  routing should hold a `ValkeyClient` themselves).

- **V2 — a checked-out connection can die unnoticed for one command.** The
  driver has no public `isClosed`, so a connection that dies between the
  close event and its `onClose` callback can be checked out once and fail its
  first command. The failure is loud, the connection is retired at release,
  and the pool refills — the same eventual posture as the Postgres pool's
  `isClosed` race, one command wider.

- **V3 — `expire(_:after:)` sends `PEXPIRE`.** The doc spells
  `expire(key, after: ttl)`; the wire command takes whole seconds. The sugar
  takes a `Duration` and sends `PEXPIRE` (milliseconds, clamped up so a
  positive sub-millisecond TTL never becomes "delete now"). Also:
  `Duration` has no `.hours` in the standard library — the doc's
  `.hours(1)` is spelled `.seconds(3600)`.

- **V4 — `zrevrange` sugar sends `ZRANGE … REV`.** `ZREVRANGE` is deprecated
  server-side; the doc's spelling is kept as sugar over its replacement, with
  the `withScores: true` overload returning `[(String, Double)]` as written.

- **V5 — changeset key derivation.** §5.3 says "an `HSET` of exactly the
  changed fields" but a hash needs a key. Convention:
  `<tableName>:<pk>[:<pk>…]` — identity values for updates, the changed
  fields' primary-key values for inserts (missing → a loud
  `missingKeyField`), with an explicit-key override on `apply(_:to:key:)`.
  Fields set to nil become `HDEL`; when a write needs both `HSET` and `HDEL`
  they ride in one `MULTI` batch.

- **V6 — no keepalive on pooled connections.** Parked connections idle
  silently (the driver's keepalive lives in its own pool, which delta V1
  bypasses). Servers with a non-zero `timeout` will drop idle connections;
  the pool notices via `onClose` and redials. The default server timeout
  (0 = never) makes this moot.

## Boundary notes (§1.1, §7, §9)

No caching abstraction, no PubSub, no migrations, no `@Transactional` (the
module registers **no** transaction coordinator — asserted by test), no
vendor-specific commands in the guaranteed surface, no RediStack shim, no
cluster topology management.

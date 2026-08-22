# Flight Cache

Declarative caching for Flight: annotate a method and its results are cached
and served from cache on subsequent calls with the same inputs — Spring's
`@Cacheable`/`@CacheEvict`/`@CachePut` analogue with **compile-time
expansion in place of runtime proxies**. Implements
[`../flight-cache-design.md`](../flight-cache-design.md) (as revised
2026-08-22, §13) on top of Flight Core.

| Piece | Contents |
|---|---|
| `Cache` + `CacheKey` | §2: the entire cross-store seam — four async, non-throwing, `Data`-valued methods; injective, prefix-safe key encoding |
| `@Cacheable` / `@CacheEvict` / `@CachePut` | §3: body macros expanding INTO the method body — no proxy, so self-invocation caches (the Spring footgun that cannot occur here) |
| `CacheKeyContributing` | §4: explicit, compiler-checked key derivation; primitives ship, custom types conform deliberately |
| `CacheCodec` / `JSONCacheCodec` | §5: Codable values, JSON by default, decode failure = miss |
| `CacheRuntime` + `FlightCaches` | §3.1/§11: the runtime the expansions call, reached through a `FlightTransactions`-style seam (task-local override → installed runtime → warn-once no-op) |
| `SingleFlight` | §8: local stampede protection — leader computes inline, waiters receive the encoded bytes, errors propagate, cancellation hands leadership over |
| `InMemoryCache` | §10.1: actor-guarded `OrderedDictionary` LRU with TTL, bounded by default |
| `FlightCacheModule` | §11: compose-by-presence — an adapter registered under `FlightCacheModule.storeQualifier` wins, else in-memory |
| `FlightCacheTesting` | `RecordingCache` — recording, seedable, `misbehave()`-able store for consumer tests |

The Valkey/Redis adapter is
[`../flight-cache-valkey`](../flight-cache-valkey) — a **separate package**
that this one knows nothing about (design §2.1).

## Build status

**Builds and passes all tests** — verified 2026-08-22 against Swift 6.2.3 on
Linux (x86_64): 51 tests green (11 macro-expansion fixtures, 40 runtime
tests), including the real-macro end-to-end suite (self-invocation caching,
`@CachePut`/`@CacheEvict` targeting `@Cacheable` entries across methods,
fail-open with no runtime installed) and the §8 single-flight suite
(coalescing, shared errors, leader-cancellation handover).

## Using it

```swift
try await bootstrap(configuration: .load(), modules: [
    FlightCacheModule.self,          // in-memory by default
    // FlightCacheValkeyModule.self, // …or the Valkey/Redis store
])
```

```swift
@Service
final class PricingService {
    @Autowired var repository: PriceRepository

    @Cacheable(namespace: "prices", ttl: .seconds(900))
    func price(for productID: ProductID, in region: Region) async throws -> Price {
        try await repository.computePrice(productID, region)
    }

    @CacheEvict(namespace: "prices", allEntries: true)
    func invalidateAll() async {}

    @CachePut(namespace: "prices", ttl: .seconds(900), excluding: ["price"])
    func overridePrice(for productID: ProductID, in region: Region, to price: Price) async throws -> Price {
        try await repository.store(productID, region, price)
    }
}
```

```yaml
cache:
  default_ttl: 300          # integer seconds; 0 = no default
  namespaces:
    prices: 900             # lowercase/digits/underscores — see design §6 R4
  memory:
    max_entries: 10000      # the in-memory adapter's LRU bound
```

Key-contributing parameter types conform explicitly:

```swift
extension ProductID: CacheKeyContributing {
    var cacheKeyRepresentation: String { rawValue }   // or the RawRepresentable default
}
```

## Design deltas

Discovered while implementing; each is a deliberate refinement of the
(already-revised) design doc, in its spirit.

- **C1 — two runtime entry points per annotation shape, selected by the
  macro.** A non-throwing async method body cannot ride a `throws` closure
  parameter without poisoning the enclosing signature, so `CacheRuntime`
  ships throwing and non-throwing `cacheable(...)` overloads and the
  expansion emits `try await`/`await` to match. The non-throwing waiter
  cannot rethrow a throwing leader's error (possible only via a
  cross-method shared key), so it computes directly instead.
- **C2 — typed throws is rejected at the annotation site.** §8's shared
  failure semantics propagate waiter errors as `any Error`; a
  `throws(SpecificError)` method could not re-throw them. Diagnosed, not
  silently mis-expanded.
- **C3 — `FlightCaches` layers a task-local override over the installed
  global.** The design named only the seam; tests need scoped runtimes
  (`FlightCaches.$override.withValue`), and a process-global alone would
  make parallel test isolation impossible. Order: override → installed →
  warn-once no-op.
- **C4 — the empty key segment escapes to `\e`.** §2's encoding spec left
  one collision open (`parts: []` vs `parts: [""]` both rendering a bare
  prefix); a reserved marker for the empty segment closes it while keeping
  the common case (`prices:123:eu`) readable in the store.
- **C5 — metric counters are memoized per namespace.** swift-metrics
  creates a backend handler per `Counter(label:dimensions:)` construction;
  hot cache paths would otherwise construct one per call.
- **C6 — `SingleFlight` makes coalescing observable.**
  `coalescedCount(on:)` and `waitUntilCoalescing(_:on:)` exist because a
  waiter is suspended *inside* `join`, so nothing it does can announce that
  it arrived. Without an explicit signal, any test wanting "a leader and
  then a waiter, in that order" has to sleep and hope — a race dressed up
  as a delay, which silently stops testing the intended interleaving on a
  loaded machine. The concurrency suite now establishes every ordering by
  signal and contains no sleeps.

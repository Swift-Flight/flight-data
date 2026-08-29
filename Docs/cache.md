# Flight Cache

Declarative caching for Flight: annotate a method and its results are cached
and served from cache on subsequent calls with the same inputs — Spring's
`@Cacheable`/`@CacheEvict`/`@CachePut` analogue with **compile-time expansion
in place of runtime proxies**, on top of Flight Core.

| Piece | Contents |
|---|---|
| `Cache` + `CacheKey` | The entire cross-store seam — four async, non-throwing, `Data`-valued methods; injective, prefix-safe key encoding |
| `@Cacheable` / `@CacheEvict` / `@CachePut` | Body macros expanding INTO the method body — no proxy, so self-invocation caches (the Spring footgun that cannot occur here) |
| `CacheKeyContributing` | Explicit, compiler-checked key derivation; primitives ship, custom types conform deliberately |
| `CacheCodec` / `JSONCacheCodec` | Codable values, JSON by default, decode failure = miss |
| `CacheRuntime` + `FlightCaches` | The runtime the expansions call, reached through a `FlightTransactions`-style seam (task-local override → installed runtime → warn-once no-op) |
| `SingleFlight` | Local stampede protection — leader computes inline, waiters receive the encoded bytes, errors propagate, cancellation hands leadership over |
| `InMemoryCache` | Actor-guarded LRU with TTL, bounded by default; hit, insert and evict are all O(1) |
| `FlightCacheModule` | Compose-by-presence — an adapter registered under `FlightCacheModule.storeQualifier` wins, else in-memory |
| `FlightCacheTesting` | `RecordingCache` — recording, seedable, `misbehave()`-able store for consumer tests |

The Valkey/Redis adapter is [`FlightCacheValkey`](cache-valkey.md), a target
in **this** package behind the `Valkey` trait. It was a separate package
once, and this page said so long after it stopped being true; the traits are
what make co-location free — a consumer that does not enable `Valkey`
resolves none of its dependencies.

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
    prices: 900             # lowercase/digits/underscores only
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
package's intent, in its spirit.

- **C1 — two runtime entry points per annotation shape, selected by the
  macro.** A non-throwing async method body cannot ride a `throws` closure
  parameter without poisoning the enclosing signature, so `CacheRuntime`
  ships throwing and non-throwing `cacheable(...)` overloads and the
  expansion emits `try await`/`await` to match. The non-throwing waiter
  cannot rethrow a throwing leader's error (possible only via a
  cross-method shared key), so it computes directly instead.
- **C2 — typed throws is rejected at the annotation site.** The shared
  failure semantics propagate waiter errors as `any Error`; a
  `throws(SpecificError)` method could not re-throw them. Diagnosed, not
  silently mis-expanded.
- **C3 — `FlightCaches` layers a task-local override over the installed
  global.** The design named only the seam; tests need scoped runtimes
  (`FlightCaches.$override.withValue`), and a process-global alone would
  make parallel test isolation impossible. Order: override → installed →
  warn-once no-op.
- **C4 — the empty key segment escapes to `\e`.** The plain escaping rule
  left one collision open (`parts: []` vs `parts: [""]` both rendering a
  bare prefix); a reserved marker for the empty segment closes it while
  keeping the common case (`prices:123:eu`) readable in the store.
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
- **C7 — the LRU order is a hand-rolled intrusive list.** `InMemoryCache`
  used an `OrderedDictionary`, refreshing recency by removing the key and
  reinserting it. That reads as O(1) and is not: an ordered dictionary keeps
  keys and values in dense arrays, so removing anything but the last element
  shifts everything after it — at the default 10,000-entry bound, every
  **hit** paid a ~10,000-element double-array shift. A doubly-linked list
  threaded through the entries makes touch, insert and evict pointer
  rewrites.

## What a hit actually costs

Worth knowing before sizing anything: an in-memory hit is not free, and not
because of the store. Values cross the `Cache` seam as `Data`, so every hit
pays a JSON decode, and the decoder is constructed per call. That is
deliberate — waiters in a single flight receive encoded bytes, and the
in-memory adapter behaving exactly like the Valkey one is what makes swapping
them a configuration change rather than a behaviour change — but it means the
in-memory adapter is a *cache*, not a memoization table. Caching a value that
is expensive to decode and cheap to compute is a loss.

## `@CachePut` and nil

`@CachePut` always overwrites, and that includes nil: a body returning nil
**evicts** the entry rather than leaving what was there. It used to skip the
write and leave the old value, so a method that had just removed something
handed the removed thing back to the next reader.

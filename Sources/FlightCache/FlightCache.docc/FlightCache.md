# ``FlightCache``

Caching as an annotation, with the parts that are actually hard handled
underneath.

## Overview

The easy part of caching is `get`, `set`, and a TTL. The hard parts are key
derivation that survives a refactor, invalidation that fires on the right
writes, and what happens when a hundred requests miss the same key at once.
This module is mostly about the hard parts:

```swift
@Service
final class PriceService: Sendable {
    @Cacheable(namespace: "prices", ttl: .seconds(900))
    func price(for sku: String, in currency: Currency) async throws -> Price {
        try await api.fetch(sku, currency)
    }

    @CacheEvict(namespace: "prices", allEntries: true)
    func invalidateAll() async throws { ... }
}
```

The key comes from the function's parameters, so renaming a parameter or
changing its type changes the key rather than silently colliding with the old
one. ``CacheKeyContributing`` is how a custom type says what part of itself
belongs in a key, and `excluding:` drops a parameter that should not
participate — a trace ID, a logger, anything that varies per call without
changing the answer.

## The thundering herd

``SingleFlight`` is the reason `@Cacheable` is worth using over a hand-rolled
`get`-then-`set`. When N callers miss the same key simultaneously, one
computes and the rest wait on that result. Without it, a cold cache turns a
traffic spike into N identical database queries — which is exactly when the
database can least afford them.

## Backends

``Cache`` is the protocol. ``InMemoryCache`` is process-local and is what a
single node uses; `FlightCacheValkey` is the shared one. ``NoopCache``
disables caching without removing the annotations, which is what a test that
wants deterministic behaviour actually needs.

``CacheCodec`` decides how values serialize — ``JSONCacheCodec`` by default,
replaceable when the payload deserves something denser.

## Expiry is policy, not a magic number

``CacheTTLPolicy`` centralizes TTLs so they live in configuration rather than
scattered across annotations. ``CacheRuntime`` is what the annotations
actually call, and ``FlightCaches`` names the configured caches when an
application has more than one.

## Topics

### Annotations

- ``Cacheable(namespace:ttl:excluding:)``
- ``CachePut(namespace:ttl:excluding:)``
- ``CacheEvict(namespace:allEntries:excluding:)``

### Keys

- ``CacheKey``
- ``CacheKeyContributing``

### Backends

- ``Cache``
- ``InMemoryCache``
- ``NoopCache``
- ``CacheCodec``
- ``JSONCacheCodec``

### Policy and runtime

- ``CacheTTLPolicy``
- ``CacheRuntime``
- ``SingleFlight``
- ``FlightCaches``

### Hosting

- ``FlightCacheModule``
- ``CacheConfigKey``
- ``CacheConfigurationError``

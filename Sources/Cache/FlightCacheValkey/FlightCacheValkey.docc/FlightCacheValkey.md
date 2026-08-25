# ``FlightCacheValkey``

The shared cache backend: `FlightCache` over Valkey.

## Overview

`FlightCache`'s annotations do not change. Registering
``FlightCacheValkeyModule`` swaps the in-memory backend for ``ValkeyCache``,
and `@Cacheable` starts writing somewhere every node can read:

```yaml
cache:
  valkey:
    url: redis://localhost:6379
    namespace: app
```

That is the whole point of `Cache` being a protocol. A single node develops
against `InMemoryCache` and a deployment shares one, with no call site
changing.

## Namespacing is not optional

``ValkeyCacheSettings`` carries a key prefix, and it matters more here than
in the in-memory case: a shared Valkey instance is shared with everything
else that uses it. Two applications caching under bare `prices` keys are one
deployment away from serving each other's data.

``ValkeyCacheURL`` validates the URL at bootstrap;
``ValkeyCacheConfigurationError`` is what a malformed one produces, during
startup rather than at the first cache read.

## Eviction crosses nodes

`@CacheEvict` on a shared cache invalidates for every node at once, which is
the behaviour a distributed deployment actually needs and the one an
in-memory cache cannot provide. It is also why a stale entry in a shared
cache is a worse bug than a stale entry in a local one: it is stale
everywhere, until its TTL.

## Topics

### The backend

- ``FlightCacheValkeyModule``
- ``ValkeyCache``

### Configuration

- ``ValkeyCacheSettings``
- ``ValkeyCacheURL``
- ``ValkeyCacheConfigKey``

### Failure

- ``ValkeyCacheConfigurationError``
- ``ValkeyCacheURLError``

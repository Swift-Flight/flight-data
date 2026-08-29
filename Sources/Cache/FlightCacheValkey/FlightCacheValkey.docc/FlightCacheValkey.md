# ``FlightCacheValkey``

The shared cache backend: `FlightCache` over Valkey.

## Overview

`FlightCache`'s annotations do not change. Registering
``FlightCacheValkeyModule`` swaps the in-memory backend for ``ValkeyCache``,
and `@Cacheable` starts writing somewhere every node can read:

```yaml
cache:
  valkey:
    url: redis://localhost:6379/2    # the path segment is the database index
    command_timeout_ms: 250
    unreachable_after_ms: 250
    pool_size: 20
    min_connections: 1
```

That is the whole point of `Cache` being a protocol. A single node develops
against `InMemoryCache` and a deployment shares one, with no call site
changing.

## Sharing one Valkey with something else

Every key is stored under a fixed `flight-cache:` prefix followed by
`CacheKey.storageKey` — so `flight-cache:prices:123:eu` is greppable in a
store that also holds non-cache data.

**The prefix is fixed and there is no `namespace` setting.** This page
described one for a while; it never existed. Two applications pointed at the
same server *and* the same database index therefore share a key space: the
same namespace with the same arguments is the same key, and one app will serve
the other's cached value. Separate them with the URL's database index —
`redis://host:6379/2`, as above — or with separate servers. Distinct
`cache.namespaces` names also work, but by convention only, and only until
someone picks `users` twice.

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

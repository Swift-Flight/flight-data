/// The declarative caching annotations — body macros (SE-0415),
/// the same expansion model as Core's `@Transactional`: the caching logic
/// expands INTO the method body, so there is no proxy and no
/// self-invocation footgun.
///
/// Shared constraints, diagnosed at the annotation site:
/// - the method must be `async` (the `Cache` protocol is async);
/// - `@Cacheable`/`@CachePut` methods must return a `Codable & Sendable`
///   value;
/// - a function takes at most ONE body macro — `@Cacheable` and
///   `@Transactional` do not compose on a single method;
/// - `excluding:` names must match parameter names (the internal name —
///   `for productID:` excludes as `"productID"`).

/// Check cache; on hit return it; on miss call the body, store the result
/// under `namespace` + the key-contributing arguments, return it.
/// Concurrent same-key callers coalesce.
///
/// `ttl: nil` defers to the policy: `cache.namespaces.<namespace>`, then
/// `cache.default_ttl`, then no expiry.
@attached(body)
public macro Cacheable(namespace: String, ttl: Duration? = nil, excluding: [String] = []) =
    #externalMacro(module: "FlightCacheMacrosImpl", type: "CacheableMacro")

/// Call the body; on normal return (not on a throw) remove the entry
/// derived from the arguments — or the whole namespace with
/// `allEntries: true`. The flag is explicit: `allEntries: false` with
/// zero key-contributing parameters is a compile error, never an implicit
/// namespace wipe.
@attached(body)
public macro CacheEvict(namespace: String, allEntries: Bool = false, excluding: [String] = []) =
    #externalMacro(module: "FlightCacheMacrosImpl", type: "CacheEvictMacro")

/// Always call the body, then overwrite the cached value. Distinct from
/// `@Cacheable`: it never short-circuits. Remember `excluding:` for the
/// new-value parameter — it is not part of the entry's identity.
@attached(body)
public macro CachePut(namespace: String, ttl: Duration? = nil, excluding: [String] = []) =
    #externalMacro(module: "FlightCacheMacrosImpl", type: "CachePutMacro")

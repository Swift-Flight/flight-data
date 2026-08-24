// The flight-data half of the API shapes Docs cover, compiled by the build.
//
// A page that shows an API is a claim about it. Compiling the shapes makes a
// signature change break the build rather than only mislead a reader.
import FlightCache
import FlightCacheTesting
import FlightCore
import FlightDataCore
import FlightDataTesting
import Foundation

func dataTestingShapes() async {
    // A working in-memory cache that also records what was asked of it, so a
    // test can assert something was cached rather than only that it returned
    // the right value.
    let cache = RecordingCache()
    let key = CacheKey(namespace: "prices", parts: ["eu"])
    await cache.set(key, value: Data("42".utf8), ttl: .seconds(60))
    _ = await cache.get(key)
    await cache.evict(key)
    await cache.evictNamespace("prices")
}

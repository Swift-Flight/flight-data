import FlightCore

/// Module wiring (design §11), following PubSub's compose-by-presence
/// pattern:
///
/// ```swift
/// try await bootstrap(configuration: .load(), modules: [
///     FlightCacheModule.self,
///     FlightCacheValkeyModule.self,   // optional adapter; omit for in-memory
/// ])
/// ```
///
/// `configure(_:)` registers:
///
/// 1. `InMemoryCache` — the §10.1 default store, `.singleton`, its LRU
///    bound read from `cache.memory.max_entries` at `freeze()` so a bad
///    value fails bootstrap;
/// 2. the unqualified `(any Cache)` — resolves an adapter registered under
///    `storeQualifier` if one is present (catching only
///    `ResolutionError.notRegistered`), else the in-memory store. Absent
///    adapter module = single-instance deployment, the common case;
/// 3. `CacheRuntime` — store + TTL policy + codec + single-flight +
///    metrics. Its factory **installs the runtime into the `FlightCaches`
///    seam** (§3.1) — the factory runs at `freeze()`, so annotated methods
///    are served from the first request.
///
/// No `service`: the in-memory store has no long-running work. Adapter
/// modules with a connection (the Valkey client) expose their own.
public struct FlightCacheModule: FlightModule {
    /// Adapter modules register their store as `(any Cache).self` under
    /// this qualifier; `FlightCacheModule` composes by its presence.
    public static let storeQualifier = "flight.cache.store"

    public init() {}

    public func configure(_ container: Container) throws {
        container.register(InMemoryCache.self, scope: .singleton) { container in
            let configuration = try container.resolve(Configuration.self)
            let maxEntries =
                try configuration.getIfPresent(CacheConfigKey.memoryMaxEntries, as: Int.self)
                ?? InMemoryCache.defaultMaxEntries
            guard maxEntries > 0 else {
                throw CacheConfigurationError.invalidMaxEntries(maxEntries)
            }
            return InMemoryCache(maxEntries: maxEntries)
        }

        container.register((any Cache).self, scope: .singleton) { container in
            do {
                return try container.resolve((any Cache).self, qualifier: Self.storeQualifier)
            } catch let error as ResolutionError {
                // Absent adapter = in-memory deployment, the common case.
                // Any other resolution failure is a real wiring bug.
                guard case .notRegistered = error else { throw error }
                return try container.resolve(InMemoryCache.self)
            }
        }

        container.register(CacheRuntime.self, scope: .singleton) { container in
            let runtime = try CacheRuntime(
                store: try container.resolve((any Cache).self),
                configuration: try container.resolve(Configuration.self)
            )
            FlightCaches.install(runtime)
            return runtime
        }
    }
}

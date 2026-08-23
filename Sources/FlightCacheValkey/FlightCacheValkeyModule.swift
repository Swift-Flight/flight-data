import FlightCache
import FlightCore
import ServiceLifecycle

/// The adapter module:
///
/// ```swift
/// try await Flight.bootstrap(configuration: .load(), modules: [
///     FlightCacheModule.self,          // pulled in via dependencies anyway
///     FlightCacheValkeyModule.self,
/// ])
/// ```
///
/// `configure(_:)` registers `ValkeyCache` (settings read at the factory,
/// which runs at `freeze()` — a bad URL fails bootstrap, never the first
/// request) and exposes it as `(any Cache)` under
/// `FlightCacheModule.storeQualifier`, which is all it takes for
/// `FlightCacheModule` to choose it over the in-memory default ('s
/// compose-by-presence).
///
/// `service` runs the driver's own client pool — `ValkeyClient` is already
/// a ServiceLifecycle `Service` whose `run()` handles graceful shutdown.
/// Its health rides the module row in Actuator ( R5).
public final class FlightCacheValkeyModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [FlightCacheModule.self] }

    /// Stashed during `configure` so `service` can resolve the cache
    /// lazily — modules cannot resolve during the registration phase
    /// (Flight Core).
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container

        container.register(ValkeyCache.self, scope: .singleton) { container in
            let configuration = try container.resolve(Configuration.self)
            let settings = try ValkeyCacheSettings.load(from: configuration)
            return try ValkeyCache(settings: settings)
        }

        container.register(
            (any Cache).self, qualifier: FlightCacheModule.storeQualifier, scope: .singleton
        ) { container in
            try container.resolve(ValkeyCache.self)
        }
    }

    public var service: (any Service)? {
        container.map { ValkeyCacheClientService(container: $0) }
    }
}

/// Resolves the cache post-freeze and runs its client pool.
struct ValkeyCacheClientService: Service {
    let container: Container

    func run() async throws {
        let cache = try container.resolve(ValkeyCache.self)
        await cache.client.run()
    }
}

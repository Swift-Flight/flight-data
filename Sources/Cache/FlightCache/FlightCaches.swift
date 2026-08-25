import Logging
import Synchronization

/// The seam the expansions target — Flight Cache's analogue of Core's
/// `FlightTransactions`: Flight Core has no ambient container and a body
/// macro cannot add members, so generated code reaches runtime state
/// through this process-level access point, named fully qualified
/// (`FlightCache.FlightCaches.current`) so it resolves in any client module.
///
/// Three layers, first match wins:
///
/// 1. `override` — a task-local, for tests and for pipelines that need a
///    different runtime scoped to a task tree.
/// 2. The installed runtime — set once by `FlightCacheModule`'s
///    `CacheRuntime` factory at `freeze()`.
/// 3. A no-op fallback over `NoopCache` — a `@Cacheable` method in an app
///    that never installed `FlightCacheModule` computes every call: a
///    warn-once log, not an error. The unwired cache fails open like every
///    other cache failure.
public enum FlightCaches {
    /// Task-local override — tests bind it with
    /// `FlightCaches.$override.withValue(runtime) { ... }`.
    @TaskLocal public static var override: CacheRuntime?

    private static let installed = Mutex<CacheRuntime?>(nil)
    private static let warnedUnwired = Mutex<Bool>(false)
    private static let noop: CacheRuntime = {
        // Constructing over NoopCache with no configuration cannot throw.
        try! CacheRuntime(store: NoopCache(), configuration: nil)
    }()

    /// The runtime the expansions use for this call.
    public static var current: CacheRuntime {
        if let override { return override }
        if let runtime = installed.withLock({ $0 }) { return runtime }
        warnUnwiredOnce()
        return noop
    }

    /// Installs the process-wide runtime. `FlightCacheModule` calls this
    /// from the `CacheRuntime` singleton factory; a second install (another
    /// bootstrap in the same process — tests, mostly) replaces the first.
    public static func install(_ runtime: CacheRuntime) {
        installed.withLock { $0 = runtime }
    }

    /// Clears the installed runtime — test isolation only.
    public static func uninstall() {
        installed.withLock { $0 = nil }
    }

    /// Whether a runtime is installed (introspection for tests and
    /// diagnostics; the task-local override does not count).
    public static var isInstalled: Bool {
        installed.withLock { $0 != nil }
    }

    private static func warnUnwiredOnce() {
        let shouldWarn = warnedUnwired.withLock { warned -> Bool in
            defer { warned = true }
            return !warned
        }
        if shouldWarn {
            Logger(label: "flight.cache").warning(
                "a cache annotation ran but no cache runtime is installed — every call computes. Add FlightCacheModule to bootstrap's modules to enable caching."
            )
        }
    }
}

import FlightCache
import FlightCore
import Testing

@testable import FlightCacheValkey

/// Serialized: assembling FlightCacheModule installs into the process-global
/// FlightCaches seam.
@Suite("FlightCacheValkeyModule — §11 wiring", .serialized)
struct ModuleRegistrationTests {

    @Test("the Valkey store wins the compose-by-presence choice")
    func adapterChosen() throws {
        defer { FlightCaches.uninstall() }
        // Construction parses eagerly but dials only when the service runs
        // (nothing listens on port 5).
        let application = try assemble(
            configuration: Configuration(values: ["cache.valkey.url": "valkey://localhost:5"]),
            modules: [FlightCacheValkeyModule.self])
        let store = try application.container.resolve((any Cache).self)
        #expect(store is ValkeyCache)
        #expect(FlightCaches.isInstalled)
        // The adapter contributed its client service to the group.
        #expect(application.services.contains { $0.moduleName == "FlightCacheValkeyModule" })
    }

    @Test("a malformed URL fails bootstrap, never the first command")
    func badURLFailsBootstrap() {
        defer { FlightCaches.uninstall() }
        #expect(throws: (any Error).self) {
            _ = try assemble(
                configuration: Configuration(values: ["cache.valkey.url": "http://nope"]),
                modules: [FlightCacheValkeyModule.self])
        }
    }

    @Test("a missing URL fails bootstrap with a config error")
    func missingURLFailsBootstrap() {
        defer { FlightCaches.uninstall() }
        #expect(throws: (any Error).self) {
            _ = try assemble(configuration: Configuration(), modules: [FlightCacheValkeyModule.self])
        }
    }
}

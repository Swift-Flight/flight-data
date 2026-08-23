import FlightCore

/// §7: a thin wrapper producing a frozen `Container` from a set of modules
/// without going through full `ServiceGroup` bootstrap — scoping and
/// lifecycle logic don't need real services running.
///
///     let container = try TestContainer.build { InMemoryDataModule<PrimaryDataSource>() }
///
/// Declared module dependencies are honored: instantiated (via `init()`) and
/// configured first, in DAG order, exactly as real bootstrap would.
///
/// Deliberately identical to `FlightWebTesting.TestContainer` — a data test
/// must not need the web package to get a container. If a test target
/// imports both testing libraries, qualify the name
/// (`FlightDataTesting.TestContainer`); hoisting this into a shared
/// flight-testing package is the recorded follow-up (README, delta D6).
public enum TestContainer {

    /// Lets `build { InMemoryDataModule<PrimaryDataSource>() }` and
    /// multi-statement module lists read naturally at test sites.
    @resultBuilder
    public enum ModuleBuilder {
        public static func buildBlock(_ modules: any FlightModule...) -> [any FlightModule] {
            modules
        }
    }

    public static func build(
        configuration: Configuration = Configuration(),
        @ModuleBuilder _ modules: () -> [any FlightModule]
    ) throws -> Container {
        let instances = modules()
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in configuration }

        // Same ordering rules as bootstrap (Flight Core §7 step 5), with the
        // caller's ready-made instances substituted where types match.
        let byType = Dictionary(
            instances.map { (ObjectIdentifier(type(of: $0)), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ordered = try Flight.resolveModuleOrder(instances.map { type(of: $0) })
        for moduleType in ordered {
            let module = byType[ObjectIdentifier(moduleType)] ?? moduleType.init()
            try module.configure(container)
        }

        try container.freeze()
        return container
    }

    /// A frozen, empty container (plus optional configuration) — enough for
    /// tests that only need `Configuration` or hand-registered components.
    public static func empty(configuration: Configuration = Configuration()) -> Container {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in configuration }
        // An empty registration set cannot fail eager singleton construction.
        try! container.freeze()
        return container
    }
}

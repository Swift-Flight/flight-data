// swift-tools-version: 6.1
// Flight Data Valkey — Valkey (and Redis) as a first-class Flight data store:
// typed access to its data structures, scope-bound connections, and
// repository-layer integration. See README.md for the decisions made
// during implementation.
import PackageDescription

let package = Package(
    name: "flight-data-valkey",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core and
        // flight-data-core (and valkey-swift's own `valkeySwift 1.0`
        // availability). Linux with a Swift 6.1+ toolchain is unaffected.
        .macOS(.v15)
    ],
    products: [
        // The Flight package: ValkeyDataSource (the pool), ValkeyDataModule,
        // the `multi` batch, the raw-command escape hatch, and
        // changeset apply.
        .library(name: "FlightDataValkey", targets: ["FlightDataValkey"])
    ],
    dependencies: [
        // FlightCore re-exports FlightConfig; FlightDataCore supplies the
        // DataSource seam this package plugs into.
        .package(path: "../../Core/flight-core"),
        .package(path: "../../Data/flight-data-core"),
        // The driver: valkey-swift — concurrency-native, Valkey/Redis
        // compatible, command coverage generated from Valkey's own command
        // specifications. NOT RediStack (deprecated, pre-concurrency).
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
    ],
    targets: [
        .target(
            name: "FlightDataValkey",
            dependencies: [
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightDataCore", package: "flight-data-core"),
                .product(name: "Valkey", package: "valkey-swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightDataValkeyTests",
            dependencies: [
                "FlightDataValkey",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightDataCore", package: "flight-data-core"),
                .product(name: "FlightDataTesting", package: "flight-data-core"),
                .product(name: "Valkey", package: "valkey-swift"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

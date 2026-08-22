// swift-tools-version: 6.1
// Flight Cache Valkey — the Valkey/Redis-backed Cache adapter
// (flight-cache-design.md §10.2): namespaces as key prefixes, TTL as native
// expiry, a short command timeout and a consecutive-failure breaker for §7
// fail-open behavior.
import PackageDescription

let package = Package(
    name: "flight-cache-valkey",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core and
        // valkey-swift's own `valkeySwift 1.0` availability.
        .macOS(.v15)
    ],
    products: [
        .library(name: "FlightCacheValkey", targets: ["FlightCacheValkey"])
    ],
    dependencies: [
        .package(path: "../../Core/flight-core"),
        // The protocol this adapter implements. NOTE (design §2.1):
        // deliberately NOT flight-data-valkey — a cache adapter needs GET,
        // SET, DEL/UNLINK, and TTL, not repositories, Scope-bound checkout,
        // or DataSource conformance. Shared *library* dependency (the
        // valkey-swift client below), independent *package* dependency.
        .package(path: "../flight-cache"),
        // The driver (Data Valkey §2): valkey-swift — concurrency-native,
        // Valkey/Redis compatible, command coverage generated from Valkey's
        // own command specifications. NOT RediStack (deprecated).
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
    ],
    targets: [
        .target(
            name: "FlightCacheValkey",
            dependencies: [
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightCache", package: "flight-cache"),
                .product(name: "Valkey", package: "valkey-swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightCacheValkeyTests",
            dependencies: [
                "FlightCacheValkey",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightCache", package: "flight-cache"),
                .product(name: "Valkey", package: "valkey-swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

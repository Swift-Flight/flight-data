// swift-tools-version: 6.1
// Flight Cache Valkey — the Valkey/Redis-backed Cache adapter
// Namespaces as key prefixes, TTL as native
// expiry, a short command timeout and a consecutive-failure breaker for
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
        // The protocol this adapter implements. NOTE:
        // deliberately NOT flight-data-valkey — a cache adapter needs GET,
        // SET, DEL/UNLINK, and TTL, not repositories, Scope-bound checkout,
        // or DataSource conformance. Shared *library* dependency (the
        // valkey-swift client below), independent *package* dependency.
        .package(path: "../flight-cache"),
        // The driver (Data Valkey): valkey-swift — concurrency-native,
        // Valkey/Redis compatible, command coverage generated from Valkey's
        // own command specifications. NOT RediStack (deprecated).
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // Declared explicitly: `ValkeyCacheSettings` imports NIOSSL for its
        // TLS configuration. It resolved anyway as a transitive dependency of
        // valkey-swift, which meant this package compiled only for as long as
        // valkey-swift happened to keep depending on it.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
    ],
    targets: [
        .target(
            name: "FlightCacheValkey",
            dependencies: [
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
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

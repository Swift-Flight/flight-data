// swift-tools-version: 6.1
// Flight Cache — declarative caching: @Cacheable/@CacheEvict/@CachePut with
// compile-time expansion, a store-agnostic `Cache` protocol, a bounded
// in-memory adapter, and local single-flight stampede protection.
// See README.md for the design decisions
// discovered during implementation.
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "flight-cache",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core.
        .macOS(.v15)
    ],
    products: [
        // The package: the Cache protocol + CacheKey, the macros,
        // key derivation, codecs, single-flight, the
        // in-memory adapter, and FlightCacheModule.
        .library(name: "FlightCache", targets: ["FlightCache"]),
        // Test support: RecordingCache for consumers (and this package's own
        // suites) to assert cache interactions without a real store.
        .library(name: "FlightCacheTesting", targets: ["FlightCacheTesting"]),
    ],
    dependencies: [
        .package(path: "../../Core/flight-core"),
        // Dependency policy follows Flight Core: Apple-adjacent,
        // SSWG-blessed only.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // Design (R5): flight-core deliberately ships no metrics facade
        // yet, so this is the first Flight runtime package to take
        // swift-metrics directly. Counters only; backend is the app's.
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        //: OrderedDictionary is the LRU order for the in-memory
        // adapter.
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        // swift-syntax bumps its major with each Swift release; the open
        // range is the community convention for macro packages.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        // NOTE: deliberately NOT flight-data-valkey and not
        // any data package — the Valkey-backed adapter is a separate
        // package (flight-cache-valkey) built on the client library alone.
    ],
    targets: [
        .target(
            name: "FlightCache",
            dependencies: [
                "FlightCacheMacrosImpl",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .macro(
            name: "FlightCacheMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "FlightCacheTesting",
            dependencies: ["FlightCache"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightCacheTests",
            dependencies: [
                "FlightCache",
                "FlightCacheTesting",
                .product(name: "FlightCore", package: "flight-core"),
            ]
        ),
        .testTarget(
            name: "FlightCacheMacroTests",
            dependencies: [
                "FlightCacheMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

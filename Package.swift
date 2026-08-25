// swift-tools-version: 6.3
import CompilerPluginSupport
import Foundation
import PackageDescription

// Flight Data: persistence and caching.
//
// The abstractions and the drivers live together because they break together
// — a change to the DataSource contract breaks every adapter at once, and
// keeping them in one package makes that a compile error in CI rather than a
// discovery weeks later in whichever adapter nobody rebuilt.
//
// The heavy drivers are gated behind traits so that co-location costs nothing.
// SwiftPM does not prune a package's dependencies by which product you use,
// but it *does* prune dependencies that no enabled trait reaches. Without
// traits, an application wanting only the in-memory cache would resolve
// PostgresNIO, valkey-swift, NIOSSL, and swift-crypto; with them it resolves
// none of those.
//
//     .package(url: "...flight-data.git", from: "0.1.0")                      // cache + protocols
//     .package(url: "...flight-data.git", from: "0.1.0", traits: ["Postgres"]) // + Postgres
//
// Building this package itself: `swift test --enable-all-traits`.
let package = Package(
    name: "flight-data",
    platforms: [.macOS(.v15)],
    products: [
        // Always available — no database or cache driver required.
        .library(name: "FlightCache", targets: ["FlightCache"]),
        .library(name: "FlightCacheTesting", targets: ["FlightCacheTesting"]),
        .library(name: "FlightDataCore", targets: ["FlightDataCore"]),
        .library(name: "FlightDataTesting", targets: ["FlightDataTesting"]),
        .library(name: "FlightMigrateCore", targets: ["FlightMigrateCore"]),
        .plugin(name: "FlightMigratePlugin", targets: ["FlightMigratePlugin"]),

        // Requires the "Postgres" trait.
        .library(name: "FlightDataPostgres", targets: ["FlightDataPostgres"]),
        .library(name: "FlightSchedulerPostgres", targets: ["FlightSchedulerPostgres"]),
        .library(name: "FlightMigrate", targets: ["FlightMigrate"]),
        .library(name: "FlightMigrateCLI", targets: ["FlightMigrateCLI"]),

        // Requires the "Valkey" trait.
        .library(name: "FlightCacheValkey", targets: ["FlightCacheValkey"]),
        .library(name: "FlightDataValkey", targets: ["FlightDataValkey"]),
        .library(name: "FlightPubSubValkey", targets: ["FlightPubSubValkey"]),
    ],
    traits: [
        // Opt-in: name a driver to get it, and resolve nothing else.
        //
        //     traits: []                    cache and protocols only, no driver
        //     traits: ["Postgres"]          + PostgresNIO, Hangar, migrations
        //     traits: ["Postgres", "Valkey"] both
        //
        // Requires Swift 6.3 or later. Through 6.2.x, SwiftPM did not resolve
        // the gated dependencies of a non-default trait enabled on a
        // *versioned* dependency (swiftlang/swift-package-manager #9286,
        // fixed by #9269) — path dependencies worked, so it only showed up
        // once this package was tagged.
        .default(enabledTraits: []),
        .trait(
            name: "Postgres",
            description: "PostgreSQL data source, migrations, and the migration CLI."
        ),
        .trait(
            name: "Valkey",
            description: "Valkey-backed distributed cache and data source."
        ),
    ],
    dependencies: [
        // traits: [] — flight-data needs only the container and lifecycle,
        // never FlightWeb. Opting out of flight's default "Web" trait keeps
        // Hummingbird, NIO, and the TLS stack out of every consumer that
        // wants a cache or a data source but not an HTTP server.
        .package(url: "https://github.com/Swift-Flight/flight.git", from: "0.2.2", traits: []),
        .package(url: "https://github.com/Swift-Flight/swift-changeset.git", from: "0.1.0"),
        .package(url: "https://github.com/Swift-Flight/hangar.git", from: "0.2.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
        // Reached only through the Postgres trait.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        // Reached only through the Valkey trait.
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
    ],
    targets: [
        // MARK: Cache — no driver required

        .macro(
            name: "FlightCacheMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Cache/FlightCacheMacrosImpl"
        ),
        .target(
            name: "FlightCache",
            dependencies: [
                "FlightCacheMacrosImpl",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            path: "Sources/Cache/FlightCache",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightCacheTesting",
            dependencies: ["FlightCache"],
            path: "Sources/Cache/FlightCacheTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Data protocols — no driver required

        .target(
            name: "FlightDataCore",
            dependencies: [
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Changesets", package: "swift-changeset"),
            ],
            path: "Sources/Data/FlightDataCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightDataTesting",
            dependencies: [
                "FlightDataCore",
                .product(name: "FlightCore", package: "flight"),
            ],
            path: "Sources/Data/FlightDataTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "FlightSchedulerPostgres",
            dependencies: [
                "FlightDataCore",
                "FlightDataPostgres",
                .product(name: "FlightScheduler", package: "flight"),
                // Gated, like every other Postgres-facing target here: an
                // ungated dependency makes a trait-free consumer resolve
                // PostgresNIO, which is exactly what the lean-consumer check
                // exists to catch — and did.
                .product(
                    name: "PostgresNIO", package: "postgres-nio",
                    condition: .when(traits: ["Postgres"])),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Scheduler/FlightSchedulerPostgres",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "FlightPubSubValkey",
            dependencies: [
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightPubSub", package: "flight"),
                .product(
                    name: "Valkey", package: "valkey-swift",
                    condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/PubSub/FlightPubSubValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Migrations — the core and generator are driver-free

        .target(name: "FlightMigrateCore", path: "Sources/Migrate/FlightMigrateCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "flight-migrate-gen",
            dependencies: ["FlightMigrateCore"],
            path: "Sources/Migrate/flight-migrate-gen",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .plugin(
            name: "FlightMigratePlugin",
            capability: .buildTool(),
            dependencies: ["flight-migrate-gen"]
        ),

        // MARK: Postgres — requires the "Postgres" trait

        .target(
            name: "FlightMigrate",
            dependencies: [
                "FlightMigrateCore",
                .product(name: "PostgresNIO", package: "postgres-nio", condition: .when(traits: ["Postgres"])),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Migrate/FlightMigrate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightMigrateCLI",
            dependencies: [
                "FlightMigrate",
                "FlightMigrateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Postgres"])),
            ],
            path: "Sources/Migrate/FlightMigrateCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ExampleMigrations",
            dependencies: ["FlightMigrate"],
            path: "Sources/Migrate/ExampleMigrations",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["FlightMigratePlugin"]
        ),
        .executableTarget(
            name: "flight-migrate-example",
            dependencies: ["FlightMigrateCLI", "ExampleMigrations"],
            path: "Sources/Migrate/flight-migrate-example",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightDataPostgres",
            dependencies: [
                "FlightDataCore", "FlightMigrate",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Hangar", package: "hangar", condition: .when(traits: ["Postgres"])),
                .product(name: "PostgresNIO", package: "postgres-nio", condition: .when(traits: ["Postgres"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Data/FlightDataPostgres",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Valkey — requires the "Valkey" trait

        .target(
            name: "FlightCacheValkey",
            dependencies: [
                "FlightCache",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Cache/FlightCacheValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightDataValkey",
            dependencies: [
                "FlightDataCore",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Data/FlightDataValkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Tests

        .testTarget(
            name: "FlightCacheTests",
            dependencies: [
                "FlightCache", "FlightCacheTesting",
                .product(name: "FlightCore", package: "flight"),
            ],
            path: "Tests/Cache/FlightCacheTests"
        ),
        .testTarget(
            name: "FlightCacheMacroTests",
            dependencies: [
                "FlightCacheMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/Cache/FlightCacheMacroTests"
        ),
        .testTarget(
            name: "FlightDataCoreTests",
            dependencies: [
                "FlightDataCore", "FlightDataTesting",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Data/FlightDataCoreTests"
        ),
        .testTarget(
            name: "FlightMigrateTests",
            dependencies: ["FlightMigrate", "FlightMigrateCore", "FlightMigrateCLI", "ExampleMigrations"],
            path: "Tests/Migrate/FlightMigrateTests"
        ),
        .testTarget(
            name: "FlightSchedulerPostgresTests",
            dependencies: [
                "FlightSchedulerPostgres",
                .product(name: "FlightScheduler", package: "flight"),
            ],
            path: "Tests/Scheduler/FlightSchedulerPostgresTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightDataPostgresTests",
            dependencies: [
                "FlightDataPostgres", "FlightDataCore", "FlightDataTesting", "FlightMigrate",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "PostgresNIO", package: "postgres-nio", condition: .when(traits: ["Postgres"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Data/FlightDataPostgresTests"
        ),
        .testTarget(
            name: "FlightCacheValkeyTests",
            dependencies: [
                "FlightCacheValkey", "FlightCache", "FlightCacheTesting",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
            ],
            path: "Tests/Cache/FlightCacheValkeyTests"
        ),
        .testTarget(
            name: "FlightPubSubValkeyTests",
            dependencies: [
                "FlightPubSubValkey",
                .product(name: "FlightPubSub", package: "flight"),
                .product(
                    name: "Valkey", package: "valkey-swift",
                    condition: .when(traits: ["Valkey"])),
            ],
            path: "Tests/PubSub/FlightPubSubValkeyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightDataValkeyTests",
            dependencies: [
                "FlightDataValkey", "FlightDataCore", "FlightDataTesting",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Data/FlightDataValkeyTests"
        ),
    ]
)

// Documentation tooling only, gated so that consumers never resolve it.
if ProcessInfo.processInfo.environment["FLIGHT_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}

// Strict warnings, opt-in and scoped to Flight's own targets.
//
// `swift build -Xswiftc -warnings-as-errors` cannot be used for this: it
// applies to every module in the build, dependencies included, so a warning
// in third-party code that a newer compiler has already fixed fails the
// build. This setting reaches only the targets declared above.
//
//     FLIGHT_STRICT_WARNINGS=1 swift build --enable-all-traits
if ProcessInfo.processInfo.environment["FLIGHT_STRICT_WARNINGS"] != nil {
    // Plugin targets reject build settings outright.
    for target in package.targets where target.type != .plugin {
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        target.swiftSettings = settings
    }
}

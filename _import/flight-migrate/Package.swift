// swift-tools-version: 6.0
import PackageDescription
import Foundation

let package = Package(
    name: "flight-migrate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The migration library: Migration protocol, SchemaBuilder DSL, FlightMigrator runner.
        .library(name: "FlightMigrate", targets: ["FlightMigrate"]),
        // Ready-made CLI commands. Conform an executable target's @main type to `MigrateTool`.
        .library(name: "FlightMigrateCLI", targets: ["FlightMigrateCLI"]),
        // Build plugin that discovers Migration types in a target and generates `_allMigrations()`.
        .plugin(name: "FlightMigratePlugin", targets: ["FlightMigratePlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
    ],
    targets: [
        // Dependency-free core shared by the library and the build-time generator:
        // checksums, migration filename/timestamp parsing, source scanning, registry generation.
        .target(
            name: "FlightMigrateCore"
        ),

        // The migration library.
        .target(
            name: "FlightMigrate",
            dependencies: [
                "FlightMigrateCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // Build-time generator executable invoked by the plugin. Deliberately depends only on
        // FlightMigrateCore so host builds of the tool stay fast and dependency-light.
        .executableTarget(
            name: "flight-migrate-gen",
            dependencies: ["FlightMigrateCore"]
        ),

        // Build tool plugin: runs flight-migrate-gen over a migrations target and compiles the
        // generated `_allMigrations()` registry into it.
        .plugin(
            name: "FlightMigratePlugin",
            capability: .buildTool(),
            dependencies: ["flight-migrate-gen"]
        ),

        // CLI building blocks (apply/status/rollback/create/repair) and the MigrateTool entry point.
        .target(
            name: "FlightMigrateCLI",
            dependencies: [
                "FlightMigrate",
                "FlightMigrateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Example migrations target: exercises the plugin in this package's own build and
        // provides fixtures for tests.
        .target(
            name: "ExampleMigrations",
            dependencies: ["FlightMigrate"],
            plugins: ["FlightMigratePlugin"]
        ),

        // Example migrate executable wired up exactly as a consumer would do it.
        .executableTarget(
            name: "flight-migrate-example",
            dependencies: ["FlightMigrateCLI", "ExampleMigrations"]
        ),

        .testTarget(
            name: "FlightMigrateTests",
            dependencies: [
                "FlightMigrate",
                "FlightMigrateCore",
                "FlightMigrateCLI",
                "ExampleMigrations",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// Documentation tooling only, gated so consumers never resolve it.
//
//     FLIGHT_MIGRATE_BUILD_DOCS=1 swift package generate-documentation
if ProcessInfo.processInfo.environment["FLIGHT_MIGRATE_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}

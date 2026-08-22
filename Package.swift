// swift-tools-version: 6.1
// Flight Data Core — the store-agnostic parts of persistence: the DataSource
// seam, scope-bound connection checkout, config/health/lifecycle conventions.
// Deliberately tiny (flight-data-core-design.md §1): no query model, no
// transactions, no migrations — those live in each store package.
import PackageDescription

let package = Package(
    name: "flight-data-core",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core.
        .macOS(.v15)
    ],
    products: [
        // The contract: DataSource, ScopedConnection, register(dataSource:),
        // DataSourceSettings (§4 key conventions), DataSourceLiveness (§5).
        .library(name: "FlightDataCore", targets: ["FlightDataCore"]),
        // Test support (§7): InMemoryDataSource — a DataSource backed by
        // nothing, for verifying scoping and lifecycle without a live
        // database — plus InMemoryDataModule and TestContainer.
        .library(name: "FlightDataTesting", targets: ["FlightDataTesting"]),
    ],
    dependencies: [
        // FlightCore re-exports FlightConfig, so this one dependency covers
        // both the design doc's "Depends on" lines.
        .package(path: "../../Core/flight-core"),
        // Changeset/ValidatedChanges/TableModel live in their own
        // Flight-independent package since 2026-08-21 (extracted per
        // hangar-design §11.2, so Hangar can consume them too);
        // FlightDataCore re-exports the module (see Exports.swift).
        .package(path: "../swift-changeset"),
        // Test-target only: lifecycle tests conform fixtures to
        // ServiceLifecycle's Service to exercise the §5 bootstrap ordering.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "FlightDataCore",
            dependencies: [
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "Changesets", package: "swift-changeset"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightDataTesting",
            dependencies: [
                "FlightDataCore",
                .product(name: "FlightCore", package: "flight-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightDataCoreTests",
            dependencies: [
                "FlightDataCore",
                "FlightDataTesting",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
    ]
)

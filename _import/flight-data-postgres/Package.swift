// swift-tools-version: 6.1
// Flight Data Postgres — the thin adapter between Hangar (the query layer)
// and Flight: the pool as a DataSource, request-scoped connections with a
// scoped `Repo`, @Transactional's coordinator, and migrate wiring.
// Implements ../flight-data-postgres-design.md –; – (entities,
// queries, the StructuredQueries binding) are superseded by Hangar
// (../../Hangar/hangar-design.md) — StructuredQueries has left the
// stack entirely. SPIKE-FINDINGS.md records the retired binding's history.
import PackageDescription

let package = Package(
    name: "flight-data-postgres",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core and
        // flight-data-core. Linux with a Swift 6.1+ toolchain is unaffected.
        .macOS(.v15)
    ],
    products: [
        // The Flight package: PostgresDataSource (the pool), PostgresDataModule,
        // a request-scoped Hangar `Repo`, @Transactional's Postgres
        // coordinator, and migrate wiring.
        .library(name: "FlightDataPostgres", targets: ["FlightDataPostgres"]),
    ],
    dependencies: [
        // FlightCore re-exports FlightConfig; FlightDataCore supplies the
        // DataSource seam this package plugs into.
        .package(path: "../../Core/flight-core"),
        .package(path: "../flight-data-core"),
        // Migrations: delegated to Flight Migrate; this package only
        // wires it to the datasource URL resolved from Flight Config.
        .package(path: "../flight-migrate"),
        // The driver: structured-concurrency pooling, SwiftLog/metrics/
        // ServiceLifecycle integrated — Flight's exact dependency posture.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        // The query layer (hangar-design): entities, queries,
        // changeset-consuming writes, preloads — everything used to get
        // from StructuredQueries, now from Hangar.
        .package(path: "../../Hangar/hangar"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        // –: the pool as a DataSource, the module, the scoped Repo,
        // transactions, and migrate wiring.
        .target(
            name: "FlightDataPostgres",
            dependencies: [
                .product(name: "Hangar", package: "hangar"),
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightDataCore", package: "flight-data-core"),
                .product(name: "FlightMigrate", package: "flight-migrate"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightDataPostgresTests",
            dependencies: [
                "FlightDataPostgres",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightDataCore", package: "flight-data-core"),
                .product(name: "FlightDataTesting", package: "flight-data-core"),
                .product(name: "FlightMigrate", package: "flight-migrate"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

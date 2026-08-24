// swift-tools-version: 6.2
import PackageDescription

// A CI fixture, not a shipped product.
//
// `traits: []` is the lean path: every optional trait in flight-data is a
// default trait (see the manifest for why SwiftPM forces that), so a
// consumer subtracts rather than opts in. Naming no traits at all would
// mean "everything". It pins the property the trait gating
// exists for: a consumer taking only the driver-free products must not
// resolve the heavy drivers. Building this from the repository root would
// prove nothing — a root build compiles every target regardless of traits —
// so the check has to come from an actual consumer.
let package = Package(
    name: "lean-consumer",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..", traits: [])],
    targets: [
        .executableTarget(
            name: "LeanConsumer",
            dependencies: [.product(name: "FlightCache", package: "flight-data")]
        )
    ]
)

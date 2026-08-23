import FlightCore

/// A datasource's liveness probe as a component — the store-agnostic surface
/// Flight Actuator reads.
///
/// `register(dataSource:)` registers one of these per named datasource,
/// qualified by the datasource's name, wrapping the pool's `ping()`. Module
/// *health* — did the pool's service start and stay up — is tracked by
/// bootstrap with no per-store instrumentation; this component is the second,
/// complementary signal: is the store on the other end of the pool actually
/// answering right now.
///
/// Actuator (or anything else) enumerates every datasource's probe without
/// knowing any store package exists via `DataSourceLiveness.all(in:)`.
public struct DataSourceLiveness: Sendable {
    /// The datasource this probe belongs to — its qualifier in the container.
    public let datasourceName: String

    private let probe: @Sendable () async throws -> Void

    public init(datasourceName: String, probe: @escaping @Sendable () async throws -> Void) {
        self.datasourceName = datasourceName
        self.probe = probe
    }

    /// Runs the store's cheap liveness probe (a `SELECT 1`-equivalent).
    /// Returning normally means live; any thrown error means not.
    public func ping() async throws {
        try await probe()
    }

    /// Every registered datasource's probe, discovered through container
    /// introspection (Flight Core) — no store-package knowledge required.
    public static func all(in container: Container) throws -> [DataSourceLiveness] {
        let typeName = String(reflecting: DataSourceLiveness.self)
        return try container.allRegistrations()
            .filter { $0.typeName == typeName }
            .map { try container.resolve(DataSourceLiveness.self, qualifier: $0.qualifier) }
    }
}

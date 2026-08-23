import FlightDataCore
import FlightDataTesting
import Testing

/// The reference driver runs the same conformance suite the real drivers do.
///
/// If `InMemoryDataSource` can drift from the contract, so can anything a
/// user writes against it — and the in-memory source is what
/// `InMemoryDataModule` substitutes into tests, so a divergence here makes
/// every downstream test lie about production behaviour.
@Suite("DataSource conformance — InMemoryDataSource")
struct InMemoryConformanceTests {

    @Test("the reference driver satisfies the DataSource contract")
    func conforms() async throws {
        try await DataSourceConformance.verify {
            InMemoryDataSource(poolSize: 4)
        } shutdown: { source in
            source.close()
        }
    }
}

import FlightCore
import Synchronization

/// A connection acquired by an async caller, waiting to become a scope's
/// lease.
///
/// The problem this solves: `ScopedConnection`'s factory is synchronous,
/// because scoped components are built inside synchronous factory bodies, and
/// a synchronous checkout cannot wait for a busy pool — it fails. A caller
/// that *can* await (a web request's transaction binding, a job, a CLI
/// command) should be able to queue for a connection instead, then hand it to
/// the scope it is about to open.
///
/// So the async caller takes the connection first, offers it here for the
/// duration of the unit of work, and the factory takes it if it runs. The
/// offer is task-local, so two concurrent requests cannot see each other's,
/// and one-shot, so a second scope opened inside the same body gets its own
/// connection rather than a second reference to one already leased.
///
/// Nothing is lost if the factory never runs — a request that touches no
/// repository — because the offer is withdrawn and the connection returned
/// when the body ends.
public enum PendingConnections {
    /// One offered connection, takeable exactly once.
    public final class Offer: Sendable {
        private let slot: Mutex<(any Sendable)?>

        public init(_ connection: some Sendable) {
            self.slot = Mutex(connection)
        }

        /// Takes the connection, leaving nothing behind. The second caller
        /// gets nil and checks out its own.
        public func take<C: Sendable>(as type: C.Type = C.self) -> C? {
            slot.withLock { slot in
                guard let value = slot as? C else { return nil }
                slot = nil
                return value
            }
        }

    }

    /// Offers by datasource name, for the duration of one unit of work.
    ///
    /// Bind it through ``offering(_:connection:_:)`` rather than by hand:
    /// `$offers.withValue([name: offer])` *replaces* the dictionary, so a
    /// nested unit of work on a second datasource erased the outer one's offer
    /// for its duration and the scoped factory fell back to a non-waiting
    /// checkout — failing with `poolExhausted` next to a connection reserved
    /// for it.
    @TaskLocal public static var offers: [String: Offer] = [:]

    /// Offers `connection` to the scope opened inside `body`, merging with any
    /// offer an enclosing unit of work already made for another datasource.
    ///
    /// If nothing took it — a unit of work that touched no repository — the
    /// connection goes to `returning`, on the throwing path as well as the
    /// normal one. The offer is one-shot, so a second scope inside `body`
    /// checks out its own connection rather than getting a second reference to
    /// one already leased.
    ///
    /// The withdraw-or-return decision belongs here rather than at the call
    /// site because it has to be made under the same one-shot lock that hands
    /// the connection out: a caller checking "was it taken?" separately can be
    /// beaten to the slot and either leak the connection or release one that
    /// is still leased.
    ///
    /// - Warning: Offers are keyed by datasource *name*. Two distinct pools
    ///   registered under one name, both reached from the same task tree, would
    ///   see each other's offers and a taken connection could be released to
    ///   the wrong pool. Names are the qualifier the container registers under,
    ///   so this is not reachable through the normal module wiring.
    public static func offering<C: Sendable, T>(
        _ name: String,
        connection: C,
        returning returnConnection: (C) -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let offer = Offer(connection)
        defer { if let unclaimed: C = offer.take() { returnConnection(unclaimed) } }
        return try await $offers.withValue(offers.merging([name: offer]) { _, new in new }) {
            try await body()
        }
    }

    /// Takes the offered connection for `datasource`, if there is one.
    public static func take<C: Sendable>(datasource name: String) -> C? {
        offers[name]?.take(as: C.self)
    }
}

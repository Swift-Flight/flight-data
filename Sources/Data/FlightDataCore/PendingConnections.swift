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

        /// Whether the offer is still outstanding — how the offering caller
        /// knows whether to return the connection itself.
        public var isUnclaimed: Bool { slot.withLock { $0 != nil } }
    }

    /// Offers by datasource name, for the duration of one unit of work.
    @TaskLocal public static var offers: [String: Offer] = [:]

    /// Takes the offered connection for `datasource`, if there is one.
    public static func take<C: Sendable>(datasource name: String) -> C? {
        offers[name]?.take(as: C.self)
    }
}

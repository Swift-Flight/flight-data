import FlightCore

/// One scope's checked-out connection: the component `register(dataSource:)`
/// registers as `.scoped`.
///
/// Resolving this within a `Scope` checks a connection out of the pool on
/// first resolution and yields the *same* connection for every further
/// resolution in that scope — which is the whole property: Flight Web ties
/// a Scope to a request, a job runner to one job, a CLI command to one
/// invocation, and all three get correct connection lifetime with neither
/// package knowing about the other.
///
/// ## Why a lease class, not the raw `Connection` (design delta D2)
///
/// The obvious reading is "register the Connection type as `.scoped`". Core's
/// `Scope` has no close hooks — closing a scope simply drops its instances,
/// making them "eligible for cleanup" (Flight Core). A raw connection
/// value dropped on the floor never finds its way back to the pool, so the
/// scoped component is this deinit-carrying wrapper instead: when the scope
/// closes (or, for the rare first-touch race in `Scope.instance`, when a
/// losing duplicate is discarded) ARC runs `deinit` and the connection goes
/// back to the pool — deterministically, on the spot, because the scope's
/// storage held the only reference.
///
/// Anyone who stashes a lease beyond its scope keeps the connection checked
/// out until that reference dies. Don't: a lease's lifetime is its scope's,
/// exactly as a `Scope`'s lifetime is its `withScope` body.
public final class ScopedConnection<Source: DataSource>: Sendable {
    /// The name this lease's datasource was registered under.
    public let datasourceName: String
    /// The scope's connection. Repositories read this; they never release it —
    /// return-to-pool is the lease's job, at scope close.
    public let connection: Source.Connection

    private let source: Source

    internal init(datasourceName: String, connection: Source.Connection, source: Source) {
        self.datasourceName = datasourceName
        self.connection = connection
        self.source = source
    }

    deinit {
        source.release(connection)
    }
}

import FlightCore
import FlightPubSub
import Logging
import ServiceLifecycle
import Valkey

/// Registers the Valkey adapter, which is all it takes to make PubSub
/// clustered:
///
/// ```swift
/// try await Flight.bootstrap(configuration: try Configuration.load(), modules: [
///     FlightPubSubValkeyModule.self,   // pulls in FlightPubSubModule
///     AppModule.self,
/// ])
/// ```
///
/// ```yaml
/// pubsub:
///   valkey:
///     url: valkey://localhost:6379
/// ```
///
/// `FlightPubSubModule` composes by *presence*: its `any PubSub` factory runs
/// at `freeze()`, sees a registered `DistributedPubSubAdapter`, and hands the
/// application a `ClusteredPubSub` instead of the local core. Nothing that
/// publishes or subscribes changes, which is the whole point of the seam.
///
/// Two long-running pieces go into the application's service group: the
/// Valkey client's own pool, and `PubSubRelayService`, which drains the
/// adapter's incoming stream into local fan-out.
public final class FlightPubSubValkeyModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [FlightPubSubModule.self] }

    /// Stashed during `configure` so `service` can resolve post-freeze —
    /// modules cannot resolve during the registration phase.
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container

        container.register(ValkeyPubSubClient.self, scope: .singleton) { container in
            let configuration = try container.resolve(Configuration.self)
            let settings = try ValkeyPubSubSettings.load(from: configuration)
            return try ValkeyPubSubClient(settings: settings)
        }

        // Registering this is what flips FlightPubSubModule's compose-by-
        // presence choice from local to clustered.
        container.register(ValkeyPubSubAdapter.self, scope: .singleton) { container in
            let client = try container.resolve(ValkeyPubSubClient.self)
            return ValkeyPubSubAdapter(
                client: client.client,
                channel: client.channel,
                retryDelay: client.retryDelay)
        }
        container.register((any DistributedPubSubAdapter).self, scope: .singleton) { container in
            try container.resolve(ValkeyPubSubAdapter.self)
        }
    }

    public var service: (any Service)? {
        container.map { ValkeyPubSubService(container: $0) }
    }
}

/// Holds the client so the module can register it once and the service can
/// run it, without constructing two clients that each dial Valkey.
public final class ValkeyPubSubClient: Sendable {
    public let client: ValkeyClient
    public let channel: String
    public let retryDelay: Duration

    init(settings: ValkeyPubSubSettings) throws {
        // Throwing, because building the TLS context can fail and this runs at
        // freeze(): a `valkeys://` URL whose TLS cannot be configured must fail
        // bootstrap rather than quietly connecting in the clear.
        self.client = ValkeyClient(
            .hostname(settings.host, port: settings.port),
            configuration: try settings.clientConfiguration(),
            logger: Logger(label: "flight.pubsub.valkey.client"))
        self.channel = settings.channel
        self.retryDelay = settings.retryDelay
    }
}

/// Runs the client pool and the relay for the application's lifetime.
struct ValkeyPubSubService: Service {
    let container: Container

    func run() async throws {
        let client = try container.resolve(ValkeyPubSubClient.self)
        let adapter = try container.resolve(ValkeyPubSubAdapter.self)

        // Shutdown is ordered on purpose: the relay's subscription must
        // unwind *before* the client pool goes away. Cancelling both at once
        // — the obvious `group.cancelAll()` — can release a subscription
        // connection while it is still initializing, which trips a fatal
        // assertion inside valkey-swift's subscription state machine and
        // takes the process down during what should be a graceful stop.
        // Found by a test crashing at teardown; the same race exists here.
        let pool = Task { await client.client.run() }
        defer { pool.cancel() }

        // The relay refuses if PubSub is not clustered, which would mean this
        // module registered an adapter and something else overrode the
        // composition — worth failing loudly rather than relaying into
        // nothing.
        do {
            try await PubSubRelayService(container: container).run()
        } catch {
            await adapter.drainSubscriptions()
            throw error
        }

        // The relay returning means it stopped *reading*; the subscribe loop
        // behind `incoming()` is a separate task and may still be unwinding.
        // This used to be `try? await Task.sleep(for: .milliseconds(50))` —
        // which under outright cancellation throws immediately and is
        // swallowed, so the pool was cancelled with the subscription still in
        // flight: exactly the crash the ordering above exists to avoid, on the
        // one path where it is most likely. Wait for the thing itself.
        await adapter.drainSubscriptions()
    }
}

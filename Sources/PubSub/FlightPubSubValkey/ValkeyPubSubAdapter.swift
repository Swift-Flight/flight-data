import FlightPubSub
import Foundation
import Logging
import Valkey

/// Carries PubSub messages between nodes over Valkey's `PUBLISH`/`SUBSCRIBE`.
///
/// `FlightPubSub` handles delivery *within* a process on its own; this is the
/// hop *between* processes. Registering one turns three things from
/// single-node into clustered without any call site changing:
///
/// - `Channels` broadcasts reach sockets connected to other servers
/// - `Presence` can run in its membership mode
/// - `ClusteredPubSub` becomes reachable at all
///
/// ```swift
/// try await Flight.bootstrap(
///     configuration: try Configuration.load(),
///     modules: [FlightPubSubValkeyModule.self, AppModule.self])
/// ```
///
/// ## What this does and does not promise
///
/// Valkey's pub/sub is **at-most-once and fire-and-forget**. A node that is
/// disconnected at the moment of a publish does not receive that message
/// later; there is no replay, no acknowledgement and no ordering guarantee
/// across channels. That is the right shape for what PubSub carries here —
/// presence diffs, chat fan-out, cache invalidation — where the next update
/// supersedes the last and a dropped one costs a moment of staleness.
///
/// It is the wrong shape for work that must not be lost. A job queue wants a
/// queue; `ClusteredPubSub` documents the same at-most-once posture and logs
/// rather than throwing when a broadcast fails, so a lost hop never becomes a
/// crashed publisher.
///
/// ## Reconnection
///
/// The adapter's contract says a finished `incoming()` stream means the
/// adapter is done for good, and that transient reconnection is the adapter's
/// job. So the subscribe loop retries with backoff and the stream stays open
/// across a Valkey restart — the relay above never learns it happened, beyond
/// a gap in delivery.
public struct ValkeyPubSubAdapter: DistributedPubSubAdapter {
    private let client: ValkeyClient
    private let channel: String
    private let logger: Logger
    private let retryDelay: Duration

    /// - Parameters:
    ///   - client: A running `ValkeyClient`. Its `run()` must be executing —
    ///     `FlightPubSubValkeyModule` puts it in the application's service
    ///     group.
    ///   - channel: The Valkey channel every node publishes to and subscribes
    ///     to. One channel carries every topic: Flight's own `Message` names
    ///     its topic, and a channel per topic would mean re-subscribing every
    ///     time a socket joined a room.
    ///   - retryDelay: How long to wait before re-subscribing after the
    ///     connection drops.
    ///   - logger: Where dropped frames and lost subscriptions are reported.
    ///     Both are survivable and neither throws, so this is the only place
    ///     they surface.
    public init(
        client: ValkeyClient,
        channel: String = "flight-pubsub",
        retryDelay: Duration = .seconds(1),
        logger: Logger = Logger(label: "flight.pubsub.valkey")
    ) {
        self.client = client
        self.channel = channel
        self.retryDelay = retryDelay
        self.logger = logger
    }

    public func broadcast(_ message: Message) async throws {
        let encoded = try JSONEncoder().encode(WireMessage(message))
        // `Data` renders as a RESP bulk string directly, so the payload
        // crosses as bytes rather than being base64'd through a String.
        _ = try await client.publish(channel: channel, message: encoded)
    }

    /// Publishes bytes that are deliberately not a valid frame.
    ///
    /// Internal, and only a test uses it: proving that one unreadable message
    /// does not kill the relay requires producing one, and there is no honest
    /// way to do that through the public surface.
    func publishRaw(_ bytes: Data) async throws {
        _ = try await client.publish(channel: channel, message: bytes)
    }

    public func incoming() -> AsyncStream<Message> {
        let client = self.client
        let channel = self.channel
        let logger = self.logger
        let retryDelay = self.retryDelay

        return AsyncStream { continuation in
            let task = Task {
                // Retries forever rather than finishing: per the adapter
                // contract, a finished stream means "this adapter is done for
                // good", and a Valkey restart is not that. Cancellation is,
                // which is why the loop checks it.
                while !Task.isCancelled {
                    do {
                        try await client.subscribe(to: channel) { subscription in
                            for try await entry in subscription {
                                guard !Task.isCancelled else { return }
                                let bytes = Data(entry.message)
                                do {
                                    let wire = try JSONDecoder().decode(WireMessage.self, from: bytes)
                                    continuation.yield(wire.message)
                                } catch {
                                    // One unreadable message must not take
                                    // down the relay for every other node.
                                    logger.error(
                                        "dropped an undecodable pubsub message",
                                        metadata: ["error": .string("\(error)")])
                                }
                            }
                        }
                    } catch {
                        if Task.isCancelled { break }
                        logger.warning(
                            "pubsub subscription dropped; retrying",
                            metadata: ["error": .string("\(error)")])
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: retryDelay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The wire form of a `Message`.
///
/// `Message` is `Codable`, but encoding it directly would make Flight's
/// in-process type the wire contract: renaming a property would silently
/// break every node running the old build. An explicit wire type means the
/// mapping is a place someone has to edit on purpose.
struct WireMessage: Codable {
    let topic: String
    let payload: Data
    let metadata: [String: String]

    init(_ message: Message) {
        self.topic = message.topic
        self.payload = message.payload
        self.metadata = message.metadata
    }

    var message: Message {
        Message(topic: topic, payload: payload, metadata: metadata)
    }
}

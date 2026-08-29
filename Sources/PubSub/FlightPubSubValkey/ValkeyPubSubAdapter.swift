import FlightPubSub
import Foundation
import Logging
import Synchronization
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
    /// Shared by every copy of this struct, so shutdown can wait for the
    /// subscribe loops `incoming()` started.
    private let subscriptions = SubscriptionTasks()

    /// - Parameters:
    ///   - client: A running `ValkeyClient`. Its `run()` must be executing —
    ///     `FlightPubSubValkeyModule` puts it in the application's service
    ///     group.
    ///   - channel: The Valkey channel every node publishes to and subscribes
    ///     to. One channel carries every topic: Flight's own `Message` names
    ///     its topic, and a channel per topic would mean re-subscribing every
    ///     time a socket joined a room.
    ///   - retryDelay: The first delay before re-subscribing after the
    ///     connection drops. It doubles up to a cap and is jittered, because a
    ///     fixed delay means every node in the cluster retries in lockstep at
    ///     the same instant — a thundering herd aimed at a server that has just
    ///     come back up.
    ///   - logger: Where dropped frames and lost subscriptions are reported.
    ///     Both are survivable and neither throws, so this is the only place
    ///     they surface.
    public init(
        client: ValkeyClient,
        // One definition of the default, in the settings type. It used to be
        // spelled out here as well, and a desync between two literals makes
        // two nodes silently deaf to each other.
        channel: String = ValkeyPubSubSettings.defaultChannel,
        retryDelay: Duration = .seconds(1),
        logger: Logger = Logger(label: "flight.pubsub.valkey")
    ) {
        self.client = client
        self.channel = channel
        self.retryDelay = retryDelay
        self.logger = logger
    }

    public func broadcast(_ message: Message) async throws {
        _ = try await client.publish(channel: channel, message: WireMessage.encode(message))
    }

    /// Publishes bytes that are deliberately not a valid frame.
    ///
    /// Internal, and only a test uses it: proving that one unreadable message
    /// does not kill the relay requires producing one, and there is no honest
    /// way to do that through the public surface.
    func publishRaw(_ bytes: Data) async throws {
        _ = try await client.publish(channel: channel, message: bytes)
    }

    /// The most a retry delay grows to. Past a few seconds the difference
    /// between "reconnecting" and "reconnected a moment ago" stops mattering,
    /// and a longer wait only lengthens the gap in delivery.
    private static let maximumRetryDelay = Duration.seconds(30)

    public func incoming() -> AsyncStream<Message> {
        let client = self.client
        let channel = self.channel
        let logger = self.logger
        let retryDelay = self.retryDelay
        let subscriptions = self.subscriptions

        // Bounded on purpose. This is an at-most-once transport carrying
        // presence diffs and fan-out where the next update supersedes the
        // last, so a consumer that falls behind should lose the stale updates,
        // not grow a queue of them until the process runs out of memory.
        return AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { continuation in
            let task = Task {
                var delay = retryDelay
                // Retries forever rather than finishing: per the adapter
                // contract, a finished stream means "this adapter is done for
                // good", and a Valkey restart is not that. Cancellation is,
                // which is why the loop checks it.
                while !Task.isCancelled {
                    do {
                        try await client.subscribe(to: channel) { subscription in
                            for try await entry in subscription {
                                guard !Task.isCancelled else { return }
                                delay = retryDelay  // a delivery means we are connected
                                do {
                                    continuation.yield(
                                        try WireMessage.decode(Data(entry.message)))
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
                            metadata: [
                                "error": .string("\(error)"),
                                "retry-in": .string("\(delay)"),
                            ])
                    }
                    if Task.isCancelled { break }
                    // Jittered, so a cluster whose nodes all lost the server at
                    // the same instant does not reconnect at the same instant.
                    let jitter = Double.random(in: 0.5...1.5)
                    try? await Task.sleep(for: delay * jitter)
                    delay = min(delay * 2, Self.maximumRetryDelay)
                }
                continuation.finish()
            }
            subscriptions.register(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cancels the subscribe loops and waits for them to finish.
    ///
    /// The module's service calls this between the relay stopping and the
    /// client pool being cancelled: releasing a subscription connection while
    /// it is still initializing trips a fatal assertion inside valkey-swift's
    /// subscription state machine, so "the subscription is done" has to be a
    /// fact rather than a guess.
    public func drainSubscriptions() async {
        await subscriptions.drain()
    }
}

/// Holds the subscribe loops so shutdown can wait for them.
///
/// A reference type inside the adapter struct: `DistributedPubSubAdapter`
/// conformances are values that get copied around, and every copy has to see
/// the same set of running tasks or shutdown waits on an empty list.
final class SubscriptionTasks: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func register(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func drain() async {
        let running = tasks.withLock { current -> [Task<Void, Never>] in
            defer { current = [] }
            return current
        }
        for task in running {
            task.cancel()
            await task.value
        }
    }
}

/// The wire form of a `Message`: a small JSON header, then the payload bytes
/// verbatim.
///
/// `Message` is `Codable`, but encoding it directly would make Flight's
/// in-process type the wire contract: renaming a property would silently break
/// every node running the old build. An explicit wire form means the mapping is
/// a place someone has to edit on purpose.
///
/// ## Why not just JSON (delta PV2)
///
/// It was `Codable` over the whole message, with `payload: Data` — and
/// `JSONEncoder` renders `Data` as **base64**. So a comment claiming the
/// payload "crosses as bytes rather than being base64'd through a String" was
/// true only of the outer RESP frame: every payload byte was inflated by a
/// third and re-encoded on every hop, on the stated hot use case of chat
/// fan-out and presence diffs.
///
/// The frame is:
///
///     "FPS1"                4 bytes, magic and version
///     UInt32 big-endian     header length
///     header                JSON: {"topic": …, "metadata": {…}}
///     payload               the caller's bytes, untouched
///
/// The header stays JSON because it is small and because `metadata` is an
/// arbitrary string map — hand-rolling that encoding would be more code and
/// more ways to be wrong for no measurable gain.
enum WireMessage {
    /// Magic and version. A node running an older build sees a frame it cannot
    /// read and drops it loudly, rather than decoding it into nonsense.
    static let magic: [UInt8] = Array("FPS1".utf8)

    private struct Header: Codable {
        let topic: String
        let metadata: [String: String]
    }

    static func encode(_ message: Message) throws -> Data {
        let header = try JSONEncoder().encode(
            Header(topic: message.topic, metadata: message.metadata))
        var frame = Data(magic)
        withUnsafeBytes(of: UInt32(header.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(header)
        frame.append(message.payload)
        return frame
    }

    static func decode(_ frame: Data) throws -> Message {
        let prefix = magic.count + 4
        guard frame.count >= prefix, Array(frame.prefix(magic.count)) == magic else {
            throw WireMessageError.notAFlightFrame
        }
        let lengthBytes = frame[frame.startIndex + magic.count..<frame.startIndex + prefix]
        let headerLength = Int(lengthBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let headerEnd = frame.startIndex + prefix + headerLength
        guard headerLength >= 0, headerEnd <= frame.endIndex else {
            throw WireMessageError.truncated
        }
        let header = try JSONDecoder().decode(
            Header.self, from: frame[frame.startIndex + prefix..<headerEnd])
        return Message(
            topic: header.topic,
            payload: Data(frame[headerEnd...]),
            metadata: header.metadata)
    }
}

enum WireMessageError: Error, Equatable, CustomStringConvertible {
    case notAFlightFrame
    case truncated

    var description: String {
        switch self {
        case .notAFlightFrame:
            return "not a Flight PubSub frame — something else is publishing to this channel, or a node is running an incompatible build."
        case .truncated:
            return "a Flight PubSub frame ended inside its header."
        }
    }
}

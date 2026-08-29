import FlightPubSub
import Foundation
import Logging
import Synchronization
import Testing
import Valkey

@testable import FlightPubSubValkey

/// Two nodes, one Valkey, a message that has to cross.
///
/// There is nothing worth asserting against a fake here: the property under
/// test is that a publish on one process reaches a subscriber in another, and
/// that is Valkey's behaviour plus this adapter's framing. A mock would test
/// neither.
@Suite(
    "Valkey PubSub adapter", .serialized,
    .enabled(if: PubSubTestServer.isConfigured, "set FLIGHT_VALKEY_TEST_URL"))
struct ValkeyPubSubAdapterTests {

    private func withNode<T>(
        channel: String, _ body: (ValkeyPubSubAdapter) async throws -> T
    ) async throws -> T {
        let client = try PubSubTestServer.client()
        let runner = Task { await client.run() }
        let adapter = ValkeyPubSubAdapter(
            client: client, channel: channel, retryDelay: .milliseconds(50),
            logger: PubSubTestServer.quietLogger)
        let result = try await body(adapter)
        // Ordered teardown, matching ValkeyPubSubService: let the
        // subscription unwind before the pool is cancelled. Cancelling the
        // pool underneath a live subscription trips a fatal assertion inside
        // valkey-swift.
        try? await Task.sleep(for: .milliseconds(100))
        runner.cancel()
        return result
    }

    /// Waits for a condition rather than sleeping a fixed time — the
    /// difference between a test that is slow and one that is flaky.
    private func eventually(
        timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Publishes until `condition` holds, or gives up.
    ///
    /// Valkey pub/sub is at-most-once, so a message published before the
    /// subscriber's `SUBSCRIBE` has landed is legitimately lost — which is why
    /// these tests used to sleep a few hundred milliseconds first and hope the
    /// subscription had established. A sleep long enough to be reliable is a
    /// sleep every run pays, and one short enough to be quick is a test that
    /// fails on a loaded machine for reasons that have nothing to do with the
    /// code. Republishing needs no guess: the transport's own semantics say a
    /// dropped message is a retry's problem.
    @discardableResult
    private func publishUntil(
        _ adapter: ValkeyPubSubAdapter,
        _ message: Message,
        timeout: Duration = .seconds(5),
        until condition: @Sendable () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await adapter.broadcast(message)
            for _ in 0..<5 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return condition()
    }

    @Test("a message published on one node arrives on another")
    func crossesBetweenNodes() async throws {
        let channel = "flight-test-\(UUID().uuidString)"
        try await withNode(channel: channel) { publisher in
            try await withNode(channel: channel) { subscriber in
                let received = Mutex<[Message]>([])
                let consumer = Task {
                    for await message in subscriber.incoming() {
                        received.withLock { $0.append(message) }
                    }
                }
                defer { consumer.cancel() }

                let arrived = try await publishUntil(
                    publisher,
                    Message(
                        topic: "room:42", payload: Data("hello".utf8),
                        metadata: ["origin": "node-a"])
                ) { received.withLock { !$0.isEmpty } }
                #expect(arrived, "nothing crossed between nodes")

                let message = try #require(received.withLock { $0.first })
                #expect(message.topic == "room:42")
                #expect(message.payload == Data("hello".utf8))
                #expect(message.metadata["origin"] == "node-a", "metadata must survive the hop")
            }
        }
    }

    @Test("a binary payload survives the round trip byte for byte")
    func binaryPayloadSurvives() async throws {
        // The payload is Data, not text: anything that base64s or
        // string-coerces it would pass a "hello" test and corrupt real
        // traffic.
        let channel = "flight-test-\(UUID().uuidString)"
        let payload = Data((0...255).map { UInt8($0) })
        try await withNode(channel: channel) { publisher in
            try await withNode(channel: channel) { subscriber in
                let received = Mutex<[Message]>([])
                let consumer = Task {
                    for await message in subscriber.incoming() {
                        received.withLock { $0.append(message) }
                    }
                }
                defer { consumer.cancel() }

                let arrived = try await publishUntil(
                    publisher, Message(topic: "bin", payload: payload)
                ) { received.withLock { !$0.isEmpty } }
                #expect(arrived, "nothing crossed between nodes")
                #expect(received.withLock { $0.first?.payload } == payload)
            }
        }
    }

    @Test("nodes on a different channel do not see the traffic")
    func channelsAreIsolated() async throws {
        // Two Flight clusters against one Valkey must not bleed into each
        // other; the channel is what separates them.
        let mine = "flight-test-\(UUID().uuidString)"
        let theirs = "flight-test-\(UUID().uuidString)"
        try await withNode(channel: mine) { publisher in
            try await withNode(channel: theirs) { stranger in
                let received = Mutex<[Message]>([])
                let consumer = Task {
                    for await message in stranger.incoming() {
                        received.withLock { $0.append(message) }
                    }
                }
                defer { consumer.cancel() }

                // A negative assertion cannot be waited *for*, so this one
                // publishes repeatedly across a window that comfortably covers
                // a delivery — if the channels leaked, several of these would
                // land rather than none.
                let leaked = try await publishUntil(
                    publisher, Message(topic: "t", payload: Data("x".utf8)),
                    timeout: .seconds(1)
                ) { received.withLock { !$0.isEmpty } }
                #expect(!leaked, "traffic leaked across channels")
            }
        }
    }

    @Test("an undecodable message is dropped without killing the stream")
    func undecodableMessageIsSurvivable() async throws {
        // One bad frame — an old build, a stray publisher — must not take
        // down the relay for every other node.
        let channel = "flight-test-\(UUID().uuidString)"
        try await withNode(channel: channel) { publisher in
            try await withNode(channel: channel) { subscriber in
                let received = Mutex<[Message]>([])
                let consumer = Task {
                    for await message in subscriber.incoming() {
                        received.withLock { $0.append(message) }
                    }
                }
                defer { consumer.cancel() }

                // A first message that actually lands, so the assertion below
                // distinguishes "the bad frame killed the stream" from "the
                // subscription had not established yet".
                let established = try await publishUntil(
                    publisher, Message(topic: "before", payload: Data())
                ) { received.withLock { $0.contains { $0.topic == "before" } } }
                #expect(established, "the subscription never established")

                // The bad frame goes out on the *publisher's* connection
                // rather than a second client. A client whose run() is
                // cancelled while its connection is still initializing trips
                // an assertion inside valkey-swift's subscription state
                // machine — a real lifecycle constraint, and not the thing
                // this test is about.
                try await publisher.publishRaw(Data("not json".utf8))

                let arrived = try await publishUntil(
                    publisher, Message(topic: "after", payload: Data())
                ) { received.withLock { $0.contains { $0.topic == "after" } } }
                #expect(arrived, "the stream died on an undecodable message")
            }
        }
    }
}

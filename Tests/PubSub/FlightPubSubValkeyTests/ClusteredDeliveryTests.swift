import FlightPubSub
import Foundation
import Synchronization
import Testing

@testable import FlightPubSubValkey

/// The thing the adapter exists for: a `publish` on one node reaching a
/// `subscribe` on another, through `ClusteredPubSub` — not through the
/// adapter directly.
///
/// The adapter tests prove bytes cross. These prove the composition works:
/// origin stamping, echo suppression, and local delivery all still behave
/// with a real transport underneath rather than `InMemoryCluster`.
@Suite(
    "Clustered delivery over Valkey", .serialized,
    .enabled(if: PubSubTestServer.isConfigured, "set FLIGHT_VALKEY_TEST_URL"))
struct ClusteredDeliveryTests {

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

    /// Two independent nodes, each with its own local core, adapter and relay
    /// — the shape a two-server deployment actually has.
    private func withCluster<T>(
        _ body: (ClusteredPubSub, ClusteredPubSub) async throws -> T
    ) async throws -> T {
        let channel = "flight-test-\(UUID().uuidString)"
        let clientA = try PubSubTestServer.client()
        let clientB = try PubSubTestServer.client()
        let runnerA = Task { await clientA.run() }
        let runnerB = Task { await clientB.run() }

        let nodeA = ClusteredPubSub(
            local: LocalPubSub(),
            adapter: ValkeyPubSubAdapter(
                client: clientA, channel: channel, logger: PubSubTestServer.quietLogger),
            nodeID: "node-a")
        let nodeB = ClusteredPubSub(
            local: LocalPubSub(),
            adapter: ValkeyPubSubAdapter(
                client: clientB, channel: channel, logger: PubSubTestServer.quietLogger),
            nodeID: "node-b")

        let relayA = Task { try await PubSubRelayService(clustered: nodeA).run() }
        let relayB = Task { try await PubSubRelayService(clustered: nodeB).run() }
        // The relays need a moment to start draining; each test republishes
        // until delivery, so this only has to get the tasks scheduled.
        try await Task.sleep(for: .milliseconds(50))

        let result = try await body(nodeA, nodeB)

        relayA.cancel()
        relayB.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        runnerA.cancel()
        runnerB.cancel()
        return result
    }

    @Test("a publish on one node reaches a subscriber on the other")
    func crossNodeDelivery() async throws {
        try await withCluster { nodeA, nodeB in
            let received = Mutex<[Data]>([])
            let subscription = try await nodeB.subscribe("room:42")
            let consumer = Task {
                for await message in subscription {
                    received.withLock { $0.append(message.payload) }
                }
            }
            defer { consumer.cancel() }

            // Republished until it lands rather than sleeping first and hoping
            // the subscription had established: Valkey pub/sub is at-most-once,
            // so a message published too early is legitimately lost — which
            // makes a retry the transport's own answer, and a fixed sleep a
            // guess that gets slower or flakier depending on which way you
            // tune it.
            let arrived = try await publishUntil(
                nodeA, Message(topic: "room:42", payload: Data("hi".utf8))
            ) { received.withLock { !$0.isEmpty } }
            #expect(arrived, "the message never crossed to the other node")
            #expect(received.withLock { $0.first } == Data("hi".utf8))
        }
    }

    /// Publishes until `condition` holds, or gives up. See `crossNodeDelivery`
    /// for why an at-most-once transport wants this rather than a sleep.
    @discardableResult
    private func publishUntil(
        _ node: ClusteredPubSub,
        _ message: Message,
        timeout: Duration = .seconds(5),
        until condition: @Sendable () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await node.publish(message)
            for _ in 0..<5 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return condition()
    }

    @Test("a publisher's own subscribers get it exactly once, not twice")
    func noEchoDuplication() async throws {
        // Valkey echoes a publish back to the publishing connection's
        // subscribers, so without origin stamping a local subscriber would
        // see every message twice — once locally, once off the wire.
        try await withCluster { nodeA, _ in
            let count = Mutex(0)
            let subscription = try await nodeA.subscribe("room:echo")
            let consumer = Task {
                for await _ in subscription { count.withLock { $0 += 1 } }
            }
            defer { consumer.cancel() }
            try await Task.sleep(for: .milliseconds(200))

            try await nodeA.publish(Message(topic: "room:echo", payload: Data("x".utf8)))
            try await Task.sleep(for: .milliseconds(600))

            #expect(count.withLock { $0 } == 1, "local subscriber saw the message more than once")
        }
    }

    @Test("subscribers on a topic nobody published to hear nothing")
    func topicsAreIsolated() async throws {
        try await withCluster { nodeA, nodeB in
            let received = Mutex(0)
            let subscription = try await nodeB.subscribe("room:quiet")
            let consumer = Task {
                for await _ in subscription { received.withLock { $0 += 1 } }
            }
            defer { consumer.cancel() }
            try await Task.sleep(for: .milliseconds(200))

            try await nodeA.publish(Message(topic: "room:loud", payload: Data("x".utf8)))
            try await Task.sleep(for: .milliseconds(500))

            #expect(received.withLock { $0 } == 0)
        }
    }
}

import FlightDataValkey
import Testing
import Valkey

/// The §5.2 batch builder, no server required: what a `multi` block queues.
/// EXEC semantics (per-slot failures, atomicity) are integration territory.
@Suite("Multi batch builder (§5.2)")
struct MultiBatchTests {
    @Test func designDocExampleQueuesIncrThenExpire() throws {
        var batch = ValkeyMultiBatch()
        batch.incr("counter")
        batch.expire("counter", after: .seconds(3600))

        #expect(batch.commands.count == 2)
        let incr = try #require(batch.commands[0] as? INCR)
        #expect(incr.key == "counter")
        let expire = try #require(batch.commands[1] as? PEXPIRE)
        #expect(expire.key == "counter")
        #expect(expire.milliseconds == 3_600_000)
    }

    @Test func conveniencesQueueTheExpectedCommands() throws {
        var batch = ValkeyMultiBatch()
        batch.set("k", value: "v")
        batch.incrby("k2", 5)
        batch.decr("k2")
        batch.del("k", "k2")
        batch.persist("k")
        batch.hset("h", field: "f", value: "v")
        batch.hset("h", [("a", "1"), ("b", "2")])
        batch.hdel("h", fields: "a", "b")
        batch.sadd("s", members: "m1", "m2")
        batch.srem("s", members: "m1")
        batch.zadd("z", score: 1.5, member: "m")
        batch.zrem("z", members: "m")
        batch.lpush("l", elements: "x")
        batch.rpush("l", elements: "y")
        batch.command("OBJECT", "ENCODING", "k", keys: ["k"])
        batch.add(GET("k"))

        #expect(batch.commands.count == 16)
        #expect(batch.commands[1] as? INCRBY == INCRBY("k2", increment: 5))
        #expect((batch.commands[3] as? DEL)?.keys == ["k", "k2"])
        let hset = try #require(batch.commands[6] as? HSET<String, String>)
        #expect(hset.data == [.init(field: "a", value: "1"), .init(field: "b", value: "2")])
        let raw = try #require(batch.commands[14] as? ValkeyRawCommand)
        #expect(raw == ValkeyRawCommand("OBJECT", arguments: ["ENCODING", "k"], keys: ["k"]))
    }

    @Test func subMillisecondTTLNeverBecomesDeleteNow() {
        var batch = ValkeyMultiBatch()
        batch.expire("k", after: .microseconds(500))
        // PEXPIRE 0 would delete the key immediately; a positive TTL clamps up.
        #expect((batch.commands[0] as? PEXPIRE)?.milliseconds == 1)
    }

    @Test func rawCommandEqualityAndHashingSeeArguments() {
        let a = ValkeyRawCommand("JSON.SET", arguments: ["doc:1", "$", "{}"])
        let b = ValkeyRawCommand("JSON.SET", arguments: ["doc:1", "$", "{}"])
        let c = ValkeyRawCommand("JSON.SET", arguments: ["doc:1", "$", "[]"])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        // Mixed argument representations still compare by value.
        let bytes = ValkeyRawCommand("SET", arguments: ["k", [UInt8]([1, 2])])
        let sameBytes = ValkeyRawCommand("SET", arguments: ["k", [UInt8]([1, 2])])
        #expect(bytes == sameBytes)
    }
}

import Valkey

/// `MULTI`/`EXEC` under its own honest name.
///
/// This is deliberately **not** `@Transactional`. Valkey's `MULTI`/`EXEC` is
/// an atomic batch — other clients never observe a point between the queued
/// commands — but it is *not* a transaction in the SQL sense: no rollback on
/// logical failure, no isolation of the `BEGIN` kind, and a command that
/// fails inside `EXEC` does not undo the ones before it. A shared
/// transaction abstraction would have to lie about one of the two semantics
/// (Flight Data Core), so the capability ships under a different name
/// with different semantics:
///
/// ```swift
/// try await valkey.multi { batch in
///     batch.incr("counter")
///     batch.expire("counter", after: .seconds(3600))
/// }   // atomic batch — NOT a rollback-capable transaction
/// ```
extension ValkeyClientProtocol {
    /// Queues the commands `build` adds to the batch and sends them as one
    /// `MULTI`/`EXEC` block.
    ///
    /// - Returns: One result per queued command, in queue order. A command
    ///   that the server rejects at *execution* time (wrong type, bad
    ///   arguments against live data) is a `.failure` **in its slot** — the
    ///   commands around it still ran; nothing rolls back. That per-slot
    ///   result is the semantics made visible in the signature.
    /// - Throws: `ValkeyTransactionError` when `EXEC` itself aborts (a
    ///   command failed to *queue*, or a `WATCH` guard tripped), or a
    ///   connection-level error. An empty batch sends nothing.
    @discardableResult
    public func multi(
        _ build: (inout ValkeyMultiBatch) throws -> Void
    ) async throws -> ValkeyMultiResults {
        var batch = ValkeyMultiBatch()
        try build(&batch)
        guard !batch.commands.isEmpty else { return ValkeyMultiResults(results: []) }
        return ValkeyMultiResults(results: try await transaction(batch.commands))
    }
}

/// The commands queued by one `multi` block, in order.
///
/// Any `ValkeyCommand` can be queued via `add(_:)` — the typed command
/// values (`INCR`, `HSET`, …) are the same ones the direct surface executes,
/// and `ValkeyRawCommand` rides along for the escape hatch. The named
/// methods below are conveniences for the common-command-set operations
/// batches most often queue; they add nothing `add` can't.
public struct ValkeyMultiBatch: Sendable {
    public private(set) var commands: [any ValkeyCommand] = []

    public init() {}

    /// Queues any typed command value.
    public mutating func add(_ command: some ValkeyCommand) {
        commands.append(command)
    }

    /// Queues a raw command.
    public mutating func command(
        _ name: String,
        _ arguments: any RESPStringRenderable...,
        keys: [ValkeyKey] = []
    ) {
        commands.append(ValkeyRawCommand(name, arguments: arguments, keys: keys))
    }

    // MARK: - Strings & counters

    public mutating func set(_ key: ValkeyKey, value: some RESPStringRenderable) {
        add(SET(key, value: value))
    }

    public mutating func incr(_ key: ValkeyKey) {
        add(INCR(key))
    }

    public mutating func incrby(_ key: ValkeyKey, _ increment: Int) {
        add(INCRBY(key, increment: increment))
    }

    public mutating func decr(_ key: ValkeyKey) {
        add(DECR(key))
    }

    // MARK: - Generic

    public mutating func del(_ keys: ValkeyKey...) {
        add(DEL(keys: keys))
    }

    /// Sub-second precision via `PEXPIRE`, matching the direct surface's
    /// `expire(_:after:)`.
    ///
    /// A non-positive duration is clamped to one millisecond rather than sent
    /// as-is: the server reads a negative timeout as "delete the key", and a
    /// batch builder cannot throw to say so. One millisecond expires the key
    /// almost immediately, which is what the caller asked for, without
    /// turning a TTL into a deletion. The direct `expire(_:after:)` refuses
    /// outright, because it can.
    public mutating func expire(_ key: ValkeyKey, after duration: Duration) {
        add(PEXPIRE(key, milliseconds: duration > .zero ? duration.wholeMilliseconds : 1))
    }

    public mutating func persist(_ key: ValkeyKey) {
        add(PERSIST(key))
    }

    // MARK: - Hashes

    public mutating func hset(_ key: ValkeyKey, _ fields: [(String, some RESPStringRenderable)]) {
        add(HSET(key, data: fields.map { .init(field: $0.0, value: $0.1) }))
    }

    public mutating func hset(_ key: ValkeyKey, field: String, value: some RESPStringRenderable) {
        add(HSET(key, data: [.init(field: field, value: value)]))
    }

    public mutating func hdel(_ key: ValkeyKey, fields: String...) {
        add(HDEL(key, fields: fields))
    }

    // MARK: - Sets & sorted sets

    public mutating func sadd(_ key: ValkeyKey, members: String...) {
        add(SADD(key, members: members))
    }

    public mutating func srem(_ key: ValkeyKey, members: String...) {
        add(SREM(key, members: members))
    }

    public mutating func zadd(_ key: ValkeyKey, score: Double, member: String) {
        add(ZADD(key, data: [.init(score: score, member: member)]))
    }

    public mutating func zrem(_ key: ValkeyKey, members: String...) {
        add(ZREM(key, members: members))
    }

    // MARK: - Lists

    public mutating func lpush(_ key: ValkeyKey, elements: String...) {
        add(LPUSH(key, elements: elements))
    }

    public mutating func rpush(_ key: ValkeyKey, elements: String...) {
        add(RPUSH(key, elements: elements))
    }
}

/// The per-command outcomes of one `multi` batch, in queue order.
public struct ValkeyMultiResults: Sendable, RandomAccessCollection {
    /// One entry per queued command. `.failure` means the server rejected
    /// that command at execution time; its neighbors still ran.
    public let results: [Result<RESPToken, ValkeyClientError>]

    public init(results: [Result<RESPToken, ValkeyClientError>]) {
        self.results = results
    }

    public var startIndex: Int { results.startIndex }
    public var endIndex: Int { results.endIndex }
    public subscript(position: Int) -> Result<RESPToken, ValkeyClientError> {
        results[position]
    }

    /// The reply in slot `index`, decoded — throws that slot's error if the
    /// command failed, or the decode failure if the reply has another shape.
    public func decode<Value: RESPTokenDecodable>(
        _ index: Int, as type: Value.Type = Value.self
    ) throws -> Value {
        try results[index].get().decode(as: Value.self)
    }
}

extension Duration {
    /// Whole milliseconds, for `PEXPIRE`. Clamped up to 1ms — a positive
    /// sub-millisecond TTL must not become "delete immediately".
    ///
    /// Only defined for a positive duration: the callers refuse a non-positive
    /// expiry outright, because `PEXPIRE` with a negative timeout deletes the
    /// key and that must never happen by accident from arithmetic against a
    /// deadline that has already passed.
    ///
    /// Saturating rather than trapping. A `Duration` can hold far more
    /// milliseconds than an `Int` on a 32-bit platform, and `.seconds(Int.max)`
    /// — reachable from a caller's own arithmetic — overflowed the multiply.
    /// A TTL clamped to `Int.max` milliseconds is 292 million years; nobody is
    /// harmed by the difference, and everybody is harmed by a crash.
    var wholeMilliseconds: Int {
        precondition(self > .zero, "wholeMilliseconds is only meaningful for a positive duration")
        let milliseconds =
            components.seconds.multipliedReportingOverflow(by: 1000).partialValue
            &+ Int64(components.attoseconds / 1_000_000_000_000_000)
        if components.seconds.multipliedReportingOverflow(by: 1000).overflow {
            return Int.max
        }
        if milliseconds <= 0 { return 1 }
        return milliseconds > Int64(Int.max) ? Int.max : Int(milliseconds)
    }
}

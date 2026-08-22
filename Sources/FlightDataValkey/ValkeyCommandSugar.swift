import Valkey

/// Two small conveniences so the design doc's §4.3 repository reads exactly
/// as written. The typed command surface itself is the driver's — generated
/// from Valkey's own command specifications (§2), covering the common
/// command set (§3.1) — and this package deliberately does not re-wrap it.
extension ValkeyClientProtocol {
    /// `expire(_:after:)` with a `Duration`, via `PEXPIRE` for sub-second
    /// precision.
    ///
    /// - Returns: True when the timeout was set; false when the key does not
    ///   exist.
    @discardableResult
    public func expire(_ key: ValkeyKey, after duration: Duration) async throws -> Bool {
        try await execute(PEXPIRE(key, milliseconds: duration.wholeMilliseconds)) == 1
    }

    /// The highest-scored members of a sorted set, best first — the §4.3
    /// leaderboard read. `ZREVRANGE` itself is deprecated server-side; this
    /// sends its replacement, `ZRANGE … REV`.
    public func zrevrange(_ key: ValkeyKey, _ start: Int, _ stop: Int) async throws -> [String] {
        let reply = try await execute(ZRANGE(key, start: "\(start)", stop: "\(stop)", rev: true))
        return try reply.decode(as: [String].self)
    }

    /// As `zrevrange(_:_:_:)`, with each member's score. The `withScores`
    /// parameter mirrors the wire command's spelling; this overload's return
    /// type already promises scores, so they are fetched regardless of its
    /// value (members-only reads use the overload above).
    public func zrevrange(
        _ key: ValkeyKey, _ start: Int, _ stop: Int, withScores: Bool
    ) async throws -> [(String, Double)] {
        let reply = try await execute(
            ZRANGE(key, start: "\(start)", stop: "\(stop)", rev: true, withscores: true))
        return try reply.decode(as: [SortedSetEntry].self).map {
            (String(decoding: $0.value, as: UTF8.self), $0.score)
        }
    }
}

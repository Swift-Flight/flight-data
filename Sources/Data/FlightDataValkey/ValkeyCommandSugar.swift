import Valkey

/// Two small conveniences so the design doc's repository reads exactly
/// as written. The typed command surface itself is the driver's — generated
/// from Valkey's own command specifications, covering the common
/// command set — and this package deliberately does not re-wrap it.
extension ValkeyClientProtocol {
    /// `expire(_:after:)` with a `Duration`, via `PEXPIRE` for sub-second
    /// precision.
    ///
    /// A non-positive duration throws. The server would **delete the key** —
    /// that is what `PEXPIRE` with a negative timeout means — and a caller
    /// computing a TTL from a deadline that has already passed would then
    /// destroy data by asking for an expiry. Deleting is a reasonable reading
    /// of "expire it now"; doing it silently, from arithmetic that went
    /// negative by accident, is not.
    ///
    /// - Returns: True when the timeout was set; false when the key does not
    ///   exist.
    @discardableResult
    public func expire(_ key: ValkeyKey, after duration: Duration) async throws -> Bool {
        guard duration > .zero else {
            throw ValkeyCommandError.nonPositiveExpiry(
                key: "\(key)", duration: "\(duration)")
        }
        return try await execute(PEXPIRE(key, milliseconds: duration.wholeMilliseconds)) == 1
    }

    /// The highest-scored members of a sorted set, best first — the
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

/// A command this package refused to send.
public enum ValkeyCommandError: Error, Sendable, Equatable, CustomStringConvertible {
    /// An expiry of zero or less. The server reads that as "delete the key",
    /// which is not what a caller whose TTL arithmetic went negative meant.
    case nonPositiveExpiry(key: String, duration: String)

    public var description: String {
        switch self {
        case .nonPositiveExpiry(let key, let duration):
            return """
                expire('\(key)') was asked for \(duration). A non-positive expiry deletes the \
                key rather than scheduling one, so this is refused — delete it explicitly if \
                that is the intent, or clamp the duration if it came from a deadline that has \
                already passed.
                """
        }
    }
}

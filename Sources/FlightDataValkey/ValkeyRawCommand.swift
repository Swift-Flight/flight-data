import Valkey

/// The escape hatch (design §4.3): a raw command for anything the typed
/// surface doesn't cover — vendor-specific commands, newly-added server
/// commands, module commands.
///
/// ```swift
/// try await valkey.command("JSON.SET", "doc:1", "$", jsonPayload)   // Redis-only; §3.1 applies
/// ```
///
/// First-class, not a leak — no client can wrap every command of two
/// diverging servers. But it is **outside Flight's compatibility guarantee**
/// (§3.1): the typed surface sticks to the common command set that runs on
/// both Valkey and Redis; a raw command is an informed choice to send
/// whatever you typed, and pinning to one server's vendor-specific commands
/// is exactly the cost the design doc says it is.
extension ValkeyClientProtocol {
    /// Sends `name` with `arguments` verbatim and returns the raw
    /// `RESPToken` reply, to be decoded with `decode(as:)`.
    ///
    /// - Parameters:
    ///   - name: The command name (`"JSON.SET"`). Multi-word commands are
    ///     two arguments (`command("OBJECT", "ENCODING", key)`), exactly as
    ///     they are two RESP bulk strings on the wire.
    ///   - arguments: Command arguments. `String`, `Substring`, `Data`,
    ///     `[UInt8]` and `ByteBuffer` all conform; numbers are rendered by
    ///     the caller (`"\(count)"`) since RESP arguments are strings.
    ///   - keys: The keys the command touches — only consulted for slot
    ///     routing in cluster mode; harmless to omit otherwise.
    @discardableResult
    public func command(
        _ name: String,
        _ arguments: any RESPStringRenderable...,
        keys: [ValkeyKey] = []
    ) async throws -> RESPToken {
        try await execute(ValkeyRawCommand(name, arguments: arguments, keys: keys))
    }
}

/// §4.3's raw command as a `ValkeyCommand` value — usable anywhere a typed
/// command is: `execute`, pipelines, and `multi` batches.
public struct ValkeyRawCommand: ValkeyCommand {
    public typealias Response = RESPToken

    /// The protocol requirement is static (used for span naming); raw
    /// commands surface as "CUSTOM" there, with the real name in `command`.
    public static var name: String { "CUSTOM" }

    /// The command name sent on the wire.
    public var command: String
    /// The arguments, each rendered as one RESP bulk string.
    public var arguments: [any RESPStringRenderable]
    /// Keys for cluster slot routing.
    public var keysAffected: [ValkeyKey]

    public init(_ command: String, arguments: [any RESPStringRenderable], keys: [ValkeyKey] = []) {
        self.command = command
        self.arguments = arguments
        self.keysAffected = keys
    }

    public func encode(into commandEncoder: inout ValkeyCommandEncoder) {
        commandEncoder.encodeArray(command, arguments.map(RawBulkString.init))
    }

    // `ValkeyCommand` requires Hashable; `any RESPStringRenderable` refines
    // Hashable, so equality/hash go through existential opening.

    public static func == (lhs: ValkeyRawCommand, rhs: ValkeyRawCommand) -> Bool {
        guard lhs.command == rhs.command,
            lhs.keysAffected == rhs.keysAffected,
            lhs.arguments.count == rhs.arguments.count
        else { return false }
        for (left, right) in zip(lhs.arguments, rhs.arguments) where erased(left) != erased(right) {
            return false
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(command)
        hasher.combine(keysAffected)
        for argument in arguments {
            hasher.combine(erased(argument))
        }
    }
}

/// Opens the `any RESPStringRenderable` existential (which refines Hashable)
/// so raw commands can satisfy `ValkeyCommand`'s Hashable requirement.
private func erased(_ value: some RESPStringRenderable) -> AnyHashable {
    AnyHashable(value)
}

/// Bridges `any RESPStringRenderable` (one bulk string) into the
/// `RESPRenderable` currency `encodeArray` counts entries with. The driver
/// has the same internal adapter; it isn't public, so this package carries
/// its own.
struct RawBulkString: RESPRenderable {
    let value: any RESPStringRenderable

    var respEntries: Int { 1 }

    func encode(into commandEncoder: inout ValkeyCommandEncoder) {
        value.encode(into: &commandEncoder)
    }
}

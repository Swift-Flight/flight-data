import FlightCore
import FlightPubSub
import Foundation
import Testing
import Valkey

@testable import FlightPubSubValkey

/// The tests that need no server.
///
/// Both existing suites gate on `FLIGHT_VALKEY_TEST_URL`, so on a machine
/// without one this target proved nothing at all — and the two worst bugs it
/// shipped with were both in code a server never touches: `rediss://` accepted
/// with TLS never enabled, and `valkey://:secret@host` silently skipping
/// authentication. The cache adapter keeps exactly these tests server-free;
/// this is that, applied here.
@Suite("pubsub.valkey.url and the wire frame")
struct ValkeyPubSubSettingsTests {

    // MARK: - Schemes and TLS

    @Test("valkey:// and redis:// are the same plaintext connection")
    func plainSchemes() throws {
        for scheme in ["valkey", "redis"] {
            let url = try ValkeyPubSubSettings.parse("\(scheme)://localhost:6379")
            #expect(url.host == "localhost")
            #expect(url.port == 6379)
            #expect(url.useTLS == false)
        }
    }

    @Test("valkeys:// and rediss:// enable TLS")
    func tlsSchemes() throws {
        // The critical one. `rediss://` was accepted and TLS was never turned
        // on, so the client sent AUTH over plaintext RESP — the credential
        // leaked on the very path the operator asked to encrypt, and nothing
        // failed loudly enough to notice.
        for scheme in ["valkeys", "rediss"] {
            let url = try ValkeyPubSubSettings.parse("\(scheme)://localhost:6379")
            #expect(url.useTLS == true, "\(scheme):// must mean TLS")
        }
    }

    @Test("a TLS URL produces a client configuration with TLS on it")
    func tlsReachesTheClientConfiguration() throws {
        let settings = try ValkeyPubSubSettings.load(
            from: Configuration(values: [
                ValkeyPubSubConfigKey.url: "rediss://user:secret@valkey.internal:6380"
            ]))
        #expect(settings.useTLS)
        let configuration = try settings.clientConfiguration()
        #expect(tlsIsEnabled(configuration), "asking for rediss:// must actually configure TLS")
    }

    /// Whether a client configuration will actually negotiate TLS.
    ///
    /// Through reflection because valkey-swift's own `isEnabled` is
    /// package-internal — and asserting on our `useTLS` flag instead would be
    /// no test at all: the flag was parsed correctly the whole time the bug was
    /// live. What was missing was the line that carries it into the client.
    private func tlsIsEnabled(_ configuration: ValkeyClientConfiguration) -> Bool {
        let base = Mirror(reflecting: configuration.tls).children.first?.value
        return String(describing: base ?? "").hasPrefix("enable")
    }

    @Test("a plaintext URL leaves TLS off")
    func plaintextLeavesTLSOff() throws {
        let settings = try ValkeyPubSubSettings.load(
            from: Configuration(values: [
                ValkeyPubSubConfigKey.url: "valkey://localhost:6379"
            ]))
        #expect(!tlsIsEnabled(try settings.clientConfiguration()))
    }

    @Test("an unsupported scheme is refused at bootstrap")
    func unsupportedScheme() {
        #expect(throws: ValkeyPubSubConfigurationError.unsupportedScheme("http")) {
            _ = try ValkeyPubSubSettings.parse("http://localhost:6379")
        }
    }

    @Test("a URL with no host is refused")
    func missingHost() {
        #expect(throws: ValkeyPubSubConfigurationError.self) {
            _ = try ValkeyPubSubSettings.parse("valkey://")
        }
    }

    // MARK: - Authentication

    @Test("password-only userinfo authenticates as the default user")
    func passwordOnlyAuthenticates() throws {
        // `valkey://:secret@host` used to set `password` and leave `username`
        // nil, and the `if let username, let password` guard then skipped
        // authentication entirely — a server requiring AUTH refused every
        // command, with an error naming neither the cause nor the URL.
        let url = try ValkeyPubSubSettings.parse("valkey://:secret@localhost:6379")
        #expect(url.username == "default")
        #expect(url.password == "secret")

        let settings = try ValkeyPubSubSettings(
            host: url.host, port: url.port,
            username: url.username, password: url.password)
        let configuration = try settings.clientConfiguration()
        #expect(configuration.authentication != nil, "a password in the URL must be used")
    }

    @Test("user:password userinfo authenticates as that user")
    func usernameAndPassword() throws {
        let url = try ValkeyPubSubSettings.parse("valkey://app:secret@localhost:6379")
        #expect(url.username == "app")
        #expect(url.password == "secret")
    }

    @Test("a username with no password is a typo, not a connection")
    func usernameWithoutPasswordIsRefused() {
        // RESP AUTH is a pair; accepting this would silently drop the
        // username and connect unauthenticated.
        #expect(throws: ValkeyPubSubConfigurationError.usernameWithoutPassword) {
            _ = try ValkeyPubSubSettings.parse("valkey://app@localhost:6379")
        }
    }

    @Test("no userinfo means no authentication")
    func noUserinfo() throws {
        let url = try ValkeyPubSubSettings.parse("valkey://localhost:6379")
        #expect(url.username == nil)
        #expect(url.password == nil)
    }

    // MARK: - Database

    @Test("a database path segment selects that database")
    func databasePath() throws {
        // Previously accepted and silently ignored, so `valkey://host/3`
        // published to database 0 and an operator's two clusters were one.
        let url = try ValkeyPubSubSettings.parse("valkey://localhost:6379/3")
        #expect(url.database == 3)

        let settings = try ValkeyPubSubSettings(host: url.host, database: url.database)
        #expect(try settings.clientConfiguration().databaseNumber == 3)
    }

    @Test("no path means database 0")
    func noDatabasePath() throws {
        #expect(try ValkeyPubSubSettings.parse("valkey://localhost:6379").database == 0)
        #expect(try ValkeyPubSubSettings.parse("valkey://localhost:6379/").database == 0)
    }

    @Test("a path that is not a database number is refused")
    func invalidDatabasePath() {
        #expect(throws: ValkeyPubSubConfigurationError.self) {
            _ = try ValkeyPubSubSettings.parse("valkey://localhost:6379/notanumber")
        }
    }

    // MARK: - Configuration keys

    @Test("a missing url fails bootstrap with a message naming the key")
    func missingURL() {
        #expect(throws: ValkeyPubSubConfigurationError.missingURL) {
            _ = try ValkeyPubSubSettings.load(from: Configuration(values: [:]))
        }
        #expect(
            "\(ValkeyPubSubConfigurationError.missingURL)".contains("pubsub.valkey.url"),
            "the error has to name the key someone must set")
    }

    @Test("the channel defaults, and an empty one is refused")
    func channel() throws {
        let defaulted = try ValkeyPubSubSettings.load(
            from: Configuration(values: [ValkeyPubSubConfigKey.url: "valkey://localhost"]))
        #expect(defaulted.channel == ValkeyPubSubSettings.defaultChannel)

        let named = try ValkeyPubSubSettings.load(
            from: Configuration(values: [
                ValkeyPubSubConfigKey.url: "valkey://localhost",
                ValkeyPubSubConfigKey.channel: "rooms",
            ]))
        #expect(named.channel == "rooms")

        // Two nodes that disagree about the channel are silently deaf to each
        // other, so an empty one is worth refusing rather than defaulting.
        #expect(throws: ValkeyPubSubConfigurationError.emptyChannel) {
            _ = try ValkeyPubSubSettings.load(
                from: Configuration(values: [
                    ValkeyPubSubConfigKey.url: "valkey://localhost",
                    ValkeyPubSubConfigKey.channel: "",
                ]))
        }
    }

    @Test("timeouts are bounded rather than left at the driver's minute")
    func timeoutsAreHardened() throws {
        let settings = try ValkeyPubSubSettings.load(
            from: Configuration(values: [ValkeyPubSubConfigKey.url: "valkey://localhost"]))
        // The driver's own connection-creation breaker defaults to 60 seconds,
        // which is a minute of a publisher hanging on a fire-and-forget
        // broadcast to a server that is down.
        #expect(settings.commandTimeout == ValkeyPubSubSettings.defaultCommandTimeout)
        #expect(settings.unreachableAfter == settings.commandTimeout)

        let tuned = try ValkeyPubSubSettings.load(
            from: Configuration(values: [
                ValkeyPubSubConfigKey.url: "valkey://localhost",
                ValkeyPubSubConfigKey.commandTimeoutMilliseconds: "100",
                ValkeyPubSubConfigKey.unreachableAfterMilliseconds: "2000",
                ValkeyPubSubConfigKey.retryDelayMilliseconds: "250",
            ]))
        #expect(tuned.commandTimeout == .milliseconds(100))
        #expect(tuned.unreachableAfter == .milliseconds(2000))
        #expect(tuned.retryDelay == .milliseconds(250))
    }

    @Test("a non-positive timeout is refused rather than applied")
    func nonPositiveTimeout() {
        #expect(throws: ValkeyPubSubConfigurationError.self) {
            _ = try ValkeyPubSubSettings.load(
                from: Configuration(values: [
                    ValkeyPubSubConfigKey.url: "valkey://localhost",
                    ValkeyPubSubConfigKey.commandTimeoutMilliseconds: "0",
                ]))
        }
    }
}

/// The frame, which nothing used to check without a live server.
@Suite("The PubSub wire frame")
struct WireMessageTests {

    @Test("a message survives the round trip")
    func roundTrip() throws {
        let message = Message(
            topic: "room:42",
            payload: Data("hello".utf8),
            metadata: ["origin": "node-a", "seq": "7"])

        let decoded = try WireMessage.decode(try WireMessage.encode(message))
        #expect(decoded.topic == message.topic)
        #expect(decoded.payload == message.payload)
        #expect(decoded.metadata == message.metadata)
    }

    @Test("arbitrary bytes survive byte for byte")
    func binaryPayload() throws {
        let payload = Data((0...255).map(UInt8.init))
        let decoded = try WireMessage.decode(
            try WireMessage.encode(Message(topic: "t", payload: payload, metadata: [:])))
        #expect(decoded.payload == payload)
    }

    @Test("an empty payload round-trips")
    func emptyPayload() throws {
        let decoded = try WireMessage.decode(
            try WireMessage.encode(Message(topic: "t", payload: Data(), metadata: [:])))
        #expect(decoded.payload.isEmpty)
        #expect(decoded.topic == "t")
    }

    @Test("the payload crosses as bytes, not base64")
    func payloadIsNotInflated() throws {
        // The claim the old comment made and the old encoding did not keep:
        // `JSONEncoder` renders `Data` as base64, so every payload byte cost a
        // third more on the wire and an encode/decode on every hop.
        let payload = Data(repeating: 0xAB, count: 4096)
        let frame = try WireMessage.encode(
            Message(topic: "t", payload: payload, metadata: [:]))
        #expect(
            frame.count < payload.count + 256,
            "the payload is being re-encoded rather than carried verbatim")
        #expect(frame.suffix(payload.count) == payload)
    }

    @Test("a frame that is not ours is rejected rather than misread")
    func foreignFrameIsRejected() {
        #expect(throws: WireMessageError.notAFlightFrame) {
            _ = try WireMessage.decode(Data("not json".utf8))
        }
        #expect(throws: WireMessageError.notAFlightFrame) {
            _ = try WireMessage.decode(Data())
        }
    }

    @Test("a truncated frame is rejected rather than misread")
    func truncatedFrameIsRejected() throws {
        let frame = try WireMessage.encode(
            Message(topic: "t", payload: Data("x".utf8), metadata: [:]))
        #expect(throws: (any Error).self) {
            _ = try WireMessage.decode(frame.prefix(frame.count / 2))
        }
    }
}

import Foundation
import Logging
import Valkey

/// The integration gate. Uses database 3 — cache tests use 1 and data tests
/// use 2 — so no suite can flush another's keys. Pub/sub is not per-database
/// in Valkey, but the client still selects one, and keeping the convention
/// costs nothing.
enum PubSubTestServer {
    static var url: String? {
        let value = ProcessInfo.processInfo.environment["FLIGHT_VALKEY_TEST_URL"]
        return (value?.isEmpty == false) ? value : nil
    }

    static var isConfigured: Bool { url != nil }

    static var quietLogger: Logger {
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        return logger
    }

    static func client() throws -> ValkeyClient {
        guard let url, let parsed = URL(string: url), let host = parsed.host else {
            throw Missing()
        }
        return ValkeyClient(
            .hostname(host, port: parsed.port ?? 6379),
            configuration: ValkeyClientConfiguration(),
            logger: quietLogger)
    }

    struct Missing: Error {}
}

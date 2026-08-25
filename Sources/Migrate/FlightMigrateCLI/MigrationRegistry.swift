import FlightMigrate
import Foundation

/// Holds the migration list for the ArgumentParser commands.
///
/// ArgumentParser instantiates command values itself, so the registry can't be passed
/// through initializers; it is set once by `MigrateTool.main()` before parsing begins.
/// Guarded by a lock purely for strict-concurrency correctness.
enum MigrationRegistry {
    private static let storage = LockedBox<[MigrationEntry]>([])

    static func set(_ migrations: [MigrationEntry]) {
        storage.set(migrations)
    }

    static var migrations: [MigrationEntry] {
        storage.get()
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

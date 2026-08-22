import Foundation

/// The pluggable serialization seam (design §5). `Codable` is the
/// conformance requirement; the codec chooses the bytes. JSON is the
/// default — debuggable, inspectable in the backing store — with this
/// protocol as the seam for a binary format where it matters.
public protocol CacheCodec: Sendable {
    func encode<Value: Encodable>(_ value: Value) throws -> Data
    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value
}

/// The default codec (§5). Coders are constructed per call — they are not
/// `Sendable`, and construction is cheap next to the I/O this package
/// fronts. Top-level fragments (a cached `Int`, `String`, …) are supported
/// by Foundation's JSON coders on every platform Flight targets.
public struct JSONCacheCodec: CacheCodec {
    public init() {}

    public func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

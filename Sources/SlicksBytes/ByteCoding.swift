import Foundation

/// Compact little-endian binary encoding for network messages.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 64) {
        bytes.reserveCapacity(capacity)
    }

    public var data: Data { Data(bytes) }
    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    public mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { append(v) }
    public mutating func u32(_ v: UInt32) { append(v) }
    public mutating func u64(_ v: UInt64) { append(v) }
    public mutating func i32(_ v: Int32) { append(UInt32(bitPattern: v)) }
    public mutating func f64(_ v: Double) { append(v.bitPattern) }

    public mutating func optionalF64(_ v: Double?) {
        bool(v != nil)
        if let v { f64(v) }
    }

    /// UTF-8 with a 16-bit length prefix.
    public mutating func string(_ s: String) {
        let utf8 = Array(s.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(utf8.count))
        bytes += utf8
    }

    /// Raw bytes with a 32-bit length prefix.
    public mutating func blob(_ d: Data) {
        u32(UInt32(d.count))
        bytes += d
    }

    /// Raw bytes with no length prefix (fixed-size fields like keys).
    public mutating func raw<C: Collection>(_ b: C) where C.Element == UInt8 {
        bytes += b
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes += $0 }
    }
}

public enum WireError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalid(String)

    public var description: String {
        switch self {
        case .truncated: "message ended early"
        case let .invalid(what): "invalid \(what)"
        }
    }
}

/// Reads what `ByteWriter` wrote. Every read is bounds-checked: messages come from the network.
public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) { bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init<C: Collection>(slice: C) where C.Element == UInt8 { bytes = Array(slice) }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    public mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw WireError.invalid("bool")
        }
    }

    public mutating func u16() throws -> UInt16 { try read() }
    public mutating func u32() throws -> UInt32 { try read() }
    public mutating func u64() throws -> UInt64 { try read() }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try read() as UInt32) }
    public mutating func f64() throws -> Double { Double(bitPattern: try read()) }

    /// A double that must be a real number (no NaN or infinity).
    public mutating func finite() throws -> Double {
        let v = try f64()
        guard v.isFinite else { throw WireError.invalid("number") }
        return v
    }

    public mutating func optionalFinite() throws -> Double? {
        try bool() ? try finite() : nil
    }

    public mutating func string(maxLength: Int = 256) throws -> String {
        let n = Int(try u16())
        guard n <= maxLength else { throw WireError.invalid("string length") }
        guard remaining >= n else { throw WireError.truncated }
        defer { offset += n }
        guard let s = String(bytes: bytes[offset..<offset + n], encoding: .utf8) else { throw WireError.invalid("text") }
        return s
    }

    public mutating func blob(maxLength: Int) throws -> Data {
        let n = Int(try u32())
        guard n <= maxLength else { throw WireError.invalid("data length") }
        guard remaining >= n else { throw WireError.truncated }
        defer { offset += n }
        return Data(bytes[offset..<offset + n])
    }

    /// Exactly `count` raw bytes.
    public mutating func raw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// Everything left.
    public mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }

    private mutating func read<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var v: T = 0
        for i in 0..<size { v |= T(bytes[offset + i]) << (8 * i) }
        offset += size
        return v
    }
}

import Foundation

/// Lua 5.1 strings are arbitrary byte sequences, not Unicode strings.
/// This value type keeps the exact bytes while still offering UTF-8 helpers
/// for GMod/GLua source and logging.
public struct LuaString: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var count: Int { bytes.count }
    public var utf8: [UInt8] { bytes }
    public var isEmpty: Bool { bytes.isEmpty }

    /// Stable accounting estimate for a Lua string allocation. Swift owns the
    /// byte buffer through ARC rather than Lua's mark/sweep heap, but creating
    /// it is still mutator allocation work that must advance Lua's GC debt.
    /// The fixed component approximates the value and array-storage headers;
    /// exact allocator capacity is intentionally not part of the public count.
    var estimatedHeapByteCount: Int { 32 + bytes.count }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public var utf8String: String { description }

    public subscript(index: Int) -> UInt8 {
        bytes[index]
    }

    public func slice(_ range: Range<Int>) -> LuaString {
        LuaString(bytes: Array(bytes[range]))
    }

    public static func + (lhs: LuaString, rhs: LuaString) -> LuaString {
        LuaString(bytes: lhs.bytes + rhs.bytes)
    }

    public static func < (lhs: LuaString, rhs: LuaString) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public func lexicographicallyPrecedes(_ other: LuaString) -> Bool {
        self < other
    }

    public func lowercased() -> LuaString { LuaString(utf8String.lowercased()) }
    public func uppercased() -> LuaString { LuaString(utf8String.uppercased()) }
}

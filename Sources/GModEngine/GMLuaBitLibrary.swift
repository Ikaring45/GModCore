import Foundation
import GModLua

/// LuaJIT/Lua BitOp compatible 32-bit bitwise operations used by GLua.
public enum GMLuaBitLibrary {
    private static let helperPrefix = "__gmodlua_bit_"
    private static let functionNames = [
        "tobit", "tohex", "bnot", "band", "bor", "bxor",
        "lshift", "rshift", "arshift", "rol", "ror", "bswap"
    ]

    // LuaJIT's lj_vm_tobit uses the 2^52 + 2^51 trick. Reading the low
    // 32 bits of the resulting IEEE-754 representation gives the rounded,
    // modulo-2^32 operand without a trapping floating-point-to-int cast.
    private static let bitConversionBias = 6_755_399_441_055_744.0

    /// Installs the global `bit` table and `package.loaded.bit` module.
    /// Reinstalling updates an existing table in place so captured references
    /// remain valid across bootstrap/reload boundaries.
    public static func install(into state: LuaState) throws {
        state.register(helperPrefix + "tobit") { arguments in
            [.number(signedNumber(try operand(arguments, 0, "tobit")))]
        }
        state.register(helperPrefix + "tohex") { arguments in
            [.string(LuaString(try hexadecimal(arguments)))]
        }
        state.register(helperPrefix + "bnot") { arguments in
            [.number(signedNumber(~(try operand(arguments, 0, "bnot"))))]
        }
        state.register(helperPrefix + "band") { arguments in
            [.number(signedNumber(try reduce(arguments, "band", &)))]
        }
        state.register(helperPrefix + "bor") { arguments in
            [.number(signedNumber(try reduce(arguments, "bor", |)))]
        }
        state.register(helperPrefix + "bxor") { arguments in
            [.number(signedNumber(try reduce(arguments, "bxor", ^)))]
        }
        state.register(helperPrefix + "lshift") { arguments in
            let value = try operand(arguments, 0, "lshift")
            let shift = try shiftCount(arguments, "lshift")
            return [.number(signedNumber(value << shift))]
        }
        state.register(helperPrefix + "rshift") { arguments in
            let value = try operand(arguments, 0, "rshift")
            let shift = try shiftCount(arguments, "rshift")
            return [.number(signedNumber(value >> shift))]
        }
        state.register(helperPrefix + "arshift") { arguments in
            let value = Int32(bitPattern: try operand(arguments, 0, "arshift"))
            let shift = try shiftCount(arguments, "arshift")
            return [.number(Double(value >> shift))]
        }
        state.register(helperPrefix + "rol") { arguments in
            let value = try operand(arguments, 0, "rol")
            let shift = try shiftCount(arguments, "rol")
            let result = shift == 0 ? value : (value << shift) | (value >> (32 - shift))
            return [.number(signedNumber(result))]
        }
        state.register(helperPrefix + "ror") { arguments in
            let value = try operand(arguments, 0, "ror")
            let shift = try shiftCount(arguments, "ror")
            let result = shift == 0 ? value : (value >> shift) | (value << (32 - shift))
            return [.number(signedNumber(result))]
        }
        state.register(helperPrefix + "bswap") { arguments in
            [.number(signedNumber(try operand(arguments, 0, "bswap").byteSwapped))]
        }

        defer {
            for name in functionNames {
                state.setGlobal(helperPrefix + name, value: .nilValue)
            }
        }

        let assignments = functionNames.map { name in
            "module.\(name) = \(helperPrefix)\(name)"
        }.joined(separator: "\n")

        try state.execute(
            """
            local module = type(bit) == "table" and bit or {}
            \(assignments)
            bit = module
            package.loaded.bit = module
            """,
            sourceName: "=[GModLua bit library]"
        )
    }

    private static func operand(
        _ arguments: [LuaValue],
        _ index: Int,
        _ functionName: String
    ) throws -> UInt32 {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' (number expected, got no value)"
            )
        }
        guard let number = numericValue(arguments[index]) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' " +
                "(number expected, got \(arguments[index].typeName))"
            )
        }
        return normalize(number)
    }

    private static func normalize(_ number: Double) -> UInt32 {
        let biased = number + bitConversionBias
        return UInt32(truncatingIfNeeded: biased.bitPattern)
    }

    private static func signedNumber(_ bitPattern: UInt32) -> Double {
        Double(Int32(bitPattern: bitPattern))
    }

    private static func shiftCount(_ arguments: [LuaValue], _ functionName: String) throws -> Int {
        Int(try operand(arguments, 1, functionName) & 31)
    }

    private static func reduce(
        _ arguments: [LuaValue],
        _ functionName: String,
        _ combine: (UInt32, UInt32) -> UInt32
    ) throws -> UInt32 {
        var result = try operand(arguments, 0, functionName)
        for index in arguments.indices.dropFirst() {
            result = combine(result, try operand(arguments, index, functionName))
        }
        return result
    }

    private static func hexadecimal(_ arguments: [LuaValue]) throws -> String {
        var value = try operand(arguments, 0, "tohex")
        let requested: Int32
        if arguments.count >= 2 {
            requested = Int32(bitPattern: try operand(arguments, 1, "tohex"))
        } else {
            requested = 8
        }

        let uppercase = requested < 0
        let magnitude: UInt32
        if requested < 0 {
            magnitude = ~UInt32(bitPattern: requested) &+ 1
        } else {
            magnitude = UInt32(requested)
        }
        if magnitude < 8 {
            value &= (UInt32(1) << (magnitude * 4)) &- 1
        }

        let raw = String(value, radix: 16, uppercase: uppercase)

        // GMod currently embeds LuaJIT 2.1.0-beta3. Its formatter stores
        // precision as an 8-bit (n + 1) field: 254 is the largest padding
        // width, 255 selects unspecified precision, and larger widths wrap.
        // This behavior is observable through GMod's exported Lua C API.
        let encodedPrecision = UInt8(truncatingIfNeeded: magnitude &+ 1)
        guard encodedPrecision != 0 else { return raw }
        let precision = Int(encodedPrecision) - 1
        if precision == 0, value == 0 { return "" }
        if raw.count >= precision { return raw }
        return String(repeating: "0", count: precision - raw.count) + raw
    }

    private static func numericValue(_ value: LuaValue) -> Double? {
        switch value {
        case let .number(number):
            return number
        case let .string(string):
            let text = string.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
            return parseHexadecimalNumber(text) ?? Double(text)
        default:
            return nil
        }
    }

    /// LuaJIT's number scanner accepts hexadecimal numeric strings, including
    /// a fractional significand and a binary `p` exponent.
    private static func parseHexadecimalNumber(_ text: String) -> Double? {
        guard !text.isEmpty else { return nil }
        var cursor = text[...]
        var sign = 1.0
        if cursor.first == "+" {
            cursor.removeFirst()
        } else if cursor.first == "-" {
            sign = -1
            cursor.removeFirst()
        }
        guard cursor.hasPrefix("0x") || cursor.hasPrefix("0X") else { return nil }
        cursor.removeFirst(2)

        let exponentSplit = cursor.firstIndex { $0 == "p" || $0 == "P" }
        let significandText = exponentSplit.map { cursor[..<$0] } ?? cursor
        let exponentText = exponentSplit.map { cursor[cursor.index(after: $0)...] }
        guard !significandText.isEmpty else { return nil }

        var significand = 0.0
        var sawDigit = false
        var afterPoint = false
        var fractionalScale = 1.0
        for character in significandText {
            if character == "." {
                guard !afterPoint else { return nil }
                afterPoint = true
                continue
            }
            guard let digit = character.hexDigitValue else { return nil }
            sawDigit = true
            if afterPoint {
                fractionalScale /= 16
                significand += Double(digit) * fractionalScale
            } else {
                significand = significand * 16 + Double(digit)
            }
        }
        guard sawDigit else { return nil }

        var exponent = 0
        if let exponentText {
            guard !exponentText.isEmpty, let parsed = Int(exponentText) else { return nil }
            exponent = parsed
        }
        return sign * significand * Foundation.pow(2, Double(exponent))
    }
}

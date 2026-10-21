import Foundation

public enum GModJavaPropertiesParserError: Error, Equatable, CustomStringConvertible {
    case invalidUnicodeEscape(line: Int, escape: String)

    public var description: String {
        switch self {
        case let .invalidUnicodeEscape(line, escape):
            return "invalid Java properties Unicode escape at line \(line): \(escape)"
        }
    }
}

/// Parser for the Java `.properties` files shipped in GMod content packs.
/// It intentionally implements the file format rather than relying on
/// `NSDictionary(contentsOf:)`, which does not preserve Java continuation and
/// escape semantics consistently across Foundation versions.
public enum GModJavaPropertiesParser {
    public static func parse(data: Data) throws -> [String: String] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return try parse(text)
    }

    public static func parse(_ source: String) throws -> [String: String] {
        var normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.first?.value == 0xFEFF {
            normalized.removeFirst()
        }

        let physicalLines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var result: [String: String] = [:]
        var logicalLine = ""
        var logicalStartLine = 1
        var isContinuing = false

        func trailingBackslashCount(_ value: String) -> Int {
            var count = 0
            for scalar in value.unicodeScalars.reversed() {
                guard scalar.value == 0x5C else { break }
                count += 1
            }
            return count
        }

        for (index, slice) in physicalLines.enumerated() {
            var physical = String(slice)
            if isContinuing {
                while let first = physical.first,
                      Self.isPropertyWhitespace(first) {
                    physical.removeFirst()
                }
            } else {
                logicalLine = ""
                logicalStartLine = index + 1
            }
            logicalLine.append(physical)

            if trailingBackslashCount(logicalLine).isMultiple(of: 2) {
                try parseLogicalLine(
                    logicalLine,
                    lineNumber: logicalStartLine,
                    into: &result
                )
                logicalLine = ""
                isContinuing = false
            } else {
                logicalLine.removeLast()
                isContinuing = true
            }
        }

        if isContinuing || !logicalLine.isEmpty {
            try parseLogicalLine(
                logicalLine,
                lineNumber: logicalStartLine,
                into: &result
            )
        }
        return result
    }

    private static func parseLogicalLine(
        _ line: String,
        lineNumber: Int,
        into result: inout [String: String]
    ) throws {
        let scalars = Array(line.unicodeScalars)
        var start = 0
        while start < scalars.count, isPropertyWhitespace(scalars[start]) {
            start += 1
        }
        guard start < scalars.count,
              scalars[start].value != 0x23,
              scalars[start].value != 0x21 else {
            return
        }

        var separator = scalars.count
        var separatorWasWhitespace = false
        var escaped = false
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if escaped {
                escaped = false
            } else if scalar.value == 0x5C {
                escaped = true
            } else if scalar.value == 0x3D || scalar.value == 0x3A {
                separator = index
                break
            } else if isPropertyWhitespace(scalar) {
                separator = index
                separatorWasWhitespace = true
                break
            }
            index += 1
        }

        var valueStart = separator
        if separator < scalars.count {
            if separatorWasWhitespace {
                while valueStart < scalars.count,
                      isPropertyWhitespace(scalars[valueStart]) {
                    valueStart += 1
                }
                if valueStart < scalars.count,
                   scalars[valueStart].value == 0x3D
                    || scalars[valueStart].value == 0x3A {
                    valueStart += 1
                }
            } else {
                valueStart += 1
            }
            while valueStart < scalars.count,
                  isPropertyWhitespace(scalars[valueStart]) {
                valueStart += 1
            }
        }

        let rawKey = String(String.UnicodeScalarView(scalars[start..<separator]))
        let rawValue = valueStart < scalars.count
            ? String(String.UnicodeScalarView(scalars[valueStart...]))
            : ""
        let key = try unescape(rawKey, lineNumber: lineNumber)
        let value = try unescape(rawValue, lineNumber: lineNumber)
        result[key] = value
    }

    private static func unescape(
        _ raw: String,
        lineNumber: Int
    ) throws -> String {
        let scalars = Array(raw.unicodeScalars)
        var output: [UnicodeScalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x5C else {
                output.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else {
                output.append("\\")
                break
            }

            switch scalars[index].value {
            case 0x74:
                output.append("\t")
                index += 1
            case 0x6E:
                output.append("\n")
                index += 1
            case 0x72:
                output.append("\r")
                index += 1
            case 0x66:
                output.append("\u{000C}")
                index += 1
            case 0x75:
                let first = try unicodeUnit(
                    in: scalars,
                    uIndex: index,
                    lineNumber: lineNumber
                )
                index += 5
                if (0xD800...0xDBFF).contains(first) {
                    guard index + 5 < scalars.count,
                          scalars[index].value == 0x5C,
                          scalars[index + 1].value == 0x75 else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))"
                        )
                    }
                    let second = try unicodeUnit(
                        in: scalars,
                        uIndex: index + 1,
                        lineNumber: lineNumber
                    )
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))\\u\(hex(second))"
                        )
                    }
                    let scalarValue = 0x1_0000
                        + (UInt32(first - 0xD800) << 10)
                        + UInt32(second - 0xDC00)
                    guard let combined = UnicodeScalar(scalarValue) else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))\\u\(hex(second))"
                        )
                    }
                    output.append(combined)
                    index += 6
                } else {
                    guard !(0xDC00...0xDFFF).contains(first),
                          let decoded = UnicodeScalar(first) else {
                        throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                            line: lineNumber,
                            escape: "\\u\(hex(first))"
                        )
                    }
                    output.append(decoded)
                }
            default:
                // Java properties treats a backslash before an otherwise
                // unknown character as quoting that character.
                output.append(scalars[index])
                index += 1
            }
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func unicodeUnit(
        in scalars: [UnicodeScalar],
        uIndex: Int,
        lineNumber: Int
    ) throws -> UInt16 {
        guard uIndex + 4 < scalars.count else {
            let suffix = String(String.UnicodeScalarView(scalars[uIndex...]))
            throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                line: lineNumber,
                escape: "\\\(suffix)"
            )
        }
        let digits = scalars[(uIndex + 1)...(uIndex + 4)]
        var value: UInt16 = 0
        for scalar in digits {
            guard let nibble = hexValue(scalar) else {
                let escape = String(String.UnicodeScalarView(
                    scalars[uIndex...(uIndex + 4)]
                ))
                throw GModJavaPropertiesParserError.invalidUnicodeEscape(
                    line: lineNumber,
                    escape: "\\\(escape)"
                )
            }
            value = (value << 4) | UInt16(nibble)
        }
        return value
    }

    private static func hexValue(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        default: return nil
        }
    }

    private static func hex(_ value: UInt16) -> String {
        String(format: "%04X", value)
    }

    private static func isPropertyWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0C
    }

    private static func isPropertyWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{000C}"
    }
}

import Foundation

/// Authored native GameUI Scheme data, deliberately separate from Derma's
/// Default skin/GWEN atlas. The reference platform is explicit, not inferred
/// from the machine executing this parser (for example, an iPad host).
public struct SourceVGUIScheme: Equatable, Sendable {
    public struct BorderSegment: Equatable, Sendable {
        public let side: String
        public let depth: Int
        public let startOffset: Int
        public let endOffset: Int
        public let color: GMLuaPanelColorSnapshot
    }
    public enum SchemeError: Error, Equatable {
        case missingScheme
        case unresolvedDirective(String)
        case unsupportedConditional(String)
        case missingColor(String)
        case invalidColor(String)
        case aliasCycle(String)
        case unsupportedBorder(String)
        case missingFont(String)
        case unsupportedFont(String)
    }

    public let entries: [SourceKeyValuesParser.Entry]
    private let colors: [SourceKeyValuesParser.Entry]
    public let baseSettings: [SourceKeyValuesParser.Entry]
    /// Preserved for the native font/border adapters. Parsing these objects
    /// does not claim that a runtime has applied them.
    public let fonts: [SourceKeyValuesParser.Entry]
    public let borders: [SourceKeyValuesParser.Entry]

    public init(source: String, activeSymbols: Set<String>) throws {
        let known: Set<String> = ["WIN32", "WINDOWS", "X360", "LINUX", "OSX", "POSIX"]
        let active = Set(activeSymbols.map { $0.uppercased() })
        guard active.isSubset(of: known) else {
            throw SchemeError.unsupportedConditional(active.subtracting(known).sorted().joined(separator: ","))
        }
        var parser = SourceKeyValuesParser(source: source, options: .init(
            preserveKeyCase: true, preserveConditionals: true))
        func select(_ values: [SourceKeyValuesParser.Entry]) throws -> [SourceKeyValuesParser.Entry] {
            var result: [SourceKeyValuesParser.Entry] = []
            for entry in values {
                if entry.key.hasPrefix("#") { throw SchemeError.unresolvedDirective(entry.key) }
                if let expression = entry.conditional {
                    var symbol = expression.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let negated = symbol.hasPrefix("!")
                    if negated { symbol.removeFirst() }
                    guard symbol.hasPrefix("$"), known.contains(String(symbol.dropFirst())) else {
                        throw SchemeError.unsupportedConditional(expression)
                    }
                    let enabled = active.contains(String(symbol.dropFirst()))
                    if enabled == negated { continue }
                }
                let value: SourceKeyValuesParser.Value
                switch entry.value {
                case .string: value = entry.value
                case let .object(children): value = .object(try select(children))
                }
                result.append(.init(key: entry.key, value: value, conditional: nil))
            }
            return result
        }
        entries = try select(parser.parse())
        guard let root = entries.first(where: { $0.key.caseInsensitiveCompare("Scheme") == .orderedSame }),
              case let .object(children) = root.value else { throw SchemeError.missingScheme }
        func section(_ name: String) -> [SourceKeyValuesParser.Entry] {
            guard let entry = children.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }),
                  case let .object(fields) = entry.value else { return [] }
            return fields
        }
        colors = section("Colors")
        baseSettings = section("BaseSettings")
        fonts = section("Fonts")
        borders = section("Borders")
    }

    /// Native KeyValues lookup is ordered and case-insensitive. Keep the first
    /// surviving key, rather than letting dictionary construction choose a
    /// platform's duplicate arbitrarily.
    public func string(_ name: String) -> String? {
        for fields in [baseSettings, colors] {
            if let entry = fields.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }),
               case let .string(value) = entry.value { return value }
        }
        return nil
    }

    public func color(_ name: String) throws -> GMLuaPanelColorSnapshot {
        var key = name
        var seen: Set<String> = []
        while true {
            guard seen.insert(key.lowercased()).inserted else { throw SchemeError.aliasCycle(name) }
            guard let value = string(key) else { throw SchemeError.missingColor(key) }
            if string(value) != nil { key = value; continue }
            let components = value.split(whereSeparator: { $0.isWhitespace })
            if components.count == 3 || components.count == 4 {
                let bytes = components.compactMap { UInt8($0) }
                guard bytes.count == components.count else { throw SchemeError.invalidColor(key) }
                return .init(red: Double(bytes[0]), green: Double(bytes[1]), blue: Double(bytes[2]),
                    alpha: components.count == 4 ? Double(bytes[3]) : 255)
            }
            guard components.count == 1, Double(value) == nil else { throw SchemeError.invalidColor(key) }
            key = value
        }
    }

    /// Authored ordered line borders, retaining each edge's endpoint trims.
    /// Image/rounded/custom backgrounds remain explicit unsupported cases.
    public func borderSegments(_ name: String) throws -> [BorderSegment] {
        var key = name
        var seen: Set<String> = []
        while true {
            guard seen.insert(key.lowercased()).inserted else { throw SchemeError.aliasCycle(name) }
            guard let entry = borders.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw SchemeError.unsupportedBorder(name)
            }
            if case let .string(alias) = entry.value { key = alias; continue }
            guard case let .object(fields) = entry.value else { throw SchemeError.unsupportedBorder(name) }
            guard fields.allSatisfy({ ["inset", "left", "right", "top", "bottom"].contains($0.key.lowercased()) }) else {
                throw SchemeError.unsupportedBorder(name)
            }
            var result: [BorderSegment] = []
            for side in ["Left", "Right", "Top", "Bottom"] {
                guard let edge = fields.first(where: { $0.key.caseInsensitiveCompare(side) == .orderedSame }),
                      case let .object(lines) = edge.value else { throw SchemeError.unsupportedBorder(name) }
                for (depth, line) in lines.enumerated() {
                    guard case let .object(properties) = line.value,
                          properties.allSatisfy({ ["color", "offset"].contains($0.key.lowercased()) }) else {
                        throw SchemeError.unsupportedBorder(name)
                    }
                    func field(_ key: String) -> String? {
                        guard let property = properties.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
                              case let .string(value) = property.value else { return nil }
                        return value
                    }
                    let parts = (field("offset") ?? "").split(whereSeparator: { $0.isWhitespace })
                    let offsets = parts.compactMap { Int32($0) }.map(Int.init)
                    guard parts.count == 2, offsets.count == 2, offsets.allSatisfy({ $0 >= 0 }), let colorName = field("color") else {
                        throw SchemeError.unsupportedBorder(name)
                    }
                    result.append(.init(side: side.lowercased(), depth: depth, startOffset: offsets[0],
                        endOffset: offsets[1], color: try color(colorName)))
                }
            }
            return result
        }
    }

    public func flatBorderColor(_ name: String) throws -> GMLuaPanelColorSnapshot {
        let segments = try borderSegments(name)
        guard let first = segments.first, segments.count == 4,
              segments.allSatisfy({ $0.depth == 0 && $0.startOffset == 0 && $0.endOffset == 0 && $0.color == first.color }) else {
            throw SchemeError.unsupportedBorder(name)
        }
        return first.color
    }
}

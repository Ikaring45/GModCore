import Foundation

/// Source GameUI resource data, independent of GLua's deprecated/no-op
/// LoadControlsFromString API. Preserve every field for the native adapter;
/// parsing an unknown ControlName does not claim that its behavior exists.
public struct SourceVGUIResource: Equatable, Sendable {
    public struct Control: Equatable, Sendable {
        public let name: String
        public let entries: [SourceKeyValuesParser.Entry]
        public let conditional: String?

        public func value(_ key: String) -> String? {
            // KeyValues::FindKey returns the first case-insensitive match.
            // GLua table conversion has a separate, intentionally different contract.
            guard let entry = entries.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
                  case let .string(value) = entry.value else { return nil }
            return value
        }

        public var controlName: String? { value("ControlName") }
        public var fieldName: String { value("fieldName") ?? name }

        public func frame(parent: GMLuaPanelRect, screen: GMLuaPanelRect) throws -> GMLuaPanelRect {
            func number(_ text: String, field: String) throws -> Double {
                guard let value = Double(text), value.isFinite else {
                    throw ResourceError.unsupportedCoordinate(control: name, field: field, value: text)
                }
                return value
            }
            let width = try number(value("wide") ?? "0", field: "wide")
            let height = try number(value("tall") ?? "0", field: "tall")
            guard width >= 0, height >= 0 else { throw ResourceError.negativeSize(name) }
            func position(_ field: String, extent: Double, screenExtent: Double, size: Double) throws -> Double {
                let text = value(field) ?? "0"
                if text.hasPrefix("r") {
                    // LoadingDialogGMod.res explicitly defines rY in screen
                    // space, not relative to an intermediate parent panel.
                    return screenExtent - size - (try number(String(text.dropFirst()), field: field))
                }
                if text.hasPrefix("c") {
                    let offset = text.dropFirst()
                    return extent / 2 + (try number(offset.isEmpty ? "0" : String(offset), field: field))
                }
                return try number(text, field: field)
            }
            return try GMLuaPanelRect(
                x: position("xpos", extent: parent.width, screenExtent: screen.width, size: width),
                y: position("ypos", extent: parent.height, screenExtent: screen.height, size: height),
                width: width, height: height
            )
        }
    }

    public enum ResourceError: Error, Equatable {
        case unsupportedCoordinate(control: String, field: String, value: String)
        case negativeSize(String)
        case missingRoot
        case unsupportedConditional(String)
    }

    public let name: String
    public let controls: [Control]
    public let entries: [SourceKeyValuesParser.Entry]
    /// Includes are kept explicit until the mounting adapter resolves them.
    /// Do not silently ignore #base/#include or platform conditionals.
    public let directives: [SourceKeyValuesParser.Entry]

    /// Omitting activeSymbols preserves conditionals for a later mounting
    /// adapter. Supplying a reference platform resolves them before lookup.
    public init(source: String, activeSymbols: Set<String>? = nil) throws {
        var parser = SourceKeyValuesParser(source: source, options: .init(
            preserveKeyCase: true, preserveConditionals: true
        ))
        var entries = try parser.parse()
        if let activeSymbols {
            do {
                entries = try SourceKeyValuesPlatformSelection.select(entries, activeSymbols: activeSymbols)
            } catch let SourceKeyValuesPlatformSelection.SelectionError.unsupportedConditional(expression) {
                throw ResourceError.unsupportedConditional(expression)
            }
        }
        self.entries = entries
        guard let root = entries.first(where: {
            if case .object = $0.value { return true }
            return false
        }), case let .object(children) = root.value else { throw ResourceError.missingRoot }
        name = root.key
        directives = entries.filter { $0.key.hasPrefix("#") }
        controls = children.compactMap { entry in
            guard case let .object(fields) = entry.value else { return nil }
            return Control(name: entry.key, entries: fields, conditional: entry.conditional)
        }
    }
}

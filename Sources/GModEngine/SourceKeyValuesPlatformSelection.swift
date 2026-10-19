import Foundation

/// Select a deliberately bounded Source reference platform, not the platform
/// running the host. Compound/unknown expressions must not silently disappear.
enum SourceKeyValuesPlatformSelection {
    enum SelectionError: Error {
        case unsupportedConditional(String)
        case unresolvedDirective(String)
    }

    static func select(_ entries: [SourceKeyValuesParser.Entry], activeSymbols: Set<String>,
                       rejectDirectives: Bool = false) throws -> [SourceKeyValuesParser.Entry] {
        let known: Set<String> = ["WIN32", "WINDOWS", "X360", "LINUX", "OSX", "POSIX"]
        let active = Set(activeSymbols.map { $0.uppercased() })
        guard active.isSubset(of: known) else {
            throw SelectionError.unsupportedConditional(active.subtracting(known).sorted().joined(separator: ","))
        }
        func selected(_ values: [SourceKeyValuesParser.Entry]) throws -> [SourceKeyValuesParser.Entry] {
            var result: [SourceKeyValuesParser.Entry] = []
            for entry in values {
                if rejectDirectives && entry.key.hasPrefix("#") {
                    throw SelectionError.unresolvedDirective(entry.key)
                }
                if let expression = entry.conditional {
                    var symbol = expression.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let negated = symbol.hasPrefix("!")
                    if negated { symbol.removeFirst() }
                    guard symbol.hasPrefix("$"), known.contains(String(symbol.dropFirst())) else {
                        throw SelectionError.unsupportedConditional(expression)
                    }
                    if active.contains(String(symbol.dropFirst())) == negated { continue }
                }
                let value: SourceKeyValuesParser.Value
                switch entry.value {
                case .string: value = entry.value
                case let .object(children): value = .object(try selected(children))
                }
                result.append(.init(key: entry.key, value: value, conditional: nil))
            }
            return result
        }
        return try selected(entries)
    }
}

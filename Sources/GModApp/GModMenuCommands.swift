import Foundation

enum GModHomeMenuAction: Equatable, Sendable {
    case startMap(String)
    case setLanguage(String)
    case hideGameUI
    case openOptions
    case openProblems
    case disconnect
    case quit
}

enum GModHomeMenuCommandParser {
    static func parse(_ source: String) -> GModHomeMenuAction? {
        if let arguments = callArguments(
            function: "RunConsoleCommand",
            in: source
        ), let command = arguments.first?.lowercased() {
            switch command {
            case "map":
                guard arguments.count > 1, !arguments[1].isEmpty else {
                    return nil
                }
                return .startMap(arguments[1])
            case "gmod_language":
                guard arguments.count > 1, !arguments[1].isEmpty else {
                    return nil
                }
                return .setLanguage(arguments[1])
            case "gamemenucommand":
                guard arguments.count > 1 else { return nil }
                switch arguments[1].lowercased() {
                case "openoptionsdialog":
                    return .openOptions
                case "openproblemspanel", "openproblemsdialog":
                    return .openProblems
                default:
                    break
                }
            case "disconnect":
                return .disconnect
            case "quit", "exit":
                return .quit
            default:
                break
            }
        }

        let compact = source
            .filter { !$0.isWhitespace }
            .lowercased()
        if compact.contains("gui.hidegameui()") {
            return .hideGameUI
        }
        if callArguments(function: "OpenProblemsPanel", in: source) != nil {
            return .openProblems
        }
        if callArguments(function: "OpenOptionsDialog", in: source) != nil {
            return .openOptions
        }
        return nil
    }

    private static func callArguments(
        function: String,
        in source: String
    ) -> [String]? {
        let characters = Array(source)
        let needle = Array(function.lowercased())
        guard !needle.isEmpty, characters.count >= needle.count else {
            return nil
        }

        var start = 0
        var quote: Character?
        var escaped = false
        while start + needle.count <= characters.count {
            let current = characters[start]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if current == "\\" {
                    escaped = true
                } else if current == activeQuote {
                    quote = nil
                }
                start += 1
                continue
            }
            if current == "\"" || current == "'" {
                quote = current
                start += 1
                continue
            }
            if current == "-", start + 1 < characters.count,
               characters[start + 1] == "-" {
                while start < characters.count, characters[start] != "\n" {
                    start += 1
                }
                continue
            }
            let candidate = String(characters[start..<(start + needle.count)])
                .lowercased()
            if candidate == String(needle) {
                let previousIsIdentifier = start > 0
                    && isIdentifier(characters[start - 1])
                var open = start + needle.count
                while open < characters.count, characters[open].isWhitespace {
                    open += 1
                }
                if !previousIsIdentifier,
                   open < characters.count,
                   characters[open] == "(" {
                    return parseArguments(characters, afterOpenParenthesis: open)
                }
            }
            start += 1
        }
        return nil
    }

    private static func parseArguments(
        _ characters: [Character],
        afterOpenParenthesis open: Int
    ) -> [String]? {
        var arguments: [String] = []
        var index = open + 1
        while index < characters.count {
            skipWhitespace(characters, index: &index)
            if index < characters.count, characters[index] == ")" {
                return arguments
            }
            guard index < characters.count else { return nil }

            let value: String
            if characters[index] == "\"" || characters[index] == "'" {
                guard let parsed = parseQuotedString(characters, index: &index) else {
                    return nil
                }
                value = parsed
            } else {
                let start = index
                while index < characters.count,
                      characters[index] != ",",
                      characters[index] != ")" {
                    index += 1
                }
                value = String(characters[start..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            arguments.append(value)
            skipWhitespace(characters, index: &index)

            guard index < characters.count else { return nil }
            if characters[index] == ")" { return arguments }
            guard characters[index] == "," else { return nil }
            index += 1
        }
        return nil
    }

    private static func parseQuotedString(
        _ characters: [Character],
        index: inout Int
    ) -> String? {
        let quote = characters[index]
        index += 1
        var result = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == quote { return result }
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard index < characters.count else { return nil }
            let escaped = characters[index]
            index += 1
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            default: result.append(escaped)
            }
        }
        return nil
    }

    private static func skipWhitespace(
        _ characters: [Character],
        index: inout Int
    ) {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}

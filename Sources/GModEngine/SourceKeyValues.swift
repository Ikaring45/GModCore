import Foundation
import GModLua

public enum SourceKeyValuesError: Error, CustomStringConvertible, Equatable {
    case unexpectedToken(line: Int, column: Int, expected: String)
    case unterminatedString(line: Int, column: Int)
    case unterminatedConditional(line: Int, column: Int)
    case missingClosingBrace(line: Int, column: Int)

    public var description: String {
        switch self {
        case let .unexpectedToken(line, column, expected):
            return "KeyValues parse error \(line):\(column): expected \(expected)"
        case let .unterminatedString(line, column):
            return "KeyValues parse error \(line):\(column): unterminated quoted string"
        case let .unterminatedConditional(line, column):
            return "KeyValues parse error \(line):\(column): unterminated conditional"
        case let .missingClosingBrace(line, column):
            return "KeyValues parse error \(line):\(column): missing closing brace"
        }
    }
}

/// Parser for the text form of Source/Valve KeyValues 1.
///
/// It deliberately preserves entries as an ordered list before conversion to
/// Lua. That makes duplicate-key behavior explicit and also supports the
/// `KeyValuesToTablePreserveOrder` surface without reparsing.
public struct SourceKeyValuesParser {
    public struct Options: Sendable {
        public var usesEscapeSequences: Bool
        public var preserveKeyCase: Bool
        public var preserveConditionals: Bool

        public init(
            usesEscapeSequences: Bool = false,
            preserveKeyCase: Bool = false,
            preserveConditionals: Bool = false
        ) {
            self.usesEscapeSequences = usesEscapeSequences
            self.preserveKeyCase = preserveKeyCase
            self.preserveConditionals = preserveConditionals
        }
    }

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: Value
        public let conditional: String?
    }

    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case object([Entry])
    }

    private enum Token: Equatable {
        case text(String, line: Int, column: Int)
        case leftBrace(line: Int, column: Int)
        case rightBrace(line: Int, column: Int)
        case conditional(String, line: Int, column: Int)
        case eof(line: Int, column: Int)

        var location: (line: Int, column: Int) {
            switch self {
            case let .text(_, line, column),
                 let .leftBrace(line, column),
                 let .rightBrace(line, column),
                 let .conditional(_, line, column),
                 let .eof(line, column):
                return (line, column)
            }
        }
    }

    private let options: Options
    private var lexer: Lexer
    private var lookahead: Token?

    public init(source: String, options: Options = Options()) {
        self.options = options
        self.lexer = Lexer(source: source, usesEscapeSequences: options.usesEscapeSequences)
    }

    public mutating func parse() throws -> [Entry] {
        try parseEntries(expectingClosingBrace: false)
    }

    private mutating func parseEntries(expectingClosingBrace: Bool) throws -> [Entry] {
        var entries: [Entry] = []
        while true {
            let token = try peek()
            switch token {
            case .eof:
                if expectingClosingBrace {
                    let location = token.location
                    throw SourceKeyValuesError.missingClosingBrace(
                        line: location.line,
                        column: location.column
                    )
                }
                return entries
            case .rightBrace:
                if !expectingClosingBrace {
                    let location = token.location
                    throw SourceKeyValuesError.unexpectedToken(
                        line: location.line,
                        column: location.column,
                        expected: "a key"
                    )
                }
                _ = try consume()
                return entries
            case .conditional:
                let location = token.location
                throw SourceKeyValuesError.unexpectedToken(
                    line: location.line,
                    column: location.column,
                    expected: "a key before the conditional"
                )
            case .leftBrace:
                let location = token.location
                throw SourceKeyValuesError.unexpectedToken(
                    line: location.line,
                    column: location.column,
                    expected: "a key before '{'"
                )
            case let .text(rawKey, _, _):
                _ = try consume()
                let key = options.preserveKeyCase ? rawKey : rawKey.lowercased()
                let valueToken = try consume()
                let value: Value
                switch valueToken {
                case let .text(text, _, _):
                    value = .string(text)
                case .leftBrace:
                    value = .object(try parseEntries(expectingClosingBrace: true))
                default:
                    let location = valueToken.location
                    throw SourceKeyValuesError.unexpectedToken(
                        line: location.line,
                        column: location.column,
                        expected: "a value or '{'"
                    )
                }

                var conditional: String?
                if case let .conditional(expression, _, _) = try peek() {
                    _ = try consume()
                    if options.preserveConditionals { conditional = expression }
                }
                entries.append(Entry(key: key, value: value, conditional: conditional))
            }
        }
    }

    private mutating func peek() throws -> Token {
        if let lookahead { return lookahead }
        let token = try lexer.nextToken()
        lookahead = token
        return token
    }

    private mutating func consume() throws -> Token {
        if let lookahead {
            self.lookahead = nil
            return lookahead
        }
        return try lexer.nextToken()
    }

    private struct Lexer {
        private let characters: [Character]
        private let usesEscapeSequences: Bool
        private var index = 0
        private var line = 1
        private var column = 1

        init(source: String, usesEscapeSequences: Bool) {
            self.characters = Array(source)
            self.usesEscapeSequences = usesEscapeSequences
        }

        mutating func nextToken() throws -> Token {
            skipWhitespaceAndComments()
            let startLine = line
            let startColumn = column
            guard let character = current else {
                return .eof(line: line, column: column)
            }
            switch character {
            case "{":
                advance()
                return .leftBrace(line: startLine, column: startColumn)
            case "}":
                advance()
                return .rightBrace(line: startLine, column: startColumn)
            case "\"":
                return .text(
                    try quotedString(startLine: startLine, startColumn: startColumn),
                    line: startLine,
                    column: startColumn
                )
            case "[":
                return .conditional(
                    try conditional(startLine: startLine, startColumn: startColumn),
                    line: startLine,
                    column: startColumn
                )
            default:
                var text = ""
                while let current,
                      !current.isWhitespace,
                      current != "{", current != "}", current != "[", current != "\"" {
                    text.append(current)
                    advance()
                }
                if text.isEmpty {
                    advance()
                }
                return .text(text, line: startLine, column: startColumn)
            }
        }

        private mutating func skipWhitespaceAndComments() {
            while true {
                while let current, current.isWhitespace { advance() }
                guard current == "/", peekCharacter == "/" else { return }
                while let current, !current.isNewline { advance() }
            }
        }

        private mutating func quotedString(startLine: Int, startColumn: Int) throws -> String {
            advance() // opening quote
            var result = ""
            while let character = current {
                if character == "\"" {
                    advance()
                    return result
                }
                if character == "\\", let escaped = peekCharacter {
                    // A backslash-quote never ends the token. Whether the
                    // slash is retained follows usesEscapeSequences.
                    if ["\"", "\\", "n", "r", "t"].contains(escaped) {
                        advance()
                        advance()
                        if usesEscapeSequences {
                            switch escaped {
                            case "n": result.append("\n")
                            case "r": result.append("\r")
                            case "t": result.append("\t")
                            case "\"": result.append("\"")
                            case "\\": result.append("\\")
                            default: break
                            }
                        } else {
                            result.append("\\")
                            result.append(escaped)
                        }
                        continue
                    }
                }
                result.append(character)
                advance()
            }
            throw SourceKeyValuesError.unterminatedString(line: startLine, column: startColumn)
        }

        private mutating func conditional(startLine: Int, startColumn: Int) throws -> String {
            advance() // opening bracket
            var result = ""
            while let character = current {
                if character == "]" {
                    advance()
                    return result.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                result.append(character)
                advance()
            }
            throw SourceKeyValuesError.unterminatedConditional(line: startLine, column: startColumn)
        }

        private var current: Character? {
            index < characters.count ? characters[index] : nil
        }

        private var peekCharacter: Character? {
            index + 1 < characters.count ? characters[index + 1] : nil
        }

        private mutating func advance() {
            guard index < characters.count else { return }
            let character = characters[index]
            index += 1
            if character.isNewline {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
    }
}

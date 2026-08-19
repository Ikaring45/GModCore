import Foundation

public enum LuaSourceDecoder {
    /// Lua 5.1 source is byte-oriented. Invalid UTF-8 bytes are represented by
    /// private-use scalars so the lexer can restore them without expansion.
    public static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var scalars = String.UnicodeScalarView()
        for byte in data {
            let value = byte < 0x80 ? UInt32(byte) : 0xE000 + UInt32(byte)
            guard let scalar = UnicodeScalar(value) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

enum LuaTokenKind: Equatable {
    case identifier(String)
    case number(Double)
    case string(LuaString)

    case keywordLocal, keywordFunction, keywordEnd, keywordReturn
    case keywordTrue, keywordFalse, keywordNil
    case keywordIf, keywordThen, keywordElseif, keywordElse
    case keywordWhile, keywordDo, keywordRepeat, keywordUntil
    case keywordFor, keywordIn, keywordBreak, keywordContinue
    case keywordAnd, keywordOr, keywordNot

    case plus, minus, star, slash, percent, caret
    case hash
    case leftParen, rightParen
    case leftBrace, rightBrace
    case leftBracket, rightBracket
    case comma, semicolon
    case assign
    case equal, notEqual, less, lessEqual, greater, greaterEqual
    case dot, concat, vararg
    case colon
    case eof
}

struct LuaToken {
    let kind: LuaTokenKind
    let line: Int
    let column: Int
}

final class LuaLexer {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var column = 1

    init(source: String) {
        // Lua treats CR, LF, CRLF, and LFCR as a single line ending and
        // normalizes line breaks captured by strings to LF.
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\r", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.characters = Array(normalized)
    }

    func tokenize() throws -> [LuaToken] {
        var tokens: [LuaToken] = []

        // Lua's standalone loader ignores an initial Unix shebang line.
        if index == 0, peek() == "#", peek(1) == "!" {
            skipLineComment()
        }

        while !isAtEnd {
            let startLine = line
            let startColumn = column
            let character = advance()

            if character.isWhitespace { continue }

            switch character {
            case "+": tokens.append(token(.plus, startLine, startColumn))
            case "*": tokens.append(token(.star, startLine, startColumn))
            case "%": tokens.append(token(.percent, startLine, startColumn))
            case "^": tokens.append(token(.caret, startLine, startColumn))
            case "#": tokens.append(token(.hash, startLine, startColumn))
            case "(": tokens.append(token(.leftParen, startLine, startColumn))
            case ")": tokens.append(token(.rightParen, startLine, startColumn))
            case "{": tokens.append(token(.leftBrace, startLine, startColumn))
            case "}": tokens.append(token(.rightBrace, startLine, startColumn))
            case "]": tokens.append(token(.rightBracket, startLine, startColumn))
            case ",": tokens.append(token(.comma, startLine, startColumn))
            case ";": tokens.append(token(.semicolon, startLine, startColumn))
            case ":": tokens.append(token(.colon, startLine, startColumn))

            case "-":
                if peek() == "-" {
                    _ = advance()
                    if peek() == "[" {
                        _ = advance() // first '['
                        if let level = consumeLongBracketOpeningIfPresent() {
                            _ = try scanLongBracketBody(level: level, collect: false, startLine: startLine, startColumn: startColumn)
                        } else {
                            // It was just --[... rather than a long comment.
                            skipLineComment()
                        }
                    } else {
                        skipLineComment()
                    }
                } else {
                    tokens.append(token(.minus, startLine, startColumn))
                }

            case "/":
                if peek() == "/" { // GLua
                    _ = advance(); skipLineComment()
                } else if peek() == "*" { // GLua
                    _ = advance(); try skipCStyleBlockComment(startLine: startLine, startColumn: startColumn)
                } else {
                    tokens.append(token(.slash, startLine, startColumn))
                }

            case "=":
                if peek() == "=" { _ = advance(); tokens.append(token(.equal, startLine, startColumn)) }
                else { tokens.append(token(.assign, startLine, startColumn)) }

            case "~":
                guard peek() == "=" else { throw lexerError(startLine, startColumn, "unexpected '~'") }
                _ = advance(); tokens.append(token(.notEqual, startLine, startColumn))

            case "!": // GLua
                if peek() == "=" { _ = advance(); tokens.append(token(.notEqual, startLine, startColumn)) }
                else { tokens.append(token(.keywordNot, startLine, startColumn)) }

            case "&": // GLua &&
                guard peek() == "&" else { throw lexerError(startLine, startColumn, "expected '&' after '&'") }
                _ = advance(); tokens.append(token(.keywordAnd, startLine, startColumn))

            case "|": // GLua ||
                guard peek() == "|" else { throw lexerError(startLine, startColumn, "expected '|' after '|'") }
                _ = advance(); tokens.append(token(.keywordOr, startLine, startColumn))

            case "<":
                if peek() == "=" { _ = advance(); tokens.append(token(.lessEqual, startLine, startColumn)) }
                else { tokens.append(token(.less, startLine, startColumn)) }

            case ">":
                if peek() == "=" { _ = advance(); tokens.append(token(.greaterEqual, startLine, startColumn)) }
                else { tokens.append(token(.greater, startLine, startColumn)) }

            case ".":
                if peek() == ".", peek(1) == "." {
                    _ = advance(); _ = advance(); tokens.append(token(.vararg, startLine, startColumn))
                } else if peek() == "." {
                    _ = advance(); tokens.append(token(.concat, startLine, startColumn))
                } else if let next = peek(), next.isNumber {
                    let value = try scanDecimalNumber(first: ".", startLine: startLine, startColumn: startColumn)
                    tokens.append(token(.number(value), startLine, startColumn))
                } else {
                    tokens.append(token(.dot, startLine, startColumn))
                }

            case "[":
                if let level = consumeLongBracketOpeningIfPresent() {
                    let text = try scanLongBracketBody(level: level, collect: true, startLine: startLine, startColumn: startColumn)
                    tokens.append(token(.string(text), startLine, startColumn))
                } else {
                    tokens.append(token(.leftBracket, startLine, startColumn))
                }

            case "\"", "'":
                tokens.append(token(.string(try scanQuotedString(quote: character, startLine: startLine, startColumn: startColumn)), startLine, startColumn))

            default:
                if character.isNumber {
                    tokens.append(token(.number(try scanNumber(first: character, startLine: startLine, startColumn: startColumn)), startLine, startColumn))
                } else if character.isLetter || character == "_" {
                    let name = scanIdentifier(first: character)
                    tokens.append(token(keywordOrIdentifier(name), startLine, startColumn))
                } else {
                    throw lexerError(startLine, startColumn, "unexpected character '\(character)'")
                }
            }
        }

        tokens.append(LuaToken(kind: .eof, line: line, column: column))
        return tokens
    }

    private var isAtEnd: Bool { index >= characters.count }

    @discardableResult
    private func advance() -> Character {
        let value = characters[index]
        index += 1
        if value == "\n" { line += 1; column = 1 }
        else { column += 1 }
        return value
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let target = index + offset
        guard target >= 0, target < characters.count else { return nil }
        return characters[target]
    }

    private func skipLineComment() {
        while let value = peek(), value != "\n" { _ = advance() }
    }

    private func skipCStyleBlockComment(startLine: Int, startColumn: Int) throws {
        while !isAtEnd {
            if peek() == "*", peek(1) == "/" { _ = advance(); _ = advance(); return }
            _ = advance()
        }
        throw lexerError(startLine, startColumn, "unfinished block comment")
    }

    /// Called after the first '[' is already consumed. Accepts [[ and [=[ etc.
    private func consumeLongBracketOpeningIfPresent() -> Int? {
        var offset = 0
        while peek(offset) == "=" { offset += 1 }
        guard peek(offset) == "[" else { return nil }
        for _ in 0..<offset { _ = advance() }
        _ = advance()
        return offset
    }

    private func scanLongBracketBody(
        level: Int,
        collect: Bool,
        startLine: Int,
        startColumn: Int
    ) throws -> LuaString {
        var bytes: [UInt8] = []

        // Lua ignores the first newline immediately after an opening long bracket.
        if peek() == "\n" { _ = advance() }
        else if peek() == "\r" {
            _ = advance(); if peek() == "\n" { _ = advance() }
        }

        while !isAtEnd {
            if matchesLongBracketClose(level: level) {
                _ = advance()
                for _ in 0..<level { _ = advance() }
                _ = advance()
                return LuaString(bytes: bytes)
            }
            let value = advance()
            if collect { appendSourceBytes(value, to: &bytes) }
        }

        throw lexerError(startLine, startColumn, "unfinished long string/comment")
    }

    private func matchesLongBracketClose(level: Int) -> Bool {
        guard peek() == "]" else { return false }
        for i in 0..<level where peek(1 + i) != "=" { return false }
        return peek(1 + level) == "]"
    }

    private func scanNumber(first: Character, startLine: Int, startColumn: Int) throws -> Double {
        if first == "0", peek() == "x" || peek() == "X" {
            _ = advance()
            var digits = ""
            while let c = peek(), c.isHexDigit { digits.append(advance()) }
            guard !digits.isEmpty, let intValue = UInt64(digits, radix: 16) else {
                throw lexerError(startLine, startColumn, "malformed number")
            }
            return Double(intValue)
        }
        return try scanDecimalNumber(first: first, startLine: startLine, startColumn: startColumn)
    }

    private func scanDecimalNumber(first: Character, startLine: Int, startColumn: Int) throws -> Double {
        var text = String(first)
        while let value = peek(), value.isNumber { text.append(advance()) }

        if peek() == ".", peek(1) != "." {
            text.append(advance())
            while let value = peek(), value.isNumber { text.append(advance()) }
        }

        if peek() == "e" || peek() == "E" {
            text.append(advance())
            if peek() == "+" || peek() == "-" { text.append(advance()) }
            guard let digit = peek(), digit.isNumber else { throw lexerError(startLine, startColumn, "malformed number") }
            while let value = peek(), value.isNumber { text.append(advance()) }
        }

        guard let value = Double(text) else { throw lexerError(startLine, startColumn, "malformed number") }
        return value
    }

    private func scanIdentifier(first: Character) -> String {
        var text = String(first)
        while let value = peek(), value.isLetter || value.isNumber || value == "_" { text.append(advance()) }
        return text
    }

    private func keywordOrIdentifier(_ name: String) -> LuaTokenKind {
        switch name {
        case "local": return .keywordLocal
        case "function": return .keywordFunction
        case "end": return .keywordEnd
        case "return": return .keywordReturn
        case "true": return .keywordTrue
        case "false": return .keywordFalse
        case "nil": return .keywordNil
        case "if": return .keywordIf
        case "then": return .keywordThen
        case "elseif": return .keywordElseif
        case "else": return .keywordElse
        case "while": return .keywordWhile
        case "do": return .keywordDo
        case "repeat": return .keywordRepeat
        case "until": return .keywordUntil
        case "for": return .keywordFor
        case "in": return .keywordIn
        case "break": return .keywordBreak
        case "continue": return .keywordContinue // GLua extension
        case "and": return .keywordAnd
        case "or": return .keywordOr
        case "not": return .keywordNot
        default: return .identifier(name)
        }
    }

    private func scanQuotedString(quote: Character, startLine: Int, startColumn: Int) throws -> LuaString {
        var bytes: [UInt8] = []

        while !isAtEnd {
            let value = advance()
            if value == quote { return LuaString(bytes: bytes) }
            if value == "\n" || value == "\r" { throw lexerError(startLine, startColumn, "unfinished string") }

            if value != "\\" {
                appendSourceBytes(value, to: &bytes)
                continue
            }

            guard !isAtEnd else { break }
            let escaped = advance()
            switch escaped {
            case "a": bytes.append(7)
            case "b": bytes.append(8)
            case "f": bytes.append(12)
            case "n": bytes.append(10)
            case "r": bytes.append(13)
            case "t": bytes.append(9)
            case "v": bytes.append(11)
            case "\\": bytes.append(92)
            case "\"": bytes.append(34)
            case "'": bytes.append(39)
            case "\n": bytes.append(10)
            case "\r":
                if peek() == "\n" { _ = advance() }
                bytes.append(10)
            default:
                if escaped.isNumber {
                    var digits = String(escaped)
                    for _ in 0..<2 {
                        if let next = peek(), next.isNumber { digits.append(advance()) } else { break }
                    }
                    guard let integer = Int(digits), integer <= 255 else {
                        throw lexerError(startLine, startColumn, "escape sequence too large")
                    }
                    bytes.append(UInt8(integer))
                } else {
                    // Lua 5.1 accepts unknown escapes by dropping the backslash.
                    appendSourceBytes(escaped, to: &bytes)
                }
            }
        }

        throw lexerError(startLine, startColumn, "unfinished string")
    }

    private func appendSourceBytes(_ character: Character, to bytes: inout [UInt8]) {
        let text = String(character)
        let scalars = Array(text.unicodeScalars)
        if scalars.count == 1 {
            let value = scalars[0].value
            if (0xE080...0xE0FF).contains(value) {
                bytes.append(UInt8(value - 0xE000))
                return
            }
        }
        bytes.append(contentsOf: text.utf8)
    }

    private func token(_ kind: LuaTokenKind, _ line: Int, _ column: Int) -> LuaToken {
        LuaToken(kind: kind, line: line, column: column)
    }

    private func lexerError(_ line: Int, _ column: Int, _ message: String) -> LuaError {
        .lexer(line: line, column: column, message: message)
    }
}

private extension Character {
    var isHexDigit: Bool {
        isNumber || ("a"..."f").contains(String(self).lowercased())
    }
}

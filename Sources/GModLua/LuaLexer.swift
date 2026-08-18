enum LuaTokenKind: Equatable {

    case identifier(String)
    case number(Double)
    case string(String)

    case keywordLocal
    case keywordTrue
    case keywordFalse
    case keywordNil

    case plus
    case minus
    case star
    case slash
    case percent

    case leftParen
    case rightParen

    case comma
    case equal
    case semicolon

    case eof
}

struct LuaToken {

    let kind: LuaTokenKind

    let line: Int
    let column: Int
}

final class LuaLexer {

    private let characters:
        [Character]

    private var index = 0
    private var line = 1
    private var column = 1

    init(
        source: String
    ) {

        self.characters =
            Array(source)
    }

    func tokenize()
        throws -> [LuaToken]
    {

        var tokens:
            [LuaToken] = []

        while !isAtEnd {

            let startLine =
                line

            let startColumn =
                column

            let character =
                advance()

            if character.isWhitespace {
                continue
            }

            switch character {

            case "+":

                tokens.append(
                    token(
                        .plus,
                        startLine,
                        startColumn
                    )
                )

            case "-":

                if peek() == "-" {

                    while
                        let value = peek(),
                        value != "\n"
                    {
                        _ = advance()
                    }

                } else {

                    tokens.append(
                        token(
                            .minus,
                            startLine,
                            startColumn
                        )
                    )
                }

            case "*":

                tokens.append(
                    token(
                        .star,
                        startLine,
                        startColumn
                    )
                )

            case "/":

                tokens.append(
                    token(
                        .slash,
                        startLine,
                        startColumn
                    )
                )

            case "%":

                tokens.append(
                    token(
                        .percent,
                        startLine,
                        startColumn
                    )
                )

            case "(":

                tokens.append(
                    token(
                        .leftParen,
                        startLine,
                        startColumn
                    )
                )

            case ")":

                tokens.append(
                    token(
                        .rightParen,
                        startLine,
                        startColumn
                    )
                )

            case ",":

                tokens.append(
                    token(
                        .comma,
                        startLine,
                        startColumn
                    )
                )

            case "=":

                tokens.append(
                    token(
                        .equal,
                        startLine,
                        startColumn
                    )
                )

            case ";":

                tokens.append(
                    token(
                        .semicolon,
                        startLine,
                        startColumn
                    )
                )

            case "\"", "'":

                let value =
                    try scanString(
                        quote: character,
                        line: startLine,
                        column: startColumn
                    )

                tokens.append(
                    token(
                        .string(value),
                        startLine,
                        startColumn
                    )
                )

            default:

                if character.isNumber {

                    let value =
                        try scanNumber(
                            first: character,
                            line: startLine,
                            column: startColumn
                        )

                    tokens.append(
                        token(
                            .number(value),
                            startLine,
                            startColumn
                        )
                    )

                } else if
                    character.isLetter ||
                    character == "_"
                {

                    let name =
                        scanIdentifier(
                            first:
                                character
                        )

                    tokens.append(
                        token(
                            keywordOrIdentifier(
                                name
                            ),
                            startLine,
                            startColumn
                        )
                    )

                } else {

                    throw LuaError.lexer(
                        line: startLine,
                        column: startColumn,
                        message:
                            "unexpected character '\(character)'"
                    )
                }
            }
        }

        tokens.append(
            LuaToken(
                kind: .eof,
                line: line,
                column: column
            )
        )

        return tokens
    }

    private var isAtEnd: Bool {
        index >=
            characters.count
    }

    @discardableResult
    private func advance()
        -> Character
    {

        let value =
            characters[index]

        index += 1

        if value == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }

        return value
    }

    private func peek(
        _ offset: Int = 0
    ) -> Character? {

        let target =
            index + offset

        guard
            target >= 0,
            target <
                characters.count
        else {
            return nil
        }

        return characters[target]
    }

    private func scanNumber(
        first: Character,
        line: Int,
        column: Int
    ) throws -> Double {

        var text =
            String(first)

        while
            let value = peek(),
            value.isNumber
        {
            text.append(
                advance()
            )
        }

        if
            peek() == ".",
            let next = peek(1),
            next.isNumber
        {

            text.append(
                advance()
            )

            while
                let value = peek(),
                value.isNumber
            {
                text.append(
                    advance()
                )
            }
        }

        guard
            let value =
                Double(text)
        else {

            throw LuaError.lexer(
                line: line,
                column: column,
                message:
                    "invalid number '\(text)'"
            )
        }

        return value
    }

    private func scanIdentifier(
        first: Character
    ) -> String {

        var text =
            String(first)

        while
            let value = peek(),
            value.isLetter ||
            value.isNumber ||
            value == "_"
        {

            text.append(
                advance()
            )
        }

        return text
    }

    private func keywordOrIdentifier(
        _ name: String
    ) -> LuaTokenKind {

        switch name {

        case "local":
            return .keywordLocal

        case "true":
            return .keywordTrue

        case "false":
            return .keywordFalse

        case "nil":
            return .keywordNil

        default:
            return .identifier(
                name
            )
        }
    }

    private func scanString(
        quote: Character,
        line startLine: Int,
        column startColumn: Int
    ) throws -> String {

        var result = ""

        while !isAtEnd {

            let value =
                advance()

            if value == quote {
                return result
            }

            if value == "\n" {

                throw LuaError.lexer(
                    line: startLine,
                    column:
                        startColumn,
                    message:
                        "unfinished string"
                )
            }

            if value == "\\" {

                guard !isAtEnd else {
                    break
                }

                let escaped =
                    advance()

                switch escaped {

                case "n":
                    result.append("\n")

                case "r":
                    result.append("\r")

                case "t":
                    result.append("\t")

                case "\\":
                    result.append("\\")

                case "\"":
                    result.append("\"")

                case "'":
                    result.append("'")

                default:
                    result.append(
                        escaped
                    )
                }

            } else {

                result.append(
                    value
                )
            }
        }

        throw LuaError.lexer(
            line: startLine,
            column: startColumn,
            message:
                "unfinished string"
        )
    }

    private func token(
        _ kind: LuaTokenKind,
        _ line: Int,
        _ column: Int
    ) -> LuaToken {

        LuaToken(
            kind: kind,
            line: line,
            column: column
        )
    }
}

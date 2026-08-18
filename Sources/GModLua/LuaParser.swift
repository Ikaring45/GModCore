indirect enum LuaExpression {

    case number(Double)
    case string(String)
    case boolean(Bool)
    case nilValue

    case variable(String)

    case unary(
        LuaUnaryOperator,
        LuaExpression
    )

    case binary(
        LuaExpression,
        LuaBinaryOperator,
        LuaExpression
    )

    case call(
        String,
        [LuaExpression]
    )
}

enum LuaUnaryOperator {
    case negate
}

enum LuaBinaryOperator {

    case add
    case subtract
    case multiply
    case divide
    case modulo
}

enum LuaStatement {

    case localDeclaration(
        String,
        LuaExpression?
    )

    case assignment(
        String,
        LuaExpression
    )

    case expression(
        LuaExpression
    )
}

struct LuaChunk {

    let statements:
        [LuaStatement]
}

final class LuaParser {

    private let tokens:
        [LuaToken]

    private var current = 0

    init(
        tokens: [LuaToken]
    ) {

        self.tokens =
            tokens
    }

    func parse()
        throws -> LuaChunk
    {

        var statements:
            [LuaStatement] = []

        while !check(.eof) {

            while match(.semicolon) {
            }

            if check(.eof) {
                break
            }

            statements.append(
                try parseStatement()
            )

            _ = match(
                .semicolon
            )
        }

        return LuaChunk(
            statements:
                statements
        )
    }

    private func parseStatement()
        throws -> LuaStatement
    {

        if match(
            .keywordLocal
        ) {

            return try
                parseLocalDeclaration()
        }

        if
            case let .identifier(name) =
                peek.kind,
            checkNext(.equal)
        {

            _ = advance()

            try consume(
                .equal,
                "expected '='"
            )

            let value =
                try parseExpression()

            return .assignment(
                name,
                value
            )
        }

        return .expression(
            try parseExpression()
        )
    }

    private func parseLocalDeclaration()
        throws -> LuaStatement
    {

        let name =
            try consumeIdentifier(
                "expected local variable name"
            )

        var initializer:
            LuaExpression?

        if match(.equal) {

            initializer =
                try parseExpression()
        }

        return .localDeclaration(
            name,
            initializer
        )
    }

    private func parseExpression()
        throws -> LuaExpression
    {

        try parseAddition()
    }

    private func parseAddition()
        throws -> LuaExpression
    {

        var expression =
            try parseMultiplication()

        while true {

            if match(.plus) {

                expression =
                    .binary(
                        expression,
                        .add,
                        try parseMultiplication()
                    )

            } else if match(.minus) {

                expression =
                    .binary(
                        expression,
                        .subtract,
                        try parseMultiplication()
                    )

            } else {
                break
            }
        }

        return expression
    }

    private func parseMultiplication()
        throws -> LuaExpression
    {

        var expression =
            try parseUnary()

        while true {

            if match(.star) {

                expression =
                    .binary(
                        expression,
                        .multiply,
                        try parseUnary()
                    )

            } else if match(.slash) {

                expression =
                    .binary(
                        expression,
                        .divide,
                        try parseUnary()
                    )

            } else if match(.percent) {

                expression =
                    .binary(
                        expression,
                        .modulo,
                        try parseUnary()
                    )

            } else {
                break
            }
        }

        return expression
    }

    private func parseUnary()
        throws -> LuaExpression
    {

        if match(.minus) {

            return .unary(
                .negate,
                try parseUnary()
            )
        }

        return try
            parsePrimary()
    }

    private func parsePrimary()
        throws -> LuaExpression
    {

        let token =
            peek

        switch token.kind {

        case let .number(value):

            _ = advance()

            return .number(
                value
            )

        case let .string(value):

            _ = advance()

            return .string(
                value
            )

        case .keywordTrue:

            _ = advance()

            return .boolean(
                true
            )

        case .keywordFalse:

            _ = advance()

            return .boolean(
                false
            )

        case .keywordNil:

            _ = advance()

            return .nilValue

        case let .identifier(name):

            _ = advance()

            if match(
                .leftParen
            ) {

                var arguments:
                    [LuaExpression] = []

                if !check(
                    .rightParen
                ) {

                    repeat {

                        arguments.append(
                            try parseExpression()
                        )

                    } while match(
                        .comma
                    )
                }

                try consume(
                    .rightParen,
                    "expected ')'"
                )

                return .call(
                    name,
                    arguments
                )
            }

            return .variable(
                name
            )

        case .leftParen:

            _ = advance()

            let expression =
                try parseExpression()

            try consume(
                .rightParen,
                "expected ')'"
            )

            return expression

        default:

            throw LuaError.parser(
                line: token.line,
                column:
                    token.column,
                message:
                    "expected expression"
            )
        }
    }

    private var peek:
        LuaToken
    {
        tokens[current]
    }

    @discardableResult
    private func advance()
        -> LuaToken
    {

        let result =
            tokens[current]

        if !check(.eof) {
            current += 1
        }

        return result
    }

    private func check(
        _ kind: LuaTokenKind
    ) -> Bool {

        peek.kind == kind
    }

    private func checkNext(
        _ kind: LuaTokenKind
    ) -> Bool {

        guard
            current + 1 <
                tokens.count
        else {
            return false
        }

        return
            tokens[current + 1]
                .kind == kind
    }

    private func match(
        _ kind: LuaTokenKind
    ) -> Bool {

        guard check(kind)
        else {
            return false
        }

        _ = advance()

        return true
    }

    private func consume(
        _ kind: LuaTokenKind,
        _ message: String
    ) throws {

        guard match(kind)
        else {

            throw LuaError.parser(
                line: peek.line,
                column:
                    peek.column,
                message:
                    message
            )
        }
    }

    private func consumeIdentifier(
        _ message: String
    ) throws -> String {

        guard
            case let .identifier(name) =
                peek.kind
        else {

            throw LuaError.parser(
                line: peek.line,
                column:
                    peek.column,
                message:
                    message
            )
        }

        _ = advance()

        return name
    }
}

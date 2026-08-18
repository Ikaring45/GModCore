indirect enum LuaExpression {

    case number(
        Double
    )

    case string(
        String
    )

    case boolean(
        Bool
    )

    case nilValue

    case variable(
        String
    )

    case table(
        [LuaTableField]
    )

    case function(
        parameters: [String],
        body: [LuaStatement]
    )

    case field(
        LuaExpression,
        String
    )

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
        LuaExpression,
        [LuaExpression]
    )

    case methodCall(
        LuaExpression,
        String,
        [LuaExpression]
    )
}

enum LuaTableField {

    case named(
        String,
        LuaExpression
    )

    case array(
        LuaExpression
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

indirect enum LuaAssignmentTarget {

    case variable(
        String
    )

    case field(
        LuaExpression,
        String
    )
}

enum LuaStatement {

    case localDeclaration(
        String,
        LuaExpression?
    )

    case localFunction(
        String,
        [String],
        [LuaStatement]
    )

    case assignment(
        LuaAssignmentTarget,
        LuaExpression
    )

    case functionDeclaration(
        LuaAssignmentTarget,
        [String],
        [LuaStatement]
    )

    case returnValues(
        [LuaExpression]
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

        LuaChunk(
            statements:
                try parseBlock(
                    untilEnd:
                        false
                )
        )
    }

    private func parseBlock(
        untilEnd: Bool
    ) throws -> [LuaStatement] {

        var statements:
            [LuaStatement] = []

        while !check(.eof) {

            while match(
                .semicolon
            ) {
            }

            if
                check(.eof) ||
                (
                    untilEnd &&
                    check(.keywordEnd)
                )
            {
                break
            }

            statements.append(
                try parseStatement()
            )

            _ = match(
                .semicolon
            )
        }

        return statements
    }

    private func parseStatement()
        throws -> LuaStatement
    {

        if match(
            .keywordLocal
        ) {

            if match(
                .keywordFunction
            ) {

                let name =
                    try consumeIdentifier(
                        "expected local function name"
                    )

                let (
                    parameters,
                    body
                ) =
                    try parseFunctionTail(
                        prependSelf:
                            false
                    )

                return .localFunction(
                    name,
                    parameters,
                    body
                )
            }

            return try
                parseLocalDeclaration()
        }

        if match(
            .keywordFunction
        ) {

            return try
                parseNamedFunctionDeclaration()
        }

        if match(
            .keywordReturn
        ) {

            return try
                parseReturn()
        }

        let expression =
            try parseExpression()

        if match(.equal) {

            let target =
                try assignmentTarget(
                    from:
                        expression
                )

            return .assignment(
                target,
                try parseExpression()
            )
        }

        return .expression(
            expression
        )
    }

    private func parseLocalDeclaration()
        throws -> LuaStatement
    {

        let name =
            try consumeIdentifier(
                "expected local variable name"
            )

        let initializer =
            match(.equal)
                ? try parseExpression()
                : nil

        return .localDeclaration(
            name,
            initializer
        )
    }

    private func parseNamedFunctionDeclaration()
        throws -> LuaStatement
    {

        let firstName =
            try consumeIdentifier(
                "expected function name"
            )

        var targetExpression =
            LuaExpression.variable(
                firstName
            )

        /*
         function a.b.c()
        */
        while match(.dot) {

            let fieldName =
                try consumeIdentifier(
                    "expected field name after '.'"
                )

            targetExpression =
                .field(
                    targetExpression,
                    fieldName
                )
        }

        /*
         function t:GetValue()

         は内部的に

         t.GetValue =
             function(self)

         と同じ。
        */
        var prependSelf =
            false

        if match(.colon) {

            let methodName =
                try consumeIdentifier(
                    "expected method name after ':'"
                )

            targetExpression =
                .field(
                    targetExpression,
                    methodName
                )

            prependSelf =
                true
        }

        let target =
            try assignmentTarget(
                from:
                    targetExpression
            )

        let (
            parameters,
            body
        ) =
            try parseFunctionTail(
                prependSelf:
                    prependSelf
            )

        return .functionDeclaration(
            target,
            parameters,
            body
        )
    }

    private func parseReturn()
        throws -> LuaStatement
    {

        if
            check(.keywordEnd) ||
            check(.semicolon) ||
            check(.eof)
        {

            return .returnValues(
                []
            )
        }

        var values:
            [LuaExpression] = [

                try parseExpression()
            ]

        while match(.comma) {

            values.append(
                try parseExpression()
            )
        }

        return .returnValues(
            values
        )
    }

    private func parseFunctionTail(
        prependSelf: Bool
    ) throws -> (
        [String],
        [LuaStatement]
    ) {

        try consume(
            .leftParen,
            "expected '('"
        )

        var parameters:
            [String] =
                prependSelf
                    ? ["self"]
                    : []

        if !check(
            .rightParen
        ) {

            repeat {

                parameters.append(
                    try consumeIdentifier(
                        "expected parameter name"
                    )
                )

            } while match(
                .comma
            )
        }

        try consume(
            .rightParen,
            "expected ')'"
        )

        let body =
            try parseBlock(
                untilEnd:
                    true
            )

        try consume(
            .keywordEnd,
            "expected 'end' after function body"
        )

        return (
            parameters,
            body
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
            parsePostfix()
    }

    private func parsePostfix()
        throws -> LuaExpression
    {

        var expression =
            try parsePrimary()

        while true {

            /*
             self.value
            */
            if match(.dot) {

                let name =
                    try consumeIdentifier(
                        "expected field name after '.'"
                    )

                expression =
                    .field(
                        expression,
                        name
                    )

            /*
             t:GetValue()
            */
            } else if match(.colon) {

                let name =
                    try consumeIdentifier(
                        "expected method name after ':'"
                    )

                try consume(
                    .leftParen,
                    "expected '(' after method name"
                )

                expression =
                    .methodCall(
                        expression,
                        name,
                        try parseArgumentsAfterOpenParen()
                    )

            /*
             counter()
             makeCounter()
             print(...)
            */
            } else if match(
                .leftParen
            ) {

                expression =
                    .call(
                        expression,
                        try parseArgumentsAfterOpenParen()
                    )

            } else {

                break
            }
        }

        return expression
    }

    private func parsePrimary()
        throws -> LuaExpression
    {

        let token =
            peek

        switch token.kind {

        case let .number(
            value
        ):

            _ = advance()

            return .number(
                value
            )

        case let .string(
            value
        ):

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

        case let .identifier(
            name
        ):

            _ = advance()

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

        case .leftBrace:

            _ = advance()

            return try
                parseTableConstructor()

        /*
         function()
             ...
         end
        */
        case .keywordFunction:

            _ = advance()

            let (
                parameters,
                body
            ) =
                try parseFunctionTail(
                    prependSelf:
                        false
                )

            return .function(
                parameters:
                    parameters,
                body:
                    body
            )

        default:

            throw LuaError.parser(
                line:
                    token.line,
                column:
                    token.column,
                message:
                    "expected expression"
            )
        }
    }

    private func parseTableConstructor()
        throws -> LuaExpression
    {

        var fields:
            [LuaTableField] = []

        while !check(
            .rightBrace
        ) {

            /*
             {
                 value = 42
             }
            */
            if
                case let
                    .identifier(name) =
                    peek.kind,
                checkNext(.equal)
            {

                _ = advance()

                try consume(
                    .equal,
                    "expected '=' after table field name"
                )

                fields.append(
                    .named(
                        name,
                        try parseExpression()
                    )
                )

            /*
             {
                 10,
                 20,
                 30
             }
            */
            } else {

                fields.append(
                    .array(
                        try parseExpression()
                    )
                )
            }

            if
                match(.comma) ||
                match(.semicolon)
            {

                if check(
                    .rightBrace
                ) {
                    break
                }

                continue
            }

            break
        }

        try consume(
            .rightBrace,
            "expected '}'"
        )

        return .table(
            fields
        )
    }

    private func parseArgumentsAfterOpenParen()
        throws -> [LuaExpression]
    {

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

        return arguments
    }

    private func assignmentTarget(
        from expression:
            LuaExpression
    ) throws -> LuaAssignmentTarget {

        switch expression {

        case let .variable(
            name
        ):

            return .variable(
                name
            )

        case let .field(
            base,
            name
        ):

            return .field(
                base,
                name
            )

        default:

            throw LuaError.parser(
                line:
                    peek.line,
                column:
                    peek.column,
                message:
                    "invalid assignment target"
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
        _ kind:
            LuaTokenKind
    ) -> Bool {

        peek.kind ==
            kind
    }

    private func checkNext(
        _ kind:
            LuaTokenKind
    ) -> Bool {

        guard
            current + 1 <
                tokens.count
        else {
            return false
        }

        return
            tokens[
                current + 1
            ].kind == kind
    }

    private func match(
        _ kind:
            LuaTokenKind
    ) -> Bool {

        guard check(kind)
        else {
            return false
        }

        _ = advance()

        return true
    }

    private func consume(
        _ kind:
            LuaTokenKind,
        _ message:
            String
    ) throws {

        guard match(kind)
        else {

            throw LuaError.parser(
                line:
                    peek.line,
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
            case let
                .identifier(name) =
                peek.kind
        else {

            throw LuaError.parser(
                line:
                    peek.line,
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

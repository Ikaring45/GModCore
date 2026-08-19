indirect enum LuaExpression {
    case number(Double)
    case string(LuaString)
    case boolean(Bool)
    case nilValue
    case variable(String)
    case vararg
    case group(LuaExpression)
    case table([LuaTableField])
    case function(LuaFunctionPrototype)
    case field(LuaExpression, String)
    case index(LuaExpression, LuaExpression)
    case unary(LuaUnaryOperator, LuaExpression)
    case binary(LuaExpression, LuaBinaryOperator, LuaExpression)
    case call(LuaExpression, [LuaExpression])
    case methodCall(LuaExpression, String, [LuaExpression])
}

enum LuaTableField {
    case named(String, LuaExpression)
    case indexed(LuaExpression, LuaExpression)
    case array(LuaExpression)
}

enum LuaUnaryOperator { case negate, not, length }

enum LuaBinaryOperator {
    case add, subtract, multiply, divide, modulo, power
    case concat
    case equal, notEqual, less, lessEqual, greater, greaterEqual
    case and, or
}

struct LuaFunctionPrototype {
    let parameters: [String]
    let isVararg: Bool
    let body: [LuaStatement]
    let lineDefined: Int
    let lastLineDefined: Int
    let activeLines: Set<Int>
}

indirect enum LuaAssignmentTarget {
    case variable(String)
    case field(LuaExpression, String)
    case index(LuaExpression, LuaExpression)
}

struct LuaIfBranch {
    let condition: LuaExpression
    let conditionLine: Int
    let body: [LuaStatement]
}

enum LuaStatement {
    case localDeclaration([String], [LuaExpression], line: Int)
    case localFunction(String, LuaFunctionPrototype, line: Int)
    case assignment([LuaAssignmentTarget], [LuaExpression], line: Int)
    case functionDeclaration(LuaAssignmentTarget, LuaFunctionPrototype, line: Int)
    case ifStatement([LuaIfBranch], elseBody: [LuaStatement]?, endLine: Int)
    case whileLoop(LuaExpression, [LuaStatement], conditionLine: Int, endLine: Int)
    case repeatLoop([LuaStatement], LuaExpression, conditionLine: Int)
    case numericFor(String, LuaExpression, LuaExpression, LuaExpression?, [LuaStatement], line: Int, endLine: Int)
    case genericFor([String], [LuaExpression], [LuaStatement], line: Int, endLine: Int)
    case doBlock([LuaStatement])
    case breakLoop(line: Int)
    case continueLoop(line: Int)
    case returnValues([LuaExpression], line: Int)
    case expression(LuaExpression, line: Int)
}

struct LuaChunk { let statements: [LuaStatement] }

final class LuaParser {
    private let tokens: [LuaToken]
    private var current = 0

    init(tokens: [LuaToken]) { self.tokens = tokens }

    func parse() throws -> LuaChunk {
        LuaChunk(statements: try parseBlock { kind in kind == .eof })
    }

    private func parseBlock(until shouldStop: (LuaTokenKind) -> Bool) throws -> [LuaStatement] {
        var statements: [LuaStatement] = []
        while !shouldStop(peek.kind) {
            while match(.semicolon) {}
            if shouldStop(peek.kind) { break }
            statements.append(try parseStatement())
            _ = match(.semicolon)
        }
        return statements
    }

    private func parseStatement() throws -> LuaStatement {
        let statementLine = peek.line
        if match(.keywordLocal) {
            if match(.keywordFunction) {
                let lineDefined = previous.line
                let name = try consumeIdentifier("expected local function name")
                let prototype = try parseFunctionTail(prependSelf: false, lineDefined: lineDefined)
                return .localFunction(name, prototype, line: statementLine)
            }
            return try parseLocalDeclaration(line: statementLine)
        }

        if match(.keywordFunction) {
            return try parseNamedFunctionDeclaration(lineDefined: previous.line, statementLine: statementLine)
        }
        if match(.keywordIf) { return try parseIfStatement() }
        if match(.keywordWhile) { return try parseWhileLoop() }
        if match(.keywordRepeat) { return try parseRepeatLoop() }
        if match(.keywordFor) { return try parseForLoop(line: statementLine) }
        if match(.keywordDo) { return try parseDoBlock() }
        if match(.keywordBreak) { return .breakLoop(line: statementLine) }
        if match(.keywordContinue) { return .continueLoop(line: statementLine) }
        if match(.keywordReturn) { return try parseReturn(line: statementLine) }

        let first = try parseExpression()
        if check(.comma) || check(.assign) {
            var targetExpressions = [first]
            while match(.comma) { targetExpressions.append(try parseExpression()) }
            try consume(.assign, "expected '=' in assignment")
            let targets = try targetExpressions.map { try assignmentTarget(from: $0) }
            let values = try parseExpressionList()
            return .assignment(targets, values, line: statementLine)
        }

        return .expression(first, line: statementLine)
    }

    private func parseLocalDeclaration(line: Int) throws -> LuaStatement {
        var names = [try consumeIdentifier("expected local variable name")]
        while match(.comma) { names.append(try consumeIdentifier("expected local variable name")) }
        let values = match(.assign) ? try parseExpressionList() : []
        return .localDeclaration(names, values, line: line)
    }

    private func parseNamedFunctionDeclaration(lineDefined: Int, statementLine: Int) throws -> LuaStatement {
        let firstName = try consumeIdentifier("expected function name")
        var targetExpression = LuaExpression.variable(firstName)
        while match(.dot) {
            targetExpression = .field(targetExpression, try consumeIdentifier("expected field name after '.'"))
        }

        var prependSelf = false
        if match(.colon) {
            targetExpression = .field(targetExpression, try consumeIdentifier("expected method name after ':'"))
            prependSelf = true
        }

        let prototype = try parseFunctionTail(prependSelf: prependSelf, lineDefined: lineDefined)
        return .functionDeclaration(
            try assignmentTarget(from: targetExpression),
            prototype,
            line: statementLine
        )
    }

    private func parseIfStatement() throws -> LuaStatement {
        var branches: [LuaIfBranch] = []
        let firstConditionLine = peek.line
        let firstCondition = try parseExpression()
        try consume(.keywordThen, "expected 'then'")
        let firstBody = try parseBlock { kind in
            kind == .keywordElseif || kind == .keywordElse || kind == .keywordEnd || kind == .eof
        }
        branches.append(LuaIfBranch(condition: firstCondition, conditionLine: firstConditionLine, body: firstBody))

        while match(.keywordElseif) {
            let conditionLine = peek.line
            let condition = try parseExpression()
            try consume(.keywordThen, "expected 'then'")
            let body = try parseBlock { kind in
                kind == .keywordElseif || kind == .keywordElse || kind == .keywordEnd || kind == .eof
            }
            branches.append(LuaIfBranch(condition: condition, conditionLine: conditionLine, body: body))
        }

        var elseBody: [LuaStatement]?
        if match(.keywordElse) {
            elseBody = try parseBlock { kind in kind == .keywordEnd || kind == .eof }
        }

        try consume(.keywordEnd, "expected 'end' after if")
        return .ifStatement(branches, elseBody: elseBody, endLine: previous.line)
    }

    private func parseWhileLoop() throws -> LuaStatement {
        let conditionLine = peek.line
        let condition = try parseExpression()
        try consume(.keywordDo, "expected 'do' after while condition")
        let body = try parseBlock { kind in kind == .keywordEnd || kind == .eof }
        try consume(.keywordEnd, "expected 'end' after while")
        return .whileLoop(condition, body, conditionLine: conditionLine, endLine: previous.line)
    }

    private func parseRepeatLoop() throws -> LuaStatement {
        let body = try parseBlock { kind in kind == .keywordUntil || kind == .eof }
        try consume(.keywordUntil, "expected 'until' after repeat block")
        let conditionLine = previous.line
        return .repeatLoop(body, try parseExpression(), conditionLine: conditionLine)
    }

    private func parseForLoop(line: Int) throws -> LuaStatement {
        let firstName = try consumeIdentifier("expected for variable")

        if match(.assign) {
            let start = try parseExpression()
            try consume(.comma, "expected ',' after numeric for start")
            let limit = try parseExpression()
            let step: LuaExpression?
            if match(.comma) { step = try parseExpression() } else { step = nil }
            try consume(.keywordDo, "expected 'do' after numeric for")
            let body = try parseBlock { kind in kind == .keywordEnd || kind == .eof }
            try consume(.keywordEnd, "expected 'end' after for")
            return .numericFor(firstName, start, limit, step, body, line: line, endLine: previous.line)
        }

        var names = [firstName]
        while match(.comma) { names.append(try consumeIdentifier("expected for variable")) }
        try consume(.keywordIn, "expected 'in' in generic for")
        let expressions = try parseExpressionList()
        try consume(.keywordDo, "expected 'do' after generic for")
        let body = try parseBlock { kind in kind == .keywordEnd || kind == .eof }
        try consume(.keywordEnd, "expected 'end' after for")
        return .genericFor(names, expressions, body, line: line, endLine: previous.line)
    }

    private func parseDoBlock() throws -> LuaStatement {
        let body = try parseBlock { kind in kind == .keywordEnd || kind == .eof }
        try consume(.keywordEnd, "expected 'end' after do block")
        return .doBlock(body)
    }

    private func parseReturn(line: Int) throws -> LuaStatement {
        if isReturnTerminator(peek.kind) { return .returnValues([], line: line) }
        return .returnValues(try parseExpressionList(), line: line)
    }

    private func isReturnTerminator(_ kind: LuaTokenKind) -> Bool {
        kind == .keywordEnd || kind == .keywordElse || kind == .keywordElseif ||
        kind == .keywordUntil || kind == .semicolon || kind == .eof
    }

    private func parseFunctionTail(prependSelf: Bool, lineDefined: Int) throws -> LuaFunctionPrototype {
        try consume(.leftParen, "expected '('")
        var parameters = prependSelf ? ["self"] : []
        var isVararg = false

        if !check(.rightParen) {
            while true {
                if match(.vararg) {
                    isVararg = true
                    break
                }
                parameters.append(try consumeIdentifier("expected parameter name"))
                if !match(.comma) { break }
                if check(.vararg) {
                    _ = advance()
                    isVararg = true
                    break
                }
            }
        }

        try consume(.rightParen, "expected ')'")
        let bodyTokenStart = current
        let body = try parseBlock { kind in kind == .keywordEnd || kind == .eof }
        let bodyTokenEnd = current
        let lastLineDefined = peek.line
        try consume(.keywordEnd, "expected 'end' after function body")
        var activeLines = Set(tokens[bodyTokenStart..<bodyTokenEnd].map(\.line))
        activeLines.insert(lastLineDefined)
        return LuaFunctionPrototype(
            parameters: parameters,
            isVararg: isVararg,
            body: body,
            lineDefined: lineDefined,
            lastLineDefined: lastLineDefined,
            activeLines: activeLines
        )
    }

    private func parseExpressionList() throws -> [LuaExpression] {
        var values = [try parseExpression()]
        while match(.comma) { values.append(try parseExpression()) }
        return values
    }

    private func parseExpression() throws -> LuaExpression { try parseOr() }

    private func parseOr() throws -> LuaExpression {
        var expression = try parseAnd()
        while match(.keywordOr) { expression = .binary(expression, .or, try parseAnd()) }
        return expression
    }

    private func parseAnd() throws -> LuaExpression {
        var expression = try parseComparison()
        while match(.keywordAnd) { expression = .binary(expression, .and, try parseComparison()) }
        return expression
    }

    private func parseComparison() throws -> LuaExpression {
        var expression = try parseConcat()
        while true {
            if match(.equal) { expression = .binary(expression, .equal, try parseConcat()) }
            else if match(.notEqual) { expression = .binary(expression, .notEqual, try parseConcat()) }
            else if match(.less) { expression = .binary(expression, .less, try parseConcat()) }
            else if match(.lessEqual) { expression = .binary(expression, .lessEqual, try parseConcat()) }
            else if match(.greater) { expression = .binary(expression, .greater, try parseConcat()) }
            else if match(.greaterEqual) { expression = .binary(expression, .greaterEqual, try parseConcat()) }
            else { break }
        }
        return expression
    }

    private func parseConcat() throws -> LuaExpression {
        let left = try parseAddition()
        if match(.concat) { return .binary(left, .concat, try parseConcat()) }
        return left
    }

    private func parseAddition() throws -> LuaExpression {
        var expression = try parseMultiplication()
        while true {
            if match(.plus) { expression = .binary(expression, .add, try parseMultiplication()) }
            else if match(.minus) { expression = .binary(expression, .subtract, try parseMultiplication()) }
            else { break }
        }
        return expression
    }

    private func parseMultiplication() throws -> LuaExpression {
        var expression = try parseUnary()
        while true {
            if match(.star) { expression = .binary(expression, .multiply, try parseUnary()) }
            else if match(.slash) { expression = .binary(expression, .divide, try parseUnary()) }
            else if match(.percent) { expression = .binary(expression, .modulo, try parseUnary()) }
            else { break }
        }
        return expression
    }

    private func parseUnary() throws -> LuaExpression {
        if match(.minus) { return .unary(.negate, try parseUnary()) }
        if match(.keywordNot) { return .unary(.not, try parseUnary()) }
        if match(.hash) { return .unary(.length, try parseUnary()) }
        return try parsePower()
    }

    private func parsePower() throws -> LuaExpression {
        let left = try parsePostfix()
        if match(.caret) { return .binary(left, .power, try parseUnary()) }
        return left
    }

    private func parsePostfix() throws -> LuaExpression {
        var expression = try parsePrimary()
        while true {
            guard isPrefixExpression(expression) else { break }
            if match(.dot) {
                expression = .field(expression, try consumeIdentifier("expected field name after '.'"))
            } else if match(.leftBracket) {
                let key = try parseExpression()
                try consume(.rightBracket, "expected ']'")
                expression = .index(expression, key)
            } else if match(.colon) {
                let name = try consumeIdentifier("expected method name after ':'")
                expression = .methodCall(expression, name, try parseCallArguments())
            } else if check(.leftParen) || check(.leftBrace) || isStringToken(peek.kind) {
                expression = .call(expression, try parseCallArguments())
            } else {
                break
            }
        }
        return expression
    }

    private func isPrefixExpression(_ expression: LuaExpression) -> Bool {
        switch expression {
        case .variable, .group, .field, .index, .call, .methodCall:
            return true
        default:
            return false
        }
    }

    private func parsePrimary() throws -> LuaExpression {
        let token = peek
        switch token.kind {
        case let .number(value): _ = advance(); return .number(value)
        case let .string(value): _ = advance(); return .string(value)
        case .keywordTrue: _ = advance(); return .boolean(true)
        case .keywordFalse: _ = advance(); return .boolean(false)
        case .keywordNil: _ = advance(); return .nilValue
        case let .identifier(name): _ = advance(); return .variable(name)
        case .vararg: _ = advance(); return .vararg
        case .leftParen:
            _ = advance()
            let expression = try parseExpression()
            try consume(.rightParen, "expected ')'")
            return .group(expression)
        case .leftBrace:
            _ = advance()
            return try parseTableConstructor()
        case .keywordFunction:
            _ = advance()
            return .function(try parseFunctionTail(prependSelf: false, lineDefined: token.line))
        default:
            throw parserError(token, "expected expression")
        }
    }

    private func parseTableConstructor() throws -> LuaExpression {
        var fields: [LuaTableField] = []
        while !check(.rightBrace) {
            if match(.leftBracket) {
                let key = try parseExpression()
                try consume(.rightBracket, "expected ']' in table field")
                try consume(.assign, "expected '=' after table key")
                fields.append(.indexed(key, try parseExpression()))
            } else if case let .identifier(name) = peek.kind, checkNext(.assign) {
                _ = advance(); _ = advance()
                fields.append(.named(name, try parseExpression()))
            } else {
                fields.append(.array(try parseExpression()))
            }

            if match(.comma) || match(.semicolon) {
                if check(.rightBrace) { break }
                continue
            }
            break
        }
        try consume(.rightBrace, "expected '}'")
        return .table(fields)
    }

    private func parseCallArguments() throws -> [LuaExpression] {
        if match(.leftParen) {
            return try parseArgumentsAfterOpenParen()
        }
        if match(.leftBrace) {
            return [try parseTableConstructor()]
        }
        if case let .string(value) = peek.kind {
            _ = advance()
            return [.string(value)]
        }
        throw parserError(peek, "function arguments expected")
    }

    private func isStringToken(_ kind: LuaTokenKind) -> Bool {
        if case .string = kind { return true }
        return false
    }

    private func parseArgumentsAfterOpenParen() throws -> [LuaExpression] {
        if check(.rightParen) { _ = advance(); return [] }
        let args = try parseExpressionList()
        try consume(.rightParen, "expected ')'")
        return args
    }

    private func assignmentTarget(from expression: LuaExpression) throws -> LuaAssignmentTarget {
        switch expression {
        case let .variable(name): return .variable(name)
        case let .field(base, name): return .field(base, name)
        case let .index(base, key): return .index(base, key)
        default: throw parserError(peek, "invalid assignment target")
        }
    }

    private var peek: LuaToken { tokens[current] }
    private var previous: LuaToken { tokens[max(0, current - 1)] }

    @discardableResult
    private func advance() -> LuaToken {
        let result = tokens[current]
        if !check(.eof) { current += 1 }
        return result
    }

    private func check(_ kind: LuaTokenKind) -> Bool { peek.kind == kind }

    private func checkNext(_ kind: LuaTokenKind) -> Bool {
        guard current + 1 < tokens.count else { return false }
        return tokens[current + 1].kind == kind
    }

    private func match(_ kind: LuaTokenKind) -> Bool {
        guard check(kind) else { return false }
        _ = advance()
        return true
    }

    private func consume(_ kind: LuaTokenKind, _ message: String) throws {
        guard match(kind) else { throw parserError(peek, message) }
    }

    private func consumeIdentifier(_ message: String) throws -> String {
        guard case let .identifier(name) = peek.kind else { throw parserError(peek, message) }
        _ = advance()
        return name
    }

    private func parserError(_ token: LuaToken, _ message: String) -> LuaError {
        .parser(line: token.line, column: token.column, message: message)
    }
}

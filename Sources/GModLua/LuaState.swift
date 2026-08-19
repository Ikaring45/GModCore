import Foundation

final class LuaEnvironment {
    private var values: [String: LuaValue] = [:]
    private var order: [String] = []
    private let parent: LuaEnvironment?
    var globalTable: LuaTable
    let varargs: [LuaValue]?

    init(
        parent: LuaEnvironment? = nil,
        globalTable: LuaTable,
        varargs: [LuaValue]? = nil,
        inheritVarargs: Bool = true
    ) {
        self.parent = parent
        self.globalTable = globalTable
        if let varargs {
            self.varargs = varargs
        } else if inheritVarargs {
            self.varargs = parent?.varargs
        } else {
            self.varargs = nil
        }
    }

    func child() -> LuaEnvironment {
        LuaEnvironment(parent: self, globalTable: globalTable)
    }

    func define(_ name: String, value: LuaValue) {
        if values[name] == nil { order.append(name) }
        values[name] = value
    }

    func directEntries() -> [(String, LuaValue)] {
        order.compactMap { name in values[name].map { (name, $0) } }
    }

    func capturedEntries() -> [(String, LuaValue)] {
        var result: [(String, LuaValue)] = []
        var seen = Set<String>()
        var cursor: LuaEnvironment? = self
        while let env = cursor {
            for (name, value) in env.directEntries() where !seen.contains(name) {
                seen.insert(name)
                result.append((name, value))
            }
            cursor = env.parent
        }
        return result
    }

    func localValue(_ name: String) -> LuaValue? {
        findLocal(name)
    }

    private func findLocal(_ name: String) -> LuaValue? {
        if let value = values[name] { return value }
        return parent?.findLocal(name)
    }

    @discardableResult
    func assignExisting(_ name: String, value: LuaValue) -> Bool {
        if values[name] != nil {
            values[name] = value
            return true
        }
        if let parent { return parent.assignExisting(name, value: value) }
        return false
    }
}

enum LuaControl {
    case normal
    case returned([LuaValue])
    case breakLoop
    case continueLoop
}

enum LuaResolvedTarget {
    case variable(String)
    case indexed(LuaValue, LuaValue)
}

final class LuaCallStackBox {
    var functions: [LuaFunction] = []
    var environments: [LuaEnvironment] = []
}

public final class LuaState {
    let globalTable = LuaTable()
    let registryTable = LuaTable()
    var dumpRegistry: [LuaString: LuaFunction] = [:]
    var dumpSerial: UInt64 = 0
    var randomState: UInt64 = 0x4D595DF4D0F33173
    private let output: (String) -> Void
    private static let maxMetatableChainDepth = 100
    private let callStackKey = "GModLua.CallStack.\(UUID().uuidString)"
    private var primitiveMetatables: [String: LuaTable] = [:]
    public var fileLoader: ((String) throws -> String)?

    public init(
        output: @escaping (String) -> Void = { print($0) },
        fileLoader: ((String) throws -> String)? = nil
    ) {
        self.output = output
        self.fileLoader = fileLoader
        installStandardLibrary()
    }

    public func register(_ name: String, function: @escaping LuaNativeFunction) {
        globalTable.rawSetValue(.nativeFunction(LuaNativeFunctionBox(function)), forString: name)
    }

    public func setGlobal(_ name: String, value: LuaValue) {
        globalTable.rawSetValue(value, forString: name)
    }

    public func getGlobal(_ name: String) -> LuaValue {
        globalTable.rawValue(forString: name)
    }

    public func execute(_ source: String, sourceName: String = "=(chunk)") throws {
        let chunkFunction = try compile(source, sourceName: sourceName)
        _ = try callValue(.luaFunction(chunkFunction), arguments: [])
    }

    public func compile(_ source: String, sourceName: String = "=(loadstring)") throws -> LuaFunction {
        let tokens = try LuaLexer(source: source).tokenize()
        let chunk = try LuaParser(tokens: tokens).parse()
        let root = LuaEnvironment(globalTable: globalTable, inheritVarargs: false)
        return LuaFunction(
            parameters: [],
            isVararg: true,
            body: chunk.statements,
            closure: root,
            environmentTable: globalTable,
            sourceName: sourceName,
            lineDefined: 0
        )
    }

    // MARK: - Execution

    private func makeLuaFunction(
        from prototype: LuaFunctionPrototype,
        closure: LuaEnvironment
    ) -> LuaFunction {
        let parent = currentLuaFunction()
        return LuaFunction(
            parameters: prototype.parameters,
            isVararg: prototype.isVararg,
            body: prototype.body,
            closure: closure,
            environmentTable: parent?.environmentTable ?? closure.globalTable,
            sourceName: parent?.sourceName ?? "=(chunk)",
            lineDefined: prototype.lineDefined,
            lastLineDefined: prototype.lastLineDefined,
            activeLines: prototype.activeLines
        )
    }

    private func executeBlock(_ statements: [LuaStatement], environment: LuaEnvironment) throws -> LuaControl {
        for statement in statements {
            let control = try execute(statement, environment: environment)
            if case .normal = control { continue }
            return control
        }
        return .normal
    }

    private func execute(_ statement: LuaStatement, environment: LuaEnvironment) throws -> LuaControl {
        switch statement {
        case let .localDeclaration(names, expressions):
            let values = try evaluateExpressionList(expressions, environment: environment)
            for (index, name) in names.enumerated() {
                environment.define(name, value: index < values.count ? values[index] : .nilValue)
            }
            return .normal

        case let .localFunction(name, prototype):
            environment.define(name, value: .nilValue)
            let function = makeLuaFunction(from: prototype, closure: environment)
            _ = environment.assignExisting(name, value: .luaFunction(function))
            return .normal

        case let .assignment(targets, expressions):
            // Resolve all indexed LHS expressions before writing anything.
            let resolved = try targets.map { try resolveTarget($0, environment: environment) }
            let values = try evaluateExpressionList(expressions, environment: environment)
            for index in resolved.indices {
                let value = index < values.count ? values[index] : .nilValue
                try assignResolved(resolved[index], value: value, environment: environment)
            }
            return .normal

        case let .functionDeclaration(target, prototype):
            let function = makeLuaFunction(from: prototype, closure: environment)
            let resolved = try resolveTarget(target, environment: environment)
            try assignResolved(resolved, value: .luaFunction(function), environment: environment)
            return .normal

        case let .ifStatement(branches, elseBody):
            for branch in branches {
                if try evaluateSingle(branch.condition, environment: environment).isTruthy {
                    return try executeBlock(branch.body, environment: environment.child())
                }
            }
            if let elseBody { return try executeBlock(elseBody, environment: environment.child()) }
            return .normal

        case let .whileLoop(condition, body):
            while try evaluateSingle(condition, environment: environment).isTruthy {
                let control = try executeBlock(body, environment: environment.child())
                switch control {
                case .normal, .continueLoop: continue
                case .breakLoop: return .normal
                case .returned: return control
                }
            }
            return .normal

        case let .repeatLoop(body, condition):
            repeat {
                let loopEnvironment = environment.child()
                let control = try executeBlock(body, environment: loopEnvironment)
                switch control {
                case .breakLoop: return .normal
                case .returned: return control
                case .normal, .continueLoop: break
                }
                if try evaluateSingle(condition, environment: loopEnvironment).isTruthy { break }
            } while true
            return .normal

        case let .numericFor(name, startExpression, limitExpression, stepExpression, body):
            var current = try numericValue(evaluateSingle(startExpression, environment: environment))
            let limit = try numericValue(evaluateSingle(limitExpression, environment: environment))
            let step = try stepExpression.map { try numericValue(evaluateSingle($0, environment: environment)) } ?? 1.0
            if step == 0 { throw LuaError.runtime("'for' step is zero") }

            let loopEnvironment = environment.child()
            loopEnvironment.define(name, value: .number(current))
            func shouldRun(_ value: Double) -> Bool { step > 0 ? value <= limit : value >= limit }

            while shouldRun(current) {
                _ = loopEnvironment.assignExisting(name, value: .number(current))
                let control = try executeBlock(body, environment: loopEnvironment.child())
                switch control {
                case .breakLoop: return .normal
                case .returned: return control
                case .normal, .continueLoop: break
                }
                current += step
            }
            return .normal

        case let .genericFor(names, expressions, body):
            let values = try evaluateExpressionList(expressions, environment: environment)
            let iterator = values.indices.contains(0) ? values[0] : .nilValue
            let state = values.indices.contains(1) ? values[1] : .nilValue
            var controlValue = values.indices.contains(2) ? values[2] : .nilValue
            let loopEnvironment = environment.child()
            for name in names { loopEnvironment.define(name, value: .nilValue) }

            while true {
                let results = try callValue(iterator, arguments: [state, controlValue])
                let first = results.first ?? .nilValue
                if isNil(first) { break }
                controlValue = first

                for (index, name) in names.enumerated() {
                    _ = loopEnvironment.assignExisting(name, value: index < results.count ? results[index] : .nilValue)
                }

                let control = try executeBlock(body, environment: loopEnvironment.child())
                switch control {
                case .breakLoop: return .normal
                case .returned: return control
                case .normal, .continueLoop: break
                }
            }
            return .normal

        case let .doBlock(body):
            return try executeBlock(body, environment: environment.child())

        case .breakLoop:
            return .breakLoop

        case .continueLoop:
            return .continueLoop

        case let .returnValues(expressions):
            return .returned(try evaluateExpressionList(expressions, environment: environment))

        case let .expression(expression):
            _ = try evaluateMulti(expression, environment: environment)
            return .normal
        }
    }

    // MARK: - Assignment

    private func resolveTarget(_ target: LuaAssignmentTarget, environment: LuaEnvironment) throws -> LuaResolvedTarget {
        switch target {
        case let .variable(name):
            return .variable(name)
        case let .field(baseExpression, name):
            let receiver = try evaluateSingle(baseExpression, environment: environment)
            return .indexed(receiver, .string(LuaString(name)))
        case let .index(baseExpression, keyExpression):
            let receiver = try evaluateSingle(baseExpression, environment: environment)
            let key = try evaluateSingle(keyExpression, environment: environment)
            return .indexed(receiver, key)
        }
    }

    private func assignResolved(_ target: LuaResolvedTarget, value: LuaValue, environment: LuaEnvironment) throws {
        switch target {
        case let .variable(name):
            if !environment.assignExisting(name, value: value) {
                try setIndexedValue(receiver: .table(environment.globalTable), key: .string(LuaString(name)), value: value)
            }
        case let .indexed(receiver, key):
            try setIndexedValue(receiver: receiver, key: key, value: value)
        }
    }

    // MARK: - Expressions

    private func evaluateExpressionList(_ expressions: [LuaExpression], environment: LuaEnvironment) throws -> [LuaValue] {
        guard !expressions.isEmpty else { return [] }
        var values: [LuaValue] = []
        for index in expressions.indices {
            if index == expressions.count - 1 {
                values.append(contentsOf: try evaluateMulti(expressions[index], environment: environment))
            } else {
                values.append(try evaluateSingle(expressions[index], environment: environment))
            }
        }
        return values
    }

    private func evaluateSingle(_ expression: LuaExpression, environment: LuaEnvironment) throws -> LuaValue {
        try evaluateMulti(expression, environment: environment).first ?? .nilValue
    }

    private func evaluateMulti(_ expression: LuaExpression, environment: LuaEnvironment) throws -> [LuaValue] {
        switch expression {
        case .vararg:
            guard let varargs = environment.varargs else {
                throw LuaError.runtime("cannot use '...' outside a vararg function")
            }
            return varargs

        case let .call(calleeExpression, argumentExpressions):
            let callable = try evaluateSingle(calleeExpression, environment: environment)
            let arguments = try evaluateExpressionList(argumentExpressions, environment: environment)
            return try callValue(callable, arguments: arguments)

        case let .methodCall(receiverExpression, name, argumentExpressions):
            let receiver = try evaluateSingle(receiverExpression, environment: environment)
            let callable = try getIndexedValue(receiver: receiver, key: .string(LuaString(name)))
            let arguments = try evaluateExpressionList(argumentExpressions, environment: environment)
            return try callValue(callable, arguments: [receiver] + arguments)

        default:
            return [try evaluateNonMulti(expression, environment: environment)]
        }
    }

    private func evaluateNonMulti(_ expression: LuaExpression, environment: LuaEnvironment) throws -> LuaValue {
        switch expression {
        case let .number(value): return .number(value)
        case let .string(value): return .string(value)
        case let .boolean(value): return .boolean(value)
        case .nilValue: return .nilValue
        case let .variable(name):
            if let local = environment.localValue(name) { return local }
            return try getIndexedValue(receiver: .table(environment.globalTable), key: .string(LuaString(name)))

        case let .table(fields):
            let table = LuaTable()
            var arrayIndex = 1.0
            for (fieldIndex, field) in fields.enumerated() {
                switch field {
                case let .named(name, valueExpression):
                    table.rawSetValue(try evaluateSingle(valueExpression, environment: environment), forString: name)
                case let .indexed(keyExpression, valueExpression):
                    let key = try evaluateSingle(keyExpression, environment: environment)
                    let value = try evaluateSingle(valueExpression, environment: environment)
                    try table.rawSetValue(value, for: key)
                case let .array(valueExpression):
                    let isLast = fieldIndex == fields.count - 1
                    let fieldValues = isLast
                        ? try evaluateMulti(valueExpression, environment: environment)
                        : [try evaluateSingle(valueExpression, environment: environment)]
                    for value in fieldValues {
                        table.rawSetValue(value, forNumber: arrayIndex)
                        arrayIndex += 1
                    }
                }
            }
            return .table(table)

        case let .function(prototype):
            return .luaFunction(makeLuaFunction(from: prototype, closure: environment))

        case let .field(baseExpression, name):
            let receiver = try evaluateSingle(baseExpression, environment: environment)
            return try getIndexedValue(receiver: receiver, key: .string(LuaString(name)))

        case let .index(baseExpression, keyExpression):
            let receiver = try evaluateSingle(baseExpression, environment: environment)
            let key = try evaluateSingle(keyExpression, environment: environment)
            return try getIndexedValue(receiver: receiver, key: key)

        case let .unary(operation, inner):
            let value = try evaluateSingle(inner, environment: environment)
            switch operation {
            case .negate:
                if let number = coerceNumber(value) { return .number(-number) }
                return try unaryMetamethod(value, name: "__unm")
            case .not:
                return .boolean(!value.isTruthy)
            case .length:
                switch value {
                case let .string(string): return .number(Double(string.count))
                case let .table(table): return .number(Double(table.rawLength()))
                default:
                    if let result = try callMetamethod(name: "__len", values: [value]) { return result }
                    throw LuaError.runtime("attempt to get length of a \(value.typeName) value")
                }
            }

        case let .binary(left, operation, right):
            if operation == .and {
                let lhs = try evaluateSingle(left, environment: environment)
                return lhs.isTruthy ? try evaluateSingle(right, environment: environment) : lhs
            }
            if operation == .or {
                let lhs = try evaluateSingle(left, environment: environment)
                return lhs.isTruthy ? lhs : try evaluateSingle(right, environment: environment)
            }

            let lhs = try evaluateSingle(left, environment: environment)
            let rhs = try evaluateSingle(right, environment: environment)

            switch operation {
            case .add: return try arithmeticBinary(lhs, rhs, metamethod: "__add", primitive: +)
            case .subtract: return try arithmeticBinary(lhs, rhs, metamethod: "__sub", primitive: -)
            case .multiply: return try arithmeticBinary(lhs, rhs, metamethod: "__mul", primitive: *)
            case .divide: return try arithmeticBinary(lhs, rhs, metamethod: "__div", primitive: /)
            case .modulo:
                if let a = coerceNumber(lhs), let b = coerceNumber(rhs) {
                    return .number(a - floor(a / b) * b)
                }
                if let result = try callBinaryMetamethod(lhs, rhs, name: "__mod") { return result }
                throw arithmeticError(lhs, rhs)
            case .power:
                if let a = coerceNumber(lhs), let b = coerceNumber(rhs) { return .number(pow(a, b)) }
                if let result = try callBinaryMetamethod(lhs, rhs, name: "__pow") { return result }
                throw arithmeticError(lhs, rhs)
            case .concat:
                if let a = primitiveConcatString(lhs), let b = primitiveConcatString(rhs) { return .string(a + b) }
                if let result = try callBinaryMetamethod(lhs, rhs, name: "__concat") { return result }
                throw LuaError.runtime("attempt to concatenate a \(lhs.typeName) value")
            case .equal:
                return .boolean(try luaEqual(lhs, rhs))
            case .notEqual:
                return .boolean(!(try luaEqual(lhs, rhs)))
            case .less:
                return .boolean(try luaLessThan(lhs, rhs))
            case .lessEqual:
                return .boolean(try luaLessEqual(lhs, rhs))
            case .greater:
                return .boolean(try luaLessThan(rhs, lhs))
            case .greaterEqual:
                return .boolean(try luaLessEqual(rhs, lhs))
            case .and, .or:
                fatalError("handled above")
            }

        case let .group(inner):
            return try evaluateSingle(inner, environment: environment)

        case .vararg, .call, .methodCall:
            return try evaluateMulti(expression, environment: environment).first ?? .nilValue
        }
    }

    private func getIndexedValue(receiver: LuaValue, key: LuaValue) throws -> LuaValue {
        switch receiver {
        case let .table(table):
            return try getTableValue(table: table, receiver: receiver, key: key, depth: 0)
        case let .userdata(userdata):
            return try getUserdataValue(userdata: userdata, receiver: receiver, key: key, depth: 0)
        case .string:
            guard case let .string(keyName) = key,
                  case let .table(stringLibrary) = getGlobal("string") else {
                throw LuaError.runtime("attempt to index a string value")
            }
            return stringLibrary.rawValue(forString: keyName)
        default:
            throw LuaError.runtime("attempt to index a \(receiver.typeName) value")
        }
    }

    private func setIndexedValue(receiver: LuaValue, key: LuaValue, value: LuaValue) throws {
        switch receiver {
        case let .table(table):
            try setTableValue(table: table, receiver: receiver, key: key, value: value, depth: 0)
        case let .userdata(userdata):
            try setUserdataValue(userdata: userdata, receiver: receiver, key: key, value: value, depth: 0)
        default:
            throw LuaError.runtime("attempt to index a \(receiver.typeName) value")
        }
    }

    // MARK: - Calls

    func callValue(_ callable: LuaValue, arguments: [LuaValue]) throws -> [LuaValue] {
        switch callable {
        case let .nativeFunction(function):
            return try function.body(arguments)

        case let .luaFunction(function):
            let fixedCount = function.parameters.count
            let extra = function.isVararg && arguments.count > fixedCount
                ? Array(arguments.dropFirst(fixedCount))
                : []
            let callEnvironment = LuaEnvironment(
                parent: function.closure,
                globalTable: function.environmentTable,
                varargs: function.isVararg ? extra : nil,
                inheritVarargs: false
            )
            for (index, parameter) in function.parameters.enumerated() {
                callEnvironment.define(parameter, value: index < arguments.count ? arguments[index] : .nilValue)
            }
            let stack = currentCallStack()
            stack.functions.append(function)
            stack.environments.append(callEnvironment)
            defer {
                _ = stack.functions.popLast()
                _ = stack.environments.popLast()
            }

            let control = try executeBlock(function.body, environment: callEnvironment)
            switch control {
            case let .returned(values): return values
            case .normal: return []
            case .breakLoop: throw LuaError.runtime("no loop to break")
            case .continueLoop: throw LuaError.runtime("no loop to continue")
            }

        default:
            if let metatable = metatable(of: callable) {
                let callMeta = metatable.rawValue(forString: "__call")
                if !isNil(callMeta) {
                    return try callValue(callMeta, arguments: [callable] + arguments)
                }
            }
            throw LuaError.runtime("attempt to call a \(callable.typeName) value")
        }
    }

    // MARK: - Metatables

    func getTableValue(table: LuaTable, receiver: LuaValue, key: LuaValue, depth: Int) throws -> LuaValue {
        guard depth < Self.maxMetatableChainDepth else { throw LuaError.runtime("loop in gettable") }
        let raw = try table.rawValue(for: key)
        if !isNil(raw) { return raw }
        guard let metatable = table.metatable else { return .nilValue }
        let index = metatable.rawValue(forString: "__index")

        switch index {
        case .nilValue: return .nilValue
        case let .table(fallbackTable):
            return try getTableValue(table: fallbackTable, receiver: .table(fallbackTable), key: key, depth: depth + 1)
        case .luaFunction, .nativeFunction:
            return try callValue(index, arguments: [receiver, key]).first ?? .nilValue
        default:
            throw LuaError.runtime("attempt to index a \(index.typeName) value")
        }
    }

    private func setTableValue(table: LuaTable, receiver: LuaValue, key: LuaValue, value: LuaValue, depth: Int) throws {
        guard depth < Self.maxMetatableChainDepth else { throw LuaError.runtime("loop in settable") }
        let existing = try table.rawValue(for: key)
        if !isNil(existing) {
            try table.rawSetValue(value, for: key)
            return
        }
        guard let metatable = table.metatable else {
            try table.rawSetValue(value, for: key)
            return
        }
        let newIndex = metatable.rawValue(forString: "__newindex")
        switch newIndex {
        case .nilValue:
            try table.rawSetValue(value, for: key)
        case let .table(targetTable):
            try setTableValue(table: targetTable, receiver: .table(targetTable), key: key, value: value, depth: depth + 1)
        case .luaFunction, .nativeFunction:
            _ = try callValue(newIndex, arguments: [receiver, key, value])
        default:
            throw LuaError.runtime("attempt to index a \(newIndex.typeName) value")
        }
    }

    private func getUserdataValue(userdata: LuaUserdata, receiver: LuaValue, key: LuaValue, depth: Int) throws -> LuaValue {
        guard depth < Self.maxMetatableChainDepth else { throw LuaError.runtime("loop in gettable") }
        guard let metatable = userdata.metatable else {
            throw LuaError.runtime("attempt to index a userdata value")
        }
        let index = metatable.rawValue(forString: "__index")
        switch index {
        case .nilValue:
            throw LuaError.runtime("attempt to index a userdata value")
        case let .table(table):
            return try getTableValue(table: table, receiver: .table(table), key: key, depth: depth + 1)
        case .luaFunction, .nativeFunction:
            return try callValue(index, arguments: [receiver, key]).first ?? .nilValue
        default:
            throw LuaError.runtime("attempt to index a \(index.typeName) value")
        }
    }

    private func setUserdataValue(userdata: LuaUserdata, receiver: LuaValue, key: LuaValue, value: LuaValue, depth: Int) throws {
        guard depth < Self.maxMetatableChainDepth else { throw LuaError.runtime("loop in settable") }
        guard let metatable = userdata.metatable else {
            throw LuaError.runtime("attempt to index a userdata value")
        }
        let newIndex = metatable.rawValue(forString: "__newindex")
        switch newIndex {
        case let .table(table):
            try setTableValue(table: table, receiver: .table(table), key: key, value: value, depth: depth + 1)
        case .luaFunction, .nativeFunction:
            _ = try callValue(newIndex, arguments: [receiver, key, value])
        default:
            throw LuaError.runtime("attempt to index a userdata value")
        }
    }

    // MARK: - Metamethod operations

    private func metamethod(_ value: LuaValue, _ name: String) -> LuaValue {
        metatable(of: value)?.rawValue(forString: name) ?? .nilValue
    }

    private func callMetamethod(name: String, values: [LuaValue]) throws -> LuaValue? {
        guard let first = values.first else { return nil }
        let handler = metamethod(first, name)
        if isNil(handler) { return nil }
        return try callValue(handler, arguments: values).first ?? .nilValue
    }

    private func callBinaryMetamethod(_ lhs: LuaValue, _ rhs: LuaValue, name: String) throws -> LuaValue? {
        var handler = metamethod(lhs, name)
        if isNil(handler) { handler = metamethod(rhs, name) }
        if isNil(handler) { return nil }
        return try callValue(handler, arguments: [lhs, rhs]).first ?? .nilValue
    }

    private func unaryMetamethod(_ value: LuaValue, name: String) throws -> LuaValue {
        if let result = try callMetamethod(name: name, values: [value]) { return result }
        throw LuaError.runtime("attempt to perform arithmetic on a \(value.typeName) value")
    }

    private func arithmeticBinary(
        _ lhs: LuaValue,
        _ rhs: LuaValue,
        metamethod name: String,
        primitive: (Double, Double) -> Double
    ) throws -> LuaValue {
        if let a = coerceNumber(lhs), let b = coerceNumber(rhs) { return .number(primitive(a, b)) }
        if let result = try callBinaryMetamethod(lhs, rhs, name: name) { return result }
        throw arithmeticError(lhs, rhs)
    }

    private func arithmeticError(_ lhs: LuaValue, _ rhs: LuaValue) -> LuaError {
        .runtime("attempt to perform arithmetic on a \(coerceNumber(lhs) == nil ? lhs.typeName : rhs.typeName) value")
    }

    func coerceNumber(_ value: LuaValue) -> Double? {
        switch value {
        case let .number(number): return number
        case let .string(string): return Double(string.utf8String.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private func primitiveConcatString(_ value: LuaValue) -> LuaString? {
        switch value {
        case let .string(string): return string
        case .number: return LuaString(value.printable)
        default: return nil
        }
    }

    private func sharedComparisonHandler(_ lhs: LuaValue, _ rhs: LuaValue, name: String) -> LuaValue? {
        guard lhs.typeName == rhs.typeName else { return nil }
        let a = metamethod(lhs, name)
        let b = metamethod(rhs, name)
        guard !isNil(a), rawEqual(a, b) else { return nil }
        return a
    }

    private func luaEqual(_ lhs: LuaValue, _ rhs: LuaValue) throws -> Bool {
        if rawEqual(lhs, rhs) { return true }
        switch (lhs, rhs) {
        case (.table, .table), (.userdata, .userdata):
            if let handler = sharedComparisonHandler(lhs, rhs, name: "__eq") {
                return (try callValue(handler, arguments: [lhs, rhs]).first ?? .nilValue).isTruthy
            }
            return false
        default:
            return false
        }
    }

    func luaLessThan(_ lhs: LuaValue, _ rhs: LuaValue) throws -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a < b
        case let (.string(a), .string(b)): return a < b
        default:
            if let handler = sharedComparisonHandler(lhs, rhs, name: "__lt") {
                return (try callValue(handler, arguments: [lhs, rhs]).first ?? .nilValue).isTruthy
            }
            throw LuaError.runtime("attempt to compare \(lhs.typeName) with \(rhs.typeName)")
        }
    }

    func luaLessEqual(_ lhs: LuaValue, _ rhs: LuaValue) throws -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a <= b
        case let (.string(a), .string(b)): return a <= b
        default:
            if let handler = sharedComparisonHandler(lhs, rhs, name: "__le") {
                return (try callValue(handler, arguments: [lhs, rhs]).first ?? .nilValue).isTruthy
            }
            if let handler = sharedComparisonHandler(lhs, rhs, name: "__lt") {
                return !(try callValue(handler, arguments: [rhs, lhs]).first ?? .nilValue).isTruthy
            }
            throw LuaError.runtime("attempt to compare \(lhs.typeName) with \(rhs.typeName)")
        }
    }

    // MARK: - Shared runtime helpers

    func rawEqual(_ lhs: LuaValue, _ rhs: LuaValue) -> Bool {
        switch (lhs, rhs) {
        case (.nilValue, .nilValue): return true
        case let (.boolean(a), .boolean(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.table(a), .table(b)): return a === b
        case let (.luaFunction(a), .luaFunction(b)): return a === b
        case let (.nativeFunction(a), .nativeFunction(b)): return a === b
        case let (.userdata(a), .userdata(b)): return a === b
        case let (.thread(a), .thread(b)): return a === b
        default: return false
        }
    }

    func luaString(_ value: LuaValue) throws -> String {
        if let metatable = metatable(of: value) {
            let metamethod = metatable.rawValue(forString: "__tostring")
            if !isNil(metamethod) {
                let result = try callValue(metamethod, arguments: [value]).first ?? .nilValue
                guard case let .string(string) = result else {
                    throw LuaError.runtime("'__tostring' must return a string")
                }
                return string.utf8String
            }
        }
        return value.printable
    }

    func isNil(_ value: LuaValue) -> Bool {
        if case .nilValue = value { return true }
        return false
    }

    private func numericValue(_ value: LuaValue) throws -> Double {
        switch value {
        case let .number(number): return number
        case let .string(string):
            if let number = Double(string.utf8String) { return number }
            fallthrough
        default:
            throw LuaError.runtime("attempt to perform arithmetic on a \(value.typeName) value")
        }
    }

    private func concatenatableString(_ value: LuaValue) throws -> LuaString {
        switch value {
        case let .string(string): return string
        case .number: return LuaString(value.printable)
        default: throw LuaError.runtime("attempt to concatenate a \(value.typeName) value")
        }
    }

    private func compare(_ lhs: LuaValue, _ rhs: LuaValue) throws -> Int {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case let (.string(a), .string(b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        default:
            throw LuaError.runtime("attempt to compare \(lhs.typeName) with \(rhs.typeName)")
        }
    }

    func errorValue(_ error: Error) -> LuaValue {
        if let raised = error as? LuaRaisedError { return raised.value }
        if let luaError = error as? LuaError {
            switch luaError {
            case let .runtime(message): return .string(LuaString(message))
            default: return .string(LuaString(luaError.description))
            }
        }
        return .string(LuaString(String(describing: error)))
    }

    func nextRandomUnit() -> Double {
        // Small deterministic 64-bit LCG; Lua 5.1 delegates random to the host C library,
        // so the exact sequence is intentionally platform-defined.
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        let mantissa = randomState >> 11
        return Double(mantissa) / Double(UInt64(1) << 53)
    }

    func currentCallStack() -> LuaCallStackBox {
        if let existing = Thread.current.threadDictionary[callStackKey] as? LuaCallStackBox {
            return existing
        }
        let box = LuaCallStackBox()
        Thread.current.threadDictionary[callStackKey] = box
        return box
    }

    func currentLuaFunction(level: Int = 1) -> LuaFunction? {
        let stack = currentCallStack().functions
        guard level >= 1, level <= stack.count else { return nil }
        return stack[stack.count - level]
    }

    func currentLuaEnvironment(level: Int = 1) -> LuaEnvironment? {
        let stack = currentCallStack().environments
        guard level >= 1, level <= stack.count else { return nil }
        return stack[stack.count - level]
    }

    func metatable(of value: LuaValue) -> LuaTable? {
        switch value {
        case let .table(table): return table.metatable
        case let .userdata(userdata): return userdata.metatable
        case .nilValue: return primitiveMetatables["nil"]
        case .boolean: return primitiveMetatables["boolean"]
        case .number: return primitiveMetatables["number"]
        case .string: return primitiveMetatables["string"]
        case .luaFunction, .nativeFunction: return primitiveMetatables["function"]
        case .thread: return primitiveMetatables["thread"]
        }
    }

    func setPrimitiveMetatable(typeName: String, table: LuaTable?) {
        primitiveMetatables[typeName] = table
    }

    func emit(_ text: String) { output(text) }
}

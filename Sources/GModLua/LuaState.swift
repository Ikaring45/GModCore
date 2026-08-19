import Foundation

final class LuaEnvironment {
    private var values: [String: LuaValue] = [:]
    private var order: [String] = []
    private let parent: LuaEnvironment?
    private let isFunctionScopeRoot: Bool
    var globalTable: LuaTable
    let varargs: [LuaValue]?

    init(
        parent: LuaEnvironment? = nil,
        globalTable: LuaTable,
        varargs: [LuaValue]? = nil,
        inheritVarargs: Bool = true,
        isFunctionScopeRoot: Bool = false
    ) {
        self.parent = parent
        self.isFunctionScopeRoot = isFunctionScopeRoot
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

    func replaceActiveFunctionGlobalTable(with table: LuaTable) {
        var cursor: LuaEnvironment? = self
        while let environment = cursor {
            environment.globalTable = table
            if environment.isFunctionScopeRoot { break }
            cursor = environment.parent
        }
    }

    func define(_ name: String, value: LuaValue) {
        if values[name] == nil { order.append(name) }
        values[name] = value
    }

    func directEntries() -> [(String, LuaValue)] {
        order.compactMap { name in values[name].map { (name, $0) } }
    }

    func activeFunctionEntries() -> [(String, LuaValue)] {
        var chain: [LuaEnvironment] = []
        var cursor: LuaEnvironment? = self
        while let environment = cursor {
            chain.append(environment)
            if environment.isFunctionScopeRoot { break }
            cursor = environment.parent
        }
        return chain.reversed().flatMap { $0.directEntries() }
    }

    @discardableResult
    func assignActiveFunctionEntry(at index: Int, value: LuaValue) -> String? {
        var chain: [LuaEnvironment] = []
        var cursor: LuaEnvironment? = self
        while let environment = cursor {
            chain.append(environment)
            if environment.isFunctionScopeRoot { break }
            cursor = environment.parent
        }

        var remaining = index
        for environment in chain.reversed() {
            let entries = environment.directEntries()
            if remaining <= entries.count {
                guard remaining >= 1 else { return nil }
                let name = entries[remaining - 1].0
                environment.values[name] = value
                return name
            }
            remaining -= entries.count
        }
        return nil
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

    func bindingKind(_ name: String) -> String? {
        var crossedFunctionBoundary = false
        var cursor: LuaEnvironment? = self
        while let environment = cursor {
            if environment.values[name] != nil {
                return crossedFunctionBoundary ? "upvalue" : "local"
            }
            if environment.isFunctionScopeRoot { crossedFunctionBoundary = true }
            cursor = environment.parent
        }
        return nil
    }

    private func findLocal(_ name: String) -> LuaValue? {
        if let value = values[name] { return value }
        return parent?.findLocal(name)
    }

    func gcReferences() -> (parent: LuaEnvironment?, globalTable: LuaTable, values: [LuaValue]) {
        (parent, globalTable, Array(values.values))
    }

    func gcClearValues() {
        values.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
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
    case tailCall(LuaPreparedCall)
    case breakLoop
    case continueLoop
}

struct LuaPreparedCall {
    let callable: LuaValue
    let arguments: [LuaValue]
    let name: String?
    let nameWhat: String
}

enum LuaResolvedTarget {
    case variable(String)
    case indexed(LuaValue, LuaValue)
}

struct LuaCallFrame {
    let callable: LuaValue
    var environment: LuaEnvironment?
    let name: String?
    let nameWhat: String
    let isTailCall: Bool
    var temporaries: [LuaValue]
    var currentLine: Int
    var lastHookLine: Int?
}

final class LuaCallStackBox {
    var frames: [LuaCallFrame] = []
}

final class LuaDebugHookState {
    var function: LuaValue = .nilValue
    var mask = ""
    var count = 0
    var countdown = 0
    var depth = 0
}

public final class LuaState {
    let globalTable = LuaTable()
    let registryTable = LuaTable()
    let garbageCollector = LuaGarbageCollector()
    var dumpRegistry: [LuaString: LuaFunction] = [:]
    var dumpSerial: UInt64 = 0
    var randomState: UInt64 = 0x4D595DF4D0F33173
    let mainDebugHookState = LuaDebugHookState()
    private let output: (String) -> Void
    private static let maxMetatableChainDepth = 100
    // Lua 5.1 accepts ordinary non-tail recursion beyond 200 Lua frames
    // (the official calls.lua suite exercises deep(200)). Keep an explicit
    // host-stack guard for this recursive Swift interpreter, but leave enough
    // headroom for Lua frames plus pcall/dofile/native wrapper frames.
    private static let maxLuaCallDepth = 1_000
    private let callStackKey = "GModLua.CallStack.\(UUID().uuidString)"
    private var primitiveMetatables: [String: LuaTable] = [:]
    private var mainFailureFrames: [LuaCallFrame]?
    public var fileLoader: ((String) throws -> String)?
    public var virtualFileSystem: LuaVirtualFileSystem?
    var threadEnvironmentTable: LuaTable

    var currentThreadEnvironmentTable: LuaTable {
        get { LuaThread.current?.environmentTable ?? threadEnvironmentTable }
        set {
            if let thread = LuaThread.current { thread.environmentTable = newValue }
            else { threadEnvironmentTable = newValue }
        }
    }

    public init(
        output: @escaping (String) -> Void = { print($0) },
        fileLoader: ((String) throws -> String)? = nil,
        virtualFileSystem: LuaVirtualFileSystem? = nil
    ) {
        self.output = output
        self.fileLoader = fileLoader
        self.virtualFileSystem = virtualFileSystem
        self.threadEnvironmentTable = globalTable
        garbageCollector.attach(to: self)
        installStandardLibrary()
        // Adopt roots after library installation. Existing-object adoption is
        // intentionally O(1), so pre-adopting empty roots would hide later raw
        // insertions from the initial heap graph scan.
        garbageCollector.adopt([.table(globalTable), .table(registryTable)])
    }

    public func register(_ name: String, function: @escaping LuaNativeFunction) {
        guard !isClosed else { return }
        let value = LuaValue.nativeFunction(LuaNativeFunctionBox(function))
        globalTable.rawSetValue(value, forString: name)
        garbageCollector.adopt(value)
    }

    public func setGlobal(_ name: String, value: LuaValue) {
        guard !isClosed else { return }
        globalTable.rawSetValue(value, forString: name)
        garbageCollector.adopt(value)
    }

    public func getGlobal(_ name: String) -> LuaValue {
        globalTable.rawValue(forString: name)
    }

    public var isClosed: Bool { garbageCollector.hasClosed }

    /// Explicitly ends this embedded state's lifetime. deinit deliberately does
    /// not run Lua while Swift object graphs are being destroyed.
    @discardableResult
    public func close() -> LuaCloseReport {
        garbageCollector.close()
    }

    /// Engine integrations can construct native-backed Lua tables without
    /// exposing the interpreter's internal table-key representation.
    public func setRawTableValue(
        _ value: LuaValue,
        for key: LuaValue,
        in table: LuaTable
    ) throws {
        try ensureOpen()
        garbageCollector.adopt([.table(table), key, value])
        try table.rawSetValue(value, for: key)
    }

    /// Assigns through Lua's ordinary table semantics, including `__newindex`.
    /// Engine integrations use this when a native API writes an observable Lua
    /// field rather than constructing an internal result table.
    public func setTableValue(
        _ value: LuaValue,
        for key: LuaValue,
        in table: LuaTable
    ) throws {
        try ensureOpen()
        garbageCollector.adopt([.table(table), key, value])
        try setIndexedValue(receiver: .table(table), key: key, value: value)
    }

    /// Reads an entry without invoking `__index`. Engine integrations use this
    /// for documented data-table arguments while keeping LuaTable's internal
    /// key representation private to GModLua.
    public func rawTableValue(
        for key: LuaValue,
        in table: LuaTable
    ) throws -> LuaValue {
        try ensureOpen()
        return try table.rawValue(for: key)
    }

    /// Enumerates the currently live entries without invoking `__pairs`,
    /// `__index`, or any other Lua code. Engine persistence adapters use this
    /// boundary to serialize documented data tables while LuaTable keeps its
    /// internal key representation private.
    public func rawTablePairs(in table: LuaTable) throws -> [(LuaValue, LuaValue)] {
        try ensureOpen()
        return table.allPairs()
    }

    /// Calls a Lua or native function from an embedding host and returns every
    /// result value. Engine lifecycle code uses this boundary instead of
    /// synthesizing Lua source merely to dispatch a hook or register a
    /// gamemode. Ordinary Lua call frames, debug hooks, errors, yields and GC
    /// roots are preserved by the same evaluator path used by script calls.
    public func call(
        _ callable: LuaValue,
        arguments: [LuaValue] = []
    ) throws -> [LuaValue] {
        try ensureOpen()
        garbageCollector.adopt([callable] + arguments)
        return try callValue(callable, arguments: arguments)
    }

    public func execute(_ source: String, sourceName: String = "=(chunk)") throws {
        try ensureOpen()
        _ = try executeReturningValues(source, sourceName: sourceName)
    }

    /// Executes a source chunk and preserves its multiple return values.
    ///
    /// `inheritCallerEnvironmentAtLevel` is used by GLua's `include()`: the
    /// included chunk runs in the environment of the Lua chunk that called the
    /// native include function. Level 1 is the native function itself, so an
    /// include implementation normally passes 2.
    public func executeReturningValues(
        _ source: String,
        sourceName: String = "=(chunk)",
        inheritCallerEnvironmentAtLevel callerLevel: Int? = nil
    ) throws -> [LuaValue] {
        try ensureOpen()
        let chunkFunction = try compile(source, sourceName: sourceName)
        if let callerLevel,
           let callerEnvironment = currentLuaEnvironment(level: callerLevel) {
            setEnvironment(callerEnvironment.globalTable, for: chunkFunction)
        }
        return try callValue(.luaFunction(chunkFunction), arguments: [])
    }

    /// Returns the source name of an active Lua caller. Native integration
    /// functions use this to resolve paths without exposing interpreter frames.
    public func luaCallerSourceName(level: Int = 2) -> String? {
        currentLuaFunction(level: level)?.sourceName
    }

    /// Returns the source of the innermost root chunk that is still executing.
    ///
    /// GLua resolves a relative `include()` against the file currently being
    /// evaluated, not necessarily against the file where an intervening helper
    /// function was defined. Root chunks are the functions produced directly
    /// by `compile` (`lineDefined == 0`); nested Lua closures retain a positive
    /// definition line. Keeping this lookup on the real call frames also makes
    /// module loaders, nested includes and tail-called helpers inherit the
    /// correct dynamic file context without maintaining a second side stack.
    ///
    /// When no root chunk is active (for example a callback invoked later by an
    /// embedding host), the immediate Lua caller remains the only meaningful
    /// source and is returned as a compatibility fallback.
    public func luaActiveRootChunkSourceName(
        fallbackCallerLevel level: Int = 2
    ) -> String? {
        for frame in currentCallStack().frames.reversed() {
            guard case let .luaFunction(function) = frame.callable,
                  function.lineDefined == 0 else { continue }
            return function.sourceName
        }
        return currentLuaFunction(level: level)?.sourceName
    }

    public func compile(_ source: String, sourceName: String = "=(loadstring)") throws -> LuaFunction {
        try ensureOpen()
        let chunk: LuaChunk
        do {
            let tokens = try LuaLexer(source: source).tokenize()
            chunk = try LuaParser(tokens: tokens).parse()
        } catch let LuaError.lexer(line, column, message) {
            throw LuaError.syntax(
                source: syntaxSourceDescription(sourceName),
                line: line,
                message: message,
                near: syntaxNearToken(source: source, line: line, column: column)
            )
        } catch let LuaError.parser(line, column, message) {
            throw LuaError.syntax(
                source: syntaxSourceDescription(sourceName),
                line: line,
                message: message,
                near: syntaxNearToken(source: source, line: line, column: column)
            )
        }
        let activeEnvironment = currentThreadEnvironmentTable
        let root = LuaEnvironment(globalTable: activeEnvironment, inheritVarargs: false)
        let function = LuaFunction(
            parameters: [],
            isVararg: true,
            hasCompatibilityArg: false,
            needsCompatibilityArgTable: false,
            body: chunk.statements,
            closure: root,
            environmentTable: activeEnvironment,
            sourceName: sourceName,
            lineDefined: 0
        )
        garbageCollector.adopt(.luaFunction(function))
        return function
    }

    private func ensureOpen() throws {
        if isClosed { throw LuaError.runtime("Lua state is closed") }
    }

    private func syntaxSourceDescription(_ sourceName: String) -> String {
        if sourceName.hasPrefix("@") { return String(sourceName.dropFirst()) }
        if sourceName.hasPrefix("=") { return String(sourceName.dropFirst()) }
        let firstLine = sourceName.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        var snippet = String(firstLine.prefix(51))
        if firstLine.count < sourceName.count || firstLine.count > 51 { snippet += "..." }
        return "[string \"\(snippet)\"]"
    }

    private func syntaxNearToken(source: String, line: Int, column: Int) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\r", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else { return "<eof>" }
        let characters = Array(lines[line - 1])
        let start = max(0, column - 1)
        guard start < characters.count else { return "<eof>" }
        let tail = Array(characters[start...])
        guard let first = tail.first else { return "<eof>" }

        if first == "'" || first == "\"" {
            var token = String(first)
            var escaped = false
            for character in tail.dropFirst() {
                token.append(character)
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == first { break }
            }
            return token
        }
        if first == "[", tail.count > 1, tail[1] == "[" {
            let text = String(tail)
            if let range = text.range(of: "]]" ) { return String(text[..<range.upperBound]) }
            return text
        }
        if first.isLetter || first == "_" {
            return String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        if first.isNumber {
            return String(tail.prefix { !$0.isWhitespace && !";,(){}[]".contains($0) })
        }
        return String(first)
    }

    // MARK: - Execution

    private func makeLuaFunction(
        from prototype: LuaFunctionPrototype,
        closure: LuaEnvironment
    ) -> LuaFunction {
        let parent = currentLuaFunction()
        let function = LuaFunction(
            parameters: prototype.parameters,
            isVararg: prototype.isVararg,
            hasCompatibilityArg: prototype.isVararg,
            needsCompatibilityArgTable: prototype.needsCompatibilityArgTable,
            body: prototype.body,
            closure: closure,
            environmentTable: parent?.environmentTable ?? closure.globalTable,
            sourceName: parent?.sourceName ?? "=(chunk)",
            lineDefined: prototype.lineDefined,
            lastLineDefined: prototype.lastLineDefined,
            activeLines: prototype.activeLines,
            upvalueNames: discoverUpvalueNames(in: prototype, closure: closure)
        )
        garbageCollector.adopt(.luaFunction(function))
        return function
    }

    private func discoverUpvalueNames(
        in prototype: LuaFunctionPrototype,
        closure: LuaEnvironment
    ) -> [String] {
        var scopes = [Set(prototype.parameters)]
        if prototype.isVararg { scopes[0].insert("arg") }
        var names: [String] = []
        var seen = Set<String>()

        func isLocal(_ name: String, scopes: [Set<String>]) -> Bool {
            scopes.reversed().contains { $0.contains(name) }
        }

        func record(_ name: String, scopes: [Set<String>]) {
            guard !isLocal(name, scopes: scopes),
                  closure.bindingKind(name) != nil,
                  seen.insert(name).inserted else { return }
            names.append(name)
        }

        func visitTarget(_ target: LuaAssignmentTarget, scopes: [Set<String>]) {
            switch target {
            case let .variable(name): record(name, scopes: scopes)
            case let .field(base, _): visitExpression(base, scopes: scopes)
            case let .index(base, key):
                visitExpression(base, scopes: scopes)
                visitExpression(key, scopes: scopes)
            }
        }

        func visitExpression(_ expression: LuaExpression, scopes: [Set<String>]) {
            switch expression {
            case let .variable(name): record(name, scopes: scopes)
            case let .group(inner), let .unary(_, inner):
                visitExpression(inner, scopes: scopes)
            case let .binary(left, _, right):
                visitExpression(left, scopes: scopes)
                visitExpression(right, scopes: scopes)
            case let .table(fields):
                for field in fields {
                    switch field {
                    case let .named(_, value), let .array(value):
                        visitExpression(value, scopes: scopes)
                    case let .indexed(key, value):
                        visitExpression(key, scopes: scopes)
                        visitExpression(value, scopes: scopes)
                    }
                }
            case let .field(base, _):
                visitExpression(base, scopes: scopes)
            case let .index(base, key):
                visitExpression(base, scopes: scopes)
                visitExpression(key, scopes: scopes)
            case let .call(callable, arguments):
                visitExpression(callable, scopes: scopes)
                arguments.forEach { visitExpression($0, scopes: scopes) }
            case let .methodCall(receiver, _, arguments):
                visitExpression(receiver, scopes: scopes)
                arguments.forEach { visitExpression($0, scopes: scopes) }
            case .function:
                // Nested functions own their free-variable list.
                break
            case .number, .string, .boolean, .nilValue, .vararg:
                break
            }
        }

        func visitBlock(_ statements: [LuaStatement], scopes: inout [Set<String>]) {
            for statement in statements {
                switch statement {
                case let .localDeclaration(localNames, expressions, _):
                    expressions.forEach { visitExpression($0, scopes: scopes) }
                    scopes[scopes.count - 1].formUnion(localNames)

                case let .localFunction(name, _, _):
                    scopes[scopes.count - 1].insert(name)

                case let .assignment(targets, expressions, _):
                    targets.forEach { visitTarget($0, scopes: scopes) }
                    expressions.forEach { visitExpression($0, scopes: scopes) }

                case let .functionDeclaration(target, _, _):
                    visitTarget(target, scopes: scopes)

                case let .ifStatement(branches, elseBody, _):
                    for branch in branches {
                        visitExpression(branch.condition, scopes: scopes)
                        var childScopes = scopes + [Set<String>()]
                        visitBlock(branch.body, scopes: &childScopes)
                    }
                    if let elseBody {
                        var childScopes = scopes + [Set<String>()]
                        visitBlock(elseBody, scopes: &childScopes)
                    }

                case let .whileLoop(condition, body, _, _):
                    visitExpression(condition, scopes: scopes)
                    var childScopes = scopes + [Set<String>()]
                    visitBlock(body, scopes: &childScopes)

                case let .repeatLoop(body, condition, _):
                    var childScopes = scopes + [Set<String>()]
                    visitBlock(body, scopes: &childScopes)
                    visitExpression(condition, scopes: childScopes)

                case let .numericFor(name, start, limit, step, body, _, _, _):
                    visitExpression(start, scopes: scopes)
                    visitExpression(limit, scopes: scopes)
                    if let step { visitExpression(step, scopes: scopes) }
                    var childScopes = scopes + [Set([name])]
                    visitBlock(body, scopes: &childScopes)

                case let .genericFor(localNames, expressions, body, _, _, _):
                    expressions.forEach { visitExpression($0, scopes: scopes) }
                    var childScopes = scopes + [Set(localNames)]
                    visitBlock(body, scopes: &childScopes)

                case let .doBlock(body):
                    var childScopes = scopes + [Set<String>()]
                    visitBlock(body, scopes: &childScopes)

                case let .returnValues(expressions, _):
                    expressions.forEach { visitExpression($0, scopes: scopes) }

                case let .expression(expression, _):
                    visitExpression(expression, scopes: scopes)

                case .breakLoop, .continueLoop:
                    break
                }
            }
        }

        visitBlock(prototype.body, scopes: &scopes)
        return names
    }

    private func executeBlock(_ statements: [LuaStatement], environment: LuaEnvironment) throws -> LuaControl {
        let stack = currentCallStack()
        let frameIndex = stack.frames.count - 1
        let previousEnvironment = frameIndex >= 0 ? stack.frames[frameIndex].environment : nil
        if frameIndex >= 0 { stack.frames[frameIndex].environment = environment }
        defer {
            if stack.frames.indices.contains(frameIndex) {
                stack.frames[frameIndex].environment = previousEnvironment
            }
        }
        for statement in statements {
            let control: LuaControl
            do {
                control = try execute(statement, environment: environment)
            } catch let LuaError.runtime(message) {
                let frame = currentCallStack().frames.last
                let source = frame.flatMap { frame -> String? in
                    guard case let .luaFunction(function) = frame.callable else { return nil }
                    return syntaxSourceDescription(function.sourceName)
                } ?? "?"
                throw LuaError.runtimeAt(
                    source: source,
                    line: max(0, frame?.currentLine ?? 0),
                    message: message
                )
            }
            if case .normal = control {
                try garbageCollector.safePoint()
                continue
            }
            return control
        }
        return .normal
    }

    private func execute(_ statement: LuaStatement, environment: LuaEnvironment) throws -> LuaControl {
        switch statement {
        case let .localDeclaration(names, expressions, line):
            // A declaration without initializers emits no VM instruction in
            // Lua 5.1, so it must not generate a line/count hook event.
            if !expressions.isEmpty { try traceInstruction(line: line) }
            let values = try evaluateExpressionList(expressions, environment: environment)
            for (index, name) in names.enumerated() {
                environment.define(name, value: index < values.count ? values[index] : .nilValue)
            }
            return .normal

        case let .localFunction(name, prototype, line):
            try traceInstruction(line: line)
            environment.define(name, value: .nilValue)
            let function = makeLuaFunction(from: prototype, closure: environment)
            _ = environment.assignExisting(name, value: .luaFunction(function))
            return .normal

        case let .assignment(targets, expressions, line):
            try traceInstruction(line: line)
            // Resolve all indexed LHS expressions before writing anything.
            let resolved = try targets.map { try resolveTarget($0, environment: environment) }
            let values = try evaluateExpressionList(expressions, environment: environment)
            for index in resolved.indices {
                let value = index < values.count ? values[index] : .nilValue
                try assignResolved(resolved[index], value: value, environment: environment)
            }
            return .normal

        case let .functionDeclaration(target, prototype, line):
            try traceInstruction(line: line)
            let function = makeLuaFunction(from: prototype, closure: environment)
            let resolved = try resolveTarget(target, environment: environment)
            try assignResolved(resolved, value: .luaFunction(function), environment: environment)
            return .normal

        case let .ifStatement(branches, elseBody, endLine):
            for branch in branches {
                try traceInstruction(line: branch.conditionLine)
                if try evaluateSingle(branch.condition, environment: environment).isTruthy {
                    let control = try executeBlock(branch.body, environment: environment.child())
                    if case .normal = control { try traceInstruction(line: endLine) }
                    return control
                }
            }
            if let elseBody {
                let control = try executeBlock(elseBody, environment: environment.child())
                if case .normal = control { try traceInstruction(line: endLine) }
                return control
            }
            try traceInstruction(line: endLine)
            return .normal

        case let .whileLoop(condition, body, conditionLine, endLine):
            while true {
                try traceInstruction(line: conditionLine, forceLineEvent: true)
                guard try evaluateSingle(condition, environment: environment).isTruthy else {
                    try traceInstruction(line: endLine)
                    return .normal
                }
                let control = try executeBlock(body, environment: environment.child())
                switch control {
                case .normal, .continueLoop: continue
                case .breakLoop: return .normal
                case .returned, .tailCall: return control
                }
            }

        case let .repeatLoop(body, condition, conditionLine):
            repeat {
                let loopEnvironment = environment.child()
                let control = try executeBlock(body, environment: loopEnvironment)
                switch control {
                case .breakLoop: return .normal
                case .returned, .tailCall: return control
                case .normal, .continueLoop: break
                }
                try traceInstruction(line: conditionLine, forceLineEvent: true)
                if try evaluateSingle(condition, environment: loopEnvironment).isTruthy { break }
            } while true
            return .normal

        case let .numericFor(name, startExpression, limitExpression, stepExpression, body, line, controlLine, endLine):
            try traceInstruction(line: controlLine, forceLineEvent: true)
            var current = try numericValue(evaluateSingle(startExpression, environment: environment))
            let limit = try numericValue(evaluateSingle(limitExpression, environment: environment))
            let step = try stepExpression.map { try numericValue(evaluateSingle($0, environment: environment)) } ?? 1.0
            func shouldRun(_ value: Double) -> Bool { step > 0 ? value <= limit : value >= limit }

            while shouldRun(current) {
                // Lua closes the visible control variable at the end of every
                // iteration. A fresh binding is therefore required so closures
                // created in different iterations do not share the same cell.
                let iterationEnvironment = environment.child()
                iterationEnvironment.define(name, value: .number(current))
                let control = try executeBlock(body, environment: iterationEnvironment.child())
                switch control {
                case .breakLoop: return .normal
                case .returned, .tailCall: return control
                case .normal, .continueLoop: break
                }
                current += step
                try traceInstruction(line: line, forceLineEvent: true)
            }
            try traceInstruction(line: endLine)
            return .normal

        case let .genericFor(names, expressions, body, line, expressionLine, endLine):
            try traceInstruction(line: expressionLine, forceLineEvent: true)
            let values = try evaluateExpressionList(expressions, environment: environment)
            let iterator = values.indices.contains(0) ? values[0] : .nilValue
            let state = values.indices.contains(1) ? values[1] : .nilValue
            var controlValue = values.indices.contains(2) ? values[2] : .nilValue
            while true {
                let results = try callValue(iterator, arguments: [state, controlValue])
                let first = results.first ?? .nilValue
                if isNil(first) { break }
                controlValue = first

                // Like numeric-for control variables, generic-for variables get
                // distinct closed bindings for each completed iteration.
                let iterationEnvironment = environment.child()
                for (index, name) in names.enumerated() {
                    iterationEnvironment.define(name, value: index < results.count ? results[index] : .nilValue)
                }

                let control = try executeBlock(body, environment: iterationEnvironment.child())
                switch control {
                case .breakLoop: return .normal
                case .returned, .tailCall: return control
                case .normal, .continueLoop: break
                }
                try traceInstruction(line: line, forceLineEvent: true)
            }
            try traceInstruction(line: endLine)
            return .normal

        case let .doBlock(body):
            return try executeBlock(body, environment: environment.child())

        case let .breakLoop(line):
            try traceInstruction(line: line)
            return .breakLoop

        case let .continueLoop(line):
            try traceInstruction(line: line)
            return .continueLoop

        case let .returnValues(expressions, line):
            try traceInstruction(line: line)
            if expressions.count == 1,
               let tailCall = try prepareCall(expressions[0], environment: environment) {
                return .tailCall(tailCall)
            }
            return .returned(try evaluateExpressionList(expressions, environment: environment))

        case let .expression(expression, line):
            try traceInstruction(line: line)
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

    private func callSite(
        for expression: LuaExpression,
        environment: LuaEnvironment
    ) -> (name: String?, nameWhat: String) {
        switch expression {
        case let .variable(name):
            return (name, environment.bindingKind(name) ?? "global")
        case let .field(_, name):
            return (name, "field")
        case let .index(_, .string(name)):
            return (name.utf8String, "field")
        case let .group(inner):
            return callSite(for: inner, environment: environment)
        default:
            return (nil, "")
        }
    }

    private func contextualOperationError(
        action: String,
        value: LuaValue,
        expression: LuaExpression,
        environment: LuaEnvironment
    ) -> LuaError {
        let site = callSite(for: expression, environment: environment)
        if let name = site.name, !site.nameWhat.isEmpty {
            return .runtime(
                "attempt to \(action) \(site.nameWhat) '\(name)' (a \(value.typeName) value)"
            )
        }
        return .runtime("attempt to \(action) a \(value.typeName) value")
    }

    private func prepareCall(
        _ expression: LuaExpression,
        environment: LuaEnvironment
    ) throws -> LuaPreparedCall? {
        switch expression {
        case let .call(calleeExpression, argumentExpressions):
            let callable = try evaluateSingle(calleeExpression, environment: environment)
            let arguments = try evaluateExpressionList(argumentExpressions, environment: environment)
            let site = callSite(for: calleeExpression, environment: environment)
            return LuaPreparedCall(
                callable: callable,
                arguments: arguments,
                name: site.name,
                nameWhat: site.nameWhat
            )

        case let .methodCall(receiverExpression, name, argumentExpressions):
            let receiver = try evaluateSingle(receiverExpression, environment: environment)
            let callable: LuaValue
            do {
                callable = try getIndexedValue(receiver: receiver, key: .string(LuaString(name)))
            } catch let LuaError.runtime(message)
                where message == "attempt to index a \(receiver.typeName) value" {
                throw contextualOperationError(
                    action: "index",
                    value: receiver,
                    expression: receiverExpression,
                    environment: environment
                )
            }
            let arguments = try evaluateExpressionList(argumentExpressions, environment: environment)
            return LuaPreparedCall(
                callable: callable,
                arguments: [receiver] + arguments,
                name: name,
                nameWhat: "method"
            )

        default:
            return nil
        }
    }

    private func evaluateMulti(_ expression: LuaExpression, environment: LuaEnvironment) throws -> [LuaValue] {
        switch expression {
        case .vararg:
            guard let varargs = environment.varargs else {
                throw LuaError.runtime("cannot use '...' outside a vararg function")
            }
            return varargs

        case .call, .methodCall:
            guard let call = try prepareCall(expression, environment: environment) else {
                fatalError("call expression preparation failed")
            }
            return try callValue(
                call.callable,
                arguments: call.arguments,
                callName: call.name,
                callNameWhat: call.nameWhat
            )

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
            garbageCollector.adopt(.table(table))
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
            do {
                return try getIndexedValue(receiver: receiver, key: .string(LuaString(name)))
            } catch let LuaError.runtime(message)
                where message == "attempt to index a \(receiver.typeName) value" {
                throw contextualOperationError(
                    action: "index",
                    value: receiver,
                    expression: baseExpression,
                    environment: environment
                )
            }

        case let .index(baseExpression, keyExpression):
            let receiver = try evaluateSingle(baseExpression, environment: environment)
            let key = try evaluateSingle(keyExpression, environment: environment)
            do {
                return try getIndexedValue(receiver: receiver, key: key)
            } catch let LuaError.runtime(message)
                where message == "attempt to index a \(receiver.typeName) value" {
                throw contextualOperationError(
                    action: "index",
                    value: receiver,
                    expression: baseExpression,
                    environment: environment
                )
            }

        case let .unary(operation, inner):
            let value = try evaluateSingle(inner, environment: environment)
            switch operation {
            case .negate:
                if let number = coerceNumber(value) { return .number(-number) }
                do {
                    return try unaryMetamethod(value, name: "__unm")
                } catch let LuaError.runtime(message)
                    where message.hasPrefix("attempt to perform arithmetic") {
                    throw contextualOperationError(
                        action: "perform arithmetic on",
                        value: value,
                        expression: inner,
                        environment: environment
                    )
                }
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
            if operation == .concat {
                return try evaluateConcatenation(left: left, right: right, environment: environment)
            }

            var lhs = try evaluateSingle(left, environment: environment)
            let stack = currentCallStack()
            let frameIndex = stack.frames.count - 1
            let temporaryIndex = stack.frames[frameIndex].temporaries.count
            stack.frames[frameIndex].temporaries.append(lhs)

            let rhs: LuaValue
            do {
                rhs = try evaluateSingle(right, environment: environment)
                lhs = stack.frames[frameIndex].temporaries[temporaryIndex]
                stack.frames[frameIndex].temporaries.removeSubrange(temporaryIndex...)
            } catch {
                stack.frames[frameIndex].temporaries.removeSubrange(temporaryIndex...)
                throw error
            }

            switch operation {
            case .add, .subtract, .multiply, .divide, .modulo, .power:
                do {
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
                    default: fatalError("non-arithmetic operation")
                    }
                } catch let LuaError.runtime(message)
                    where message.hasPrefix("attempt to perform arithmetic") {
                    let failingLeft = coerceNumber(lhs) == nil
                    throw contextualOperationError(
                        action: "perform arithmetic on",
                        value: failingLeft ? lhs : rhs,
                        expression: failingLeft ? left : right,
                        environment: environment
                    )
                }
            case .concat:
                fatalError("handled above")
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
        default:
            if let metatable = metatable(of: receiver) {
                let index = metatable.rawValue(forString: "__index")
                switch index {
                case let .table(table):
                    return try getTableValue(table: table, receiver: .table(table), key: key, depth: 1)
                case .luaFunction, .nativeFunction:
                    return try callValue(index, arguments: [receiver, key]).first ?? .nilValue
                case .nilValue:
                    break
                default:
                    throw LuaError.runtime("attempt to index a \(index.typeName) value")
                }
            }
            // The string library is exposed as the implicit string metatable's
            // __index table. Keep this fallback until the library installs that
            // metatable explicitly during bootstrap.
            if case .string = receiver,
               case let .string(keyName) = key,
               case let .table(stringLibrary) = getGlobal("string") {
                return stringLibrary.rawValue(forString: keyName)
            }
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
            if let metatable = metatable(of: receiver) {
                let newIndex = metatable.rawValue(forString: "__newindex")
                switch newIndex {
                case let .table(table):
                    try setTableValue(table: table, receiver: .table(table), key: key, value: value, depth: 1)
                    return
                case .luaFunction, .nativeFunction:
                    _ = try callValue(newIndex, arguments: [receiver, key, value])
                    return
                case .nilValue:
                    break
                default:
                    throw LuaError.runtime("attempt to index a \(newIndex.typeName) value")
                }
            }
            throw LuaError.runtime("attempt to index a \(receiver.typeName) value")
        }
    }

    // MARK: - Calls

    func callValue(
        _ callable: LuaValue,
        arguments: [LuaValue],
        callName: String? = nil,
        callNameWhat: String = ""
    ) throws -> [LuaValue] {
        switch callable {
        case let .nativeFunction(function):
            let stack = currentCallStack()
            stack.frames.append(LuaCallFrame(
                callable: callable,
                environment: nil,
                name: callName,
                nameWhat: callNameWhat,
                isTailCall: false,
                temporaries: arguments,
                currentLine: -1,
                lastHookLine: nil
            ))
            defer { _ = stack.frames.popLast() }

            try traceCallHook()
            let results: [LuaValue]
            do {
                results = try function.body(arguments)
            } catch {
                captureFailureFrames(stack.frames)
                throw error
            }
            try traceReturnHook()
            garbageCollector.adopt(results)
            return results

        case let .luaFunction(function):
            let results = try callLuaFunction(
                function,
                arguments: arguments,
                callName: callName,
                callNameWhat: callNameWhat
            )
            garbageCollector.adopt(results)
            return results

        default:
            if let metatable = metatable(of: callable) {
                let callMeta = metatable.rawValue(forString: "__call")
                if !isNil(callMeta) {
                    return try callValue(
                        callMeta,
                        arguments: [callable] + arguments,
                        callName: callName,
                        callNameWhat: callNameWhat
                    )
                }
            }
            if let callName, !callNameWhat.isEmpty {
                throw LuaError.runtime(
                    "attempt to call \(callNameWhat) '\(callName)' (a \(callable.typeName) value)"
                )
            }
            throw LuaError.runtime("attempt to call a \(callable.typeName) value")
        }
    }

    private func callLuaFunction(
        _ initialFunction: LuaFunction,
        arguments initialArguments: [LuaValue],
        callName initialCallName: String?,
        callNameWhat initialCallNameWhat: String
    ) throws -> [LuaValue] {
        let stack = currentCallStack()
        let activeLuaDepth = stack.frames.reduce(into: 0) { depth, frame in
            guard !frame.isTailCall else { return }
            if case .luaFunction = frame.callable { depth += 1 }
        }
        guard activeLuaDepth < Self.maxLuaCallDepth else {
            throw LuaError.runtime("stack overflow")
        }
        let baseDepth = stack.frames.count
        var function = initialFunction
        var arguments = initialArguments
        var callName = initialCallName
        var callNameWhat = initialCallNameWhat

        func cleanFrames() {
            if stack.frames.count > baseDepth {
                captureFailureFrames(stack.frames)
                stack.frames.removeSubrange(baseDepth...)
            }
        }

        func unwindTailFrames() throws {
            while stack.frames.count > baseDepth, stack.frames.last?.isTailCall == true {
                try traceTailReturnHook()
                _ = stack.frames.popLast()
            }
        }

        while true {
            let fixedCount = function.parameters.count
            let extra = function.isVararg && arguments.count > fixedCount
                ? Array(arguments.dropFirst(fixedCount))
                : []
            let callEnvironment = LuaEnvironment(
                parent: function.closure,
                globalTable: function.environmentTable,
                varargs: function.isVararg ? extra : nil,
                inheritVarargs: false,
                isFunctionScopeRoot: true
            )
            for (index, parameter) in function.parameters.enumerated() {
                callEnvironment.define(parameter, value: index < arguments.count ? arguments[index] : .nilValue)
            }
            if function.hasCompatibilityArg {
                // Lua 5.1 exposes the compatibility `arg` local in vararg
                // functions. Evaluating `...` clears VARARG_NEEDSARG in PUC
                // Lua 5.1, leaving that local nil instead of constructing the
                // legacy table.
                if function.needsCompatibilityArgTable {
                    let argTable = LuaTable()
                    garbageCollector.adopt(.table(argTable))
                    for (index, value) in extra.enumerated() {
                        argTable.rawSetValue(value, forNumber: Double(index + 1))
                    }
                    argTable.rawSetValue(.number(Double(extra.count)), forString: "n")
                    callEnvironment.define("arg", value: .table(argTable))
                } else {
                    callEnvironment.define("arg", value: .nilValue)
                }
            }
            let stack = currentCallStack()
            stack.frames.append(LuaCallFrame(
                callable: .luaFunction(function),
                environment: callEnvironment,
                name: callName,
                nameWhat: callNameWhat,
                isTailCall: false,
                temporaries: [],
                // A newly-entered Lua frame has not executed its definition
                // line yet. Keeping this distinct prevents a hook installed
                // by the call event from suppressing the first body line.
                currentLine: -1,
                lastHookLine: nil
            ))

            let control: LuaControl
            do {
                try traceCallHook()
                control = try executeBlock(function.body, environment: callEnvironment)
            } catch {
                cleanFrames()
                throw error
            }

            switch control {
            case let .tailCall(tailCall):
                if case let .luaFunction(nextFunction) = tailCall.callable {
                    // PUC Lua 5.1 only replaces the current Lua activation
                    // (and therefore exposes a historical "tail" pseudo
                    // frame) when OP_TAILCALL enters another Lua closure. A
                    // C/native callee returns through the still-active Lua
                    // frame. This distinction matters to getfenv(): a
                    // historical tail pseudo frame is not a valid level, but
                    // `return getfenv(1)` must still see its active caller.
                    stack.frames[stack.frames.count - 1] = LuaCallFrame(
                        callable: .luaFunction(function),
                        environment: callEnvironment,
                        name: callName,
                        nameWhat: callNameWhat,
                        isTailCall: true,
                        temporaries: [],
                        currentLine: stack.frames[stack.frames.count - 1].currentLine,
                        lastHookLine: stack.frames[stack.frames.count - 1].lastHookLine
                    )
                    function = nextFunction
                    arguments = tailCall.arguments
                    callName = tailCall.name
                    callNameWhat = tailCall.nameWhat
                    continue
                }

                do {
                    let values = try callValue(
                        tailCall.callable,
                        arguments: tailCall.arguments,
                        callName: tailCall.name,
                        callNameWhat: tailCall.nameWhat
                    )
                    try traceReturnHook()
                    _ = stack.frames.popLast()
                    try unwindTailFrames()
                    return values
                } catch {
                    cleanFrames()
                    throw error
                }

            case let .returned(values):
                do {
                    try traceReturnHook()
                    _ = stack.frames.popLast()
                    try unwindTailFrames()
                    return values
                } catch {
                    cleanFrames()
                    throw error
                }

            case .normal:
                do {
                    try traceReturnHook()
                    _ = stack.frames.popLast()
                    try unwindTailFrames()
                    return []
                } catch {
                    cleanFrames()
                    throw error
                }

            case .breakLoop:
                cleanFrames()
                throw LuaError.runtime("no loop to break")

            case .continueLoop:
                cleanFrames()
                throw LuaError.runtime("no loop to continue")
            }
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

    private func evaluateConcatenation(
        left: LuaExpression,
        right: LuaExpression,
        environment: LuaEnvironment
    ) throws -> LuaValue {
        var expressions: [LuaExpression] = []
        func flatten(_ expression: LuaExpression) {
            if case let .binary(nestedLeft, .concat, nestedRight) = expression {
                flatten(nestedLeft)
                flatten(nestedRight)
            } else {
                expressions.append(expression)
            }
        }
        flatten(left)
        flatten(right)

        let values = try expressions.map { try evaluateSingle($0, environment: environment) }
        let strings = values.map(primitiveConcatString)
        if strings.allSatisfy({ $0 != nil }) {
            let pieces = strings.compactMap { $0 }
            let maximumLua51StringLength = UInt64(UInt32.max)
            var total: UInt64 = 0
            for piece in pieces {
                let count = UInt64(piece.count)
                guard count <= maximumLua51StringLength - total else {
                    throw LuaError.runtime("string length overflow")
                }
                total += count
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(total))
            for piece in pieces { bytes.append(contentsOf: piece.bytes) }
            return .string(LuaString(bytes: bytes))
        }

        guard var result = values.last else { return .string("") }
        for value in values.dropLast().reversed() {
            if let a = primitiveConcatString(value), let b = primitiveConcatString(result) {
                let count = UInt64(a.count) + UInt64(b.count)
                guard count <= UInt64(UInt32.max) else {
                    throw LuaError.runtime("string length overflow")
                }
                result = .string(LuaString(bytes: a.bytes + b.bytes))
            } else if let metamethodResult = try callBinaryMetamethod(value, result, name: "__concat") {
                result = metamethodResult
            } else {
                throw LuaError.runtime("attempt to concatenate a \(value.typeName) value")
            }
        }
        return result
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

    func luaTostringValue(_ value: LuaValue) throws -> LuaValue {
        if let metatable = metatable(of: value) {
            let metamethod = metatable.rawValue(forString: "__tostring")
            if !isNil(metamethod) {
                return try callValue(metamethod, arguments: [value]).first ?? .nilValue
            }
        }
        return .string(LuaString(value.printable))
    }

    func luaString(_ value: LuaValue) throws -> String {
        let result = try luaTostringValue(value)
        guard case let .string(string) = result else {
            throw LuaError.runtime("'__tostring' must return a string")
        }
        return string.utf8String
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
            case .syntax:
                return .string(luaStringPreservingSourceBytes(luaError.description))
            default: return .string(LuaString(luaError.description))
            }
        }
        return .string(LuaString(String(describing: error)))
    }

    private func luaStringPreservingSourceBytes(_ text: String) -> LuaString {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            if (0xE080...0xE0FF).contains(scalar.value) {
                bytes.append(UInt8(scalar.value - 0xE000))
            } else {
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        return LuaString(bytes: bytes)
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

    func garbageCollectionRoots() -> (values: [LuaValue], environments: [LuaEnvironment]) {
        var values: [LuaValue] = [
            .table(globalTable),
            .table(registryTable),
            .table(threadEnvironmentTable),
            mainDebugHookState.function
        ]
        values.append(contentsOf: primitiveMetatables.values.map(LuaValue.table))
        values.append(contentsOf: dumpRegistry.values.map(LuaValue.luaFunction))
        if let currentThread = LuaThread.current { values.append(.thread(currentThread)) }

        var environments: [LuaEnvironment] = []
        func appendFrames(_ frames: [LuaCallFrame]) {
            for frame in frames {
                values.append(frame.callable)
                values.append(contentsOf: frame.temporaries)
                if let environment = frame.environment { environments.append(environment) }
            }
        }
        appendFrames(currentCallStack().frames)
        if let mainFailureFrames { appendFrames(mainFailureFrames) }
        return (values, environments)
    }

    func captureFailureFrames(_ frames: [LuaCallFrame]) {
        if let thread = LuaThread.current {
            thread.captureFailureFrames(frames)
        } else if mainFailureFrames == nil {
            mainFailureFrames = frames
        }
    }

    func failureFramesForCurrentThread() -> [LuaCallFrame]? {
        LuaThread.current?.failureFramesSnapshot() ?? mainFailureFrames
    }

    func clearFailureFramesForCurrentThread() {
        if let thread = LuaThread.current { thread.clearFailureFrames() }
        else { mainFailureFrames = nil }
    }

    func currentLuaFunction(level: Int = 1) -> LuaFunction? {
        guard let frame = currentLuaCallFrame(level: level),
              case let .luaFunction(function) = frame.callable else { return nil }
        return function
    }

    func currentLuaEnvironment(level: Int = 1) -> LuaEnvironment? {
        currentLuaCallFrame(level: level)?.environment
    }

    func currentLuaCallFrame(level: Int = 1) -> LuaCallFrame? {
        let frames = currentCallStack().frames
        guard level >= 1, level <= frames.count else { return nil }
        return frames[frames.count - level]
    }

    func setEnvironment(_ table: LuaTable, for function: LuaFunction) {
        function.environmentTable = table
        let stack = currentCallStack()
        for frame in stack.frames {
            guard case let .luaFunction(activeFunction) = frame.callable,
                  activeFunction === function else { continue }
            frame.environment?.replaceActiveFunctionGlobalTable(with: table)
        }
    }

    func debugHookState(for thread: LuaThread? = nil) -> LuaDebugHookState {
        if let thread { return thread.debugHookState }
        return LuaThread.current?.debugHookState ?? mainDebugHookState
    }

    func setDebugHook(function: LuaValue, mask: String, count: Int, thread: LuaThread? = nil) {
        let hookState = debugHookState(for: thread)
        hookState.function = function
        hookState.mask = ["c", "r", "l"].filter { mask.contains($0) }.joined()
        hookState.count = max(0, count)
        hookState.countdown = hookState.count
        if let thread {
            thread.seedHookLinesFromCurrentPC()
        } else {
            for index in currentCallStack().frames.indices {
                // Installing a hook does not make the remainder of the current
                // source line a new line event. Seed the hook PC from each active
                // frame's current line, matching Lua 5.1's oldpc behavior.
                currentCallStack().frames[index].lastHookLine = currentCallStack().frames[index].currentLine
            }
        }
    }

    func clearDebugHook(thread: LuaThread? = nil) {
        setDebugHook(function: .nilValue, mask: "", count: 0, thread: thread)
    }

    func traceInstruction(line: Int, forceLineEvent: Bool = false) throws {
        let stack = currentCallStack()
        guard !stack.frames.isEmpty else { return }
        let frameIndex = stack.frames.count - 1
        stack.frames[frameIndex].currentLine = line

        let hookState = debugHookState()
        guard hookState.depth == 0, !isNil(hookState.function) else { return }

        if hookState.count > 0 {
            hookState.countdown -= 1
            if hookState.countdown <= 0 {
                hookState.countdown = hookState.count
                try invokeDebugHook(event: "count", line: nil, state: hookState)
            }
        }

        guard hookState.mask.contains("l") else { return }
        if forceLineEvent || stack.frames[frameIndex].lastHookLine != line {
            stack.frames[frameIndex].lastHookLine = line
            try invokeDebugHook(event: "line", line: line, state: hookState)
        }
    }

    private func traceCallHook() throws {
        let hookState = debugHookState()
        guard hookState.depth == 0, hookState.mask.contains("c"), !isNil(hookState.function) else { return }
        try invokeDebugHook(event: "call", line: nil, state: hookState)
    }

    private func traceReturnHook() throws {
        let hookState = debugHookState()
        guard hookState.depth == 0, hookState.mask.contains("r"), !isNil(hookState.function) else { return }
        try invokeDebugHook(event: "return", line: nil, state: hookState)
    }

    private func traceTailReturnHook() throws {
        let hookState = debugHookState()
        guard hookState.depth == 0, hookState.mask.contains("r"), !isNil(hookState.function) else { return }
        try invokeDebugHook(event: "tail return", line: nil, state: hookState)
    }

    private func invokeDebugHook(event: String, line: Int?, state: LuaDebugHookState) throws {
        let hook = state.function
        guard !isNil(hook) else { return }
        state.depth += 1
        defer { state.depth -= 1 }
        _ = try callValue(
            hook,
            arguments: [.string(LuaString(event)), line.map { .number(Double($0)) } ?? .nilValue],
            callName: "?",
            callNameWhat: "hook"
        )
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

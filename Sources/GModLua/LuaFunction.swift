public final class LuaFunction: @unchecked Sendable {
    let parameters: [String]
    let isVararg: Bool
    let hasCompatibilityArg: Bool
    let needsCompatibilityArgTable: Bool
    let body: [LuaStatement]
    let closure: LuaEnvironment
    var environmentTable: LuaTable
    let sourceName: String
    let lineDefined: Int
    let lastLineDefined: Int
    let activeLines: Set<Int>
    let upvalueNames: [String]

    init(
        parameters: [String],
        isVararg: Bool,
        hasCompatibilityArg: Bool = false,
        needsCompatibilityArgTable: Bool = false,
        body: [LuaStatement],
        closure: LuaEnvironment,
        environmentTable: LuaTable? = nil,
        sourceName: String = "=(chunk)",
        lineDefined: Int = 0,
        lastLineDefined: Int = -1,
        activeLines: Set<Int> = [],
        upvalueNames: [String] = []
    ) {
        self.parameters = parameters
        self.isVararg = isVararg
        self.hasCompatibilityArg = hasCompatibilityArg
        self.needsCompatibilityArgTable = needsCompatibilityArgTable
        self.body = body
        self.closure = closure
        self.environmentTable = environmentTable ?? closure.globalTable
        self.sourceName = sourceName
        self.lineDefined = lineDefined
        self.lastLineDefined = lastLineDefined
        self.activeLines = activeLines
        self.upvalueNames = upvalueNames
    }

    func upvalueEntries() -> [(String, LuaValue)] {
        upvalueNames.compactMap { name in
            closure.localValue(name).map { (name, $0) }
        }
    }
}

/// State-local executable blueprint used by `string.dump`.
///
/// GModLua does not yet serialize PUC Lua bytecode, but a dumped chunk must
/// still behave like a binary chunk when it is loaded again in the same
/// state: loading creates a new closure, preserves the function prototype,
/// and initializes every serialized upvalue to nil. Keeping only this
/// blueprint also prevents `string.dump` from retaining the original
/// closure's captured values as hidden GC roots.
struct LuaDumpedFunction {
    let parameters: [String]
    let isVararg: Bool
    let hasCompatibilityArg: Bool
    let needsCompatibilityArgTable: Bool
    let body: [LuaStatement]
    let sourceName: String
    let lineDefined: Int
    let lastLineDefined: Int
    let activeLines: Set<Int>
    let upvalueNames: [String]

    init(_ function: LuaFunction) {
        parameters = function.parameters
        isVararg = function.isVararg
        hasCompatibilityArg = function.hasCompatibilityArg
        needsCompatibilityArgTable = function.needsCompatibilityArgTable
        body = function.body
        sourceName = function.sourceName
        lineDefined = function.lineDefined
        lastLineDefined = function.lastLineDefined
        activeLines = function.activeLines
        upvalueNames = function.upvalueNames
    }

    func instantiate(environmentTable: LuaTable) -> LuaFunction {
        let closure = LuaEnvironment(
            globalTable: environmentTable,
            inheritVarargs: false
        )
        for name in upvalueNames {
            closure.define(name, value: .nilValue)
        }
        return LuaFunction(
            parameters: parameters,
            isVararg: isVararg,
            hasCompatibilityArg: hasCompatibilityArg,
            needsCompatibilityArgTable: needsCompatibilityArgTable,
            body: body,
            closure: closure,
            environmentTable: environmentTable,
            sourceName: sourceName,
            lineDefined: lineDefined,
            lastLineDefined: lastLineDefined,
            activeLines: activeLines,
            upvalueNames: upvalueNames
        )
    }
}

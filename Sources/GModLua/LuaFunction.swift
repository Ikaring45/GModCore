public final class LuaFunction: @unchecked Sendable {
    let parameters: [String]
    let isVararg: Bool
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

public final class LuaFunction: @unchecked Sendable {
    let parameters: [String]
    let isVararg: Bool
    let body: [LuaStatement]
    let closure: LuaEnvironment
    var environmentTable: LuaTable
    let sourceName: String
    let lineDefined: Int

    init(
        parameters: [String],
        isVararg: Bool,
        body: [LuaStatement],
        closure: LuaEnvironment,
        environmentTable: LuaTable? = nil,
        sourceName: String = "=(chunk)",
        lineDefined: Int = 0
    ) {
        self.parameters = parameters
        self.isVararg = isVararg
        self.body = body
        self.closure = closure
        self.environmentTable = environmentTable ?? closure.globalTable
        self.sourceName = sourceName
        self.lineDefined = lineDefined
    }
}

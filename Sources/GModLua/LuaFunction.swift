public final class LuaFunction {

    let parameters:
        [String]

    let body:
        [LuaStatement]

    /*
     Lua closure。

     関数生成時点のEnvironmentを
     referenceとして保持する。

     これにより、

     local n = 0

     return function()
         n = n + 1
     end

     が成立する。
    */
    let closure:
        LuaEnvironment

    init(
        parameters: [String],
        body: [LuaStatement],
        closure: LuaEnvironment
    ) {

        self.parameters =
            parameters

        self.body =
            body

        self.closure =
            closure
    }
}

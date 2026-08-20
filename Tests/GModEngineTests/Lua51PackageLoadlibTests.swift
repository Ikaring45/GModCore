import GModLua
import XCTest

final class Lua51PackageLoadlibTests: XCTestCase {
    func testUnavailableDynamicLoaderUsesLua51FallbackContract() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local loader, message, where = package.loadlib(
                "does-not-exist",
                "luaopen_does_not_exist"
            )
            assert(loader == nil)
            assert(message == "dynamic libraries not enabled; check your Lua installation")
            assert(where == "absent")

            local ok, errorMessage = pcall(package.loadlib)
            assert(not ok and string.find(errorMessage, "bad argument #1"))
            ok, errorMessage = pcall(package.loadlib, "does-not-exist")
            assert(not ok and string.find(errorMessage, "bad argument #2"))

            loader, message, where = package.loadlib(123, 456)
            assert(loader == nil and type(message) == "string" and where == "absent")
            """#,
            sourceName: "@Lua51PackageLoadlibRegression.lua"
        )
    }
}

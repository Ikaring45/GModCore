import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaVectorAngleTests: XCTestCase {
    func testDocumentedVectorAngleCompatibilityRegression() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaVectorAngleRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaVectorAngleRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        try GMLuaVectorAngle.install(into: state, typeSystem: typeSystem)

        try state.execute(source, sourceName: "@GLuaVectorAngleRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_VECTOR_ANGLE_REGRESSION_OK") else {
            return XCTFail("Vector/Angle regression fixture did not reach its success sentinel")
        }
    }

    func testRuntimeInstallsNativeVectorAndAngleInStrictMode() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )

        // Before includes/util.lua installs GLua's public wrapper, core Lua
        // correctly reports native values as userdata. The constructors and
        // native metatable methods must nevertheless be available immediately.
        try runtime.execute(
            """
            local v = Vector(3, 4, 0)
            local a = Angle(0, 90, 0)
            assert(type(v) == "userdata" and type(a) == "userdata")
            assert(v.x == 3 and v.y == 4 and v.z == 0)
            assert(math.abs(v:Length() - 5) < 1e-9)
            local f = a:Forward()
            assert(math.abs(f.x) < 1e-8 and math.abs(f.y - 1) < 1e-8)
            assert(Vector ~= nil and Angle ~= nil)
            """,
            sourceName: "@GLuaVectorAngleStrictBootstrap.lua"
        )
    }
}

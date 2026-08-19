import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaConVarTests: XCTestCase {
    func testDocumentedConVarCompatibilityRegression() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaConVarRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaConVarRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        try GMLuaConVar.install(into: state, typeSystem: typeSystem, realm: .server)

        try state.execute(source, sourceName: "@GLuaConVarRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_CONVAR_REGRESSION_OK") else {
            return XCTFail("ConVar regression fixture did not reach its success sentinel")
        }
    }

    func testClientConVarAddsDocumentedArchiveAndUserInfoFlags() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        try GMLuaConVar.install(into: state, typeSystem: typeSystem, realm: .client)

        try state.execute(
            """
            local saved = CreateClientConVar("gpad_client_saved", "1")
            assert(saved:IsFlagSet(FCVAR_ARCHIVE))
            assert(saved:IsFlagSet(FCVAR_LUA_CLIENT))
            assert(not saved:IsFlagSet(FCVAR_USERINFO))

            local user = CreateClientConVar("gpad_client_user", "0", false, true)
            assert(not user:IsFlagSet(FCVAR_ARCHIVE))
            assert(user:IsFlagSet(FCVAR_USERINFO))
            assert(user:IsFlagSet(FCVAR_LUA_CLIENT))
            """,
            sourceName: "@GLuaClientConVarRegression.lua"
        )
    }

    func testStrictRuntimeInstallsNativeConVarsBeforeOfficialUtilLayer() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )

        try runtime.execute(
            """
            local value = CreateConVar("gpad_runtime_convar", "7", FCVAR_NOTIFY)
            assert(type(value) == "userdata")
            assert(value:GetInt() == 7)
            assert(GetConVar("gpad_runtime_convar") == value)
            assert(GetConVarString("missing_runtime_convar") == "")
            assert(GetConVarNumber("missing_runtime_convar") == 0)
            """,
            sourceName: "@GLuaConVarStrictBootstrap.lua"
        )
    }
}

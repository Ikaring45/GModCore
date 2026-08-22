import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaConVarTests: XCTestCase {
    func testCreateConVarRejectsBitFlagsOutsideInt64WithoutTrapping() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        try runtime.execute(
            """
            local upper_ok, upper_err = pcall(CreateConVar, "flag_upper", "1", 9223372036854775808)
            assert(not upper_ok and string.find(upper_err, "finite bitflag expected", 1, true))
            local nan_ok = pcall(CreateConVar, "flag_nan", "1", 0/0)
            local inf_ok = pcall(CreateConVar, "flag_inf", "1", 1/0)
            assert(not nan_ok and not inf_ok)
            local lower = CreateConVar("flag_lower", "1", -9223372036854775808)
            assert(lower ~= nil)
            """,
            sourceName: "@GMLuaConVarFlagRangeRegression.lua"
        )
    }

    func testRuntimeRetainsExplicitEngineCatalogAndObservesHostUpdates() throws {
        let catalog = try GMLuaEngineConVarCatalog(
            descriptors: [
                .init(name: "gmod_language", defaultValue: "en")
            ]
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            engineConVarCatalog: catalog
        )

        XCTAssertTrue(try XCTUnwrap(runtime.engineConVarCatalog) === catalog)
        try runtime.execute(
            "assert(GetConVar('gmod_language'):GetString() == 'en')"
        )
        XCTAssertTrue(catalog.setCurrentValue("ja", for: "gmod_language"))
        try runtime.execute(
            "assert(GetConVar('gmod_language'):GetString() == 'ja')"
        )
        XCTAssertEqual(runtime.conVarRegistry?.stringValue(for: "GMOD_LANGUAGE"), "ja")
    }

    func testHostCatalogInstallsEngineConVarsAndPreservesCollisions() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaEngineConVarCatalogRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaEngineConVarCatalogRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let catalog = try GMLuaEngineConVarCatalog(
            descriptors: [
                GMLuaEngineConVarDescriptor(
                    name: "gmod_language",
                    defaultValue: "en",
                    flags: 128,
                    helpText: "Headless engine language"
                ),
                GMLuaEngineConVarDescriptor(
                    name: "gpad_host_bounded",
                    defaultValue: "3",
                    initialValue: "99",
                    minimum: -10,
                    maximum: 10
                )
            ]
        )

        XCTAssertFalse(
            try catalog.define(
                GMLuaEngineConVarDescriptor(
                    name: "GMOD_LANGUAGE",
                    defaultValue: "fr"
                )
            )
        )
        XCTAssertTrue(catalog.contains("GMOD_LANGUAGE"))
        XCTAssertEqual(catalog.currentValue(for: "gpad_host_bounded"), "10")
        XCTAssertFalse(catalog.setCurrentValue("invented", for: "gpad_host_unknown"))

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaConVar.install(
            into: state,
            typeSystem: typeSystem,
            realm: .client,
            engineCatalog: catalog
        )

        try state.execute(source, sourceName: "@GLuaEngineConVarCatalogRegression.lua")
        guard case .boolean(true) = state.getGlobal(
            "GLUA_ENGINE_CONVAR_CATALOG_REGRESSION_OK"
        ) else {
            return XCTFail("engine ConVar catalog fixture did not reach its success sentinel")
        }

        XCTAssertTrue(catalog.setCurrentValue("fr", for: "GMOD_LANGUAGE"))
        XCTAssertEqual(catalog.currentValue(for: "gmod_language"), "fr")
        XCTAssertEqual(registry.stringValue(for: "GMOD_LANGUAGE"), "fr")
        try state.execute(
            "assert(GetConVar(\"gmod_language\"):GetString() == \"fr\")",
            sourceName: "=(synthetic host ConVar update regression)"
        )

        XCTAssertTrue(catalog.setCurrentValue("-99", for: "gpad_host_bounded"))
        XCTAssertEqual(catalog.currentValue(for: "GPAD_HOST_BOUNDED"), "-10")
        XCTAssertEqual(registry.stringValue(for: "gpad_host_bounded"), "-10")
    }

    func testHostCatalogRejectsInvalidDefinitionsWithoutInventingEntries() throws {
        let catalog = GMLuaEngineConVarCatalog()
        XCTAssertThrowsError(
            try catalog.define(
                GMLuaEngineConVarDescriptor(name: "", defaultValue: "1")
            )
        ) { error in
            XCTAssertEqual(error as? GMLuaEngineConVarCatalogError, .emptyName)
        }
        XCTAssertThrowsError(
            try catalog.define(
                GMLuaEngineConVarDescriptor(
                    name: "gpad_invalid_bounds",
                    defaultValue: "1",
                    minimum: 2,
                    maximum: 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? GMLuaEngineConVarCatalogError,
                .invalidBounds(name: "gpad_invalid_bounds")
            )
        }
        XCTAssertFalse(catalog.contains(""))
        XCTAssertFalse(catalog.contains("gpad_invalid_bounds"))
    }

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
        let catalog = GMLuaEngineConVarCatalog()
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        try GMLuaConVar.install(
            into: state,
            typeSystem: typeSystem,
            realm: .client,
            engineCatalog: catalog
        )

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
            user:SetString("remover")
            """,
            sourceName: "@GLuaClientConVarRegression.lua"
        )
        XCTAssertFalse(catalog.contains("gpad_client_saved"))
        XCTAssertEqual(catalog.currentValue(for: "GPAD_CLIENT_USER"), "remover")
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

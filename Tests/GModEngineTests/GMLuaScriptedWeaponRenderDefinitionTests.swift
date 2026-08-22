import GModEngine
import XCTest

final class GMLuaScriptedWeaponRenderDefinitionTests: XCTestCase {
    func testReadsInheritedWeaponRenderFieldsFromWeaponsGet() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        defer { runtime.close() }
        try runtime.execute(
            """
            weapons = {}
            function weapons.Get(name)
                assert(name == "gmod_tool")
                return {
                    ViewModel = "models/weapons/c_toolgun.mdl",
                    WorldModel = "models/weapons/w_toolgun.mdl",
                    ViewModelFOV = 62
                }
            end
            """
        )

        XCTAssertEqual(
            try runtime.scriptedWeaponRenderDefinition(className: "gmod_tool"),
            GMLuaScriptedWeaponRenderDefinition(
                className: "gmod_tool",
                viewModel: SourceEntityModelReference(
                    "models/weapons/c_toolgun.mdl"
                ),
                worldModel: SourceEntityModelReference(
                    "models/weapons/w_toolgun.mdl"
                ),
                viewModelFieldOfViewDegrees: 62
            )
        )
    }

    func testPreservesIntentionalEmptyWorldModelWithoutFallback() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        defer { runtime.close() }
        try runtime.execute(
            """
            weapons = {}
            function weapons.Get(name)
                return {
                    ViewModel = "models/weapons/c_arms.mdl",
                    WorldModel = "",
                    ViewModelFOV = 54
                }
            end
            """
        )

        let definition = try runtime.scriptedWeaponRenderDefinition(
            className: "weapon_fists"
        )
        XCTAssertEqual(
            definition.viewModel,
            SourceEntityModelReference("models/weapons/c_arms.mdl")
        )
        XCTAssertNil(definition.worldModel)
        XCTAssertEqual(definition.viewModelFieldOfViewDegrees, 54)
    }

    func testRejectsMissingOrInvalidViewModelFOV() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        defer { runtime.close() }
        try runtime.execute(
            """
            weapons = {}
            function weapons.Get(name)
                return {
                    ViewModel = "models/weapons/c_pistol.mdl",
                    WorldModel = "models/weapons/w_pistol.mdl",
                    ViewModelFOV = 180
                }
            end
            """
        )

        XCTAssertThrowsError(
            try runtime.scriptedWeaponRenderDefinition(
                className: "weapon_pistol"
            )
        ) { error in
            XCTAssertEqual(
                error as? GMLuaScriptedWeaponRenderDefinitionError,
                .invalidViewModelFieldOfView(
                    className: "weapon_pistol",
                    value: 180
                )
            )
        }
    }
}

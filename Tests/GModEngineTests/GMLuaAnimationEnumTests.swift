import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaAnimationEnumTests: XCTestCase {
    func testVerifiedCorpusSetAndRelatedAnimationFamilies() throws {
        XCTAssertEqual(
            GMLuaAnimationEnums.activityConstantsRequiredByBundledGamemodes.count,
            204
        )
        XCTAssertEqual(GMLuaAnimationEnums.playerConstants.count, 10)
        XCTAssertEqual(GMLuaAnimationEnums.playerAnimationEventConstants.count, 24)
        XCTAssertEqual(GMLuaAnimationEnums.gestureSlotConstants.count, 7)
        XCTAssertEqual(GMLuaAnimationEnums.relatedEngineConstants.count, 2)
        XCTAssertEqual(GMLuaAnimationEnums.installedConstants.count, 247)

        XCTAssertEqual(
            GMLuaAnimationEnums.activityConstantsRequiredByBundledGamemodes[
                "ACT_MP_STAND_IDLE"
            ],
            990
        )
        XCTAssertEqual(
            GMLuaAnimationEnums.activityConstantsRequiredByBundledGamemodes[
                "ACT_HL2MP_IDLE"
            ],
            1_777
        )
        XCTAssertEqual(
            GMLuaAnimationEnums.activityConstantsRequiredByBundledGamemodes[
                "ACT_GMOD_GESTURE_ITEM_PLACE"
            ],
            2_022
        )
    }

    func testFixtureRunsAgainstDirectNativeInstallation() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaAnimationEnumRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaAnimationEnumRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })
        GMLuaAnimationEnums.install(into: state)

        try state.execute(source, sourceName: "@GLuaAnimationEnumRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_ANIMATION_ENUM_REGRESSION_OK") else {
            return XCTFail("animation enum fixture did not reach its success sentinel")
        }
    }

    func testRuntimeInstallsSameNativeConstantsInEveryRealm() throws {
        for realm in [GMLuaRealm.server, .client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            defer { _ = runtime.close() }
            try runtime.execute(
                """
                assert(ACT_MP_STAND_IDLE == 990)
                assert(ACT_HL2MP_IDLE == 1777)
                assert(PLAYERANIMEVENT_CANCEL_RELOAD == 23)
                assert(GESTURE_SLOT_CUSTOM == 6)
                """,
                sourceName: "@GMLuaAnimationEnumRealmRegression.lua"
            )
        }
    }
}

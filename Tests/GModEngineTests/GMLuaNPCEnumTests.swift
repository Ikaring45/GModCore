import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaNPCEnumTests: XCTestCase {
    func testPublicDocumentedFamiliesHaveVerifiedCoverage() {
        XCTAssertEqual(GMLuaNPCEnums.sharedSpawnFlagConstants.count, 10)
        XCTAssertEqual(GMLuaNPCEnums.serverSpawnFlagConstants.count, 24)
        XCTAssertEqual(GMLuaNPCEnums.citizenTypeConstants.count, 5)
        XCTAssertEqual(GMLuaNPCEnums.npcStateConstants.count, 9)
        XCTAssertEqual(GMLuaNPCEnums.allServerConstants.count, 48)

        XCTAssertEqual(
            GMLuaNPCEnums.serverSpawnFlagConstants["SF_NPC_DROP_HEALTHKIT"],
            8
        )
        XCTAssertEqual(
            GMLuaNPCEnums.serverSpawnFlagConstants["SF_CITIZEN_MEDIC"],
            131_072
        )
        XCTAssertEqual(GMLuaNPCEnums.citizenTypeConstants["CT_UNIQUE"], 4)
        XCTAssertEqual(GMLuaNPCEnums.npcStateConstants["NPC_STATE_INVALID"], -1)
        XCTAssertEqual(GMLuaNPCEnums.npcStateConstants["NPC_STATE_DEAD"], 7)
    }

    func testServerFixtureRunsAgainstNativeInstallation() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaNPCEnumRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaNPCEnumRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })
        try GMLuaBitLibrary.install(into: state)
        GMLuaNPCEnums.install(into: state, realm: .server)

        try state.execute(source, sourceName: "@GLuaNPCEnumRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_NPC_ENUM_REGRESSION_OK") else {
            return XCTFail("NPC enum fixture did not reach its success sentinel")
        }
    }

    func testRuntimeHonorsDocumentedRealmAvailability() throws {
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        defer { _ = server.close() }
        try server.execute(
            """
            assert(SF_NPC_DROP_HEALTHKIT == 8)
            assert(SF_CITIZEN_MEDIC == 131072)
            assert(CT_REBEL == 3)
            assert(NPC_STATE_COMBAT == 3)
            assert(SF_WEAPON_NO_PLAYER_PICKUP == 2)
            """,
            sourceName: "@GMLuaNPCEnumServerRealmRegression.lua"
        )

        for realm in [GMLuaRealm.client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            defer { _ = runtime.close() }
            try runtime.execute(
                """
                assert(SF_WEAPON_NO_PLAYER_PICKUP == 2)
                assert(SF_PHYSBOX_MOTIONDISABLED == 32768)
                assert(SF_NPC_DROP_HEALTHKIT == nil)
                assert(SF_CITIZEN_MEDIC == nil)
                assert(CT_REBEL == nil)
                assert(NPC_STATE_COMBAT == nil)
                """,
                sourceName: "@GMLuaNPCEnumSharedRealmRegression.lua"
            )
        }
    }
}

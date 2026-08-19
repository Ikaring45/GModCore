import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaNetworkedGlobalsTests: XCTestCase {
    func testStandaloneRuntimePassesOriginalRegressionFixture() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        let entity = try XCTUnwrap(runtime.entityRegistry).register(
            index: 7,
            className: "fixture_entity"
        )
        runtime.state.setGlobal("TEST_NETWORK_ENTITY", value: entity)

        let values = try runtime.executeReturningValues(
            try fixtureSource(),
            sourceName: "@GLuaNetworkedGlobalsRegression.lua"
        )

        guard case .boolean(true) = values.first else {
            return XCTFail("networked globals fixture did not return true")
        }
        XCTAssertTrue(try XCTUnwrap(runtime.networkedGlobals).usesStandaloneTransport)
    }

    func testSharedTransportReplicatesServerValuesUsingRealmLocalUserdata() throws {
        let transport = GMLuaNetworkedGlobalTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            networkedGlobalTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            networkedGlobalTransport: transport
        )
        let clientWithoutEntity = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            networkedGlobalTransport: transport
        )

        _ = try XCTUnwrap(server.entityRegistry).register(
            index: 21,
            kind: .player,
            className: "player"
        )
        _ = try XCTUnwrap(client.entityRegistry).register(
            index: 21,
            kind: .player,
            className: "player"
        )

        try server.execute(
            """
            SetGlobalBool("connected_bool", true)
            SetGlobalInt("connected_int", -12)
            SetGlobalInt("connected_fractional_int", 4.75)
            SetGlobalFloat("connected_float", 3.5)
            SetGlobalString("connected_string", "server")
            SetGlobalEntity("connected_entity", Entity(21))
            SetGlobalVector("connected_vector", Vector(1.5, -2.25, 3.75))
            SetGlobalAngle("connected_angle", Angle(-4.5, 5.25, 6.75))
            """,
            sourceName: "=(networked globals server writes)"
        )

        try client.execute(
            """
            assert(GetGlobalBool("connected_bool") == true)
            assert(GetGlobalInt("connected_int") == -12)
            assert(GetGlobalInt("connected_fractional_int") == 4.75)
            assert(GetGlobalFloat("connected_float") == 3.5)
            assert(GetGlobalString("connected_string") == "server")
            assert(GetGlobalEntity("connected_entity", NULL) == Entity(21))
            local v = GetGlobalVector("connected_vector", Vector())
            assert(v.x == 1.5 and v.y == -2.25 and v.z == 3.75)
            local a = GetGlobalAngle("connected_angle", Angle())
            assert(a.p == -4.5 and a.y == 5.25 and a.r == 6.75)
            """,
            sourceName: "=(networked globals client reads)"
        )

        try clientWithoutEntity.execute(
            "assert(GetGlobalEntity('connected_entity', NULL) == NULL)",
            sourceName: "=(unresolved network entity is canonical NULL)"
        )
        XCTAssertFalse(try XCTUnwrap(server.networkedGlobals).usesStandaloneTransport)
        XCTAssertFalse(try XCTUnwrap(client.networkedGlobals).usesStandaloneTransport)
    }

    func testClientSetterIsLocalUntilHostResendsServerSnapshot() throws {
        let transport = GMLuaNetworkedGlobalTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            networkedGlobalTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            networkedGlobalTransport: transport
        )
        let observer = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            networkedGlobalTransport: transport
        )

        try server.execute("SetGlobalBool('authority', true)")
        try client.execute(
            """
            SetGlobalBool("authority", false)
            SetGlobalString("client_only", "private")
            assert(GetGlobalBool("authority") == false)
            assert(GetGlobalString("client_only") == "private")
            """
        )
        try observer.execute(
            """
            assert(GetGlobalBool("authority") == true)
            assert(GetGlobalString("client_only", "absent") == "absent")
            """
        )
        XCTAssertEqual(transport.resendServerSnapshot(), 1)
        try client.execute("assert(GetGlobalBool('authority') == true)")
        try client.execute("assert(GetGlobalString('client_only') == 'private')")
        XCTAssertEqual(GMLuaNetworkedGlobalTransport().resendServerSnapshot(), 0)
    }

    func testStandaloneRuntimesDoNotInventAConnection() throws {
        let first = GMLuaRuntime(realm: .server, logger: { _ in })
        let second = GMLuaRuntime(realm: .server, logger: { _ in })

        try first.execute("SetGlobalInt('isolated', 99)")
        try second.execute("assert(GetGlobalInt('isolated', -1) == -1)")
        XCTAssertNotIdentical(
            try XCTUnwrap(first.networkedGlobals).transport,
            try XCTUnwrap(second.networkedGlobals).transport
        )
    }

    func testNetworkStringPoolIsSharedWithGlobalKeysAndConnectedClients() throws {
        let transport = GMLuaNetworkedGlobalTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            networkedGlobalTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            networkedGlobalTransport: transport
        )

        try server.execute(
            """
            SetGlobalInt("pooled_global", 1)
            SetGlobalString("pooled_global", "same name, separate type")
            local global_id = __gmod_NetworkStringToID("pooled_global")
            assert(global_id > 0)
            local message_id = __gmod_AddNetworkString("pooled_message")
            assert(message_id > global_id)
            """
        )
        try client.execute(
            """
            local global_id = __gmod_NetworkStringToID("pooled_global")
            local message_id = __gmod_NetworkStringToID("pooled_message")
            assert(global_id > 0 and message_id > global_id)
            assert(__gmod_NetworkIDToString(global_id) == "pooled_global")
            assert(__gmod_NetworkIDToString(message_id) == "pooled_message")
            """
        )
        XCTAssertEqual(transport.pooledStringCount, 2)
        XCTAssertEqual(transport.storedValueCount, 1)
    }

    func testGlobalAndMessageNamesPreserveArbitraryLuaStringBytes() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })

        try runtime.execute(
            """
            local global_a = string.char(128)
            local global_b = string.char(129)
            assert(global_a ~= global_b)
            SetGlobalString(global_a, "first")
            SetGlobalString(global_b, "second")
            assert(GetGlobalString(global_a) == "first")
            assert(GetGlobalString(global_b) == "second")

            local message_a = string.char(192)
            local message_b = string.char(193)
            local id_a = util.AddNetworkString(message_a)
            local id_b = util.AddNetworkString(message_b)
            assert(id_a ~= id_b)
            assert(util.NetworkStringToID(message_a) == id_a)
            assert(util.NetworkStringToID(message_b) == id_b)
            assert(util.NetworkIDToString(id_a) == message_a)
            assert(util.NetworkIDToString(id_b) == message_b)
            assert(util.NetworkIDToString(id_a + 0.99) == message_a)

            net.Start(message_a)
            net.Broadcast()
            net.Start(message_b)
            net.Broadcast()
            """,
            sourceName: "=(binary NetworkString identity regression)"
        )

        let transport = try XCTUnwrap(runtime.networkedGlobals).transport
        XCTAssertEqual(transport.pooledStringCount, 4)
        XCTAssertEqual(transport.storedValueCount, 2)
        XCTAssertEqual(runtime.networkStrings.count, 4)
        XCTAssertEqual(try XCTUnwrap(runtime.netTransport).completedMessageCount, 2)
    }

    func testTypedArgumentsAndRequiredCompoundDefaultsAreEnforced() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })

        XCTAssertThrowsError(try runtime.execute("SetGlobalBool('bad', 1)"))
        XCTAssertThrowsError(try runtime.execute("SetGlobalInt('bad', {})"))
        XCTAssertThrowsError(try runtime.execute("SetGlobalEntity('bad', {})"))
        XCTAssertThrowsError(try runtime.execute("SetGlobalVector('bad', Angle())"))
        XCTAssertThrowsError(try runtime.execute("SetGlobalAngle('bad', Vector())"))
        try runtime.execute("assert(GetGlobalEntity('missing') == NULL)")
        XCTAssertThrowsError(try runtime.execute("GetGlobalVector('missing')"))
        XCTAssertThrowsError(try runtime.execute("GetGlobalAngle('missing')"))
        XCTAssertThrowsError(try runtime.execute("SetGlobalVar('bad', {})"))
        XCTAssertThrowsError(try runtime.execute("SetGlobalVar('bad', nil)"))
    }

    func testGlobalKeysAndMessagesEnforceOneShared4095NameLimit() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        try runtime.execute(
            """
            for i = 1, 4095 do
                SetGlobalBool("slot_" .. i, true)
            end
            """,
            sourceName: "=(fill NetworkString slots)"
        )

        XCTAssertEqual(
            try XCTUnwrap(runtime.networkedGlobals).transport.pooledStringCount,
            GMLuaNetworkedGlobalTransport.maximumSlots
        )
        XCTAssertThrowsError(
            try runtime.execute("__gmod_AddNetworkString('one_too_many')")
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("NetworkString limit"))
        }
    }

    func testMenuDoesNotReceiveClientServerNetworkingAPIs() throws {
        let runtime = GMLuaRuntime(realm: .menu, logger: { _ in })
        XCTAssertNil(runtime.networkedGlobals)
        XCTAssertNil(runtime.netTransport)
        XCTAssertNil(runtime.netEndpoint)
        try runtime.execute(
            """
            assert(net == nil)
            assert(SetGlobalVar == nil and GetGlobalVar == nil)
            assert(util.AddNetworkString == nil)
            assert(util.NetworkStringToID == nil and util.NetworkIDToString == nil)
            """,
            sourceName: "@GMLuaMenuNetworkRealmRegression.lua"
        )
    }

    private func fixtureSource() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaNetworkedGlobalsRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaNetworkedGlobalsRegression",
                withExtension: "lua"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

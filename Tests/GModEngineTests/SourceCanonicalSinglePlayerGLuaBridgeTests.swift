import XCTest
@testable import GModEngine
import GModLua

final class SourceCanonicalSinglePlayerGLuaBridgeTests: XCTestCase {
    func testUniqueIDAndDeletionFlagComeFromExplicitSinglePlayerCanonicalState()
        throws
    {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 21
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()
        try SourceCanonicalSinglePlayerGLuaBridge.install(into: runtime)

        _ = try adapter.createCanonicalEntity(
            kind: .player,
            at: 7,
            playerUserID: 41
        )
        let prop = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 12
        )

        try runtime.execute(
            """
            local ply = Player(41)
            assert(ply:UniqueID() == 1)
            assert(type(ply:UniqueID()) == "number")
            assert(Entity(12):IsMarkedForDeletion() == false)

            local ok, message = pcall(function()
                return Entity(12).UniqueID(Entity(12))
            end)
            assert(ok == false)
            assert(string.find(message, "attempt to call field 'UniqueID'", 1, true))
            """,
            sourceName: "=(canonical single-player identity ABI)"
        )

        _ = try adapter.markCanonicalEntityForRemoval(prop.identity)
        try runtime.execute(
            "assert(Entity(12):IsMarkedForDeletion() == true)",
            sourceName: "=(canonical pending deletion ABI)"
        )
    }

    func testGenericRuntimeDoesNotReceiveSinglePlayerValuesImplicitly() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 31
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()
        _ = try adapter.createCanonicalEntity(
            kind: .player,
            at: 5,
            playerUserID: 55
        )

        try runtime.execute(
            """
            local ply = Player(55)
            assert(ply.UniqueID == nil)
            assert(ply.IsMarkedForDeletion == nil)
            """,
            sourceName: "=(generic runtime has no single-player ABI)"
        )
    }
}

import XCTest
@testable import GModEngine
import GModLua

final class SourceCanonicalPlayerAmmoIntegrationTests: XCTestCase {
    func testDefaultAmmoABIMutatesOneCanonicalPlayerThroughFIFO() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 7,
            playerUserID: 41
        )
        let initial = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(initial.playerAmmoState, .empty)

        try runtime.execute(
            """
            local ply = Player(41)
            assert(ply:GetAmmoCount("Pistol") == 0)
            assert(ply:GetAmmoCount(3) == 0)
            assert(ply:GetAmmoCount("3") == 0)

            ply:RemoveAllAmmo()
            assert(ply:GiveAmmo(0, "Pistol", true) == 0)
            assert(ply:GiveAmmo(-1, "Pistol", true) == 0)
            assert(ply:GiveAmmo(256, "pIsToL", true) == 256)
            assert(ply:GetAmmoCount("Pistol") == 256)
            assert(ply:GetAmmoCount(3) == 256)
            assert(ply:GiveAmmo(10000, 3, true) == 9743)
            assert(ply:GetAmmoCount("Pistol") == 9999)
            assert(ply:GiveAmmo(1, "Pistol", true) == 0)
            assert(ply:GiveAmmo(1, "not_registered", true) == 0)

            assert(pcall(function()
                ply:GiveAmmo(math.huge, "Pistol", true)
            end) == false)
            local playerMeta = FindMetaTable("Player")
            assert(pcall(function()
                playerMeta.GiveAmmo(Entity(0), 1, "Pistol", true)
            end) == false)

            ply:RemoveAllAmmo()
            assert(ply:GetAmmoCount("Pistol") == 0)
            """,
            sourceName: "=(canonical Player reserve ammo ABI)"
        )

        let emptied = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(emptied.identity, player.identity)
        XCTAssertEqual(emptied.playerAmmoState, .empty)
        XCTAssertEqual(emptied.revision, initial.revision + 3)
        XCTAssertThrowsError(
            try adapter.updateCanonicalEntity(player.identity) { candidate in
                candidate.playerAmmoState = SourceCanonicalPlayerAmmoState(
                    entries: [.init(
                        typeID: 3,
                        typeName: "Pistol",
                        count: -1
                    )]
                )
            }
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: player.identity),
            emptied,
            "invalid ammo state must not publish a revision or FIFO operation"
        )
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            4,
            "create, two successful GiveAmmo updates, and RemoveAllAmmo " +
                "must retain FIFO order"
        )
    }
}

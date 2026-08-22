import XCTest
@testable import GModEngine
@testable import GModGameSession

final class SourceCanonicalWeaponInventoryGLuaBridgeTests: XCTestCase {
    func testOriginalGmGiveSWEPSelectsAndReplicatesCanonicalToolgun() throws {
        let session = try GModPlayableSession(
            configuration: .init(
                map: .construct,
                languagePhrases: [
                    "Hint_Annoy1": "Canonical hint one",
                    "Hint_Annoy2": "Canonical hint two",
                ]
            ),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil
        )
        defer { _ = try? session.close() }

        // notification.lua queries this before a Player owns any Weapon.
        // Preserve Source's NULL Entity result instead of raising or returning
        // a realm-local placeholder.
        try session.clientRuntime.execute(
            "assert(not IsValid(LocalPlayer():GetActiveWeapon()))",
            sourceName: "=(CLIENT empty canonical active Weapon)"
        )

        try session.clientRuntime.execute(
            "RunConsoleCommand('gm_giveswep', 'gmod_tool')",
            sourceName: "=(original gm_giveswep gmod_tool request)"
        )
        let tick = try session.runFixedTick()
        XCTAssertEqual(tick.actionFailures, [])

        let serverPlayer = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        let record = try XCTUnwrap(
            serverPlayer.weaponInventory.weapon(className: "gmod_tool")
        )
        XCTAssertEqual(serverPlayer.weaponInventory.activeWeapon, record.identity)

        let serverWeapon = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == record.identity
            }
        )
        XCTAssertEqual(serverWeapon.kind, .weapon)
        XCTAssertEqual(serverWeapon.className, "gmod_tool")
        XCTAssertEqual(serverWeapon.creator, serverPlayer.identity)
        XCTAssertEqual(serverWeapon.weaponHoldType, "normal")
        XCTAssertEqual(serverWeapon.lifecycle, .active)
        XCTAssertEqual(serverPlayer.playerDisplayName, "Player")

        let clientPlayer = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == serverPlayer.identity
            }
        )
        let clientWeapon = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == serverWeapon.identity
            }
        )
        XCTAssertEqual(clientPlayer.weaponInventory, serverPlayer.weaponInventory)
        XCTAssertEqual(clientWeapon, serverWeapon)
        XCTAssertEqual(clientPlayer.playerDisplayName, "Player")

        try session.serverRuntime.execute(
            """
            local ply = LocalPlayer()
            assert(ply:HasWeapon("gmod_tool"))
            assert(ply:GetWeapon("gmod_tool"):GetClass() == "gmod_tool")
            assert(ply:GetWeapon("gmod_tool"):IsWeapon())
            assert(ply:GetWeapon("gmod_tool"):GetHoldType() == "normal")
            assert(ply:GetActiveWeapon() == ply:GetWeapon("gmod_tool"))
            assert(#ply:GetWeapons() == 1)
            assert(ply:Nick() == "Player")
            assert(ply:Name() == ply:Nick() and ply:GetName() == ply:Nick())
            """,
            sourceName: "=(SERVER canonical gmod_tool inventory)"
        )
        try session.clientRuntime.execute(
            """
            local ply = LocalPlayer()
            assert(ply:HasWeapon("gmod_tool"))
            assert(ply:GetWeapon("gmod_tool"):GetClass() == "gmod_tool")
            assert(ply:GetWeapon("gmod_tool"):IsWeapon())
            assert(ply:GetWeapon("gmod_tool"):GetHoldType() == "normal")
            assert(ply:GetActiveWeapon() == ply:GetWeapon("gmod_tool"))
            assert(#ply:GetWeapons() == 1)
            assert(ply:Nick() == "Player")
            """,
            sourceName: "=(CLIENT replicated canonical gmod_tool inventory)"
        )

        // The native hold type belongs to the canonical Weapon snapshot. A
        // SERVER mutation therefore reaches CLIENT only through the ordinary
        // entity FIFO, alongside the full EHANDLE identity.
        try session.serverRuntime.execute(
            "LocalPlayer():GetActiveWeapon():SetHoldType('revolver')",
            sourceName: "=(SERVER canonical gmod_tool hold type)"
        )
        let holdTypeTick = try session.runFixedTick()
        XCTAssertEqual(holdTypeTick.actionFailures, [])
        XCTAssertEqual(holdTypeTick.server.timerFailures, [])
        XCTAssertEqual(holdTypeTick.client.timerFailures, [])
        try session.clientRuntime.execute(
            "assert(LocalPlayer():GetActiveWeapon():GetHoldType() == 'revolver')",
            sourceName: "=(CLIENT replicated gmod_tool hold type)"
        )

        // Advance the real stock HintSystem_Annoy1/Annoy2 one-shot timers
        // beyond their 5s/7s deadlines. Their callbacks enter the shipped
        // notification.lua path which calls both Panel:GetDockPadding and
        // LocalPlayer():GetActiveWeapon() while a real canonical toolgun is
        // selected.
        var timerFailures: [GMLuaSourceTimerFailure] = []
        for _ in 0..<468 {
            let report = try session.sourceAdapter.runClientFixedTick()
            timerFailures.append(contentsOf: report.timerFailures)
        }
        XCTAssertEqual(timerFailures, [])
        XCTAssertFalse(timerFailures.contains(where: {
            $0.identifier.hasPrefix("HintSystem_")
        }))
        try session.clientRuntime.execute(
            """
            assert(not timer.Exists("HintSystem_Annoy1"))
            assert(not timer.Exists("HintSystem_Annoy2"))
            """,
            sourceName: "=(stock HintSystem timers completed)"
        )

        // NotificationThink is the stock animation/layout hook. Exercise it,
        // then require both a live original
        // NoticePanel and captured text draw commands from the Surface path.
        for _ in 0..<1 {
            let frameReport = try session.runClientFrame()
            XCTAssertEqual(frameReport.hookFailures, [])
            XCTAssertEqual(frameReport.timerFailures, [])
        }
        try session.clientRuntime.execute(
            """
            local noticeIndex = 0
            for _, panel in ipairs(vgui.GetAll()) do
                if panel:GetClassName() == "NoticePanel" then
                    panel:SetPos(16, 16 + noticeIndex * 64)
                    noticeIndex = noticeIndex + 1
                end
            end
            assert(noticeIndex >= 2)
            """,
            sourceName: "=(position stock notifications for Surface capture)"
        )
        let registry = try XCTUnwrap(session.clientRuntime.vguiRegistry)
        XCTAssertTrue(registry.renderTree(
            viewportWidth: 1_024,
            viewportHeight: 768
        ).contains(where: { $0.requestedClassName == "NoticePanel" }))
        let notificationFrame = try session.renderClientVGUIFrame()
        let notificationTexts = notificationFrame.commands.compactMap {
            command -> String? in
            guard case let .text(value, _, _, _, _) = command else {
                return nil
            }
            return value.utf8String
        }
        XCTAssertTrue(notificationTexts.contains("Canonical hint one"))
        XCTAssertTrue(notificationTexts.contains("Canonical hint two"))
    }
}

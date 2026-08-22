@testable import GModEngine
@testable import GModGameSession
import XCTest

final class GModPlayableWeaponUseIntegrationTests: XCTestCase {
    func testClientUseCommandSelectsServerWeaponAndReplicatesInOrderedDrain()
        throws
    {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_camera")
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_camera")
            """,
            sourceName: "=(weapon use integration inventory)"
        )
        let baseline = try session.runFixedTick()
        XCTAssertEqual(baseline.actionFailures, [])

        let baselineClientPlayer = try clientPlayer(in: session)
        XCTAssertEqual(
            baselineClientPlayer.weaponInventory.activeWeapon,
            baselineClientPlayer.weaponInventory.weapon(
                className: "gmod_camera"
            )?.identity
        )

        try session.clientRuntime.execute(
            #"RunConsoleCommand("use", "gmod_tool")"#,
            sourceName: "=(CLIENT Source use command)"
        )
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 1)

        // Forwarded commands are delivered after this SERVER simulation tick.
        // The handler appends the Player update to the same global FIFO, and
        // the bounded drain applies that complete snapshot before CLIENT Tick.
        let commandDelivery = try session.runFixedTick()
        XCTAssertEqual(commandDelivery.actionFailures, [])
        let serverPlayerAfterCommand = try serverPlayer(in: session)
        XCTAssertEqual(
            serverPlayerAfterCommand.weaponInventory.activeWeapon,
            serverPlayerAfterCommand.weaponInventory.weapon(
                className: "gmod_tool"
            )?.identity
        )
        XCTAssertEqual(
            try clientPlayer(in: session).weaponInventory.activeWeapon,
            serverPlayerAfterCommand.weaponInventory.activeWeapon
        )
    }

    private func serverPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.kind == .player
        })
    }

    private func clientPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.clientCanonicalEntitySnapshots.first {
            $0.kind == .player
        })
    }
}

@testable import GModEngine
@testable import GModGameSession
import XCTest

final class GModPlayableNoClipIntegrationTests: XCTestCase {
    func testClientToggleUsesSandboxHookAndReplicatesOrDeniesInOrder()
        async throws
    {
        let lane = GModPlayableSessionLane()
        let configuration = GModPlayableSessionConfiguration(map: .construct)
        let started = try await lane.start(configuration: configuration)
        do {
            let initialPlayer = try await player(
                in: lane,
                generation: started.generation
            )
            XCTAssertEqual(initialPlayer.moveType, .walk)

            try await lane.execute(
                """
                NOCLIP_ORIGINAL_CALLS = {}
                local original = GAMEMODE.PlayerNoClip
                function GAMEMODE:PlayerNoClip(ply, requestedOn)
                    table.insert(NOCLIP_ORIGINAL_CALLS, {
                        player = ply,
                        requestedOn = requestedOn
                    })
                    return original(self, ply, requestedOn)
                end
                """,
                realm: .server,
                sourceName: "=(observe original Sandbox PlayerNoClip)",
                expectedGeneration: started.generation
            )

            try await lane.requestToggleNoClip(
                expectedGeneration: started.generation
            )
            let enabledFrame = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            XCTAssertEqual(enabledFrame.actionFailures, [])
            let enabledPlayer = try await player(
                in: lane,
                generation: started.generation
            )
            XCTAssertEqual(enabledPlayer.identity, initialPlayer.identity)
            XCTAssertEqual(enabledPlayer.moveType, .noClip)
            try await lane.execute(
                """
                local call = assert(NOCLIP_ORIGINAL_CALLS[1])
                assert(call.player == Player(\(configuration.playerUserID)))
                assert(call.requestedOn == true)
                assert(Player(\(configuration.playerUserID)):GetMoveType() == MOVETYPE_NOCLIP)
                """,
                realm: .server,
                sourceName: "=(verify original noclip enable)",
                expectedGeneration: started.generation
            )

            try await lane.requestToggleNoClip(
                expectedGeneration: started.generation
            )
            let disabledFrame = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            XCTAssertEqual(disabledFrame.actionFailures, [])
            let disabledPlayer = try await player(
                in: lane,
                generation: started.generation
            )
            XCTAssertEqual(disabledPlayer.identity, initialPlayer.identity)
            XCTAssertEqual(disabledPlayer.moveType, .walk)
            try await lane.execute(
                """
                local call = assert(NOCLIP_ORIGINAL_CALLS[2])
                assert(call.player == Player(\(configuration.playerUserID)))
                assert(call.requestedOn == false)
                assert(Player(\(configuration.playerUserID)):GetMoveType() == MOVETYPE_WALK)
                """,
                realm: .server,
                sourceName: "=(verify original noclip disable)",
                expectedGeneration: started.generation
            )

            try await lane.execute(
                """
                hook.Add("PlayerNoClip", "GarrysPADNoClipDenial", function(ply, requestedOn)
                    NOCLIP_DENIED_PLAYER = ply
                    NOCLIP_DENIED_ON = requestedOn
                    return false
                end)
                """,
                realm: .server,
                sourceName: "=(deny noclip through original hook chain)",
                expectedGeneration: started.generation
            )
            try await lane.requestToggleNoClip(
                expectedGeneration: started.generation
            )
            let deniedFrame = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            XCTAssertEqual(deniedFrame.actionFailures, [])
            let deniedPlayer = try await player(
                in: lane,
                generation: started.generation
            )
            XCTAssertEqual(deniedPlayer.identity, initialPlayer.identity)
            XCTAssertEqual(deniedPlayer.moveType, .walk)
            try await lane.execute(
                """
                assert(NOCLIP_DENIED_PLAYER == Player(\(configuration.playerUserID)))
                assert(NOCLIP_DENIED_ON == true)
                assert(#NOCLIP_ORIGINAL_CALLS == 2)
                hook.Remove("PlayerNoClip", "GarrysPADNoClipDenial")
                """,
                realm: .server,
                sourceName: "=(verify handled noclip denial)",
                expectedGeneration: started.generation
            )

            do {
                try await lane.requestToggleNoClip(
                    expectedGeneration: started.generation &+ 1
                )
                XCTFail("stale generation queued a noclip command")
            } catch {
                XCTAssertEqual(
                    error as? GModPlayableSessionLaneError,
                    .staleGeneration(
                        expected: started.generation &+ 1,
                        actual: started.generation
                    )
                )
            }

            try await lane.execute(
                """
                hook.Add("PlayerNoClip", "GarrysPADNoClipError", function()
                    error("typed noclip hook failure")
                end)
                """,
                realm: .server,
                sourceName: "=(throwing noclip hook)",
                expectedGeneration: started.generation
            )
            try await lane.requestToggleNoClip(
                expectedGeneration: started.generation
            )
            do {
                _ = try await lane.runHostFrame(
                    fixedTickCount: 1,
                    renderClientFrame: false,
                    expectedGeneration: started.generation
                )
                XCTFail("throwing PlayerNoClip hook was silently accepted")
            } catch let error as SourceCanonicalNoClipConsoleHostError {
                guard case let .hookExecutionFailed(reason) = error else {
                    throw error
                }
                XCTAssertTrue(reason.contains("typed noclip hook failure"))
            }
            let preservedPlayer = try await player(
                in: lane,
                generation: started.generation
            )
            XCTAssertEqual(preservedPlayer.identity, initialPlayer.identity)
            XCTAssertEqual(preservedPlayer.moveType, .walk)

            _ = try await lane.close(expectedGeneration: started.generation)
        } catch {
            _ = try? await lane.close()
            throw error
        }
    }

    private func player(
        in lane: GModPlayableSessionLane,
        generation: UInt64
    ) async throws -> SourceCanonicalEntitySnapshot {
        let snapshots = try await laneSnapshots(
            lane,
            generation: generation
        )
        return try player(in: snapshots)
    }

    private func laneSnapshots(
        _ lane: GModPlayableSessionLane,
        generation: UInt64
    ) async throws -> [SourceCanonicalEntitySnapshot] {
        try await lane.clientCanonicalEntitySnapshots(
            expectedGeneration: generation
        )
    }

    private func player(
        in snapshots: [SourceCanonicalEntitySnapshot]
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(snapshots.first { $0.kind == .player })
    }
}

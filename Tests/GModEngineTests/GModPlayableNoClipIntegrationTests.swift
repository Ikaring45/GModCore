@testable import GModEngine
@testable import GModGameSession
import XCTest

private final class ToggleableEmbeddedWorldWalkProvider:
    SourceWorldWalkCollisionProvider,
    @unchecked Sendable
{
    var isEmbedded = false

    func traceWorldWalk(
        _ ray: SourceRay,
        mask _: SourceContents
    ) throws -> SourceGameTrace {
        var result = SourceGameTrace(ray: ray)
        guard isEmbedded else { return result }
        result.startSolid = true
        result.allSolid = true
        result.fraction = 0
        result.endPosition = ray.actualStart
        result.entityHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 0)
        return result
    }

    func worldWalkPointContents(
        at _: SourceVector3,
        mask: SourceContents
    ) throws -> SourceContents {
        isEmbedded && mask.contains(.solid) ? .solid : .empty
    }
}

final class GModPlayableNoClipIntegrationTests: XCTestCase {
    func testEmbeddedWalkKeepsFIFOAliveForNoClipRecovery() throws {
        let collision = ToggleableEmbeddedWorldWalkProvider()
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: collision
        )
        defer { _ = try? session.close() }

        collision.isEmbedded = true
        let embeddedState = session.playerWalkState
        let blocked = try session.runFixedTick()
        XCTAssertEqual(blocked.movement.rejection?.reason, .feature(.stuckRecovery))
        XCTAssertEqual(session.playerWalkState, embeddedState)
        XCTAssertEqual(session.sourceAdapter.serverGlobals.tickCount, 1)
        XCTAssertEqual(blocked.client.kind, .clientFixedTick)
        XCTAssertFalse(session.isClosed)

        try session.requestToggleNoClip()
        XCTAssertGreaterThan(session.sharedSession.netTransport.pendingDeliveryCount, 0)
        let enabled = try session.runFixedTick()
        XCTAssertEqual(enabled.movement.rejection?.reason, .feature(.stuckRecovery))
        XCTAssertEqual(enabled.actionFailures, [])
        XCTAssertEqual(session.playerWalkState.origin, embeddedState.origin)
        XCTAssertEqual(session.playerWalkState.moveType, .noClip)
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
        try session.clientRuntime.execute(
            "assert(LocalPlayer():GetMoveType() == MOVETYPE_NOCLIP)",
            sourceName: "=(embedded noclip replicated through FIFO)"
        )

        let escaped = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: .zero,
                forwardMove: 100,
                buttons: [.forward]
            )
        )
        XCTAssertNil(escaped.movement.rejection)
        XCTAssertGreaterThan(session.playerWalkState.origin.x, embeddedState.origin.x)

        // Switching back to WALK while still in solid must leave the next
        // noclip request deliverable instead of permanently stopping the app.
        try session.requestToggleNoClip()
        _ = try session.runFixedTick()
        XCTAssertEqual(session.playerWalkState.moveType, .walk)
        let disabledState = session.playerWalkState
        try session.serverRuntime.execute(
            "hook.Add('PlayerNoClip', 'DenyEmbeddedRecovery', function() return false end)",
            sourceName: "=(deny embedded noclip recovery)"
        )
        try session.requestToggleNoClip()
        let denied = try session.runFixedTick()
        XCTAssertEqual(denied.movement.rejection?.reason, .feature(.stuckRecovery))
        XCTAssertEqual(denied.actionFailures, [])
        XCTAssertEqual(session.playerWalkState, disabledState)
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)

        try session.serverRuntime.execute(
            "hook.Remove('PlayerNoClip', 'DenyEmbeddedRecovery')",
            sourceName: "=(allow embedded noclip recovery)"
        )
        try session.requestToggleNoClip()
        _ = try session.runFixedTick()
        XCTAssertEqual(session.playerWalkState.moveType, .noClip)
        XCTAssertFalse(session.isClosed)
    }

    func testEnabledNoClipLeavesAnEmbeddedWorldWithoutStoppingTheSession()
        throws
    {
        let collision = ToggleableEmbeddedWorldWalkProvider()
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: collision
        )
        defer { _ = try? session.close() }

        try session.requestToggleNoClip()
        let enabled = try session.runFixedTick()
        XCTAssertEqual(enabled.actionFailures, [])
        XCTAssertEqual(session.playerWalkState.moveType, .noClip)

        collision.isEmbedded = true
        let embeddedOrigin = session.playerWalkState.origin
        let escaped = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: .zero,
                forwardMove: 100,
                buttons: [.forward]
            )
        )
        guard case let .advanced(tick) = escaped.movement else {
            return XCTFail("enabled noclip movement was rejected while embedded")
        }
        XCTAssertEqual(tick.state.moveType, .noClip)
        XCTAssertGreaterThan(tick.state.origin.x, embeddedOrigin.x)
        XCTAssertFalse(tick.state.isOnGround)
        XCTAssertEqual(tick.bumpCount, 0)
        XCTAssertEqual(tick.collisionCount, 0)
    }

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

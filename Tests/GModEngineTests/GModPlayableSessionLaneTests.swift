import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModPlayableSessionLaneTests: XCTestCase {
    func testSpawnActionFailureIsAValueInHostFrameAndLaneRemainsUsable() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        try await lane.execute(
            "RunConsoleCommand('gm_spawn', 'models/props_c17/oildrum001.mdl', '0', '')",
            realm: .client,
            sourceName: "=(lane SpawnIcon gm_spawn request)",
            expectedGeneration: snapshot.generation
        )

        let failedActionFrame = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(failedActionFrame.fixedTicks.count, 1)
        XCTAssertEqual(failedActionFrame.actionFailures.count, 1)
        XCTAssertEqual(failedActionFrame.actionFailures.first?.command, "gm_spawn")
        XCTAssertTrue(
            failedActionFrame.actionFailures.first?.message.contains("Alive")
                == true
        )

        let laterFrame = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(laterFrame.fixedTicks.count, 1)
        XCTAssertEqual(laterFrame.actionFailures, [])
        _ = try await lane.close()
    }

    func testThrowingSpawnMenuCloseRetiresPointerEpochWithoutDuplicateRelease() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        let opened = try await lane.setSpawnMenuOpen(
            true,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )

        try await lane.execute(
            """
            THROW_CLOSE_RELEASE_COUNT = 0
            THROW_CLOSE_PANEL = vgui.Create("Panel")
            THROW_CLOSE_PANEL:SetPos(0, 0)
            THROW_CLOSE_PANEL:SetSize(ScrW(), ScrH())
            THROW_CLOSE_PANEL:SetMouseInputEnabled(true)
            THROW_CLOSE_PANEL:SetZPos(32767)
            THROW_CLOSE_PANEL:SetDrawOnTop(true)
            THROW_CLOSE_PANEL:MakePopup()
            function THROW_CLOSE_PANEL:OnMousePressed() end
            function THROW_CLOSE_PANEL:OnMouseReleased()
                THROW_CLOSE_RELEASE_COUNT = THROW_CLOSE_RELEASE_COUNT + 1
            end
            hook.Add("OnSpawnMenuClose", "ThrowingLaneCloseHook", function()
                error("intentional close hook failure")
            end)
            """,
            realm: .client,
            sourceName: "=(throwing close boundary fixture)",
            expectedGeneration: snapshot.generation
        )
        _ = try await lane.dispatchClientVGUIPointerEvent(
            x: 10,
            y: 10,
            phase: .began,
            timestamp: 1,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: opened.pointerEpoch
        )

        let failedClose = try await lane.setSpawnMenuOpen(
            false,
            cancelActivePointer: true,
            cancellationTimestamp: 2,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: opened.pointerEpoch,
            expectedInputEpoch: opened.inputEpoch
        )
        XCTAssertTrue(failedClose.cancelledActivePointer)
        XCTAssertNil(failedClose.cancellationFailure)
        XCTAssertTrue(
            failedClose.lifecycleFailure?.contains(
                "intentional close hook failure"
            ) == true
        )
        XCTAssertGreaterThan(failedClose.pointerEpoch, opened.pointerEpoch)
        XCTAssertGreaterThan(failedClose.inputEpoch, opened.inputEpoch)
        try await lane.execute(
            "assert(THROW_CLOSE_RELEASE_COUNT == 1)",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        do {
            _ = try await lane.dispatchClientVGUIPointerEvent(
                x: 10,
                y: 10,
                phase: .ended,
                timestamp: 3,
                expectedGeneration: snapshot.generation,
                expectedPointerEpoch: opened.pointerEpoch
            )
            XCTFail("a pointer event crossed a failed close boundary")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .stalePointerEpoch(
                    expected: opened.pointerEpoch,
                    actual: failedClose.pointerEpoch
                )
            )
        }

        try await lane.execute(
            "hook.Remove('OnSpawnMenuClose', 'ThrowingLaneCloseHook')",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        let retriedClose = try await lane.setSpawnMenuOpen(
            false,
            cancelActivePointer: true,
            cancellationTimestamp: 4,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: failedClose.pointerEpoch,
            expectedInputEpoch: failedClose.inputEpoch
        )
        XCTAssertFalse(retriedClose.cancelledActivePointer)
        XCTAssertNil(retriedClose.cancellationFailure)
        XCTAssertNil(retriedClose.lifecycleFailure)
        XCTAssertGreaterThan(retriedClose.inputEpoch, failedClose.inputEpoch)
        try await lane.execute(
            "assert(THROW_CLOSE_RELEASE_COUNT == 1)",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        _ = try await lane.close()
    }

    func testPoppedHostFrameCannotCrossSuspensionInputEpoch() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )

        // Model a frame batch already popped from the host mailbox. It retains
        // the input epoch and movement word that were active at admission.
        let poppedInputEpoch = snapshot.inputEpoch
        _ = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            movementInput: GModPlayableMovementInput(buttons: [.forward]),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: poppedInputEpoch
        )
        try await lane.execute(
            "STALE_FRAME_SERVER_TIME = CurTime(); assert(Player(1):KeyDown(IN_FORWARD))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "STALE_FRAME_CLIENT_TIME = CurTime(); assert(LocalPlayer():KeyDown(IN_FORWARD))",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let suspended = try await lane.suspendInput(
            cancellationTimestamp: 1,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: poppedInputEpoch
        )
        XCTAssertGreaterThan(suspended.inputEpoch, poppedInputEpoch)

        do {
            _ = try await lane.runHostFrame(
                fixedTickCount: 8,
                renderClientFrame: false,
                movementInput: GModPlayableMovementInput(
                    forwardMove: 250,
                    buttons: [.forward]
                ),
                expectedGeneration: snapshot.generation,
                expectedInputEpoch: poppedInputEpoch
            )
            XCTFail("a popped frame crossed the suspension input boundary")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .staleInputEpoch(
                    expected: poppedInputEpoch,
                    actual: suspended.inputEpoch
                )
            )
        }

        // Rejection occurs before button publication, fixed ticks, CLIENT
        // Think, viewport mutation, or movement simulation.
        try await lane.execute(
            "assert(CurTime() == STALE_FRAME_SERVER_TIME and not Player(1):KeyDown(IN_FORWARD))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(CurTime() == STALE_FRAME_CLIENT_TIME and not LocalPlayer():KeyDown(IN_FORWARD))",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        let accepted = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: suspended.inputEpoch
        )
        XCTAssertEqual(accepted.fixedTicks, [])
        XCTAssertEqual(accepted.playerWalkState, snapshot.playerWalkState)

        _ = try await lane.close()
    }

    func testActorOwnsStartupFrameExecutionConsoleAndClose() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        XCTAssertEqual(snapshot.startup.map, .construct)
        XCTAssertEqual(snapshot.startup.spawnPoint.angles.yaw, 180)
        XCTAssertEqual(snapshot.worldMesh.triangleCount, 25_732)
        XCTAssertEqual(
            snapshot.playerWalkState.origin,
            snapshot.startup.spawnPoint.origin
        )

        let frame = try await lane.runHostFrame(
            fixedTickCount: 2,
            viewport: GMLuaViewportSize(width: 2_048, height: 1_536),
            movementInput: GModPlayableMovementInput(
                viewAngles: snapshot.startup.spawnPoint.angles,
                forwardMove: 200,
                buttons: [.forward]
            ),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(frame.fixedTicks.count, 2)
        XCTAssertNotNil(frame.clientFrame)
        XCTAssertTrue(frame.viewportChanged)
        XCTAssertTrue(
            frame.fixedTicks.allSatisfy {
                $0.server.hookFailures.isEmpty &&
                    $0.client.hookFailures.isEmpty
            }
        )
        XCTAssertTrue(frame.clientFrame?.hookFailures.isEmpty == true)
        XCTAssertTrue(frame.playerWalkState.isOnGround)
        XCTAssertLessThan(
            frame.playerWalkState.origin.x,
            snapshot.playerWalkState.origin.x
        )

        try await lane.execute(
            "assert(SERVER and game.GetMap() == 'gm_construct')",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(CLIENT and ScrW() == 2048 and ScrH() == 1536)",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(Player(1):KeyDown(IN_FORWARD))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(LocalPlayer():KeyDown(IN_FORWARD))",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let gestureOnlyFrame = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            movementInput: GModPlayableMovementInput(
                forwardMove: 200,
                sideMove: -200,
                buttons: []
            ),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(gestureOnlyFrame.fixedTicks, [])
        try await lane.execute(
            "assert(not Player(1):KeyDown(IN_FORWARD) and not Player(1):KeyDown(IN_MOVELEFT))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(not LocalPlayer():KeyDown(IN_FORWARD) and not LocalPlayer():KeyDown(IN_MOVELEFT))",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let opened = try await lane.setSpawnMenuOpen(
            true,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertGreaterThan(opened.pointerEpoch, snapshot.pointerEpoch)
        XCTAssertGreaterThan(opened.inputEpoch, snapshot.inputEpoch)
        XCTAssertFalse(opened.cancelledActivePointer)

        try await lane.execute(
            """
            POINTER_RELEASE_COUNT = 0
            POINTER_PANEL = vgui.Create("Panel")
            POINTER_PANEL:SetPos(0, 0)
            POINTER_PANEL:SetSize(ScrW(), ScrH())
            POINTER_PANEL:SetMouseInputEnabled(true)
            POINTER_PANEL:SetZPos(32767)
            POINTER_PANEL:SetDrawOnTop(true)
            POINTER_PANEL:MakePopup()
            function POINTER_PANEL:OnMousePressed() end
            function POINTER_PANEL:OnMouseReleased()
                POINTER_RELEASE_COUNT = POINTER_RELEASE_COUNT + 1
            end
            """,
            realm: .client,
            sourceName: "=(lane pointer epoch fixture)",
            expectedGeneration: snapshot.generation
        )
        _ = try await lane.dispatchClientVGUIPointerEvent(
            x: 10,
            y: 10,
            phase: .began,
            timestamp: 1,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: opened.pointerEpoch
        )
        _ = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            movementInput: GModPlayableMovementInput(buttons: [.forward]),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: opened.inputEpoch
        )

        let suspended = try await lane.suspendInput(
            cancellationTimestamp: 2,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: opened.pointerEpoch,
            expectedInputEpoch: opened.inputEpoch
        )
        XCTAssertTrue(suspended.cancelledActivePointer)
        XCTAssertNil(suspended.cancellationFailure)
        try await lane.execute(
            "assert(not Player(1):KeyDown(IN_FORWARD))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            """
            assert(POINTER_RELEASE_COUNT == 1)
            assert(not LocalPlayer():KeyDown(IN_FORWARD))
            """,
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        // Models a sample already popped by the host mailbox but entering the
        // actor after suspension. The epoch is validated inside the actor, so
        // it cannot recreate capture after the exactly-once cancellation.
        do {
            _ = try await lane.dispatchClientVGUIPointerEvent(
                x: 20,
                y: 20,
                phase: .ended,
                timestamp: 3,
                expectedGeneration: snapshot.generation,
                expectedPointerEpoch: opened.pointerEpoch
            )
            XCTFail("a pointer sample from the retired epoch unexpectedly ran")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .stalePointerEpoch(
                    expected: opened.pointerEpoch,
                    actual: suspended.pointerEpoch
                )
            )
        }

        let suspendedAgain = try await lane.suspendInput(
            cancellationTimestamp: 4,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: suspended.pointerEpoch,
            expectedInputEpoch: suspended.inputEpoch
        )
        XCTAssertFalse(suspendedAgain.cancelledActivePointer)
        try await lane.execute(
            "assert(POINTER_RELEASE_COUNT == 1)",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        let closed = try await lane.setSpawnMenuOpen(
            false,
            cancelActivePointer: true,
            cancellationTimestamp: 5,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: suspendedAgain.pointerEpoch,
            expectedInputEpoch: suspendedAgain.inputEpoch
        )
        XCTAssertGreaterThan(closed.inputEpoch, suspendedAgain.inputEpoch)

        let replacement = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .flatgrass)
        )
        XCTAssertNotEqual(replacement.generation, snapshot.generation)
        XCTAssertGreaterThan(replacement.inputEpoch, closed.inputEpoch)
        do {
            _ = try await lane.runHostFrame(
                fixedTickCount: 0,
                expectedGeneration: snapshot.generation,
                expectedInputEpoch: snapshot.inputEpoch
            )
            XCTFail("a stale frame generation unexpectedly reached the new session")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .staleGeneration(
                    expected: snapshot.generation,
                    actual: replacement.generation
                )
            )
        }
        do {
            try await lane.execute(
                "error('stale command reached replacement session')",
                expectedGeneration: snapshot.generation
            )
            XCTFail("a stale console generation unexpectedly reached the new session")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .staleGeneration(
                    expected: snapshot.generation,
                    actual: replacement.generation
                )
            )
        }

        _ = try await lane.close()
        _ = try await lane.close()
        do {
            _ = try await lane.runHostFrame(fixedTickCount: 0)
            XCTFail("closed lane unexpectedly ran a frame")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .notStarted
            )
        }
    }
}

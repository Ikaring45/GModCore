import XCTest
@testable import GModEngine
@testable import GModGameSession

private struct UnsupportedContentsLaneWalkProvider:
    SourceWorldWalkCollisionProvider
{
    let contents: SourceContents

    func traceWorldWalk(
        _ ray: SourceRay,
        mask _: SourceContents
    ) throws -> SourceGameTrace {
        SourceGameTrace(ray: ray)
    }

    func worldWalkPointContents(
        at _: SourceVector3,
        mask _: SourceContents
    ) throws -> SourceContents {
        contents
    }
}

private final class LaneShutdownCleanupRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var storage: [
        GModPlayableSessionLaneShutdownCleanupObservation
    ] = []

    func record(
        _ observation: GModPlayableSessionLaneShutdownCleanupObservation
    ) {
        condition.lock()
        storage.append(observation)
        condition.broadcast()
        condition.unlock()
    }

    func waitForObservation(
        timeout: TimeInterval = 10
    ) -> GModPlayableSessionLaneShutdownCleanupObservation? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while storage.isEmpty, condition.wait(until: deadline) {}
        let observation = storage.first
        condition.unlock()
        return observation
    }
}

final class GModPlayableSessionLaneTests: XCTestCase {
    func testDroppedLaneClosesFinalizersOnWorkerAfterThrowAndCancellation()
        async throws
    {
        let directRecorder = LaneShutdownCleanupRecorder()
        var directLane: GModPlayableSessionLane? = GModPlayableSessionLane(
            shutdownCleanupObserverForTesting: { observation in
                directRecorder.record(observation)
            }
        )
        let directIdentity = await directLane!
            .executionThreadIdentityForTesting()
        let directSnapshot = try await directLane!.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        try await installDropFinalizer(
            marker: "direct-drop-finalizer",
            lane: directLane!,
            generation: directSnapshot.generation
        )
        directLane = nil

        let directObservation = try XCTUnwrap(
            directRecorder.waitForObservation()
        )
        XCTAssertEqual(directObservation.workerIdentity, directIdentity)
        XCTAssertTrue(directObservation.sessionIsClosed)
        XCTAssertNil(directObservation.closeFailure)
        XCTAssertTrue(
            directObservation.closeReport?.clientFinalizerErrors.contains {
                $0.contains("direct-drop-finalizer")
            } == true
        )

        let cancelledRecorder = LaneShutdownCleanupRecorder()
        let cancelledTask = Task {
            () throws -> (identity: String, observedCancellation: Bool) in
            var lane: GModPlayableSessionLane? = GModPlayableSessionLane(
                shutdownCleanupObserverForTesting: { observation in
                    cancelledRecorder.record(observation)
                }
            )
            let identity = await lane!.executionThreadIdentityForTesting()
            let snapshot = try await lane!.start(
                configuration: GModPlayableSessionConfiguration(
                    map: .flatgrass
                )
            )
            try await self.installDropFinalizer(
                marker: "cancelled-drop-finalizer",
                lane: lane!,
                generation: snapshot.generation
            )

            do {
                try await lane!.execute(
                    "error('must not execute')",
                    realm: .menu,
                    expectedGeneration: snapshot.generation
                )
                XCTFail("unsupported realm unexpectedly executed")
            } catch {
                XCTAssertEqual(
                    error as? GModPlayableSessionLaneError,
                    .unsupportedExecutionRealm(.menu)
                )
            }

            do {
                try Task.checkCancellation()
                lane = nil
                return (identity, false)
            } catch is CancellationError {
                lane = nil
                return (identity, true)
            }
        }
        cancelledTask.cancel()
        let cancellation = try await cancelledTask.value
        XCTAssertTrue(cancellation.observedCancellation)

        let cancelledObservation = try XCTUnwrap(
            cancelledRecorder.waitForObservation()
        )
        XCTAssertEqual(
            cancelledObservation.workerIdentity,
            cancellation.identity
        )
        XCTAssertTrue(cancelledObservation.sessionIsClosed)
        XCTAssertNil(cancelledObservation.closeFailure)
        XCTAssertTrue(
            cancelledObservation.closeReport?.clientFinalizerErrors.contains {
                $0.contains("cancelled-drop-finalizer")
            } == true
        )
    }

    func testDedicatedThreadOwnsConstructCloseFlatgrassCloseLifecycle() async throws {
        let lane = GModPlayableSessionLane()
        let identity = await lane.executionThreadIdentityForTesting()

        let construct = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        let identityAfterConstruct =
            await lane.executionThreadIdentityForTesting()
        XCTAssertEqual(identityAfterConstruct, identity)
        XCTAssertEqual(construct.startup.map, .construct)
        _ = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            expectedGeneration: construct.generation,
            expectedInputEpoch: construct.inputEpoch
        )
        let identityAfterFrame =
            await lane.executionThreadIdentityForTesting()
        XCTAssertEqual(identityAfterFrame, identity)
        _ = try await lane.close()
        let identityAfterConstructClose =
            await lane.executionThreadIdentityForTesting()
        XCTAssertEqual(identityAfterConstructClose, identity)

        let flatgrass = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .flatgrass)
        )
        XCTAssertEqual(flatgrass.startup.map, .flatgrass)
        let identityAfterFlatgrass =
            await lane.executionThreadIdentityForTesting()
        XCTAssertEqual(identityAfterFlatgrass, identity)
        _ = try await lane.close()
        let identityAfterFlatgrassClose =
            await lane.executionThreadIdentityForTesting()
        XCTAssertEqual(identityAfterFlatgrassClose, identity)
    }

    func testUnsupportedMovementIsReportedWhileLaneAndRealmTimeContinue() async throws {
        let lane = GModPlayableSessionLane(
            worldWalkCollisionProvider:
                UnsupportedContentsLaneWalkProvider(contents: .ladder)
        )
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )

        let first = try await lane.runHostFrame(
            fixedTickCount: 2,
            renderClientFrame: true,
            movementInput: GModPlayableMovementInput(
                forwardMove: 200,
                buttons: [.forward]
            ),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(first.fixedTicks.count, 2)
        XCTAssertEqual(first.movementRejections.map(\.commandNumber), [1, 2])
        XCTAssertTrue(first.movementRejections.allSatisfy {
            $0.reason == .feature(.ladder) &&
                $0.preservedState == snapshot.playerWalkState
        })
        XCTAssertTrue(first.fixedTicks.allSatisfy {
            if case .rejected = $0.movement { return true }
            return false
        })
        XCTAssertEqual(first.playerWalkState, snapshot.playerWalkState)
        XCTAssertEqual(first.clientFrame?.kind, .clientFrame)
        try await lane.execute(
            "assert(math.abs(CurTime() - 0.03) < 0.000001)",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(math.abs(CurTime() - 0.03) < 0.000001)",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let later = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: true,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(later.movementRejections.map(\.commandNumber), [3])
        XCTAssertEqual(later.playerWalkState, snapshot.playerWalkState)
        XCTAssertEqual(later.clientFrame?.kind, .clientFrame)
        try await lane.execute(
            "assert(math.abs(CurTime() - 0.045) < 0.000001)",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(math.abs(CurTime() - 0.045) < 0.000001)",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        _ = try await lane.close()
    }

    func testUnavailableSpawnAssetLeavesCanonicalStateUnchangedAndLaneUsable() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        XCTAssertFalse(snapshot.canonicalEntities.contains {
            $0.kind == .propPhysics
        })
        try await lane.execute(
            "RunConsoleCommand('gm_spawn', 'models/props_c17/oildrum001.mdl', '0', '')",
            realm: .client,
            sourceName: "=(lane SpawnIcon gm_spawn request)",
            expectedGeneration: snapshot.generation
        )

        let actionFrame = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(actionFrame.fixedTicks.count, 1)
        XCTAssertEqual(actionFrame.actionFailures, [])
        let actionEntities = try await lane.clientCanonicalEntitySnapshots(
            expectedGeneration: snapshot.generation
        )
        XCTAssertFalse(actionEntities.contains { $0.kind == .propPhysics })
        XCTAssertTrue(try XCTUnwrap(actionEntities.first {
            $0.kind == .player
        }).motion.isAlive)

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

    func testContextMenuOpenAndCloseRetireInputEpochsDeterministically() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        let actions: SourceInputButtons = [.attack, .attack2, .use]
        let actionFrame = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            movementInput: GModPlayableMovementInput(buttons: actions),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(actionFrame.inputButtons.buttons, actions)

        let opened = try await lane.setContextMenuOpen(
            true,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertNil(opened.lifecycleFailure)
        XCTAssertGreaterThan(opened.pointerEpoch, snapshot.pointerEpoch)
        XCTAssertGreaterThan(opened.inputEpoch, snapshot.inputEpoch)
        try await lane.execute(
            "assert(g_ContextMenu:IsVisible() and " +
                "not LocalPlayer():KeyDown(IN_ATTACK) and " +
                "not LocalPlayer():KeyDown(IN_ATTACK2) and " +
                "not LocalPlayer():KeyDown(IN_USE))",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(not Player(1):KeyDown(IN_ATTACK) and " +
                "not Player(1):KeyDown(IN_ATTACK2) and " +
                "not Player(1):KeyDown(IN_USE))",
            expectedGeneration: snapshot.generation
        )

        let closed = try await lane.setContextMenuOpen(
            false,
            cancelActivePointer: true,
            cancellationTimestamp: 2,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: opened.pointerEpoch,
            expectedInputEpoch: opened.inputEpoch
        )
        XCTAssertNil(closed.lifecycleFailure)
        XCTAssertGreaterThan(closed.pointerEpoch, opened.pointerEpoch)
        XCTAssertGreaterThan(closed.inputEpoch, opened.inputEpoch)
        try await lane.execute(
            "assert(not g_ContextMenu:IsVisible())",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        _ = try await lane.close()
    }

    func testAtomicSpawnToContextTransitionClosesPriorBeforeOpeningTarget() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        let actions: SourceInputButtons = [.attack, .attack2, .use]
        _ = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            movementInput: GModPlayableMovementInput(buttons: actions),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        let spawn = try await lane.transitionClientMenu(
            from: nil,
            to: .spawn,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(spawn.committedMenu, .spawn)
        XCTAssertNil(spawn.lifecycleFailure)
        try await lane.execute(
            "assert(not Player(1):KeyDown(IN_ATTACK) and " +
                "not Player(1):KeyDown(IN_ATTACK2) and " +
                "not Player(1):KeyDown(IN_USE))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(not LocalPlayer():KeyDown(IN_ATTACK) and " +
                "not LocalPlayer():KeyDown(IN_ATTACK2) and " +
                "not LocalPlayer():KeyDown(IN_USE))",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let context = try await lane.transitionClientMenu(
            from: .spawn,
            to: .context,
            cancelActivePointer: true,
            cancellationTimestamp: 1,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: spawn.pointerEpoch,
            expectedInputEpoch: spawn.inputEpoch
        )
        XCTAssertEqual(context.committedMenu, .context)
        XCTAssertNil(context.lifecycleFailure)
        XCTAssertNil(context.rollbackFailure)
        XCTAssertGreaterThan(context.pointerEpoch, spawn.pointerEpoch)
        XCTAssertGreaterThan(context.inputEpoch, spawn.inputEpoch)
        try await lane.execute(
            "assert(not g_SpawnMenu:IsVisible() and g_ContextMenu:IsVisible())",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        _ = try await lane.close()
    }

    func testSpawnMenuTransitionImmediatelyExposesSurfaceInSameGeneration() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )

        let opened = try await lane.transitionClientMenu(
            from: nil,
            to: .spawn,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(opened.committedMenu, .spawn)
        XCTAssertNil(opened.lifecycleFailure)
        try await lane.execute(
            "assert(type(g_SpawnMenu) == 'Panel' and " +
                "IsValid(g_SpawnMenu) and g_SpawnMenu:IsVisible())",
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let surface = try await lane.renderClientVGUIFrame(
            expectedGeneration: snapshot.generation
        )
        XCTAssertGreaterThan(surface.drawCallCount, 0)
        XCTAssertFalse(surface.commands.isEmpty)
        _ = try await lane.close()
    }

    func testAtomicMenuTransitionRestoresPriorWhenTargetHookThrows() async throws {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        let spawn = try await lane.transitionClientMenu(
            from: nil,
            to: .spawn,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )
        try await lane.execute(
            """
            hook.Add("OnContextMenuOpen", "AtomicTargetFailure", function()
                error("intentional context open failure")
            end)
            """,
            realm: .client,
            expectedGeneration: snapshot.generation
        )

        let failed = try await lane.transitionClientMenu(
            from: .spawn,
            to: .context,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: spawn.pointerEpoch,
            expectedInputEpoch: spawn.inputEpoch
        )
        XCTAssertEqual(failed.committedMenu, .spawn)
        XCTAssertTrue(
            failed.lifecycleFailure?.contains(
                "intentional context open failure"
            ) == true
        )
        XCTAssertNil(failed.rollbackFailure)
        try await lane.execute(
            "assert(g_SpawnMenu:IsVisible() and not g_ContextMenu:IsVisible())",
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
            movementInput: GModPlayableMovementInput(
                buttons: [.forward, .attack, .attack2, .use]
            ),
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: poppedInputEpoch
        )
        try await lane.execute(
            "STALE_FRAME_SERVER_TIME = CurTime(); " +
                "assert(Player(1):KeyDown(IN_FORWARD) and " +
                "Player(1):KeyDown(IN_ATTACK) and " +
                "Player(1):KeyDown(IN_ATTACK2) and " +
                "Player(1):KeyDown(IN_USE))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "STALE_FRAME_CLIENT_TIME = CurTime(); " +
                "assert(LocalPlayer():KeyDown(IN_FORWARD) and " +
                "LocalPlayer():KeyDown(IN_ATTACK) and " +
                "LocalPlayer():KeyDown(IN_ATTACK2) and " +
                "LocalPlayer():KeyDown(IN_USE))",
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
                    buttons: [.forward, .attack, .attack2, .use]
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
            "assert(CurTime() == STALE_FRAME_SERVER_TIME and " +
                "not Player(1):KeyDown(IN_FORWARD) and " +
                "not Player(1):KeyDown(IN_ATTACK) and " +
                "not Player(1):KeyDown(IN_ATTACK2) and " +
                "not Player(1):KeyDown(IN_USE))",
            expectedGeneration: snapshot.generation
        )
        try await lane.execute(
            "assert(CurTime() == STALE_FRAME_CLIENT_TIME and " +
                "not LocalPlayer():KeyDown(IN_FORWARD) and " +
                "not LocalPlayer():KeyDown(IN_ATTACK) and " +
                "not LocalPlayer():KeyDown(IN_ATTACK2) and " +
                "not LocalPlayer():KeyDown(IN_USE))",
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
        // This is the complete construct world mesh, including expanded
        // displacement geometry (not the old coarse-face-only count).
        XCTAssertEqual(snapshot.worldMesh.triangleCount, 41_344)
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

        do {
            _ = try await lane.close(
                expectedGeneration: snapshot.generation
            )
            XCTFail("a stale disconnect closed the replacement session")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .staleGeneration(
                    expected: snapshot.generation,
                    actual: replacement.generation
                )
            )
        }
        try await lane.execute(
            "assert(true)",
            expectedGeneration: replacement.generation
        )

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

    func testClientSurfaceSoundsDrainOnceInOrderAndPauseRetiresStaleEvents()
        async throws
    {
        let lane = GModPlayableSessionLane()
        let snapshot = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )

        _ = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        try await lane.execute(
            """
            surface.PlaySound("ui/buttonclickrelease.wav")
            surface.PlaySound("ui/buttonclickrelease.wav")
            surface.PlaySound("buttons/button15.wav")
            """,
            realm: .client,
            sourceName: "@GModPlayableSurfaceSoundDrain.lua",
            expectedGeneration: snapshot.generation
        )

        let report = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertEqual(
            report.clientSurfaceSounds.requests.map(\.soundPath),
            [
                "ui/buttonclickrelease.wav",
                "ui/buttonclickrelease.wav",
                "buttons/button15.wav",
            ]
        )
        let sequences = report.clientSurfaceSounds.requests
            .map(\.sequenceNumber)
        XCTAssertEqual(sequences.count, 3)
        XCTAssertEqual(sequences[1], sequences[0] + 1)
        XCTAssertEqual(sequences[2], sequences[1] + 1)

        let drainedAgain = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: snapshot.inputEpoch
        )
        XCTAssertTrue(drainedAgain.clientSurfaceSounds.requests.isEmpty)

        try await lane.execute(
            "surface.PlaySound('ui/stale-on-pause.wav')",
            realm: .client,
            expectedGeneration: snapshot.generation
        )
        let suspended = try await lane.suspendInput(
            cancellationTimestamp: 1,
            expectedGeneration: snapshot.generation,
            expectedPointerEpoch: snapshot.pointerEpoch,
            expectedInputEpoch: snapshot.inputEpoch
        )
        let afterPause = try await lane.runHostFrame(
            fixedTickCount: 0,
            renderClientFrame: false,
            expectedGeneration: snapshot.generation,
            expectedInputEpoch: suspended.inputEpoch
        )
        XCTAssertTrue(afterPause.clientSurfaceSounds.requests.isEmpty)
        _ = try await lane.close()
    }

    private func installDropFinalizer(
        marker: String,
        lane: GModPlayableSessionLane,
        generation: UInt64
    ) async throws {
        try await lane.execute(
            """
            local dropped = newproxy(true)
            getmetatable(dropped).__gc = function()
                error('\(marker)')
            end
            DROPPED_LANE_FINALIZER = dropped
            """,
            realm: .client,
            sourceName: "=(dropped lane finalizer)",
            expectedGeneration: generation
        )
    }
}

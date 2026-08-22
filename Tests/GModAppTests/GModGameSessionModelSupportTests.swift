import XCTest
@testable import GModApp
import GModEngine

final class GModGameSessionModelSupportTests: XCTestCase {
    func testPauseAndResumePreserveTheExactLiveSessionSnapshot() {
        let snapshot = GModGameSessionContinuitySnapshot(
            map: .construct,
            playerOrigin: SourceVector3(128, -64, 32),
            viewAngles: SourceQAngle(pitch: 12, yaw: 235, roll: 0),
            fixedTickCount: 4_096
        )
        var state = GModGamePresentationState()

        XCTAssertEqual(
            state.reduce(.pauseRequested(snapshot)),
            [.suspendForPauseMenu]
        )
        XCTAssertTrue(state.showsHomeMenu)
        XCTAssertEqual(state.pausedSession, snapshot)

        XCTAssertEqual(
            state.reduce(.homeMenuAction(.hideGameUI)),
            [.resumeExistingSession]
        )
        XCTAssertFalse(state.showsHomeMenu)
        XCTAssertEqual(state.pausedSession, snapshot)
    }

    func testDisconnectClearsContinuityAndReturnsToSafeHomeState() {
        let snapshot = GModGameSessionContinuitySnapshot(
            map: .flatgrass,
            playerOrigin: SourceVector3(1, 2, 3),
            viewAngles: SourceQAngle(pitch: 4, yaw: 5, roll: 0),
            fixedTickCount: 99
        )
        var state = GModGamePresentationState()
        _ = state.reduce(.pauseRequested(snapshot))

        XCTAssertEqual(
            state.reduce(.homeMenuAction(.disconnect)),
            [.disconnectSession]
        )
        XCTAssertTrue(state.showsHomeMenu)
        XCTAssertNil(state.pausedSession)

        // Disconnect is intentionally idempotent from an already-safe Home.
        XCTAssertEqual(
            state.reduce(.homeMenuAction(.disconnect)),
            [.disconnectSession]
        )
        XCTAssertTrue(state.showsHomeMenu)
        XCTAssertNil(state.pausedSession)
    }

    func testHomeMenuActionReducerUsesOnlyValidatedMapSelections() {
        var state = GModGamePresentationState()

        XCTAssertEqual(
            state.reduce(.homeMenuAction(.startMap("gm_construct"))),
            [.awaitValidatedMapSelection("gm_construct")]
        )
        XCTAssertTrue(state.showsHomeMenu)
        XCTAssertEqual(
            state.reduce(.homeMenuAction(.setLanguage("ja"))),
            []
        )
        XCTAssertEqual(
            state.reduce(.homeMenuAction(.openOptions)),
            []
        )
        XCTAssertEqual(
            state.reduce(.homeMenuAction(.openProblems)),
            []
        )
        XCTAssertEqual(
            state.reduce(.homeMenuAction(.quit)),
            [.presentQuitUnavailable]
        )

        XCTAssertEqual(
            state.reduce(.validatedMapSelected(.construct)),
            [.startMap(.construct)]
        )
        XCTAssertFalse(state.showsHomeMenu)
    }

    func testValidatedNewMapSelectionReplacesPausedContinuity() {
        let prior = GModGameSessionContinuitySnapshot(
            map: .construct,
            playerOrigin: SourceVector3(10, 20, 30),
            viewAngles: SourceQAngle(pitch: 1, yaw: 2, roll: 0),
            fixedTickCount: 300
        )
        var state = GModGamePresentationState()
        _ = state.reduce(.pauseRequested(prior))

        XCTAssertEqual(
            state.reduce(.validatedMapSelected(.flatgrass)),
            [.startMap(.flatgrass)]
        )
        XCTAssertFalse(state.showsHomeMenu)
        XCTAssertNil(state.pausedSession)
    }

    func testCPUStartFailureRequiresExplicitReturnAndPreservesProblemEvidence() {
        let failure = GModGameStartFailure(
            map: .construct,
            origin: .cpu,
            detail: "BSP allocation rejected: requested 200 / cap 100"
        )
        var state = GModGamePresentationState()
        _ = state.reduce(.validatedMapSelected(.construct))

        XCTAssertEqual(state.reduce(.startFailed(failure)), [])
        XCTAssertFalse(state.showsHomeMenu)
        XCTAssertEqual(state.startFailure, failure)
        XCTAssertEqual(
            state.reduce(.returnHomeAfterStartFailure),
            [.abandonFailedStart]
        )
        XCTAssertTrue(state.showsHomeMenu)
        XCTAssertEqual(state.startFailure, failure)

        let problems = GModAppProblemSnapshotBuilder.build(
            retained: [],
            gameLogs: [],
            consoleLogs: [],
            worldScene: nil,
            surfaceDiagnostics: nil,
            contentError: nil,
            startFailure: failure
        )
        XCTAssertTrue(problems.problems.contains {
            $0.id.hasPrefix("session-start-failure|") &&
                $0.detail == failure.detail &&
                $0.severity == .error
        })
    }

    func testRendererStartFailureUsesTheSameNoTimeoutRecoveryEvent() {
        let failure = GModGameStartFailure(
            map: .flatgrass,
            origin: .renderer(meshIdentifier: "session-9:gm_flatgrass"),
            detail: "texture allocation failed: concrete"
        )
        var state = GModGamePresentationState()
        _ = state.reduce(.validatedMapSelected(.flatgrass))

        XCTAssertEqual(state.reduce(.startFailed(failure)), [])
        XCTAssertFalse(state.showsHomeMenu)
        XCTAssertEqual(state.startFailure, failure)
        XCTAssertEqual(
            state.reduce(.returnHomeAfterStartFailure),
            [.abandonFailedStart]
        )
        XCTAssertTrue(state.showsHomeMenu)
        XCTAssertEqual(state.startFailure, failure)
    }

    func testOrdinaryPlayHidesDeveloperChrome() {
        let ordinary = GModMainViewChromePolicy()
        XCTAssertFalse(ordinary.showsDeveloperChrome)
        XCTAssertFalse(ordinary.showsRendererHeader)
        XCTAssertFalse(ordinary.showsDebugMapControls)
        XCTAssertFalse(ordinary.showsRuntimeStatistics)
        XCTAssertFalse(ordinary.showsConsole)
        XCTAssertFalse(ordinary.showsPlayfieldDebugBorder)
        XCTAssertTrue(ordinary.hidesWorldUntilFirstFrame)

        let developer = GModMainViewChromePolicy(
            developerDiagnosticsEnabled: true
        )
        XCTAssertTrue(developer.showsDeveloperChrome)
        XCTAssertTrue(developer.showsRendererHeader)
        XCTAssertTrue(developer.showsDebugMapControls)
        XCTAssertTrue(developer.showsRuntimeStatistics)
        XCTAssertTrue(developer.showsConsole)
        XCTAssertTrue(developer.showsPlayfieldDebugBorder)
        XCTAssertTrue(developer.hidesWorldUntilFirstFrame)
    }

    func testInGameOverlayUsesUnobtrusiveLandscapeIPadMetrics() {
        let layout = GModInGameOverlayLayout(
            width: 1_366,
            height: 1_024,
            safeTop: 24,
            safeBottom: 20
        )

        XCTAssertFalse(layout.isPortrait)
        XCTAssertEqual(layout.leadingInset, 20.48, accuracy: 0.001)
        XCTAssertEqual(layout.trailingInset, 20.48, accuracy: 0.001)
        XCTAssertEqual(layout.topInset, 44.48, accuracy: 0.001)
        XCTAssertEqual(layout.bottomInset, 40.48, accuracy: 0.001)
        XCTAssertEqual(layout.joystickDiameter, 107.52, accuracy: 0.001)
        XCTAssertEqual(layout.joystickKnobDiameter, 33.3312, accuracy: 0.001)
        XCTAssertEqual(layout.lookPadWidth, 204.9, accuracy: 0.001)
        XCTAssertEqual(layout.lookPadHeight, 110.646, accuracy: 0.001)
        XCTAssertEqual(layout.jumpDiameter, 65.536, accuracy: 0.001)
        XCTAssertEqual(layout.heldActionDiameter, 51.2, accuracy: 0.001)
        XCTAssertEqual(layout.utilityButtonSize, 48.128, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(layout.utilityButtonSize, 44)
    }

    func testInGameOverlayAdaptsToPortraitAndSafeAreas() {
        let layout = GModInGameOverlayLayout(
            width: 810,
            height: 1_080,
            safeTop: 24,
            safeLeading: 7,
            safeBottom: 20,
            safeTrailing: 9
        )

        XCTAssertTrue(layout.isPortrait)
        XCTAssertEqual(layout.leadingInset, 23.2, accuracy: 0.001)
        XCTAssertEqual(layout.trailingInset, 25.2, accuracy: 0.001)
        XCTAssertEqual(layout.topInset, 40.2, accuracy: 0.001)
        XCTAssertEqual(layout.bottomInset, 36.2, accuracy: 0.001)
        XCTAssertEqual(layout.joystickDiameter, 101.25, accuracy: 0.001)
        XCTAssertEqual(layout.joystickKnobDiameter, 32, accuracy: 0.001)
        XCTAssertEqual(layout.lookPadWidth, 194.4, accuracy: 0.001)
        XCTAssertEqual(layout.lookPadHeight, 104.976, accuracy: 0.001)
        XCTAssertEqual(layout.jumpDiameter, 60, accuracy: 0.001)
        XCTAssertEqual(layout.heldActionDiameter, 44, accuracy: 0.001)
        XCTAssertEqual(layout.utilityButtonSize, 46, accuracy: 0.001)

        // Every explicit action remains above Apple's minimum touch target,
        // while the large drag surfaces remain well below a quarter-screen
        // obstruction in either iPad orientation.
        XCTAssertGreaterThanOrEqual(layout.utilityButtonSize, 44)
        XCTAssertGreaterThanOrEqual(layout.jumpDiameter, 44)
        XCTAssertGreaterThanOrEqual(layout.heldActionDiameter, 44)
        XCTAssertLessThan(layout.lookPadWidth, 810 * 0.30)
        XCTAssertLessThan(layout.joystickDiameter, 810 * 0.15)
    }

    func testFirstWorldFrameGateRejectsStaleAndDuplicateCompletions() {
        var gate = GModGameFirstWorldFrameGate()
        gate.arm(meshIdentifier: "session-7:gm_construct")
        XCTAssertTrue(gate.matches(meshIdentifier: "session-7:gm_construct"))
        XCTAssertFalse(gate.matches(meshIdentifier: "session-6:gm_construct"))

        XCTAssertFalse(gate.acknowledge(
            meshIdentifier: "session-6:gm_construct"
        ))
        XCTAssertEqual(
            gate.expectedMeshIdentifier,
            "session-7:gm_construct"
        )
        XCTAssertTrue(gate.acknowledge(
            meshIdentifier: "session-7:gm_construct"
        ))
        XCTAssertNil(gate.expectedMeshIdentifier)
        XCTAssertFalse(gate.matches(meshIdentifier: "session-7:gm_construct"))
        XCTAssertFalse(gate.acknowledge(
            meshIdentifier: "session-7:gm_construct"
        ))

        gate.arm(meshIdentifier: "session-8:gm_construct")
        gate.reset()
        XCTAssertFalse(gate.acknowledge(
            meshIdentifier: "session-8:gm_construct"
        ))
    }

    func testWorldInputOwnershipSanitizesDelayedSamplesDuringMenusAndTransitions() {
        let positive = (
            viewAngles: SourceQAngle(pitch: 10, yaw: 20, roll: 0),
            forward: Float(1),
            side: Float(-0.5),
            jump: true
        )
        let rejectedStates: [(
            suspended: Bool,
            active: GModGameClientMenu?,
            transitioning: GModGameClientMenu?
        )] = [
            (false, .spawn, nil),
            (false, nil, .context),
            (true, nil, nil),
        ]
        for state in rejectedStates {
            let accepts = GModGameWorldInputPolicy.accepts(
                isReady: true,
                isInputSuspended: state.suspended,
                activeMenu: state.active,
                transitioningMenu: state.transitioning
            )
            XCTAssertFalse(accepts)
            XCTAssertEqual(
                GModGameWorldInputPolicy.movementInput(
                    acceptsWorldInput: accepts,
                    viewAngles: positive.viewAngles,
                    forwardAxis: positive.forward,
                    sideAxis: positive.side,
                    jumpPressed: positive.jump,
                    heldActionButtons: [.attack, .attack2, .use]
                ),
                .idle
            )
        }

        let accepts = GModGameWorldInputPolicy.accepts(
            isReady: true,
            isInputSuspended: false,
            activeMenu: nil,
            transitioningMenu: nil
        )
        let admitted = GModGameWorldInputPolicy.movementInput(
            acceptsWorldInput: accepts,
            viewAngles: positive.viewAngles,
            forwardAxis: positive.forward,
            sideAxis: positive.side,
            jumpPressed: positive.jump,
            heldActionButtons: [.attack, .attack2, .use, .reload]
        )
        XCTAssertTrue(accepts)
        XCTAssertEqual(admitted.forwardMove, 250)
        XCTAssertEqual(admitted.sideMove, -125)
        XCTAssertTrue(admitted.buttons.contains(.forward))
        XCTAssertTrue(admitted.buttons.contains(.moveLeft))
        XCTAssertTrue(admitted.buttons.contains(.jump))
        XCTAssertTrue(admitted.buttons.contains(.attack))
        XCTAssertTrue(admitted.buttons.contains(.attack2))
        XCTAssertTrue(admitted.buttons.contains(.use))
        XCTAssertTrue(admitted.buttons.contains(.reload))

        let popupAccepts = GModGameWorldInputPolicy.accepts(
            isReady: true,
            isInputSuspended: false,
            activeMenu: nil,
            transitioningMenu: nil,
            isHostPopupPresented: true
        )
        XCTAssertFalse(popupAccepts)
        XCTAssertEqual(
            GModGameWorldInputPolicy.movementInput(
                acceptsWorldInput: popupAccepts,
                viewAngles: positive.viewAngles,
                forwardAxis: positive.forward,
                sideAxis: positive.side,
                jumpPressed: true,
                heldActionButtons: [.attack, .attack2, .use]
            ),
            .idle
        )
    }

    func testUnsupportedMovementDiagnosticNeverClaimsSuccess() {
        let water = GModGameMovementDiagnostic(
            commandNumber: 12,
            reason: .feature(.waterCurrent)
        )
        XCTAssertTrue(water.status.contains("Movement blocked"))
        XCTAssertTrue(water.status.contains("water"))
        XCTAssertTrue(water.status.contains("state preserved"))
        XCTAssertTrue(water.logMessage.contains("command 12 rejected"))
        XCTAssertFalse(water.status.localizedCaseInsensitiveContains("success"))

        let dynamic = GModGameMovementDiagnostic(
            commandNumber: 13,
            reason: .dynamicEntityCollision(entityIndex: 7)
        )
        XCTAssertTrue(dynamic.status.contains("index 7"))
        XCTAssertTrue(dynamic.logMessage.contains("rejected"))
    }

    func testPointerMappingUsesLogicalPointsAndViewportOnly() throws {
        let mapped = try XCTUnwrap(GModGamePointerCoordinateMapper.map(
            x: 405,
            y: 540,
            viewWidth: 810,
            viewHeight: 1_080,
            viewportWidth: 810,
            viewportHeight: 1_080
        ))

        XCTAssertEqual(mapped, GModGamePointerLocation(x: 405, y: 540))
        XCTAssertNil(GModGamePointerCoordinateMapper.map(
            x: 1,
            y: 1,
            viewWidth: 0,
            viewHeight: 1_080,
            viewportWidth: 810,
            viewportHeight: 1_080
        ))
    }

    func testSurfaceAndPointerPublicationRequiresBothGenerations() {
        let token = GModGameSessionGenerationToken(
            application: 7,
            lane: 11
        )

        XCTAssertTrue(token.matches(application: 7, lane: 11))
        XCTAssertFalse(token.matches(application: 8, lane: 11))
        XCTAssertFalse(token.matches(application: 7, lane: 12))
        XCTAssertFalse(token.matches(application: 7, lane: nil))
    }

    func testFrameTokenRequiresIndependentInputEpoch() {
        let token = GModGameFrameToken(
            generation: GModGameSessionGenerationToken(
                application: 7,
                lane: 11
            ),
            inputEpoch: 13
        )

        XCTAssertTrue(token.matches(
            application: 7,
            lane: 11,
            inputEpoch: 13
        ))
        XCTAssertFalse(token.matches(
            application: 7,
            lane: 11,
            inputEpoch: 14
        ))
        XCTAssertFalse(token.matches(
            application: 8,
            lane: 11,
            inputEpoch: 13
        ))
        XCTAssertFalse(token.matches(
            application: 7,
            lane: 12,
            inputEpoch: 13
        ))
    }

    func testSurfacePublicationRejectsStaleRevisionAndMenuState() {
        let token = GModSurfacePublicationToken(
            generation: GModGameSessionGenerationToken(
                application: 7,
                lane: 11
            ),
            requestRevision: 19,
            activeMenu: .spawn
        )

        XCTAssertTrue(token.matches(
            application: 7,
            lane: 11,
            requestRevision: 19,
            activeMenu: .spawn
        ))
        XCTAssertFalse(token.matches(
            application: 7,
            lane: 11,
            requestRevision: 20,
            activeMenu: .spawn
        ))
        XCTAssertFalse(token.matches(
            application: 7,
            lane: 11,
            requestRevision: 19,
            activeMenu: .context
        ))
        XCTAssertFalse(token.matches(
            application: 8,
            lane: 11,
            requestRevision: 19,
            activeMenu: .spawn
        ))
    }

    func testSurfaceCaptureRunsOnlyForStableForegroundClientMenu() {
        XCTAssertFalse(GModGameClientSurfaceCapturePolicy.shouldCapture(
            activeMenu: nil,
            transitioningMenu: nil
        ))
        XCTAssertTrue(GModGameClientSurfaceCapturePolicy.shouldCapture(
            activeMenu: .spawn,
            transitioningMenu: nil
        ))
        XCTAssertTrue(GModGameClientSurfaceCapturePolicy.shouldCapture(
            activeMenu: .context,
            transitioningMenu: nil
        ))
        XCTAssertFalse(GModGameClientSurfaceCapturePolicy.shouldCapture(
            activeMenu: .spawn,
            transitioningMenu: .context
        ))
    }

    func testSurfaceRefreshQueueKeepsOnlyNewestGenerationRequest() {
        var queue = GModGameSurfaceRefreshPendingQueue()
        let firstGeneration = GModGameSessionGenerationToken(
            application: 1,
            lane: 10
        )
        let latestGeneration = GModGameSessionGenerationToken(
            application: 2,
            lane: 20
        )
        let first = GModGameSurfaceRefreshRequest(
            generation: firstGeneration
        )
        let latest = GModGameSurfaceRefreshRequest(
            generation: latestGeneration
        )

        queue.submit(first)
        queue.submit(latest)
        queue.submit(GModGameSurfaceRefreshRequest(
            generation: latestGeneration
        ))
        XCTAssertEqual(queue.takeLatest(), latest)
        XCTAssertNil(queue.takeLatest())

        queue.submit(first)
        queue.removeAll()
        XCTAssertNil(queue.takeLatest())
    }

    func testPointerQueueIsBoundedCoalescesMovesAndRetainsCriticalOrder() {
        let token = GModGameSessionGenerationToken(
            application: 1,
            lane: 2
        )
        var queue = GModGamePointerPendingQueue(capacity: 3)

        XCTAssertEqual(
            queue.enqueue(sample(token: token, x: 0, phase: .began)),
            GModGamePointerQueueSubmission(
                acceptedSample: true,
                droppedSampleCount: 0,
                coalescedMoveCount: 0
            )
        )
        _ = queue.enqueue(sample(token: token, x: 1, phase: .moved))
        XCTAssertEqual(
            queue.enqueue(sample(token: token, x: 2, phase: .moved)),
            GModGamePointerQueueSubmission(
                acceptedSample: true,
                droppedSampleCount: 0,
                coalescedMoveCount: 1
            )
        )
        _ = queue.enqueue(sample(token: token, x: 3, phase: .ended))

        XCTAssertEqual(queue.samples.count, 3)
        XCTAssertEqual(queue.samples[1].x, 2)

        XCTAssertEqual(
            queue.enqueue(sample(token: token, x: 4, phase: .cancelled)),
            GModGamePointerQueueSubmission(
                acceptedSample: false,
                droppedSampleCount: 1,
                coalescedMoveCount: 0
            )
        )
        XCTAssertEqual(queue.samples.count, 3)
        XCTAssertEqual(queue.samples.map(phaseName), [
            "began", "moved", "ended"
        ])
    }

    func testNoMoveFullQueueEvictsWholeOldestGestureAndStaysBalanced() {
        let token = GModGameSessionGenerationToken(
            application: 1,
            lane: 2
        )
        var queue = GModGamePointerPendingQueue(capacity: 4)

        _ = queue.enqueue(sample(token: token, x: 1, phase: .began))
        _ = queue.enqueue(sample(token: token, x: 2, phase: .ended))
        _ = queue.enqueue(sample(token: token, x: 3, phase: .began))
        _ = queue.enqueue(sample(token: token, x: 4, phase: .ended))
        XCTAssertEqual(queue.samples.map(phaseName), [
            "began", "ended", "began", "ended"
        ])

        XCTAssertEqual(
            queue.enqueue(sample(token: token, x: 5, phase: .began)),
            GModGamePointerQueueSubmission(
                acceptedSample: true,
                droppedSampleCount: 2,
                coalescedMoveCount: 0
            )
        )
        _ = queue.enqueue(sample(token: token, x: 6, phase: .ended))

        var balance = 0
        var drained: [String] = []
        while let next = queue.popFirst() {
            drained.append(phaseName(next))
            switch next.phase {
            case .began:
                balance += 1
            case .ended, .cancelled:
                balance -= 1
                XCTAssertGreaterThanOrEqual(balance, 0)
            case .moved, .scroll:
                break
            }
        }
        XCTAssertEqual(drained, ["began", "ended", "began", "ended"])
        XCTAssertEqual(balance, 0)
    }

    private func sample(
        token: GModGameSessionGenerationToken,
        x: Double,
        phase: GMLuaPointerPhase
    ) -> GModGamePointerSample {
        GModGamePointerSample(
            generation: token,
            pointerEpoch: 3,
            x: x,
            y: 0,
            phase: phase,
            timestamp: x
        )
    }

    private func phaseName(_ sample: GModGamePointerSample) -> String {
        switch sample.phase {
        case .began: return "began"
        case .moved: return "moved"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .scroll: return "scroll"
        }
    }
}

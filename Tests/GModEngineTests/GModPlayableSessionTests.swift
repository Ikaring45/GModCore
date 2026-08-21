import XCTest
import GModEngine
import GModGameAssets
@testable import GModGameSession

private struct UnsupportedContentsPlayableWalkProvider:
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

final class GModPlayableSessionTests: XCTestCase {
    func testTouchActionWordIsReportedAndVisibleToBothRealmPlayers() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }

        let heldActions: SourceInputButtons = [.attack, .attack2, .use]
        let report = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: heldActions)
        )
        XCTAssertEqual(report.inputButtons.buttons, heldActions)
        XCTAssertTrue(report.inputButtons.serverMirrorUpdated)
        XCTAssertEqual(report.inputButtons.updatedClientMirrorCount, 1)
        try session.serverRuntime.execute(
            """
            assert(Player(1):KeyDown(IN_ATTACK))
            assert(Player(1):KeyDown(IN_ATTACK2))
            assert(Player(1):KeyDown(IN_USE))
            """,
            sourceName: "=(touch actions server mirror)"
        )
        try session.clientRuntime.execute(
            """
            assert(LocalPlayer():KeyDown(IN_ATTACK))
            assert(LocalPlayer():KeyDown(IN_ATTACK2))
            assert(LocalPlayer():KeyDown(IN_USE))
            """,
            sourceName: "=(touch actions client mirror)"
        )

        let cleared = try session.updateCurrentPlayerInputButtons([])
        XCTAssertEqual(cleared.buttons, [])
        XCTAssertTrue(cleared.serverMirrorUpdated)
        XCTAssertEqual(cleared.updatedClientMirrorCount, 1)
        try session.serverRuntime.execute(
            "assert(not Player(1):KeyDown(IN_ATTACK) and " +
                "not Player(1):KeyDown(IN_ATTACK2) and " +
                "not Player(1):KeyDown(IN_USE))",
            sourceName: "=(touch actions server clear)"
        )
        try session.clientRuntime.execute(
            "assert(not LocalPlayer():KeyDown(IN_ATTACK) and " +
                "not LocalPlayer():KeyDown(IN_ATTACK2) and " +
                "not LocalPlayer():KeyDown(IN_USE))",
            sourceName: "=(touch actions client clear)"
        )
    }

    func testWaterMovesAndLadderRejectsWhileBothRealmClocksAdvance() throws {
        let cases: [(SourceContents, SourceWorldWalkUnsupportedFeature)] = [
            (.water, .water),
            (.ladder, .ladder),
        ]

        for (contents, feature) in cases {
            let session = try GModPlayableSession(
                configuration: GModPlayableSessionConfiguration(
                    map: .construct
                ),
                textMeasurer: nil,
                logger: { _, _ in },
                worldWalkCollisionProvider:
                    UnsupportedContentsPlayableWalkProvider(
                        contents: contents
                    )
            )
            let stateBeforeTick = session.playerWalkState
            let serverTimeBefore = try XCTUnwrap(
                session.serverRuntime.timerScheduler
            ).currentTime
            let clientTimeBefore = try XCTUnwrap(
                session.clientRuntime.timerScheduler
            ).currentTime

            let report = try session.runFixedTick(
                movementInput: GModPlayableMovementInput(
                    forwardMove: 200,
                    buttons: [.forward]
                )
            )

            if feature == .water {
                guard case let .advanced(tick) = report.movement else {
                    _ = try? session.close()
                    return XCTFail("bounded water movement was rejected")
                }
                XCTAssertEqual(tick.commandNumber, 1)
                XCTAssertNotEqual(tick.state, stateBeforeTick)
                XCTAssertEqual(report.movement.state, tick.state)
                XCTAssertEqual(session.playerWalkState, tick.state)
            } else {
                guard case let .rejected(rejection) = report.movement else {
                    _ = try? session.close()
                    return XCTFail("\(feature) was reported as a successful move")
                }
                XCTAssertEqual(rejection.commandNumber, 1)
                XCTAssertEqual(rejection.reason, .feature(feature))
                XCTAssertEqual(rejection.preservedState, stateBeforeTick)
                XCTAssertEqual(report.movement.state, stateBeforeTick)
                XCTAssertEqual(session.playerWalkState, stateBeforeTick)
            }
            XCTAssertEqual(report.server.kind, .serverFixedTick)
            XCTAssertEqual(report.client.kind, .clientFixedTick)
            XCTAssertEqual(session.sourceAdapter.serverGlobals.tickCount, 1)
            let oneTick = Double(SourceGlobalVars.intervalPerTick)
            XCTAssertEqual(
                try XCTUnwrap(session.serverRuntime.timerScheduler).currentTime,
                serverTimeBefore + oneTick
            )
            XCTAssertEqual(
                try XCTUnwrap(session.clientRuntime.timerScheduler).currentTime,
                clientTimeBefore + oneTick
            )
            XCTAssertFalse(session.isClosed)
            _ = try session.close()
        }
    }

    func testNonFiniteMovementRemainsFatalAfterWaterMovement() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider:
                UnsupportedContentsPlayableWalkProvider(contents: .water)
        )
        defer { _ = try? session.close() }

        let advanced = try session.runFixedTick()
        XCTAssertNil(advanced.movement.rejection)
        let preservedState = advanced.movement.state
        XCTAssertEqual(session.playerWalkState, preservedState)
        let serverTimeAfterMovement = try XCTUnwrap(
            session.serverRuntime.timerScheduler
        ).currentTime
        let clientTimeAfterMovement = try XCTUnwrap(
            session.clientRuntime.timerScheduler
        ).currentTime

        XCTAssertThrowsError(try session.runFixedTick(
            movementInput: GModPlayableMovementInput(forwardMove: .nan)
        )) { error in
            XCTAssertEqual(
                error as? SourceWorldWalkError,
                .nonFinite("command forwardMove")
            )
        }
        XCTAssertEqual(session.playerWalkState, preservedState)
        XCTAssertEqual(session.sourceAdapter.serverGlobals.tickCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(session.serverRuntime.timerScheduler).currentTime,
            serverTimeAfterMovement
        )
        XCTAssertEqual(
            try XCTUnwrap(session.clientRuntime.timerScheduler).currentTime,
            clientTimeAfterMovement
        )
    }

    func testConstructStartsPairedSandboxAndRunsMapTraceViewportAndTicks() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(
                map: .construct,
                initialViewport: GMLuaViewportSize(width: 1_024, height: 768)
            )
        )
        defer { _ = try? session.close() }

        XCTAssertEqual(session.startupReport.map, .construct)
        XCTAssertEqual(
            session.startupReport.spawnPoint.origin,
            SourceVector3(704, 132, -143)
        )
        XCTAssertEqual(
            session.spawnPoint.angles,
            SourceQAngle(pitch: 0, yaw: 180, roll: 0)
        )
        // The rendered world now replaces coarse displacement base faces with
        // their real recursive displacement triangles. The displacement-only
        // contribution is asserted separately by GModWorldRenderMeshTests.
        XCTAssertEqual(session.worldMesh.triangleCount, 41_344)
        XCTAssertEqual(session.worldIdentity.index, 0)
        XCTAssertTrue(session.startupReport.clientStartup.playerConnectionModeled)
        XCTAssertEqual(session.sharedSession.connectedClientCount, 1)
        XCTAssertEqual(session.serverRuntime.compatibilityGaps, [])
        XCTAssertEqual(session.clientRuntime.compatibilityGaps, [])

        try assertWorldTrace(in: session, expectedFloorZ: -143.968_75)
        try session.clientRuntime.execute(
            "assert(ScrW() == 1024 and ScrH() == 768)",
            sourceName: "=(playable initial viewport)"
        )
        XCTAssertTrue(try session.updateViewport(width: 2_048, height: 1_536))
        XCTAssertFalse(try session.updateViewport(width: 2_048, height: 1_536))
        try session.clientRuntime.execute(
            "assert(ScrW() == 2048 and ScrH() == 1536)",
            sourceName: "=(playable updated viewport)"
        )

        let fixed = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: session.spawnPoint.angles,
                forwardMove: 200,
                buttons: [.forward]
            )
        )
        XCTAssertTrue(fixed.movement.state.isOnGround)
        XCTAssertNotEqual(
            fixed.movement.state.origin,
            session.spawnPoint.origin
        )
        XCTAssertEqual(fixed.server.kind, .serverFixedTick)
        XCTAssertEqual(fixed.client.kind, .clientFixedTick)
        XCTAssertEqual(fixed.server.serverPhases, SourceServerPhase.allCases)
        XCTAssertEqual(fixed.server.hookFailures, [])
        XCTAssertEqual(fixed.client.hookFailures, [])
        XCTAssertEqual(fixed.server.timerFailures, [])
        XCTAssertEqual(fixed.client.timerFailures, [])
        let frame = try session.runClientFrame()
        XCTAssertEqual(frame.kind, .clientFrame)
        XCTAssertEqual(frame.hookFailures, [])
        XCTAssertEqual(frame.timerFailures, [])
    }

    func testFlatgrassUsesItsBundledBSPAndClosesIdempotently() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .flatgrass)
        )
        XCTAssertEqual(session.startupReport.map, .flatgrass)
        XCTAssertEqual(
            session.spawnPoint.origin,
            SourceVector3(-512, 576, -12_287)
        )
        XCTAssertEqual(session.spawnPoint.angles, .zero)
        // The renderer expands gm_flatgrass' displacement faces into their
        // recursive mesh instead of retaining the old coarse base quads.
        XCTAssertEqual(session.worldMesh.triangleCount, 12_044)
        XCTAssertEqual(session.bsp.header.mapRevision, 146)
        try assertWorldTrace(in: session, expectedFloorZ: -12_287.968_75)

        let firstClose = try session.close()
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(firstClose.clientFinalizerErrors, [])
        XCTAssertEqual(firstClose.serverFinalizerErrors, [])
        XCTAssertEqual(try session.close(), GModPlayableSessionCloseReport(
            clientFinalizerErrors: [],
            serverFinalizerErrors: []
        ))
        XCTAssertThrowsError(try session.runFixedTick()) { error in
            XCTAssertEqual(error as? GModPlayableSessionError, .closed)
        }
    }

    func testStrictSandboxSpawnMenuUsesLiveClientHooksAndInputRegistry() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }

        try session.clientRuntime.execute(
            "assert(type(g_SpawnMenu) == 'Panel' and IsValid(g_SpawnMenu) and not g_SpawnMenu:IsVisible())",
            sourceName: "=(playable stock spawn menu initial state)"
        )
        let achievements = try XCTUnwrap(session.clientRuntime.achievements)
        XCTAssertEqual(achievements.capturedRequests, [])
        try session.setSpawnMenuOpen(true)
        defer { try? session.setSpawnMenuOpen(false) }
        XCTAssertEqual(achievements.capturedRequests, [.spawnMenuOpened])
        try session.clientRuntime.execute(
            "assert(IsValid(g_SpawnMenu) and g_SpawnMenu:IsVisible())",
            sourceName: "=(playable stock spawn menu open state)"
        )

        let registry = try XCTUnwrap(session.clientRuntime.vguiRegistry)
        let viewport = try XCTUnwrap(session.clientRuntime.screenMetrics).viewport
        let tree = registry.renderTree(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
        XCTAssertFalse(tree.isEmpty)

        let rendered = try session.renderClientVGUIFrame()
        XCTAssertEqual(rendered.viewportWidth, viewport.width)
        XCTAssertEqual(rendered.viewportHeight, viewport.height)
        XCTAssertGreaterThan(rendered.drawCallCount, 0)
        XCTAssertNil(try session.insertClientVGUIText("must not be inserted"))

        let outside = try session.dispatchClientVGUIPointerEvent(
            x: -1,
            y: -1,
            phase: .moved,
            timestamp: 1
        )
        XCTAssertNil(outside.hitPanelIdentifier)
        XCTAssertEqual(outside.callbackNames, [])
        XCTAssertFalse(outside.clicked)
        XCTAssertFalse(outside.doubleClicked)

        try session.setSpawnMenuOpen(false)
        try session.clientRuntime.execute(
            "assert(IsValid(g_SpawnMenu) and not g_SpawnMenu:IsVisible())",
            sourceName: "=(playable stock spawn menu closed state)"
        )
    }

    func testStrictSandboxContextMenuUsesLiveClientLifecycle() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }

        try session.clientRuntime.execute(
            "assert(type(g_ContextMenu) == 'Panel' and " +
                "IsValid(g_ContextMenu) and not g_ContextMenu:IsVisible())",
            sourceName: "=(playable stock context menu initial state)"
        )

        try session.setContextMenuOpen(true)
        try session.clientRuntime.execute(
            "assert(IsValid(g_ContextMenu) and g_ContextMenu:IsVisible())",
            sourceName: "=(playable stock context menu open state)"
        )
        let rendered = try session.renderClientVGUIFrame()
        XCTAssertGreaterThan(rendered.drawCallCount, 0)

        try session.setContextMenuOpen(false)
        try session.clientRuntime.execute(
            "assert(IsValid(g_ContextMenu) and not g_ContextMenu:IsVisible())",
            sourceName: "=(playable stock context menu closed state)"
        )
    }

    func testVGUIPointerFeedsInputCursorAndReleasesMouseAfterThrow() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }
        try session.setSpawnMenuOpen(true)
        defer { try? session.setSpawnMenuOpen(false) }
        try session.clientRuntime.execute(
            """
            INPUT_THROW_PANEL = vgui.Create("Panel")
            INPUT_THROW_PANEL:SetPos(0, 0)
            INPUT_THROW_PANEL:SetSize(ScrW(), ScrH())
            INPUT_THROW_PANEL:SetMouseInputEnabled(true)
            INPUT_THROW_PANEL:SetZPos(32767)
            INPUT_THROW_PANEL:SetDrawOnTop(true)
            INPUT_THROW_PANEL:MakePopup()
            function INPUT_THROW_PANEL:OnMousePressed()
                local x, y = input.GetCursorPos()
                assert(x == 17 and y == 29)
                assert(input.IsMouseDown(MOUSE_LEFT))
            end
            function INPUT_THROW_PANEL:OnMouseReleased()
                assert(input.IsMouseDown(MOUSE_LEFT))
                error("intentional pointer release failure")
            end
            """,
            sourceName: "=(input pointer bridge fixture)"
        )

        _ = try session.dispatchClientVGUIPointerEvent(
            x: 17,
            y: 29,
            phase: .began,
            timestamp: 1
        )
        try session.clientRuntime.execute(
            """
            local x, y = input.GetCursorPos()
            assert(x == 17 and y == 29)
            assert(input.IsMouseDown(MOUSE_LEFT))
            """,
            sourceName: "=(input pointer down assertion)"
        )

        XCTAssertThrowsError(try session.dispatchClientVGUIPointerEvent(
            x: 19,
            y: 31,
            phase: .ended,
            timestamp: 2
        )) { error in
            XCTAssertTrue(
                GMLuaRuntime.describe(error).contains(
                    "intentional pointer release failure"
                )
            )
        }
        try session.clientRuntime.execute(
            """
            local x, y = input.GetCursorPos()
            assert(x == 19 and y == 31)
            assert(not input.IsMouseDown(MOUSE_LEFT))
            """,
            sourceName: "=(input pointer throw release assertion)"
        )
    }

    func testPauseMenuNotificationClosesStockClientMenus() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }

        try session.setContextMenuOpen(true)
        try session.notifyPauseMenuWillShow()
        try session.clientRuntime.execute(
            "assert(not g_SpawnMenu:IsVisible() and " +
                "not g_ContextMenu:IsVisible())",
            sourceName: "=(playable pause menu closes client menus)"
        )
    }

    func testMissingSpawnAPIIsReportedWithoutClosingOrDesynchronizingRealms() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }

        // This is the exact command enqueued by stock SpawnIcon.DoClick. The
        // current host intentionally has no fake Player:Alive/ents/physics
        // implementation, so the SERVER action must fail explicitly.
        try session.clientRuntime.execute(
            """
            RunConsoleCommand(
                "gm_spawn",
                "models/props_c17/oildrum001.mdl",
                "0",
                ""
            )
            """,
            sourceName: "=(stock SpawnIcon gm_spawn request)"
        )
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 1)

        let failedActionTick = try session.runFixedTick()
        XCTAssertEqual(failedActionTick.server.kind, .serverFixedTick)
        XCTAssertEqual(failedActionTick.client.kind, .clientFixedTick)
        XCTAssertEqual(failedActionTick.deliveredMessages, 0)
        XCTAssertEqual(failedActionTick.actionFailures.count, 1)
        let failure = try XCTUnwrap(failedActionTick.actionFailures.first)
        XCTAssertEqual(failure.command, "gm_spawn")
        XCTAssertEqual(
            failure.arguments,
            ["models/props_c17/oildrum001.mdl", "0", ""]
        )
        XCTAssertTrue(failure.message.contains("Alive"))
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
        XCTAssertFalse(session.isClosed)
        XCTAssertFalse(session.serverRuntime.isClosed)
        XCTAssertFalse(session.clientRuntime.isClosed)
        XCTAssertEqual(session.sourceAdapter.serverGlobals.tickCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(session.serverRuntime.timerScheduler).currentTime,
            try XCTUnwrap(session.clientRuntime.timerScheduler).currentTime,
            accuracy: 0.000_001
        )

        let laterTick = try session.runFixedTick()
        XCTAssertEqual(laterTick.actionFailures, [])
        XCTAssertEqual(laterTick.server.kind, .serverFixedTick)
        XCTAssertEqual(laterTick.client.kind, .clientFixedTick)
        XCTAssertEqual(session.sourceAdapter.serverGlobals.tickCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(session.serverRuntime.timerScheduler).currentTime,
            try XCTUnwrap(session.clientRuntime.timerScheduler).currentTime,
            accuracy: 0.000_001
        )
    }

    private func assertWorldTrace(
        in session: GModPlayableSession,
        expectedFloorZ: Double
    ) throws {
        let spawn = session.spawnPoint.origin
        let source = """
        local tr = util.TraceHull({
            start = Vector(\(spawn.x), \(spawn.y), \(spawn.z + 512)),
            endpos = Vector(\(spawn.x), \(spawn.y), \(spawn.z - 4096)),
            mins = Vector(-16, -16, 0),
            maxs = Vector(16, 16, 72),
            mask = MASK_PLAYERSOLID_BRUSHONLY
        })
        assert(tr.Hit and tr.HitWorld and not tr.StartSolid)
        assert(tr.Entity == Entity(0) and tr.Entity:EntIndex() == 0)
        return tr.HitPos.z
        """
        let values = try session.clientRuntime.executeReturningValues(
            source,
            sourceName: "=(playable bundled BSP trace)"
        )
        guard case let .number(hitZ)? = values.first else {
            return XCTFail("TraceHull did not return a numeric HitPos.z")
        }
        XCTAssertEqual(hitZ, expectedFloorZ, accuracy: 0.001)
    }
}

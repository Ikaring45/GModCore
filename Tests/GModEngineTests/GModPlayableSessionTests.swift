import XCTest
import GModEngine
import GModGameAssets
import GModGameSession

final class GModPlayableSessionTests: XCTestCase {
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
        XCTAssertEqual(session.worldMesh.triangleCount, 25_732)
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
        XCTAssertEqual(session.worldMesh.triangleCount, 6_637)
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

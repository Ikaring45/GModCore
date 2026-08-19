import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModPlayableSessionLaneTests: XCTestCase {
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
            expectedGeneration: snapshot.generation
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

        let replacement = try await lane.start(
            configuration: GModPlayableSessionConfiguration(map: .flatgrass)
        )
        XCTAssertNotEqual(replacement.generation, snapshot.generation)
        do {
            _ = try await lane.runHostFrame(
                fixedTickCount: 0,
                expectedGeneration: snapshot.generation
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

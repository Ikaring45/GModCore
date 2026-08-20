import XCTest
@testable import GModApp
import GModEngine

final class GModGameSessionModelSupportTests: XCTestCase {
    func testUnsupportedMovementDiagnosticNeverClaimsSuccess() {
        let water = GModGameMovementDiagnostic(
            commandNumber: 12,
            reason: .feature(.water)
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
            spawnMenuOpen: true
        )

        XCTAssertTrue(token.matches(
            application: 7,
            lane: 11,
            requestRevision: 19,
            spawnMenuOpen: true
        ))
        XCTAssertFalse(token.matches(
            application: 7,
            lane: 11,
            requestRevision: 20,
            spawnMenuOpen: true
        ))
        XCTAssertFalse(token.matches(
            application: 7,
            lane: 11,
            requestRevision: 19,
            spawnMenuOpen: false
        ))
        XCTAssertFalse(token.matches(
            application: 8,
            lane: 11,
            requestRevision: 19,
            spawnMenuOpen: true
        ))
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

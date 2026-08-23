import XCTest
@testable import GModApp

final class GModGameOverlaySurfaceFramePacerTests: XCTestCase {
    func testTransientSurfaceStallCannotCreatePermanentFixedTickCatchUp() {
        var catchUp = GModGameFixedTickCatchUpAccumulator()

        // A single delayed host frame may legitimately ask GMEngine for its
        // full eight-tick budget, but the app mailbox must not add later
        // requests on top of that already-accumulated engine budget.
        catchUp.submit(8)
        XCTAssertEqual(catchUp.pendingTickCount, 8)
        catchUp.submit(3)
        XCTAssertEqual(catchUp.takePendingTicks(), 8)

        // Model a one-second Hint Surface stall at 120 Hz. Repeated ordinary
        // frames coalesce to the newest one-tick budget instead of replaying
        // the entire stale interval ahead of current movement input.
        for _ in 0..<120 {
            catchUp.submit(1)
        }
        XCTAssertEqual(catchUp.pendingTickCount, 1)
        XCTAssertEqual(catchUp.takePendingTicks(), 1)
        XCTAssertEqual(catchUp.pendingTickCount, 0)

        // Once the slow work is gone, the very next ordinary host frame is
        // back at real-time cadence; no hidden debt survives the drain.
        catchUp.submit(1)
        XCTAssertEqual(catchUp.takePendingTicks(), 1)

        catchUp.submit(-8)
        XCTAssertEqual(catchUp.takePendingTicks(), 0)
    }

    func testOverlayCaptureIsBoundedAndInFlightWorkDoesNotQueueCatchUp() {
        var pacer = GModGameOverlaySurfaceFramePacer(
            minimumInterval: 1.0 / 30.0
        )

        XCTAssertFalse(pacer.shouldAdmit(
            scope: .overlay,
            at: 10,
            captureInFlight: true
        ))
        XCTAssertNil(pacer.lastAdmissionTime)
        XCTAssertTrue(pacer.shouldAdmit(
            scope: .overlay,
            at: 10,
            captureInFlight: false
        ))
        XCTAssertFalse(pacer.shouldAdmit(
            scope: .overlay,
            at: 10.01,
            captureInFlight: false
        ))

        // Work arriving while the prior capture is live is discarded rather
        // than becoming another movement-lane job after that capture.
        XCTAssertFalse(pacer.shouldAdmit(
            scope: .overlay,
            at: 11,
            captureInFlight: true
        ))
        XCTAssertTrue(pacer.shouldAdmit(
            scope: .overlay,
            at: 11,
            captureInFlight: false
        ))
        XCTAssertEqual(pacer.lastAdmissionTime, 11)

        // Foreground menus keep their existing latest-only behavior: every
        // pointer refresh is accepted, including while a scene build runs.
        XCTAssertTrue(pacer.shouldAdmit(
            scope: .all,
            at: 11,
            captureInFlight: true
        ))
        XCTAssertNil(pacer.lastAdmissionTime)
    }

    func testOverlayCaptureRecoversAcrossClockReplacementAndVisibilityReset() {
        var pacer = GModGameOverlaySurfaceFramePacer(
            minimumInterval: 0.05
        )

        XCTAssertTrue(pacer.shouldAdmit(
            scope: .overlay,
            at: 20,
            captureInFlight: false
        ))
        XCTAssertTrue(pacer.shouldAdmit(
            scope: .overlay,
            at: 1,
            captureInFlight: false
        ))
        XCTAssertFalse(pacer.shouldAdmit(
            scope: .overlay,
            at: .infinity,
            captureInFlight: false
        ))

        pacer.reset()
        XCTAssertNil(pacer.lastAdmissionTime)
        XCTAssertTrue(pacer.shouldAdmit(
            scope: .overlay,
            at: 1.001,
            captureInFlight: false
        ))
    }
}

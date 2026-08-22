import XCTest
@testable import GModApp

final class GModGameOverlaySurfaceFramePacerTests: XCTestCase {
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

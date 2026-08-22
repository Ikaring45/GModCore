import XCTest
import GModEngine
@testable import GModApp

final class GModTouchLookCadenceTests: XCTestCase {
    func testNearVerticalPitchKeepsYawAndCoalescesPresentation() throws {
        var state = GModTouchLookFrameState(
            angles: SourceQAngle(pitch: -89, yaw: 350, roll: 0)
        )

        XCTAssertTrue(state.adjust(
            deltaX: 20,
            deltaY: -100,
            sensitivity: 0.5,
            invertY: false
        ))
        XCTAssertTrue(state.adjust(
            deltaX: 10,
            deltaY: -100,
            sensitivity: 0.5,
            invertY: false
        ))

        // Pitch stays at Source's host clamp while yaw continues through it.
        XCTAssertEqual(state.inputAngles.pitch, -89, accuracy: 0.0001)
        XCTAssertEqual(state.inputAngles.yaw, 5, accuracy: 0.0001)
        XCTAssertEqual(state.presentedAngles.yaw, 350, accuracy: 0.0001)

        let presented = try XCTUnwrap(state.takePendingPresentation())
        XCTAssertEqual(presented.pitch, -89, accuracy: 0.0001)
        XCTAssertEqual(presented.yaw, 5, accuracy: 0.0001)
        XCTAssertNil(state.takePendingPresentation())

        // Source AngleVectors supplies an orthogonal up vector even near the
        // vertical pole; no arbitrary world-up fallback is involved.
        let basis = presented.sourceBasis
        let dot = basis.forward.x * basis.up.x +
            basis.forward.y * basis.up.y +
            basis.forward.z * basis.up.z
        XCTAssertTrue(basis.forward.x.isFinite)
        XCTAssertTrue(basis.forward.y.isFinite)
        XCTAssertTrue(basis.forward.z.isFinite)
        XCTAssertTrue(basis.up.x.isFinite)
        XCTAssertTrue(basis.up.y.isFinite)
        XCTAssertTrue(basis.up.z.isFinite)
        XCTAssertEqual(dot, 0, accuracy: 0.0001)
    }

    func testMovementAngleChangesImmediatelyButRenderPublishesOnce() throws {
        var state = GModTouchLookFrameState()

        for _ in 0..<24 {
            XCTAssertTrue(state.adjust(
                deltaX: 1,
                deltaY: 0.25,
                sensitivity: 0.5,
                invertY: false
            ))
        }

        XCTAssertEqual(state.inputAngles.yaw, 12, accuracy: 0.0001)
        XCTAssertEqual(state.inputAngles.pitch, 3, accuracy: 0.0001)
        XCTAssertEqual(state.presentedAngles, .zero)

        let singleFrame = try XCTUnwrap(state.takePendingPresentation())
        XCTAssertEqual(singleFrame, state.inputAngles)
        XCTAssertNil(state.takePendingPresentation())

        XCTAssertFalse(state.adjust(
            deltaX: 0,
            deltaY: 0,
            sensitivity: 0.5,
            invertY: false
        ))
        XCTAssertNil(state.takePendingPresentation())
    }
}

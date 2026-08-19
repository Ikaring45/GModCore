import XCTest
@testable import GModApp
import GModEngine

final class GModTouchInputTests: XCTestCase {
    func testSingleTouchLifecycleAcceptsExactlyOneTerminalPhase() {
        var lifecycle = GModSingleTouchLifecycle()

        XCTAssertFalse(lifecycle.accept(.moved))
        XCTAssertTrue(lifecycle.accept(.began))
        XCTAssertFalse(lifecycle.accept(.began))
        XCTAssertTrue(lifecycle.accept(.moved))
        XCTAssertTrue(lifecycle.accept(.cancelled))
        XCTAssertFalse(lifecycle.isActive)
        XCTAssertFalse(lifecycle.accept(.ended))
        XCTAssertFalse(lifecycle.accept(.cancelled))
    }

    func testJoystickCancellationZerosAxesAndOffsetExactlyOnce() throws {
        var state = GModJoystickTouchState()

        let began = try XCTUnwrap(state.consume(
            sample(x: 100, y: 50, phase: .began),
            radius: 40
        ))
        XCTAssertEqual(began.offsetX, 40, accuracy: 0.001)
        XCTAssertEqual(began.offsetY, 0, accuracy: 0.001)
        XCTAssertEqual(began.forward, 0, accuracy: 0.001)
        XCTAssertEqual(began.side, 1, accuracy: 0.001)
        XCTAssertTrue(state.isTracking)

        let cancelled = try XCTUnwrap(state.consume(
            sample(x: 100, y: 50, phase: .cancelled),
            radius: 40
        ))
        XCTAssertEqual(cancelled, .zero)
        XCTAssertEqual(state.output, .zero)
        XCTAssertFalse(state.isTracking)

        XCTAssertNil(state.consume(
            sample(x: 100, y: 50, phase: .ended),
            radius: 40
        ))
        XCTAssertNil(state.consume(
            sample(x: 90, y: 50, phase: .moved),
            radius: 40
        ))
        XCTAssertEqual(state.output, .zero)
    }

    func testLookCancellationClearsPriorPointBeforeNextGesture() throws {
        var state = GModLookTouchState()

        XCTAssertNil(state.consume(sample(x: 10, y: 10, phase: .began)))
        let firstDelta = try XCTUnwrap(
            state.consume(sample(x: 16, y: 7, phase: .moved))
        )
        XCTAssertEqual(firstDelta, GModLookTouchDelta(x: 6, y: -3))
        XCTAssertTrue(state.isTracking)
        XCTAssertTrue(state.hasPriorLocation)

        XCTAssertNil(state.consume(sample(x: 16, y: 7, phase: .cancelled)))
        XCTAssertFalse(state.isTracking)
        XCTAssertFalse(state.hasPriorLocation)
        XCTAssertNil(state.consume(sample(x: 16, y: 7, phase: .ended)))

        XCTAssertNil(state.consume(sample(x: 100, y: 100, phase: .began)))
        let secondDelta = try XCTUnwrap(
            state.consume(sample(x: 102, y: 104, phase: .moved))
        )
        XCTAssertEqual(secondDelta, GModLookTouchDelta(x: 2, y: 4))
    }

    private func sample(
        x: Double,
        y: Double,
        phase: GMLuaPointerPhase
    ) -> GModTouchSample {
        GModTouchSample(
            x: x,
            y: y,
            viewWidth: 100,
            viewHeight: 100,
            phase: phase,
            timestamp: 1
        )
    }
}

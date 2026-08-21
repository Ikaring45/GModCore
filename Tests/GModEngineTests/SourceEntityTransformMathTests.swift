import XCTest
@testable import GModEngine

final class SourceEntityTransformMathTests: XCTestCase {
    func testIdentityPreservesSourceLocalAxesAndAddsOriginOnlyToPoints() {
        let transform = SourceEntityTransform(
            origin: SourceVector3(10, 20, 30)
        )
        XCTAssertEqual(
            transform.transformDirectionFromLocal(SourceVector3(1, 2, 3)),
            SourceVector3(1, 2, 3)
        )
        XCTAssertEqual(
            transform.transformPointFromLocal(SourceVector3(1, 2, 3)),
            SourceVector3(11, 22, 33)
        )
    }

    func testYawUsesSourceForwardLeftUpColumns() {
        let transform = SourceEntityTransform(
            angles: SourceQAngle(yaw: 90)
        )
        assertVector(
            transform.transformDirectionFromLocal(SourceVector3(1, 0, 0)),
            equals: SourceVector3(0, 1, 0)
        )
        assertVector(
            transform.transformDirectionFromLocal(SourceVector3(0, 1, 0)),
            equals: SourceVector3(-1, 0, 0)
        )
        assertVector(
            transform.transformDirectionFromLocal(SourceVector3(0, 0, 1)),
            equals: SourceVector3(0, 0, 1)
        )
    }

    func testPitchYawRollRoundTripPointAndDirection() {
        let transform = SourceEntityTransform(
            origin: SourceVector3(-4, 17, 3),
            angles: SourceQAngle(pitch: 31, yaw: -127, roll: 22)
        )
        let localPoint = SourceVector3(7, -2, 11)
        let localDirection = SourceVector3(-0.5, 3, 1.25)
        assertVector(
            transform.inverseTransformPointToLocal(
                transform.transformPointFromLocal(localPoint)
            ),
            equals: localPoint
        )
        assertVector(
            transform.inverseTransformDirectionToLocal(
                transform.transformDirectionFromLocal(localDirection)
            ),
            equals: localDirection
        )
    }

    private func assertVector(
        _ actual: SourceVector3,
        equals expected: SourceVector3,
        accuracy: Float = 0.000_01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}

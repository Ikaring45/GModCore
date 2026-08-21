import XCTest
@testable import GModEngine

final class SourceCollisionPropertyTests: XCTestCase {
    func testNearestPointUsesCollisionSpaceAABBClamp() throws {
        let property = try SourceCollisionProperty(
            mins: SourceVector3(-2, -1, -3),
            maxs: SourceVector3(4, 5, 6)
        )
        let transform = SourceEntityTransform(
            origin: SourceVector3(10, 20, 30),
            angles: SourceQAngle(pitch: 0, yaw: 90, roll: 0)
        )
        let query = transform.transformPointFromLocal(SourceVector3(9, -8, 2))

        let actual = try property.nearestPoint(to: query, transform: transform)
        let expected = transform.transformPointFromLocal(SourceVector3(4, -1, 2))
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.0001)
    }

    func testWorldBoundsTransformAllEightOBBCorners() throws {
        let property = try SourceCollisionProperty(
            mins: SourceVector3(-2, -1, -3),
            maxs: SourceVector3(4, 5, 6)
        )
        let bounds = try property.worldAxisAlignedBounds(
            transform: SourceEntityTransform(
                origin: SourceVector3(10, 20, 30),
                angles: SourceQAngle(pitch: 0, yaw: 90, roll: 0)
            )
        )

        XCTAssertEqual(bounds.mins.x, 5, accuracy: 0.0001)
        XCTAssertEqual(bounds.mins.y, 18, accuracy: 0.0001)
        XCTAssertEqual(bounds.mins.z, 27, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxs.x, 11, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxs.y, 24, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxs.z, 36, accuracy: 0.0001)
    }

    func testRejectsUnusableBoundsAndInputsWithoutFallback() throws {
        XCTAssertThrowsError(
            try SourceCollisionProperty(
                mins: SourceVector3(.nan, 0, 0),
                maxs: SourceVector3(1, 1, 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCollisionProperty.ValidationError,
                .nonFiniteBounds
            )
        }
        XCTAssertThrowsError(
            try SourceCollisionProperty(
                mins: SourceVector3(2, 0, 0),
                maxs: SourceVector3(1, 1, 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCollisionProperty.ValidationError,
                .invertedBounds
            )
        }

        let property = try SourceCollisionProperty(
            mins: SourceVector3(-1, -1, -1),
            maxs: SourceVector3(1, 1, 1)
        )
        XCTAssertThrowsError(
            try property.nearestPoint(
                to: SourceVector3(.infinity, 0, 0),
                transform: SourceEntityTransform()
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCollisionProperty.ValidationError,
                .nonFinitePoint
            )
        }
    }
}

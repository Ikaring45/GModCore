import XCTest
@testable import GModEngine

final class SourceCollisionTests: XCTestCase {
    func testRayHullUsesSourceCenteredRepresentation() {
        let ray = SourceRay(
            start: SourceVector3(0, 0, 0),
            end: SourceVector3(10, 0, 0),
            mins: SourceVector3(-1, -2, -3),
            maxs: SourceVector3(3, 2, 1)
        )

        XCTAssertEqual(ray.start, SourceVector3(1, 0, -1))
        XCTAssertEqual(ray.delta, SourceVector3(10, 0, 0))
        XCTAssertEqual(ray.startOffset, SourceVector3(-1, 0, 1))
        XCTAssertEqual(ray.extents, SourceVector3(2, 2, 2))
        XCTAssertEqual(ray.actualStart, .zero)
        XCTAssertEqual(ray.actualEnd, SourceVector3(10, 0, 0))
        XCTAssertEqual(ray.normalizedDelta, SourceVector3(1, 0, 0))
        XCTAssertFalse(ray.isRay)
        XCTAssertTrue(ray.isSwept)
    }

    func testPointAndSweptHullHitAABBAtDeterministicFractions() {
        let worldHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 1)
        var world = SourceCollisionWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(4, -1, -1),
                maxs: SourceVector3(6, 1, 1),
                contents: .solid,
                surface: SourceTraceSurface(name: "brick", surfaceProperties: 3),
                entityHandle: worldHandle
            )
        )

        let pointTrace = world.trace(
            SourceRay(start: .zero, end: SourceVector3(10, 0, 0)),
            mask: SourceMasks.solid
        )
        XCTAssertTrue(pointTrace.didHit)
        XCTAssertTrue(pointTrace.didHitWorld)
        XCTAssertFalse(pointTrace.startSolid)
        XCTAssertFalse(pointTrace.allSolid)
        XCTAssertEqual(pointTrace.fraction, 0.396_875, accuracy: 0.000_001)
        XCTAssertEqual(pointTrace.endPosition.x, 3.968_75, accuracy: 0.000_001)
        XCTAssertEqual(pointTrace.plane.normal, SourceVector3(-1, 0, 0))
        XCTAssertEqual(pointTrace.plane.distance, -4)
        XCTAssertEqual(pointTrace.contents, .solid)
        XCTAssertEqual(pointTrace.surface.name, "brick")

        let hullTrace = world.trace(
            SourceRay(
                start: .zero,
                end: SourceVector3(10, 0, 0),
                mins: SourceVector3(-1, -1, -1),
                maxs: SourceVector3(1, 1, 1)
            ),
            mask: SourceMasks.playerSolid
        )
        XCTAssertEqual(hullTrace.fraction, 0.296_875, accuracy: 0.000_001)
        XCTAssertEqual(hullTrace.endPosition.x, 2.968_75, accuracy: 0.000_001)
    }

    func testStartSolidReportsExitFractionAndAllSolid() {
        var world = SourceCollisionWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(-1, -1, -1),
                maxs: SourceVector3(1, 1, 1)
            )
        )

        let exits = world.trace(
            SourceRay(start: .zero, end: SourceVector3(4, 0, 0)),
            mask: SourceMasks.solid
        )
        XCTAssertTrue(exits.startSolid)
        XCTAssertFalse(exits.allSolid)
        XCTAssertEqual(exits.fraction, 0)
        XCTAssertEqual(exits.fractionLeftSolid, 0.242_187_5, accuracy: 0.000_001)
        XCTAssertEqual(exits.startPosition, SourceVector3(0.968_75, 0, 0))
        XCTAssertEqual(exits.endPosition, .zero)
        XCTAssertEqual(exits.plane.normal, SourceVector3(1, 0, 0))
        XCTAssertEqual(exits.plane.distance, 0)
        XCTAssertEqual(exits.plane.type, 0)

        let remainsInside = world.trace(
            SourceRay(start: .zero, end: SourceVector3(0.5, 0, 0)),
            mask: SourceMasks.solid
        )
        XCTAssertTrue(remainsInside.startSolid)
        XCTAssertTrue(remainsInside.allSolid)
        XCTAssertEqual(remainsInside.fraction, 0)
        XCTAssertEqual(remainsInside.fractionLeftSolid, 1)
        XCTAssertEqual(remainsInside.startPosition, SourceVector3(0.5, 0, 0))
        XCTAssertEqual(remainsInside.endPosition, .zero)
        XCTAssertEqual(remainsInside.plane.normal, SourceVector3(1, 0, 0))

        let stationary = world.trace(
            SourceRay(start: .zero, end: .zero),
            mask: SourceMasks.solid
        )
        XCTAssertTrue(stationary.startSolid)
        XCTAssertTrue(stationary.allSolid)
        XCTAssertEqual(stationary.fraction, 0)
        XCTAssertEqual(stationary.fractionLeftSolid, 1)
        XCTAssertEqual(stationary.startPosition, .zero)
        XCTAssertEqual(stationary.endPosition, .zero)
        XCTAssertEqual(stationary.plane.normal, SourceVector3(1, 0, 0))
        XCTAssertEqual(stationary.plane.distance, 0)
        XCTAssertEqual(stationary.plane.type, 0)
    }

    func testAABBToleranceIsCallerSupplied() {
        var world = SourceCollisionWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(4, -1, -1),
                maxs: SourceVector3(6, 1, 1)
            )
        )
        let ray = SourceRay(start: .zero, end: SourceVector3(10, 0, 0))

        let exact = world.trace(ray, tolerance: 0)
        let backedOff = world.trace(
            ray,
            tolerance: SourceCollisionConstants.distanceEpsilon
        )

        XCTAssertEqual(exact.fraction, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(exact.endPosition, SourceVector3(4, 0, 0))
        XCTAssertEqual(backedOff.fraction, 0.396_875, accuracy: 0.000_001)
        XCTAssertEqual(backedOff.endPosition, SourceVector3(3.968_75, 0, 0))
    }

    func testConvexBrushAlsoReceivesCallerSuppliedTolerance() {
        var world = SourceCollisionWorld()
        world.addConvexBrush(
            SourceConvexBrush(
                planes: Self.boxPlanes(
                    mins: SourceVector3(4, -1, -1),
                    maxs: SourceVector3(6, 1, 1)
                )
            )
        )
        let ray = SourceRay(start: .zero, end: SourceVector3(10, 0, 0))

        XCTAssertEqual(world.trace(ray, tolerance: 0).fraction, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(
            world.trace(
                ray,
                tolerance: SourceCollisionConstants.distanceEpsilon
            ).fraction,
            0.396_875,
            accuracy: 0.000_001
        )
    }

    func testStartSolidHullRestoresRayStartOffsetAfterBoxTrace() {
        var world = SourceCollisionWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(-1, -1, -1),
                maxs: SourceVector3(1, 1, 1)
            )
        )
        let ray = SourceRay(
            start: .zero,
            end: SourceVector3(5, 0, 0),
            mins: SourceVector3(-2, -1, -1),
            maxs: SourceVector3(0, 1, 1)
        )

        let trace = world.trace(ray)

        XCTAssertTrue(trace.startSolid)
        XCTAssertFalse(trace.allSolid)
        XCTAssertEqual(trace.fractionLeftSolid, 0.593_75, accuracy: 0.000_001)
        XCTAssertEqual(trace.startPosition, SourceVector3(2.968_75, 0, 0))
        XCTAssertEqual(trace.endPosition, .zero)
        XCTAssertEqual(trace.plane.normal, SourceVector3(1, 0, 0))
        XCTAssertEqual(trace.plane.distance, -1)
    }

    func testConvexBrushPointContentsAndTraceMask() {
        let waterBrush = SourceConvexBrush(
            planes: Self.boxPlanes(
                mins: SourceVector3(2, -2, -2),
                maxs: SourceVector3(4, 2, 2)
            ),
            contents: .water
        )
        var world = SourceCollisionWorld()
        world.addConvexBrush(waterBrush)

        XCTAssertEqual(world.pointContents(at: SourceVector3(3, 0, 0)), .water)
        XCTAssertEqual(
            world.pointContents(at: SourceVector3(3, 0, 0), mask: SourceMasks.solid),
            .empty
        )
        XCTAssertEqual(world.pointContents(at: .zero), .empty)

        let missesMask = world.trace(
            SourceRay(start: .zero, end: SourceVector3(10, 0, 0)),
            mask: SourceMasks.solid
        )
        XCTAssertFalse(missesMask.didHit)
        XCTAssertEqual(missesMask.fraction, 1)

        let hitsWater = world.trace(
            SourceRay(start: .zero, end: SourceVector3(10, 0, 0)),
            mask: SourceMasks.water
        )
        XCTAssertTrue(hitsWater.didHit)
        XCTAssertEqual(hitsWater.fraction, 0.196_875, accuracy: 0.000_001)
    }

    func testGModOracleSweptHullKeepsOneThirtySecondImpactEpsilon() {
        var world = SourceCollisionWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(-16, -16, 240),
                maxs: SourceVector3(16, 16, 272),
                contents: .solid,
                entityHandle: SourceBaseHandle(entryIndex: 72, serialNumber: 0)
            )
        )
        let ray = SourceRay(
            start: SourceVector3(-64, 0, 256),
            end: SourceVector3(64, 0, 256),
            mins: SourceVector3(-4, -4, -4),
            maxs: SourceVector3(4, 4, 4)
        )

        let trace = world.trace(ray, mask: SourceMasks.solid)

        XCTAssertEqual(trace.fraction, 0.343_505_859_375)
        XCTAssertEqual(trace.endPosition, SourceVector3(-20.031_25, 0, 256))
        XCTAssertEqual(trace.plane.normal, SourceVector3(-1, 0, 0))
        XCTAssertEqual(trace.plane.distance, 20)
        XCTAssertEqual(ray.normalizedDelta, SourceVector3(1, 0, 0))
        XCTAssertEqual(trace.contents, .solid)
    }

    private static func boxPlanes(
        mins: SourceVector3,
        maxs: SourceVector3
    ) -> [SourcePlane] {
        [
            SourcePlane(normal: SourceVector3(1, 0, 0), distance: maxs.x),
            SourcePlane(normal: SourceVector3(-1, 0, 0), distance: -mins.x),
            SourcePlane(normal: SourceVector3(0, 1, 0), distance: maxs.y),
            SourcePlane(normal: SourceVector3(0, -1, 0), distance: -mins.y),
            SourcePlane(normal: SourceVector3(0, 0, 1), distance: maxs.z),
            SourcePlane(normal: SourceVector3(0, 0, -1), distance: -mins.z),
        ]
    }
}

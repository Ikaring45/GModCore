import Foundation
import XCTest
import GModEngine
import GModGameAssets
@testable import GModGameSession

final class GModMapAllocationPolicyTests: XCTestCase {
    func testEveryResourceReportsExactRequestedAndMaximumBytes() throws {
        let policy = GModMapAllocationPolicy.iPadValidated
        for resource in GModMapAllocationResource.allCases {
            let maximum = policy.maximumByteCount(for: resource)
            XCTAssertNoThrow(try policy.validate(
                resource,
                requestedByteCount: maximum
            ))
            XCTAssertThrowsError(try policy.validate(
                resource,
                requestedByteCount: maximum + 1
            )) { error in
                XCTAssertEqual(
                    error as? GModMapAllocationPolicyError,
                    GModMapAllocationPolicyError(
                        resource: resource,
                        requestedByteCount: maximum + 1,
                        maximumByteCount: maximum
                    )
                )
            }
        }
    }

    func testBundledMapMeasurementsRemainInsideDevicePolicy() throws {
        let policy = GModMapAllocationPolicy.iPadValidated
        for map in GModBundledMap.allCases {
            let expectedBSPBytes: UInt64
            switch map {
            case .construct:
                expectedBSPBytes = 36_735_656
            case .flatgrass:
                expectedBSPBytes = 47_430_424
            }
            let url = try GModGameAssets.url(for: map, kind: .bsp)
            let fileSize = try XCTUnwrap(
                url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            XCTAssertEqual(UInt64(fileSize), expectedBSPBytes)
            XCTAssertNoThrow(try policy.validate(
                .bspEncodedBytes,
                requestedByteCount: UInt64(fileSize)
            ))

            let bsp = try SourceBSP(
                data: GModGameAssets.data(for: map, kind: .bsp)
            )
            let estimate = try GModWorldRenderMesh.allocationEstimate(
                from: bsp,
                allocationPolicy: policy
            )
            let expectedEstimate: GModWorldRenderMeshAllocationEstimate
            switch map {
            case .construct:
                expectedEstimate = GModWorldRenderMeshAllocationEstimate(
                    worldVertexCount: 56_680,
                    worldIndexCount: 139_548,
                    displacementVertexCount: 12_638,
                    displacementIndexCount: 62_976,
                    worldVertexWorkingByteCount: 7_708_480,
                    worldIndexWorkingByteCount: 1_116_384,
                    displacementVertexWorkingByteCount: 1_213_248,
                    displacementIndexWorkingByteCount: 503_808
                )
            case .flatgrass:
                expectedEstimate = GModWorldRenderMeshAllocationEstimate(
                    worldVertexCount: 17_065,
                    worldIndexCount: 44_427,
                    displacementVertexCount: 4_624,
                    displacementIndexCount: 24_576,
                    worldVertexWorkingByteCount: 2_320_840,
                    worldIndexWorkingByteCount: 355_416,
                    displacementVertexWorkingByteCount: 443_904,
                    displacementIndexWorkingByteCount: 196_608
                )
            }
            XCTAssertEqual(estimate, expectedEstimate)
            XCTAssertLessThanOrEqual(
                estimate.worldVertexWorkingByteCount,
                policy.maximumWorldVertexWorkingByteCount
            )
            XCTAssertLessThanOrEqual(
                estimate.worldIndexWorkingByteCount,
                policy.maximumWorldIndexWorkingByteCount
            )
            XCTAssertLessThanOrEqual(
                estimate.displacementVertexWorkingByteCount,
                policy.maximumDisplacementVertexWorkingByteCount
            )
            XCTAssertLessThanOrEqual(
                estimate.displacementIndexWorkingByteCount,
                policy.maximumDisplacementIndexWorkingByteCount
            )
        }
    }

    func testWorldPreflightRejectsBeforeReserveWithTypedCapacity() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )
        let policy = permissivePolicy(worldVertexBytes: 1)

        XCTAssertThrowsError(try GModWorldRenderMesh.build(
            from: bsp,
            allocationPolicy: policy
        )) { error in
            guard let failure = error as? GModMapAllocationPolicyError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(failure.resource, .worldVertexWorkingBytes)
            XCTAssertGreaterThan(failure.requestedByteCount, 1)
            XCTAssertEqual(failure.maximumByteCount, 1)
        }
    }

    func testLightmapAllocationUsesSharedCapAndPreservesExactDiagnostic() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )
        let policy = permissivePolicy(lightmapBytes: 1)
        let mesh = try GModWorldRenderMesh.build(
            from: bsp,
            allocationPolicy: policy
        )

        guard case let .capacityExceeded(
            _,
            _,
            requestedByteCount,
            _,
            _,
            maximumByteCount
        ) = mesh.diagnostics.lightmapAtlasStatus else {
            return XCTFail("expected lightmap allocation capacity diagnostic")
        }
        XCTAssertGreaterThan(requestedByteCount, 1)
        XCTAssertEqual(maximumByteCount, 1)
        XCTAssertNil(mesh.lightmapAtlas)
    }

    private func permissivePolicy(
        worldVertexBytes: UInt64 = .max,
        lightmapBytes: UInt64 = .max
    ) -> GModMapAllocationPolicy {
        GModMapAllocationPolicy(
            maximumBSPEncodedByteCount: .max,
            maximumWorldVertexWorkingByteCount: worldVertexBytes,
            maximumWorldIndexWorkingByteCount: .max,
            maximumDisplacementVertexWorkingByteCount: .max,
            maximumDisplacementIndexWorkingByteCount: .max,
            maximumLightmapAtlasByteCount: lightmapBytes
        )
    }
}

import XCTest
@testable import GModEngine
@testable import GModGameAssets
@testable import GModGameSession

final class GModWorldRenderMeshTests: XCTestCase {
    func testConstructWorldModelTriangulatesDeterministically() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )
        let mesh = try GModWorldRenderMesh.build(from: bsp)

        XCTAssertEqual(mesh.diagnostics.sourceFaceCount, 9_363)
        XCTAssertEqual(mesh.diagnostics.emittedFaceCount, 6_952)
        XCTAssertEqual(mesh.diagnostics.degenerateFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.displacementBaseFaceCount, 110)
        XCTAssertEqual(mesh.diagnostics.skippedToolOrSkyFaceCount, 2_411)
        XCTAssertEqual(mesh.vertices.count, 34_464)
        XCTAssertEqual(mesh.triangleCount, 20_560)
        XCTAssertEqual(mesh.indices.count, 61_680)
        XCTAssertEqual(bsp.textureNames.count, 204)
        XCTAssertEqual(
            bsp.textureName(forTextureDataIndex: 0),
            "BUILDING_TEMPLATE/ROOF_TEMPLATE001A"
        )
        XCTAssertTrue(
            mesh.materialRanges.contains {
                $0.materialName == "gm_construct/construct_concrete_ground"
            }
        )
        assertAllIndicesAreInBounds(mesh)
        assertFiniteOrderedBounds(mesh)
        assertMaterialRangesAndTextureCoordinates(mesh)
    }

    func testFlatgrassWorldModelTriangulatesDeterministically() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .flatgrass, kind: .bsp)
        )
        let mesh = try GModWorldRenderMesh.build(from: bsp)

        XCTAssertEqual(mesh.diagnostics.sourceFaceCount, 2_922)
        XCTAssertEqual(mesh.diagnostics.emittedFaceCount, 1_657)
        XCTAssertEqual(mesh.diagnostics.degenerateFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.displacementBaseFaceCount, 16)
        XCTAssertEqual(mesh.diagnostics.skippedToolOrSkyFaceCount, 1_265)
        XCTAssertEqual(mesh.vertices.count, 7_186)
        XCTAssertEqual(mesh.triangleCount, 3_872)
        XCTAssertEqual(mesh.indices.count, 11_616)
        XCTAssertEqual(bsp.textureNames.count, 18)
        XCTAssertEqual(
            bsp.textureName(forTextureDataIndex: 2),
            "GM_CONSTRUCT/FLATGRASS"
        )
        XCTAssertTrue(
            mesh.materialRanges.contains {
                $0.materialName == "gm_construct/flatgrass"
            }
        )
        assertAllIndicesAreInBounds(mesh)
        assertFiniteOrderedBounds(mesh)
        assertMaterialRangesAndTextureCoordinates(mesh)
    }

    private func assertAllIndicesAreInBounds(
        _ mesh: GModWorldRenderMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(mesh.indices.count % 3, 0, file: file, line: line)
        XCTAssertLessThan(
            Int(mesh.indices.max() ?? 0),
            mesh.vertices.count,
            file: file,
            line: line
        )
    }

    private func assertFiniteOrderedBounds(
        _ mesh: GModWorldRenderMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for value in [
            mesh.minimum.x, mesh.minimum.y, mesh.minimum.z,
            mesh.maximum.x, mesh.maximum.y, mesh.maximum.z,
        ] {
            XCTAssertTrue(value.isFinite, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(mesh.minimum.x, mesh.maximum.x, file: file, line: line)
        XCTAssertLessThanOrEqual(mesh.minimum.y, mesh.maximum.y, file: file, line: line)
        XCTAssertLessThanOrEqual(mesh.minimum.z, mesh.maximum.z, file: file, line: line)
    }

    private func assertMaterialRangesAndTextureCoordinates(
        _ mesh: GModWorldRenderMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(mesh.materialRanges.isEmpty, file: file, line: line)
        var covered = 0
        for range in mesh.materialRanges {
            XCTAssertEqual(range.firstIndex, covered, file: file, line: line)
            XCTAssertGreaterThan(range.indexCount, 0, file: file, line: line)
            XCTAssertEqual(range.indexCount % 3, 0, file: file, line: line)
            covered += range.indexCount
        }
        XCTAssertEqual(covered, mesh.indices.count, file: file, line: line)
        XCTAssertTrue(
            mesh.vertices.contains {
                $0.textureCoordinate.u != 0 || $0.textureCoordinate.v != 0
            },
            file: file,
            line: line
        )
        XCTAssertTrue(
            mesh.vertices.allSatisfy {
                $0.textureCoordinate.u.isFinite &&
                    $0.textureCoordinate.v.isFinite
            },
            file: file,
            line: line
        )
    }
}

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
        XCTAssertEqual(mesh.diagnostics.emittedFaceCount, 9_363)
        XCTAssertEqual(mesh.diagnostics.degenerateFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.displacementBaseFaceCount, 110)
        XCTAssertEqual(mesh.vertices.count, 44_458)
        XCTAssertEqual(mesh.triangleCount, 25_732)
        XCTAssertEqual(mesh.indices.count, 77_196)
        assertAllIndicesAreInBounds(mesh)
        assertFiniteOrderedBounds(mesh)
    }

    func testFlatgrassWorldModelTriangulatesDeterministically() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .flatgrass, kind: .bsp)
        )
        let mesh = try GModWorldRenderMesh.build(from: bsp)

        XCTAssertEqual(mesh.diagnostics.sourceFaceCount, 2_922)
        XCTAssertEqual(mesh.diagnostics.emittedFaceCount, 2_922)
        XCTAssertEqual(mesh.diagnostics.degenerateFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.displacementBaseFaceCount, 16)
        XCTAssertEqual(mesh.vertices.count, 12_481)
        XCTAssertEqual(mesh.triangleCount, 6_637)
        XCTAssertEqual(mesh.indices.count, 19_911)
        assertAllIndicesAreInBounds(mesh)
        assertFiniteOrderedBounds(mesh)
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
}

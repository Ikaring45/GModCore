import Foundation
import XCTest
import GModEngine
import GModGameAssets
@testable import GModGameSession

final class GModWorldDisplacementTerrainLODTests: XCTestCase {
    func testInstalledConstructVPKExposesAuthoredTerrainMipChains() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_VPK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip(
                "set GMOD_VPK_DIAGNOSTIC_PATH to an installed garrysmod_dir.vpk"
            )
        }
        let archive = try GMLuaVPKArchive(
            directoryFileURL: URL(fileURLWithPath: path)
        )
        let materialPath = "materials/gm_construct/grass_13.vmt"
        let source = try XCTUnwrap(
            String(
                data: try XCTUnwrap(archive.data(for: materialPath)),
                encoding: .utf8
            )
        )
        let material = try SourceVMTDocument.parse(
            source: source,
            sourceName: materialPath
        )
        XCTAssertEqual(material.shader, "WorldVertexTransition")
        XCTAssertEqual(
            try material.string(named: "$basetexture"),
            "gm_construct/grass1"
        )
        XCTAssertEqual(
            try material.string(named: "$basetexture2"),
            "gm_construct/grass2"
        )
        XCTAssertEqual(
            try material.string(named: "$detail"),
            "gm_construct/grass_clouds"
        )
        XCTAssertEqual(try material.number(named: "$detailscale"), 0.12)
        XCTAssertEqual(try material.number(named: "$detailblendfactor"), 0.5)

        let textures: [(
            name: String,
            width: Int,
            mipCount: Int,
            flags: SourceVTFTextureFlags
        )] = [
            ("grass1", 2_048, 12, [.anisotropic]),
            ("grass2", 2_048, 12, [.anisotropic]),
            ("grass_clouds", 512, 10, []),
            ("grass_blendmask", 512, 10, []),
            ("construct_sand", 1_024, 11, [.trilinear, .normal]),
        ]
        for expected in textures {
            let logicalPath = "materials/gm_construct/\(expected.name).vtf"
            let texture = try SourceVTFFile(
                data: try XCTUnwrap(archive.data(for: logicalPath))
            )
            XCTAssertEqual(texture.width, expected.width, logicalPath)
            XCTAssertEqual(texture.height, expected.width, logicalPath)
            XCTAssertEqual(texture.mipCount, expected.mipCount, logicalPath)
            XCTAssertEqual(texture.flags, expected.flags, logicalPath)
            XCTAssertFalse(texture.flags.contains(.noMip), logicalPath)
            XCTAssertEqual(
                try (0..<texture.mipCount).map { level in
                    let mip = try texture.subresource(mipLevel: level)
                    XCTAssertFalse(mip.data.isEmpty, logicalPath)
                    return [mip.width, mip.height]
                },
                (0..<expected.mipCount).map { level in
                    let dimension = max(1, expected.width >> level)
                    return [dimension, dimension]
                },
                logicalPath
            )
        }
    }

    func testBundledDisplacementsRemainWorldGeometryWithExactPVSSpans() throws {
        let fixtures: [(map: GModBundledMap, materials: Set<String>)] = [
            (
                .construct,
                [
                    "gm_construct/grass_13",
                    "gm_construct/grass-sand_13",
                    "gm_construct/flatgrass",
                    "gm_construct/flatgrass_2",
                ]
            ),
            (.flatgrass, ["gm_construct/flatgrass"]),
        ]

        for fixture in fixtures {
            let bsp = try SourceBSP(
                data: GModGameAssets.data(for: fixture.map, kind: .bsp)
            )
            let mesh = try GModWorldRenderMesh.build(from: bsp)
            let visibility = try XCTUnwrap(mesh.worldVisibility)
            XCTAssertNotNil(mesh.lightmapAtlas, fixture.map.rawValue)
            let displacementRanges = mesh.materialRanges.enumerated().filter {
                $0.element.isDisplacement
            }

            XCTAssertFalse(displacementRanges.isEmpty, fixture.map.rawValue)
            XCTAssertEqual(
                Set(displacementRanges.compactMap { $0.element.materialName }),
                fixture.materials,
                fixture.map.rawValue
            )
            XCTAssertTrue(displacementRanges.allSatisfy {
                $0.element.renderLayer == .world &&
                    $0.element.waterSurface == nil
            }, fixture.map.rawValue)
            XCTAssertEqual(
                displacementRanges.reduce(0) { $0 + $1.element.indexCount },
                mesh.diagnostics.emittedDisplacementTriangleCount * 3,
                "each emitted BSP displacement triangle must occur once"
            )
            XCTAssertTrue(mesh.materialRanges.allSatisfy {
                $0.renderLayer != .sky2D || !$0.isDisplacement
            })
            if case .construct = fixture.map {
                let ordinaryFlatgrass = mesh.materialRanges.filter {
                    $0.renderLayer == .world &&
                        $0.materialName == "gm_construct/flatgrass"
                }
                XCTAssertEqual(
                    Set(ordinaryFlatgrass.map(\.isDisplacement)),
                    [false, true],
                    "real construct brush and displacement faces share this VMT"
                )
            }

            for (rangeIndex, range) in displacementRanges {
                let rangeEnd = range.firstIndex + range.indexCount
                XCTAssertTrue(mesh.indices[range.firstIndex..<rangeEnd]
                    .allSatisfy { index in
                        mesh.vertices[Int(index)].lightmapCoordinate != nil
                    }, "displacement indices must retain authored lightmap UVs")
                let spans = visibility.spans.filter {
                    $0.materialRangeIndex == rangeIndex
                }
                XCTAssertFalse(spans.isEmpty, range.materialName ?? "<nil>")
                XCTAssertEqual(
                    spans.reduce(0) { $0 + $1.indexCount },
                    range.indexCount,
                    "range split must preserve exact PVS/frustum index coverage"
                )
                XCTAssertTrue(spans.allSatisfy { span in
                    span.firstIndex >= range.firstIndex &&
                        span.firstIndex + span.indexCount <=
                            range.firstIndex + range.indexCount &&
                        Self.hasFiniteOrderedBounds(span)
                })
            }
        }
    }

    private static func hasFiniteOrderedBounds(
        _ span: GModWorldVisibilitySpan
    ) -> Bool {
        let minimum = span.minimum
        let maximum = span.maximum
        return minimum.x.isFinite && minimum.y.isFinite && minimum.z.isFinite &&
            maximum.x.isFinite && maximum.y.isFinite && maximum.z.isFinite &&
            minimum.x <= maximum.x &&
            minimum.y <= maximum.y &&
            minimum.z <= maximum.z
    }
}

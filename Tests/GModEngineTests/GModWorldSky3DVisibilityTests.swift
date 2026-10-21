import XCTest
import GModEngine
import GModGameAssets
@testable import GModGameSession

final class GModWorldSky3DVisibilityTests: XCTestCase {
    func testOutdoorSpawnActuallySelectsSkyTerrainInCardinalViews() throws {
        for map in GModBundledMap.allCases {
            let bsp = try SourceBSP(data: GModGameAssets.data(for: map, kind: .bsp))
            let mesh = try GModWorldRenderMesh.build(from: bsp)
            let sky = try XCTUnwrap(mesh.sky3DVisibility)
            let spawn = try XCTUnwrap(bsp.entities.parsedEntities().first {
                $0.value(forKey: "classname")?.hasPrefix("info_player_") == true
            })
            let coordinates = try XCTUnwrap(spawn.value(forKey: "origin")).split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
            XCTAssertEqual(coordinates.count, 3)
            let eye = SourceVector3(coordinates[0], coordinates[1], coordinates[2] + 64)
            XCTAssertEqual(mesh.skyVisibility?.visibility(at: eye), .sky3D)
            var counts: [Int] = []
            for direction in [SourceVector3(1, 0, 0), SourceVector3(0, 1, 0),
                              SourceVector3(-1, 0, 0), SourceVector3(0, -1, 0)] {
                let metrics = try XCTUnwrap(sky.selectionMetrics(worldCameraEye: eye,
                    cameraForward: direction, cameraUp: SourceVector3(0, 0, 1),
                    verticalFieldOfViewRadians: .pi / 2, aspectRatio: 4 / 3,
                    nearPlane: 32, farPlane: 1_000_000))
                counts.append(metrics.visibleIndexCount)
            }
            print("Sky terrain spawn \(map): eye=\(eye) selected=\(counts)")
            XCTAssertTrue(counts.allSatisfy { $0 > 1_000 }, "authored terrain must survive in every cardinal view")
        }
    }

    func testFlatgrassUnreferencedDisplacementsAreBakedIntoSkyOnly() throws {
        let bsp = try SourceBSP(data: GModGameAssets.data(for: .flatgrass, kind: .bsp))
        let mesh = try GModWorldRenderMesh.build(from: bsp)
        let sky = try XCTUnwrap(mesh.sky3D)
        // Independent fixture evidence: none of these sixteen authored terrain
        // faces has an ordinary leaf-face reference, despite being in area 2.
        XCTAssertEqual(bsp.displacementInfo.count, 16)
        for displacement in bsp.displacementInfo {
            XCTAssertFalse(bsp.leafFaces.contains(displacement.mapFaceIndex))
            let p = displacement.startPosition
            let leaf = try bsp.leafIndex(containing: SourceVector3(p.x, p.y, p.z + 1))
            XCTAssertEqual(bsp.leaves[leaf].area, sky.area)
        }
        let ranges = mesh.materialRanges.filter(\.isDisplacement)
        XCTAssertEqual(Set(ranges.map(\.renderLayer)), [.sky3D])
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.indexCount }, 24_576)
        let visibility = try XCTUnwrap(mesh.sky3DVisibility)
        let spans = visibility.bspVisibility.spans.filter {
            mesh.materialRanges[$0.materialRangeIndex].isDisplacement
        }
        XCTAssertEqual(spans.count, 16)
        XCTAssertTrue(spans.allSatisfy { $0.clusterCount > 0 })
        // A corner remains authored terrain, but its position must be baked
        // relative to sky_camera, not left below the normal playable map.
        let d = bsp.displacementInfo[0]
        let v = bsp.displacementVertices[Int(d.firstVertex)]
        let source = SourceVector3(d.startPosition.x, d.startPosition.y, d.startPosition.z)
            + SourceVector3(v.vector.x, v.vector.y, v.vector.z) * v.distance
        let expected = (source - sky.origin) * sky.scale
        XCTAssertTrue(mesh.vertices.contains { ($0.position - expected).lengthSquared < 0.01 })
        XCTAssertFalse(mesh.vertices.contains { ($0.position - source).lengthSquared < 0.01 })
    }

    func testBundledMapsBuildSkyCameraPVSAndBakedFrustumSpans() throws {
        for map in GModBundledMap.allCases {
            let bsp = try SourceBSP(
                data: GModGameAssets.data(for: map, kind: .bsp)
            )
            let mesh = try GModWorldRenderMesh.build(from: bsp)
            let sky = try XCTUnwrap(mesh.sky3D)
            let visibility = try XCTUnwrap(mesh.sky3DVisibility)

            XCTAssertEqual(visibility.sourceVisibilityOrigin, sky.origin)
            XCTAssertEqual(visibility.scale, 16)
            XCTAssertEqual(
                visibility.sourceCameraEye(
                    forWorldEye: SourceVector3(160, -32, 48)
                ),
                sky.origin + SourceVector3(10, -2, 3)
            )

            let authoredSkyIndexCount = mesh.materialRanges.reduce(0) {
                guard $1.renderLayer == .sky3D,
                      $1.waterSurface == nil else { return $0 }
                return $0 + $1.indexCount
            }
            XCTAssertGreaterThan(authoredSkyIndexCount, 0)
            XCTAssertEqual(
                visibility.bspVisibility.spans.reduce(0) {
                    $0 + $1.indexCount
                },
                authoredSkyIndexCount
            )

            let metrics = try XCTUnwrap(visibility.selectionMetrics(
                worldCameraEye: .zero,
                cameraForward: SourceVector3(1, 0, 0),
                cameraUp: SourceVector3(0, 0, 1),
                verticalFieldOfViewRadians: .pi / 2,
                aspectRatio: 4.0 / 3.0,
                nearPlane: 32,
                farPlane: 1_000_000
            ))
            XCTAssertEqual(metrics.sourceIndexCount, authoredSkyIndexCount)
            XCTAssertLessThanOrEqual(
                metrics.visibleIndexCount,
                metrics.sourceIndexCount
            )
            XCTAssertLessThanOrEqual(
                metrics.drawSpanCount,
                metrics.visibleSpanCount
            )
        }
    }

    func testConstructPakRetainsAuthoredTerrainVMTAndVTFMipLOD() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )
        let pak = try SourceBSPPakFileSystem(bsp: bsp)

        let materialPath =
            "materials/maps/gm_construct/gm_construct/grass_13_wvt_patch.vmt"
        let materialData = try XCTUnwrap(pak.data(for: materialPath))
        let materialSource = try XCTUnwrap(
            String(data: materialData, encoding: .utf8)
        )
        let material = try SourceVMTDocument.parse(
            source: materialSource,
            sourceName: materialPath
        )
        XCTAssertEqual(material.shader, "LightmappedGeneric")
        XCTAssertEqual(
            try material.string(named: "$basetexture"),
            "gm_construct/grass1"
        )
        XCTAssertEqual(
            try material.string(named: "$detail"),
            "gm_construct/grass_clouds"
        )
        XCTAssertEqual(try material.number(named: "$detailscale"), 0.12)
        XCTAssertEqual(try material.number(named: "$detailblendfactor"), 0.5)

        let texturePath = "materials/maps/gm_construct/c1436_-571_-71.vtf"
        let texture = try SourceVTFFile(
            data: try XCTUnwrap(pak.data(for: texturePath))
        )
        XCTAssertEqual(texture.width, 32)
        XCTAssertEqual(texture.height, 32)
        XCTAssertEqual(texture.mipCount, 6)
        XCTAssertTrue(texture.flags.contains(.environmentMap))
        XCTAssertFalse(texture.flags.contains(.noMip))
        XCTAssertEqual(
            try (0..<texture.mipCount).map {
                let image = try texture.decodeRGBA8(mipLevel: $0)
                return [image.width, image.height]
            },
            [[32, 32], [16, 16], [8, 8], [4, 4], [2, 2], [1, 1]]
        )
    }
}

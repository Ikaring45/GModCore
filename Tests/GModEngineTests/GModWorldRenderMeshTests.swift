import XCTest
@testable import GModEngine
@testable import GModGameAssets
@testable import GModGameSession

final class GModWorldRenderMeshTests: XCTestCase {
    func testBundledMapsRetainDominantOrdinaryWorldRanges() throws {
        let expectations: [
            (map: GModBundledMap, worldIndices: Int, sky3DIndices: Int)
        ] = [
            (.construct, 120_570, 3_426),
            (.flatgrass, 36_042, 54),
        ]

        for expectation in expectations {
            let bsp = try SourceBSP(
                data: GModGameAssets.data(for: expectation.map, kind: .bsp)
            )
            let mesh = try GModWorldRenderMesh.build(from: bsp)
            let worldIndices = mesh.materialRanges
                .filter { $0.renderLayer == .world }
                .reduce(0) { $0 + $1.indexCount }
            let sky3DIndices = mesh.materialRanges
                .filter { $0.renderLayer == .sky3D }
                .reduce(0) { $0 + $1.indexCount }

            XCTAssertEqual(worldIndices, expectation.worldIndices)
            XCTAssertEqual(sky3DIndices, expectation.sky3DIndices)
            XCTAssertGreaterThan(worldIndices, sky3DIndices * 20)
            XCTAssertGreaterThan(worldIndices / 3, 1_000)
            XCTAssertTrue(mesh.materialRanges.contains {
                $0.renderLayer == .world && $0.indexCount > 0
            })
        }
    }

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
        XCTAssertEqual(mesh.diagnostics.skySurfaceFaceCount, 2_411)
        XCTAssertEqual(mesh.diagnostics.skippedToolFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.cubemapBaseFallbackFaceCount, 2_402)
        XCTAssertEqual(mesh.diagnostics.cubemapBaseFallbackMaterialCount, 152)
        XCTAssertEqual(mesh.diagnostics.cubemapBaseFallbackTargetMaterialCount, 16)
        XCTAssertEqual(mesh.diagnostics.lightmappedFaceCount, 6_887)
        XCTAssertEqual(mesh.diagnostics.unlightmappedFaceCount, 65)
        XCTAssertEqual(mesh.diagnostics.ignoredAdditionalLightStyleFaceCount, 2_438)
        XCTAssertEqual(mesh.diagnostics.ignoredBumpLightFaceCount, 2_767)
        XCTAssertEqual(mesh.vertices.count, 46_686)
        XCTAssertEqual(mesh.triangleCount, 41_344)
        XCTAssertEqual(mesh.indices.count, 124_032)
        XCTAssertEqual(bsp.displacementInfo.count, 110)
        XCTAssertEqual(bsp.displacementVertices.count, 12_638)
        XCTAssertEqual(bsp.displacementTriangles.count, 20_992)
        XCTAssertEqual(
            bsp.displacementInfo.reduce(0) { $0 + $1.vertexCount },
            bsp.displacementVertices.count
        )
        XCTAssertEqual(
            bsp.displacementInfo.reduce(0) { $0 + $1.triangleCount },
            bsp.displacementTriangles.count
        )
        XCTAssertGreaterThan(
            bsp.displacementVertices.map {
                ($0.vector.x * $0.vector.x + $0.vector.y * $0.vector.y +
                    $0.vector.z * $0.vector.z).squareRoot()
            }.max() ?? 0,
            7,
            "VBSP direct offset vectors prove the field must not be normalized"
        )
        XCTAssertEqual(mesh.diagnostics.emittedDisplacementVertexCount, 12_638)
        XCTAssertEqual(mesh.diagnostics.emittedDisplacementTriangleCount, 20_992)
        XCTAssertEqual(mesh.diagnostics.removedDisplacementTriangleCount, 0)
        XCTAssertEqual(
            mesh.diagnostics.maximumDisplacementOffsetFromBase,
            1_285.72998,
            accuracy: 0.001
        )
        XCTAssertTrue(mesh.diagnostics.displacementCollisionIsBrushOnly)
        XCTAssertEqual(mesh.diagnostics.waterSurfaceFaceCount, 60)
        XCTAssertEqual(mesh.diagnostics.waterBelowSurfaceFaceCount, 30)
        XCTAssertEqual(bsp.textureNames.count, 204)
        XCTAssertEqual(try bsp.worldspawnValue(forKey: "skyname"), "painted")
        XCTAssertEqual(bsp.lighting.byteCount, 12_274_916)
        XCTAssertEqual(bsp.lightingHDR.byteCount, 12_274_916)
        XCTAssertEqual(bsp.facesHDR, bsp.faces)
        XCTAssertEqual(
            bsp.textureName(forTextureDataIndex: 0),
            "BUILDING_TEMPLATE/ROOF_TEMPLATE001A"
        )
        XCTAssertTrue(
            mesh.materialRanges.contains {
                $0.materialName == "gm_construct/construct_concrete_ground"
            }
        )
        let fallbackRange = try XCTUnwrap(
            mesh.materialRanges.first {
                $0.materialName == "building_template/building_template007b"
            }
        )
        XCTAssertTrue(
            fallbackRange.sourceMaterialNames.contains(
                "maps/gm_construct/building_template/building_template007b_832_-448_-96"
            )
        )
        assertPaintedSkybox(mesh, sourceSurfaceCount: 2_411)
        assertConstructSky3D(bsp: bsp, mesh: mesh)
        assertConstructFaceZeroSourceSemantics(bsp: bsp, mesh: mesh)
        assertFirstDisplacementSourceSemantics(bsp: bsp, mesh: mesh)
        assertRealHDRLightmapContract(bsp)
        assertLightmapAtlas(
            mesh,
            width: 2_048,
            height: 1_410,
            byteCount: 23_101_440
        )
        assertAllIndicesAreInBounds(mesh)
        assertFiniteOrderedBounds(mesh)
        assertMaterialRangesAndTextureCoordinates(mesh)
        let waterRanges = mesh.materialRanges.filter { $0.waterSurface != nil }
        XCTAssertEqual(waterRanges.count, 2)
        XCTAssertEqual(
            Set(waterRanges.compactMap(\.materialName)),
            Set(["gm_construct/water_13", "gm_construct/water_13_beneath"])
        )
        XCTAssertEqual(waterRanges.reduce(0) { $0 + $1.indexCount }, 136 * 3)
        XCTAssertTrue(waterRanges.allSatisfy {
            $0.waterSurface?.surfaceZ == -160 &&
                $0.waterSurface?.minimumZ == -960
        })
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
        XCTAssertEqual(mesh.diagnostics.skySurfaceFaceCount, 1_265)
        XCTAssertEqual(mesh.diagnostics.skippedToolFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.cubemapBaseFallbackFaceCount, 160)
        XCTAssertEqual(mesh.diagnostics.cubemapBaseFallbackMaterialCount, 9)
        XCTAssertEqual(mesh.diagnostics.cubemapBaseFallbackTargetMaterialCount, 2)
        XCTAssertEqual(mesh.diagnostics.lightmappedFaceCount, 1_648)
        XCTAssertEqual(mesh.diagnostics.unlightmappedFaceCount, 9)
        XCTAssertEqual(mesh.diagnostics.ignoredAdditionalLightStyleFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.ignoredBumpLightFaceCount, 319)
        XCTAssertEqual(mesh.vertices.count, 11_770)
        XCTAssertEqual(mesh.triangleCount, 12_044)
        XCTAssertEqual(mesh.indices.count, 36_132)
        XCTAssertEqual(bsp.displacementInfo.count, 16)
        XCTAssertEqual(bsp.displacementVertices.count, 4_624)
        XCTAssertEqual(bsp.displacementTriangles.count, 8_192)
        XCTAssertEqual(
            bsp.displacementInfo.reduce(0) { $0 + $1.vertexCount },
            bsp.displacementVertices.count
        )
        XCTAssertEqual(
            bsp.displacementInfo.reduce(0) { $0 + $1.triangleCount },
            bsp.displacementTriangles.count
        )
        XCTAssertEqual(mesh.diagnostics.emittedDisplacementVertexCount, 4_624)
        XCTAssertEqual(mesh.diagnostics.emittedDisplacementTriangleCount, 8_192)
        XCTAssertEqual(mesh.diagnostics.removedDisplacementTriangleCount, 0)
        XCTAssertEqual(
            mesh.diagnostics.maximumDisplacementOffsetFromBase,
            649.83197,
            accuracy: 0.001
        )
        XCTAssertTrue(mesh.diagnostics.displacementCollisionIsBrushOnly)
        XCTAssertEqual(mesh.diagnostics.waterSurfaceFaceCount, 0)
        XCTAssertEqual(mesh.diagnostics.waterBelowSurfaceFaceCount, 0)
        XCTAssertEqual(bsp.textureNames.count, 18)
        XCTAssertEqual(try bsp.worldspawnValue(forKey: "skyname"), "painted")
        XCTAssertEqual(bsp.lighting.byteCount, 1_312_924)
        XCTAssertEqual(bsp.lightingHDR.byteCount, 1_312_924)
        XCTAssertEqual(bsp.facesHDR, bsp.faces)
        XCTAssertEqual(
            bsp.textureName(forTextureDataIndex: 2),
            "GM_CONSTRUCT/FLATGRASS"
        )
        XCTAssertTrue(
            mesh.materialRanges.contains {
                $0.materialName == "gm_construct/flatgrass"
            }
        )
        assertPaintedSkybox(mesh, sourceSurfaceCount: 1_265)
        assertFirstDisplacementSourceSemantics(bsp: bsp, mesh: mesh)
        assertRealHDRLightmapContract(bsp)
        assertLightmapAtlas(
            mesh,
            width: 2_048,
            height: 351,
            byteCount: 5_750_784
        )
        assertAllIndicesAreInBounds(mesh)
        assertFiniteOrderedBounds(mesh)
        assertMaterialRangesAndTextureCoordinates(mesh)
    }

    func testDisplacementUsesSourceRecursiveLeafWinding() {
        XCTAssertEqual(
            Array(GModWorldRenderMesh.displacementTriangleIndices(power: 2).prefix(24)),
            [
                0, 5, 6, 1, 0, 6, 2, 1, 6, 7, 2, 6,
                12, 7, 6, 11, 12, 6, 10, 11, 6, 5, 10, 6,
            ]
        )
    }

    func testSkyVisibilityUsesSourceLeafFlags() {
        let visibility = GModWorldSkyVisibility(
            headNode: 0,
            planes: [GModWorldSkyVisibilityPlane(
                normal: SourceVector3(1, 0, 0),
                distance: 0
            )],
            nodes: [GModWorldSkyVisibilityNode(
                planeIndex: 0,
                frontChild: -1,
                backChild: -2
            )],
            leafFlags: [0x01, 0x04]
        )

        XCTAssertEqual(
            visibility.visibility(at: SourceVector3(1, 0, 0)),
            .sky3D
        )
        XCTAssertEqual(
            visibility.visibility(at: SourceVector3(-1, 0, 0)),
            .sky2D
        )
    }

    func testSourcePotentialVisibilityDecodesLiteralAndZeroRun() throws {
        let clusterCount = 24
        let rowOffset = 4 + clusterCount * 8
        var data = Data()
        appendInt32(Int32(clusterCount), to: &data)
        for _ in 0..<clusterCount {
            appendInt32(Int32(rowOffset), to: &data)
            appendInt32(Int32(rowOffset), to: &data)
        }
        data.append(contentsOf: [0x01, 0x00, 0x01, 0x02])

        let visibility = try XCTUnwrap(
            GModSourcePotentialVisibility(data: data)
        )
        XCTAssertEqual(
            visibility.visibleClusters(from: 0),
            Set([0, 17])
        )
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
        XCTAssertTrue(
            mesh.vertices.contains { $0.lightmapCoordinate != nil },
            file: file,
            line: line
        )
        XCTAssertTrue(
            mesh.vertices.allSatisfy { vertex in
                guard let coordinate = vertex.lightmapCoordinate else { return true }
                return coordinate.u.isFinite && coordinate.v.isFinite
            },
            file: file,
            line: line
        )
    }

    private func assertPaintedSkybox(
        _ mesh: GModWorldRenderMesh,
        sourceSurfaceCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let skybox = mesh.skybox else {
            XCTFail("expected painted skybox metadata", file: file, line: line)
            return
        }
        XCTAssertEqual(skybox.name, "painted", file: file, line: line)
        XCTAssertEqual(
            skybox.sourceSkySurfaceCount,
            sourceSurfaceCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(skybox.materialNames),
            Set([
                "skybox/paintedrt", "skybox/paintedbk", "skybox/paintedlf",
                "skybox/paintedft", "skybox/paintedup", "skybox/painteddn",
            ]),
            file: file,
            line: line
        )

        let skyRanges = mesh.materialRanges.filter {
            $0.materialName?.hasPrefix("skybox/painted") == true
        }
        XCTAssertEqual(skyRanges.count, 6, file: file, line: line)
        XCTAssertTrue(
            skyRanges.allSatisfy {
                $0.indexCount == 6 && $0.renderLayer == .sky2D
            },
            file: file,
            line: line
        )
        guard mesh.vertices.count >= 24 else { return }
        let firstSkyVertex = mesh.vertices.count - 24
        for vertex in mesh.vertices[firstSkyVertex...] {
            let dot = vertex.position.x * vertex.normal.x +
                vertex.position.y * vertex.normal.y +
                vertex.position.z * vertex.normal.z
            XCTAssertEqual(dot, -1_024, accuracy: 0.001, file: file, line: line)
            XCTAssertTrue(
                vertex.textureCoordinate.u == 0 || vertex.textureCoordinate.u == 1,
                file: file,
                line: line
            )
            XCTAssertTrue(
                vertex.textureCoordinate.v == 0 || vertex.textureCoordinate.v == 1,
                file: file,
                line: line
            )
            XCTAssertNil(vertex.lightmapCoordinate, file: file, line: line)
        }
        for range in skyRanges {
            let i0 = Int(mesh.indices[range.firstIndex])
            let i1 = Int(mesh.indices[range.firstIndex + 1])
            let i2 = Int(mesh.indices[range.firstIndex + 2])
            let p0 = mesh.vertices[i0].position
            let p1 = mesh.vertices[i1].position
            let p2 = mesh.vertices[i2].position
            let a = SourceVector3(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
            let b = SourceVector3(p2.x - p0.x, p2.y - p0.y, p2.z - p0.z)
            let cross = SourceVector3(
                a.y * b.z - a.z * b.y,
                a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x
            )
            let normal = mesh.vertices[i0].normal
            XCTAssertGreaterThan(
                cross.x * normal.x + cross.y * normal.y + cross.z * normal.z,
                0,
                "skybox triangle winding must face the camera inside the cube",
                file: file,
                line: line
            )
        }
    }

    private func assertConstructSky3D(
        bsp: SourceBSP,
        mesh: GModWorldRenderMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let sky = mesh.sky3D else {
            XCTFail("expected real sky_camera metadata", file: file, line: line)
            return
        }
        XCTAssertEqual(sky.origin, SourceVector3(-1_428, 1_645, 10_991.2))
        XCTAssertEqual(sky.scale, 16)
        XCTAssertEqual(sky.area, 1)
        XCTAssertEqual(sky.cluster, 0)
        XCTAssertGreaterThan(sky.sourceFaceCount, 0)
        guard let pvs = GModSourcePotentialVisibility(data: bsp.lumps[4].data),
              let visibleClusters = pvs.visibleClusters(from: Int(sky.cluster)) else {
            XCTFail("expected real sky-camera PVS", file: file, line: line)
            return
        }
        var expectedVisibleFaces = Set<Int>()
        for leaf in bsp.leaves where
            leaf.area == sky.area &&
            leaf.cluster >= 0 &&
            visibleClusters.contains(Int(leaf.cluster)) {
            let first = Int(leaf.firstLeafFace)
            let end = first + Int(leaf.leafFaceCount)
            for index in first..<end where bsp.leafFaces.indices.contains(index) {
                expectedVisibleFaces.insert(Int(bsp.leafFaces[index]))
            }
        }
        XCTAssertEqual(
            sky.sourceFaceCount,
            expectedVisibleFaces.count,
            "sky-camera geometry must come from its cluster PVS, not area union",
            file: file,
            line: line
        )

        guard let visibility = mesh.skyVisibility else {
            XCTFail("expected Source leaf sky visibility", file: file, line: line)
            return
        }
        XCTAssertEqual(
            visibility.visibility(at: SourceVector3(704, 132, -79)),
            .sky3D,
            file: file,
            line: line
        )

        let miniatureRanges = mesh.materialRanges.filter {
            $0.renderLayer == .sky3D
        }
        XCTAssertFalse(miniatureRanges.isEmpty, file: file, line: line)
        XCTAssertTrue(miniatureRanges.contains {
            $0.materialName == "gm_construct/flatgrass"
        })
        XCTAssertTrue(mesh.materialRanges.contains {
            $0.renderLayer == .world &&
                $0.materialName == "gm_construct/flatgrass"
        })
        XCTAssertTrue(miniatureRanges.allSatisfy {
            $0.firstIndex >= 0 &&
                $0.firstIndex + $0.indexCount <= mesh.indices.count
        })
    }

    private func appendInt32(_ value: Int32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func assertConstructFaceZeroSourceSemantics(
        bsp: SourceBSP,
        mesh: GModWorldRenderMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let face = bsp.faces[0]
        XCTAssertEqual(face.side, 1, file: file, line: line)
        let info = bsp.textureInfo[Int(face.textureInfoIndex)]
        let data = bsp.textureData[Int(info.textureDataIndex)]
        XCTAssertEqual(data.width, 512, file: file, line: line)
        XCTAssertEqual(data.height, 512, file: file, line: line)
        XCTAssertEqual(
            bsp.textureName(forTextureDataIndex: Int(info.textureDataIndex)),
            "maps/gm_construct/building_template/building_template007b_832_-448_-96",
            file: file,
            line: line
        )
        let plane = bsp.planes[Int(face.planeIndex)]
        XCTAssertEqual(mesh.vertices[0].normal.x, -plane.normal.x, file: file, line: line)
        XCTAssertEqual(mesh.vertices[0].normal.y, -plane.normal.y, file: file, line: line)
        XCTAssertEqual(mesh.vertices[0].normal.z, -plane.normal.z, file: file, line: line)
        XCTAssertEqual(mesh.vertices[0].textureCoordinate.u, -12, accuracy: 0.0001)
        XCTAssertEqual(mesh.vertices[0].textureCoordinate.v, -1, accuracy: 0.0001)

        let first = Int(face.firstSurfaceEdge)
        for offset in 0..<Int(face.surfaceEdgeCount) {
            let signedEdge = bsp.surfaceEdges[first + offset]
            let edge = bsp.edges[Int(abs(Int64(signedEdge)))]
            let vertexIndex = signedEdge >= 0
                ? Int(edge.firstVertex)
                : Int(edge.secondVertex)
            let point = bsp.vertices[vertexIndex].point
            let emitted = mesh.vertices[offset]
            XCTAssertEqual(
                emitted.position,
                SourceVector3(point.x, point.y, point.z),
                "negative surfedges must select edge.v[1]",
                file: file,
                line: line
            )
            let expectedS = point.x * info.textureVectors[0].x +
                point.y * info.textureVectors[0].y +
                point.z * info.textureVectors[0].z +
                info.textureVectors[0].offset
            let expectedT = point.x * info.textureVectors[1].x +
                point.y * info.textureVectors[1].y +
                point.z * info.textureVectors[1].z +
                info.textureVectors[1].offset
            XCTAssertEqual(
                emitted.textureCoordinate.u,
                expectedS / Float(data.width),
                accuracy: 0.0001,
                "face.side changes the normal, not texinfo UV orientation",
                file: file,
                line: line
            )
            XCTAssertEqual(
                emitted.textureCoordinate.v,
                expectedT / Float(data.height),
                accuracy: 0.0001,
                file: file,
                line: line
            )
        }
    }

    private func assertFirstDisplacementSourceSemantics(
        bsp: SourceBSP,
        mesh: GModWorldRenderMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let faceIndex = bsp.faces.indices.first(where: {
            bsp.faces[$0].displacementInfoIndex >= 0
        }), let displacement = bsp.displacement(forFaceAt: faceIndex) else {
            XCTFail("expected a real displacement face", file: file, line: line)
            return
        }
        let face = bsp.faces[faceIndex]
        let firstSurfaceEdge = Int(face.firstSurfaceEdge)
        let points = (0..<Int(face.surfaceEdgeCount)).map { offset -> SourceVector3 in
            let signedEdge = bsp.surfaceEdges[firstSurfaceEdge + offset]
            let edge = bsp.edges[Int(abs(Int64(signedEdge)))]
            let vertexIndex = signedEdge >= 0
                ? Int(edge.firstVertex)
                : Int(edge.secondVertex)
            let point = bsp.vertices[vertexIndex].point
            return SourceVector3(point.x, point.y, point.z)
        }
        guard points.count == 4 else {
            XCTFail("displacement base face must be a quad", file: file, line: line)
            return
        }
        let start = SourceVector3(
            displacement.startPosition.x,
            displacement.startPosition.y,
            displacement.startPosition.z
        )
        let startCorner = points.indices.min {
            (points[$0] - start).lengthSquared <
                (points[$1] - start).lengthSquared
        } ?? 0
        let corners = (0..<4).map { points[(startCorner + $0) & 3] }
        let sideLength = displacement.sideLength
        let firstDispVertex = Int(displacement.firstVertex)

        func expectedPosition(flat: SourceVector3, localIndex: Int) -> SourceVector3 {
            let source = bsp.displacementVertices[firstDispVertex + localIndex]
            let field = SourceVector3(
                source.vector.x,
                source.vector.y,
                source.vector.z
            )
            return flat + field * source.distance
        }
        func expectedTextureUV(flat: SourceVector3) -> GModWorldTextureCoordinate {
            let info = bsp.textureInfo[Int(face.textureInfoIndex)]
            let data = bsp.textureData[Int(info.textureDataIndex)]
            let s = flat.x * info.textureVectors[0].x +
                flat.y * info.textureVectors[0].y +
                flat.z * info.textureVectors[0].z +
                info.textureVectors[0].offset
            let t = flat.x * info.textureVectors[1].x +
                flat.y * info.textureVectors[1].y +
                flat.z * info.textureVectors[1].z +
                info.textureVectors[1].offset
            return GModWorldTextureCoordinate(
                u: s / Float(data.width),
                v: t / Float(data.height)
            )
        }
        func emittedVertex(
            flat: SourceVector3,
            localIndex: Int
        ) -> GModWorldRenderVertex? {
            let position = expectedPosition(flat: flat, localIndex: localIndex)
            let uv = expectedTextureUV(flat: flat)
            return mesh.vertices.first { vertex in
                abs(vertex.position.x - position.x) < 0.0001 &&
                    abs(vertex.position.y - position.y) < 0.0001 &&
                    abs(vertex.position.z - position.z) < 0.0001 &&
                    abs(vertex.textureCoordinate.u - uv.u) < 0.0001 &&
                    abs(vertex.textureCoordinate.v - uv.v) < 0.0001
            }
        }

        guard let lowerLeft = emittedVertex(flat: corners[0], localIndex: 0),
              let lowerRight = emittedVertex(
                flat: corners[3],
                localIndex: sideLength - 1
              ),
              let upperLeft = emittedVertex(
                flat: corners[1],
                localIndex: sideLength * (sideLength - 1)
              ) else {
            XCTFail(
                "expected oriented real displacement corner vertices",
                file: file,
                line: line
            )
            return
        }
        let rawField = bsp.displacementVertices[firstDispVertex]
        let rawVector = SourceVector3(
            rawField.vector.x,
            rawField.vector.y,
            rawField.vector.z
        )
        XCTAssertEqual(
            lowerLeft.position,
            corners[0] + rawVector * rawField.distance,
            "the direct VBSP field must not be normalized",
            file: file,
            line: line
        )

        guard let lightmap = bsp.lightmap(forFaceAt: faceIndex),
              let atlas = mesh.lightmapAtlas,
              let lowerLeftLM = lowerLeft.lightmapCoordinate,
              let lowerRightLM = lowerRight.lightmapCoordinate,
              let upperLeftLM = upperLeft.lightmapCoordinate else {
            XCTFail("expected displacement lightmap coordinates", file: file, line: line)
            return
        }
        XCTAssertEqual(
            lowerRightLM.u - lowerLeftLM.u,
            Float(lightmap.width - 1) / Float(atlas.width),
            accuracy: 0.000001,
            "displacement luxels interpolate the oriented grid corners",
            file: file,
            line: line
        )
        XCTAssertEqual(
            upperLeftLM.v - lowerLeftLM.v,
            Float(lightmap.height - 1) / Float(atlas.height),
            accuracy: 0.000001,
            file: file,
            line: line
        )
    }

    private func assertRealHDRLightmapContract(
        _ bsp: SourceBSP,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let faceIndex = bsp.faces.indices.first(where: {
            bsp.lightmap(forFaceAt: $0) != nil
        }), let lightmap = bsp.lightmap(forFaceAt: faceIndex) else {
            XCTFail("expected at least one bounded real-map lightmap", file: file, line: line)
            return
        }
        XCTAssertEqual(lightmap.kind, .highDynamicRange, file: file, line: line)
        XCTAssertGreaterThan(lightmap.width, 0, file: file, line: line)
        XCTAssertGreaterThan(lightmap.height, 0, file: file, line: line)
        XCTAssertGreaterThan(lightmap.styleCount, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(lightmap.encodedByteOffset, 0, file: file, line: line)
        XCTAssertNotNil(lightmap.sample(x: 0, y: 0), file: file, line: line)
    }

    private func assertLightmapAtlas(
        _ mesh: GModWorldRenderMesh,
        width: Int,
        height: Int,
        byteCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            mesh.diagnostics.lightmapAtlasStatus,
            .built(width: width, height: height, byteCount: byteCount),
            file: file,
            line: line
        )
        guard let atlas = mesh.lightmapAtlas else {
            XCTFail("expected a bounded real-map lightmap atlas", file: file, line: line)
            return
        }
        XCTAssertEqual(atlas.width, width, file: file, line: line)
        XCTAssertEqual(atlas.height, height, file: file, line: line)
        XCTAssertEqual(atlas.linearRGBA16Float.count, byteCount, file: file, line: line)
        XCTAssertEqual(atlas.clampedChannelCount, 0, file: file, line: line)
        XCTAssertEqual(
            Array(atlas.linearRGBA16Float.prefix(8)),
            [0, 60, 0, 60, 0, 60, 0, 60],
            "the reserved unlit texel must be linear white RGBA16Float",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(atlas.unlitTextureCoordinate.u, 0, file: file, line: line)
        XCTAssertGreaterThan(atlas.unlitTextureCoordinate.v, 0, file: file, line: line)
        let hasPreservedHDRSample = stride(
            from: 0,
            to: atlas.linearRGBA16Float.count,
            by: 8 * 97
        ).contains { texelOffset in
            (0..<3).contains { channel in
                let offset = texelOffset + channel * 2
                guard offset + 1 < atlas.linearRGBA16Float.count else { return false }
                let bits = UInt16(atlas.linearRGBA16Float[offset]) |
                    UInt16(atlas.linearRGBA16Float[offset + 1]) << 8
                return Float(Float16(bitPattern: bits)) > 1
            }
        }
        XCTAssertTrue(
            hasPreservedHDRSample,
            "RGBA16Float atlas must preserve real samples above one",
            file: file,
            line: line
        )
        XCTAssertTrue(
            mesh.vertices.allSatisfy { vertex in
                guard let coordinate = vertex.lightmapCoordinate else { return true }
                return coordinate.u >= 0 && coordinate.u <= 1 &&
                    coordinate.v >= 0 && coordinate.v <= 1
            },
            file: file,
            line: line
        )
    }
}

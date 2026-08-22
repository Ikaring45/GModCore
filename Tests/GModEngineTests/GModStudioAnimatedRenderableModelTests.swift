import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModStudioAnimatedRenderableModelTests: XCTestCase {
    private let checksum: Int32 = 0x2468_1357
    private let modelName = "models/codex/skinning_golden.mdl"

    func testSkinsPositionNormalAndTangentFromAuthoredSequenceFrame() throws {
        let mdl = makeAnimationMDL()
        let studio = try SourceStudioModel(data: mdl)
        let animation = try SourceStudioAnimationDecoder.decode(mdlData: mdl)
        let source = makeSourceMesh()
        let renderable = makeRenderable(vertices: selectedVertices())

        let snapshot = try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: renderable,
            sourceMesh: source,
            studioModel: studio,
            animationModel: animation,
            sequenceIndex: 0,
            blendIndex: 0,
            frame: 12
        )

        XCTAssertEqual(snapshot.sequenceIndex, 0)
        XCTAssertEqual(snapshot.blendIndex, 0)
        XCTAssertEqual(snapshot.animationIndex, 0)
        XCTAssertEqual(snapshot.frame, 12)
        XCTAssertEqual(snapshot.boneModelTransforms.count, 2)
        assertVector(snapshot.boneModelTransforms[1].position, SourceVector3(10, 0, 0))

        assertVector(snapshot.vertices[0].position, SourceVector3(0, 0, 0))
        assertVector(snapshot.vertices[0].normal, SourceVector3(1, 0, 0))

        // childBoneToModel * childPoseToBone rotates around the bind joint at X=10.
        assertVector(
            snapshot.vertices[1].position,
            SourceVector3(10, 1, 0),
            accuracy: 0.001
        )
        assertVector(
            snapshot.vertices[1].normal,
            SourceVector3(0, 1, 0),
            accuracy: 0.001
        )
        let childTangent = try XCTUnwrap(snapshot.vertices[1].tangent)
        assertVector(
            SourceVector3(childTangent.x, childTangent.y, childTangent.z),
            SourceVector3(-1, 0, 0),
            accuracy: 0.001
        )
        XCTAssertEqual(childTangent.w, -1)

        // Equal canonical VVD influences linearly blend the two skin matrices.
        assertVector(
            snapshot.vertices[2].position,
            SourceVector3(11, 1, 0),
            accuracy: 0.001
        )
        let diagonal = Float(0.5).squareRoot()
        assertVector(
            snapshot.vertices[2].normal,
            SourceVector3(diagonal, diagonal, 0),
            accuracy: 0.001
        )
        let blendedTangent = try XCTUnwrap(snapshot.vertices[2].tangent)
        assertVector(
            SourceVector3(blendedTangent.x, blendedTangent.y, blendedTangent.z),
            SourceVector3(-diagonal, diagonal, 0),
            accuracy: 0.001
        )
        XCTAssertEqual(blendedTangent.w, -1)
    }

    func testPreservesLODSelectedBodygroupIndicesAndMaterialRanges() throws {
        let mdl = makeAnimationMDL()
        let material = makeMaterial()
        let renderable = makeRenderable(vertices: selectedVertices(), material: material)

        let snapshot = try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: renderable,
            sourceMesh: makeSourceMesh(),
            studioModel: SourceStudioModel(data: mdl),
            animationModel: SourceStudioAnimationDecoder.decode(mdlData: mdl),
            sequenceIndex: 0,
            blendIndex: 0,
            frame: 29
        )

        XCTAssertEqual(snapshot.checksum, checksum)
        XCTAssertEqual(snapshot.modelName, modelName)
        XCTAssertEqual(snapshot.lodIndex, 2)
        XCTAssertEqual(snapshot.bodyValue, 1)
        XCTAssertEqual(snapshot.skinFamilyIndex, 3)
        XCTAssertEqual(snapshot.indices, [0, 1, 2])
        XCTAssertEqual(snapshot.drawRanges, renderable.drawRanges)
        XCTAssertEqual(snapshot.drawRanges.first?.submodelIndex, 1)
        XCTAssertEqual(snapshot.drawRanges.first?.material, material)
        XCTAssertEqual(snapshot.vertices.map(\.textureCoordinate),
                       selectedVertices().map(\.textureCoordinate))
    }

    func testUnweightedVertexRemainsInAuthoredModelSpace() throws {
        var vertices = selectedVertices()
        vertices[1] = makeVertex(
            index: 1,
            position: SourceVector3(11, 0, 0),
            influences: []
        )
        let mdl = makeAnimationMDL()
        let snapshot = try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: makeRenderable(vertices: vertices),
            sourceMesh: makeSourceMesh(selected: vertices),
            studioModel: SourceStudioModel(data: mdl),
            animationModel: SourceStudioAnimationDecoder.decode(mdlData: mdl),
            sequenceIndex: 0,
            blendIndex: 0,
            frame: 7
        )

        assertVector(snapshot.vertices[1].position, SourceVector3(11, 0, 0))
        assertVector(snapshot.vertices[1].normal, SourceVector3(1, 0, 0))
        XCTAssertEqual(snapshot.vertices[1].tangent, vertices[1].tangent)
    }

    func testRejectsMismatchedGeometryIdentityLODAndFlatteningOrder() throws {
        let mdl = makeAnimationMDL()
        let studio = try SourceStudioModel(data: mdl)
        let animation = try SourceStudioAnimationDecoder.decode(mdlData: mdl)
        let renderable = makeRenderable(vertices: selectedVertices())

        assertCompileError(
            renderable: renderable,
            source: makeSourceMesh(checksum: checksum + 1),
            studio: studio,
            animation: animation,
            equals: .checksumMismatch(
                input: .sourceMesh,
                expected: checksum,
                actual: checksum + 1
            )
        )
        assertCompileError(
            renderable: renderable,
            source: makeSourceMesh(lodIndex: 1),
            studio: studio,
            animation: animation,
            equals: .lodMismatch(expected: 2, actual: 1)
        )

        var wrongOrder = selectedVertices()
        wrongOrder.swapAt(0, 1)
        assertCompileError(
            renderable: makeRenderable(vertices: wrongOrder),
            source: makeSourceMesh(),
            studio: studio,
            animation: animation,
            equals: .vertexOrderMismatch(vertex: 0)
        )
    }

    func testRejectsInvalidWeightsBoneReferencesAndDirections() throws {
        let mdl = makeAnimationMDL()
        let studio = try SourceStudioModel(data: mdl)
        let animation = try SourceStudioAnimationDecoder.decode(mdlData: mdl)

        var invalidWeight = selectedVertices()
        invalidWeight[0] = makeVertex(
            index: 0,
            position: .zero,
            influences: [SourceStudioBoneInfluence(boneIndex: 0, weight: -1)]
        )
        assertCompileError(
            renderable: makeRenderable(vertices: invalidWeight),
            source: makeSourceMesh(selected: invalidWeight),
            studio: studio,
            animation: animation,
            equals: .invalidBoneWeight(vertex: 0, influence: 0, value: -1)
        )

        var invalidBone = selectedVertices()
        invalidBone[0] = makeVertex(
            index: 0,
            position: .zero,
            influences: [SourceStudioBoneInfluence(boneIndex: 2, weight: 1)]
        )
        assertCompileError(
            renderable: makeRenderable(vertices: invalidBone),
            source: makeSourceMesh(selected: invalidBone),
            studio: studio,
            animation: animation,
            equals: .invalidBoneInfluence(
                vertex: 0,
                influence: 0,
                bone: 2,
                boneCount: 2
            )
        )

        var zeroNormal = selectedVertices()
        zeroNormal[0] = makeVertex(
            index: 0,
            position: .zero,
            normal: .zero,
            influences: [SourceStudioBoneInfluence(boneIndex: 0, weight: 1)]
        )
        assertCompileError(
            renderable: makeRenderable(vertices: zeroNormal),
            source: makeSourceMesh(selected: zeroNormal),
            studio: studio,
            animation: animation,
            equals: .invalidSkinnedDirection(vertex: 0, direction: .normal)
        )
    }

    func testPropagatesCompressedAnimationAndBlendFailuresWithoutFallback() throws {
        var compressedBytes = bytes(of: makeAnimationMDL())
        compressedBytes[1_161] = 0x08 // STUDIO_ANIM_ANIMROT
        let compressedData = Data(compressedBytes)
        let compressedAnimation = try SourceStudioAnimationDecoder.decode(
            mdlData: compressedData
        )
        let studio = try SourceStudioModel(data: compressedData)
        let renderable = makeRenderable(vertices: selectedVertices())
        let source = makeSourceMesh()

        assertCompileError(
            renderable: renderable,
            source: source,
            studio: studio,
            animation: compressedAnimation,
            equals: .animation(.unsupported(.compressedBoneValues(
                animation: 0,
                bone: 1,
                flags: 0x08
            )))
        )

        XCTAssertThrowsError(try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: renderable,
            sourceMesh: source,
            studioModel: try SourceStudioModel(data: makeAnimationMDL()),
            animationModel: try SourceStudioAnimationDecoder.decode(
                mdlData: makeAnimationMDL()
            ),
            sequenceIndex: 0,
            blendIndex: 1,
            frame: 0
        )) { error in
            XCTAssertEqual(
                error as? GModStudioAnimatedRenderableModelError,
                .animation(.invalidBlendIndex(sequence: 0, value: 1, blendCount: 1))
            )
        }
    }
}

private extension GModStudioAnimatedRenderableModelTests {
    enum Offsets {
        static let rootBone = 408
        static let childBone = 624
        static let animation = 840
        static let sequence = 940
        static let blendTable = 1_152
        static let animationRecord = 1_160
    }

    func makeAnimationMDL() -> Data {
        var result = [UInt8](repeating: 0, count: 1_200)
        putUInt32(SourceStudioModel.magic, at: 0, into: &result)
        putInt32(48, at: 4, into: &result)
        putInt32(checksum, at: 8, into: &result)
        putFixedCString(modelName, at: 12, capacity: 64, into: &result)
        putInt32(2, at: 156, into: &result)
        putInt32(Int32(Offsets.rootBone), at: 160, into: &result)
        putInt32(1, at: 180, into: &result)
        putInt32(Int32(Offsets.animation), at: 184, into: &result)
        putInt32(1, at: 188, into: &result)
        putInt32(Int32(Offsets.sequence), at: 192, into: &result)

        let rootName = appendCString("root", to: &result)
        let childName = appendCString("child", to: &result)
        let surfaceName = appendCString("default", to: &result)
        let animationName = appendCString("turn_child", to: &result)
        let sequenceName = appendCString("turn_sequence", to: &result)
        let activityName = appendCString("ACT_IDLE", to: &result)

        writeBone(
            at: Offsets.rootBone,
            nameOffset: rootName,
            parent: -1,
            bindPosition: .zero,
            poseToBone: .identity,
            surfaceOffset: surfaceName,
            into: &result
        )
        writeBone(
            at: Offsets.childBone,
            nameOffset: childName,
            parent: 0,
            bindPosition: SourceVector3(10, 0, 0),
            poseToBone: SourceStudioQuaternion.identity.matrix(
                position: SourceVector3(-10, 0, 0)
            ),
            surfaceOffset: surfaceName,
            into: &result
        )

        putInt32(Int32(-Offsets.animation), at: Offsets.animation, into: &result)
        putInt32(
            Int32(animationName - Offsets.animation),
            at: Offsets.animation + 4,
            into: &result
        )
        putFloat(30, at: Offsets.animation + 8, into: &result)
        putInt32(30, at: Offsets.animation + 16, into: &result)
        putInt32(0, at: Offsets.animation + 52, into: &result)
        putInt32(
            Int32(Offsets.animationRecord - Offsets.animation),
            at: Offsets.animation + 56,
            into: &result
        )

        putInt32(Int32(-Offsets.sequence), at: Offsets.sequence, into: &result)
        putInt32(
            Int32(sequenceName - Offsets.sequence),
            at: Offsets.sequence + 4,
            into: &result
        )
        putInt32(
            Int32(activityName - Offsets.sequence),
            at: Offsets.sequence + 8,
            into: &result
        )
        putInt32(1, at: Offsets.sequence + 56, into: &result)
        putInt32(
            Int32(Offsets.blendTable - Offsets.sequence),
            at: Offsets.sequence + 60,
            into: &result
        )
        putInt32(1, at: Offsets.sequence + 68, into: &result)
        putInt32(1, at: Offsets.sequence + 72, into: &result)
        putFloat(29, at: Offsets.sequence + 132, into: &result)
        putInt32(-1, at: Offsets.sequence + 136, into: &result)
        putInt32(-1, at: Offsets.sequence + 140, into: &result)
        putInt16(0, at: Offsets.blendTable, into: &result)

        result[Offsets.animationRecord] = 1
        result[Offsets.animationRecord + 1] = 0x03 // RAWPOS | RAWROT
        putInt16(0, at: Offsets.animationRecord + 2, into: &result)
        putQuaternion48(
            SourceStudioQAngle(pitch: 0, yaw: 90, roll: 0).quaternion,
            at: Offsets.animationRecord + 4,
            into: &result
        )
        putVector48(
            x: 0x4900,
            y: 0,
            z: 0,
            at: Offsets.animationRecord + 10,
            into: &result
        )

        putInt32(Int32(result.count), at: 76, into: &result)
        return Data(result)
    }

    func writeBone(
        at base: Int,
        nameOffset: Int,
        parent: Int32,
        bindPosition: SourceVector3,
        poseToBone: SourceStudioMatrix3x4,
        surfaceOffset: Int,
        into bytes: inout [UInt8]
    ) {
        putInt32(Int32(nameOffset - base), at: base, into: &bytes)
        putInt32(parent, at: base + 4, into: &bytes)
        for index in 0..<6 {
            putInt32(-1, at: base + 8 + index * 4, into: &bytes)
        }
        putVector(bindPosition, at: base + 32, into: &bytes)
        putQuaternion(.identity, at: base + 44, into: &bytes)
        putMatrix(poseToBone, at: base + 96, into: &bytes)
        putQuaternion(.identity, at: base + 144, into: &bytes)
        putInt32(Int32(surfaceOffset - base), at: base + 176, into: &bytes)
    }

    func selectedVertices() -> [SourceStudioMeshVertexSnapshot] {
        [
            makeVertex(
                index: 0,
                position: .zero,
                influences: [SourceStudioBoneInfluence(boneIndex: 0, weight: 1)]
            ),
            makeVertex(
                index: 1,
                position: SourceVector3(11, 0, 0),
                influences: [SourceStudioBoneInfluence(boneIndex: 1, weight: 1)]
            ),
            makeVertex(
                index: 2,
                position: SourceVector3(12, 0, 0),
                influences: [
                    SourceStudioBoneInfluence(boneIndex: 0, weight: 0.5),
                    SourceStudioBoneInfluence(boneIndex: 1, weight: 0.5),
                ]
            ),
        ]
    }

    func makeVertex(
        index: Int,
        position: SourceVector3,
        normal: SourceVector3 = SourceVector3(1, 0, 0),
        influences: [SourceStudioBoneInfluence]
    ) -> SourceStudioMeshVertexSnapshot {
        SourceStudioMeshVertexSnapshot(
            stripGroupVertexIndex: index,
            originalMeshVertexIndex: index,
            rootLODVertexIndex: index,
            sourceVVDVertexIndex: index,
            position: position,
            normal: normal,
            textureCoordinate: SourceStudioTextureCoordinate(
                u: Float(index) / 2,
                v: Float(index) / 4
            ),
            tangent: SourceStudioTangent(x: 0, y: 1, z: 0, w: -1),
            boneInfluences: influences,
            optimizedBoneReferences: []
        )
    }

    func makeSourceMesh(
        checksum: Int32? = nil,
        lodIndex: Int = 2,
        selected: [SourceStudioMeshVertexSnapshot]? = nil
    ) -> SourceStudioModelMeshSnapshot {
        let selected = selected ?? selectedVertices()
        let unselected = selected.enumerated().map { index, vertex in
            makeVertex(
                index: index,
                position: vertex.position + SourceVector3(-100, 0, 0),
                influences: vertex.boneInfluences
            )
        }
        return SourceStudioModelMeshSnapshot(
            checksum: checksum ?? self.checksum,
            modelName: modelName,
            lodIndex: lodIndex,
            bodyParts: [SourceStudioBodyPartMeshSnapshot(
                index: 0,
                name: "body",
                modelSelectionBase: 1,
                models: [
                    makeSubmodel(index: 0, material: 3, vertices: unselected),
                    makeSubmodel(index: 1, material: 7, vertices: selected),
                ]
            )]
        )
    }

    func makeSubmodel(
        index: Int,
        material: Int32,
        vertices: [SourceStudioMeshVertexSnapshot]
    ) -> SourceStudioSubmodelSnapshot {
        SourceStudioSubmodelSnapshot(
            index: index,
            name: "model\(index)",
            type: 0,
            boundingRadius: 32,
            rootLODVertexCount: vertices.count,
            meshes: [SourceStudioMeshSnapshot(
                index: 0,
                materialIndex: material,
                meshID: Int32(index),
                center: .zero,
                rootLODVertexCount: vertices.count,
                stripGroups: [SourceStudioStripGroupSnapshot(
                    index: 0,
                    flags: 0,
                    vertices: vertices,
                    indices: [0, 1, 2],
                    strips: [SourceStudioStripSnapshot(
                        index: 0,
                        topology: .triangleList,
                        indexRange: SourceStudioMeshRange(offset: 0, count: 3),
                        vertexRange: SourceStudioMeshRange(
                            offset: 0,
                            count: vertices.count
                        ),
                        boneCount: 2,
                        boneStateChanges: []
                    )]
                )]
            )]
        )
    }

    func makeMaterial() -> GModStudioRenderableMaterial {
        GModStudioRenderableMaterial(
            sourceMaterialIndex: 7,
            skinFamilyIndex: 3,
            textureIndex: 4,
            textureName: "animated",
            vmtCandidates: ["materials/models/codex/animated.vmt"]
        )
    }

    func makeRenderable(
        vertices: [SourceStudioMeshVertexSnapshot],
        material: GModStudioRenderableMaterial? = nil
    ) -> GModStudioRenderableModelSnapshot {
        let material = material ?? makeMaterial()
        return GModStudioRenderableModelSnapshot(
            checksum: checksum,
            modelName: modelName,
            lodIndex: 2,
            bodyValue: 1,
            skinFamilyIndex: 3,
            vertices: vertices.map {
                GModDynamicModelVertex(
                    position: $0.position,
                    normal: $0.normal,
                    textureCoordinate: $0.textureCoordinate
                )
            },
            indices: [0, 1, 2],
            drawRanges: [GModStudioRenderableDrawRange(
                bodyPartIndex: 0,
                submodelIndex: 1,
                meshIndex: 0,
                firstIndex: 0,
                indexCount: 3,
                material: material
            )]
        )
    }

    func assertCompileError(
        renderable: GModStudioRenderableModelSnapshot,
        source: SourceStudioModelMeshSnapshot,
        studio: SourceStudioModel,
        animation: SourceStudioAnimationModel,
        equals expected: GModStudioAnimatedRenderableModelError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: renderable,
            sourceMesh: source,
            studioModel: studio,
            animationModel: animation,
            sequenceIndex: 0,
            blendIndex: 0,
            frame: 12
        ), file: file, line: line) { error in
            XCTAssertEqual(
                error as? GModStudioAnimatedRenderableModelError,
                expected,
                file: file,
                line: line
            )
        }
    }

    func assertVector(
        _ actual: SourceVector3,
        _ expected: SourceVector3,
        accuracy: Float = 0.000_01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    func bytes(of data: Data) -> [UInt8] {
        Array(data)
    }

    func appendCString(_ value: String, to bytes: inout [UInt8]) -> Int {
        let offset = bytes.count
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
        return offset
    }

    func putFixedCString(
        _ value: String,
        at offset: Int,
        capacity: Int,
        into bytes: inout [UInt8]
    ) {
        let encoded = Array(value.utf8.prefix(capacity - 1))
        for index in 0..<capacity { bytes[offset + index] = 0 }
        for (index, byte) in encoded.enumerated() { bytes[offset + index] = byte }
    }

    func putUInt16(_ value: UInt16, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    func putInt16(_ value: Int16, at offset: Int, into bytes: inout [UInt8]) {
        putUInt16(UInt16(bitPattern: value), at: offset, into: &bytes)
    }

    func putUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    func putInt32(_ value: Int32, at offset: Int, into bytes: inout [UInt8]) {
        putUInt32(UInt32(bitPattern: value), at: offset, into: &bytes)
    }

    func putFloat(_ value: Float, at offset: Int, into bytes: inout [UInt8]) {
        putUInt32(value.bitPattern, at: offset, into: &bytes)
    }

    func putVector(_ value: SourceVector3, at offset: Int, into bytes: inout [UInt8]) {
        putFloat(value.x, at: offset, into: &bytes)
        putFloat(value.y, at: offset + 4, into: &bytes)
        putFloat(value.z, at: offset + 8, into: &bytes)
    }

    func putQuaternion(
        _ value: SourceStudioQuaternion,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        putFloat(value.x, at: offset, into: &bytes)
        putFloat(value.y, at: offset + 4, into: &bytes)
        putFloat(value.z, at: offset + 8, into: &bytes)
        putFloat(value.w, at: offset + 12, into: &bytes)
    }

    func putMatrix(
        _ value: SourceStudioMatrix3x4,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        let values = [
            value.m00, value.m01, value.m02, value.m03,
            value.m10, value.m11, value.m12, value.m13,
            value.m20, value.m21, value.m22, value.m23,
        ]
        for (index, element) in values.enumerated() {
            putFloat(element, at: offset + index * 4, into: &bytes)
        }
    }

    func putVector48(
        x: UInt16,
        y: UInt16,
        z: UInt16,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        putUInt16(x, at: offset, into: &bytes)
        putUInt16(y, at: offset + 2, into: &bytes)
        putUInt16(z, at: offset + 4, into: &bytes)
    }

    func putQuaternion48(
        _ value: SourceStudioQuaternion,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        let x = UInt16(clamping: Int(value.x * 32_768) + 32_768)
        let y = UInt16(clamping: Int(value.y * 32_768) + 32_768)
        var zw = UInt16(clamping: Int(value.z * 16_384) + 16_384) & 0x7FFF
        if value.w < 0 { zw |= 0x8000 }
        putUInt16(x, at: offset, into: &bytes)
        putUInt16(y, at: offset + 2, into: &bytes)
        putUInt16(zw, at: offset + 4, into: &bytes)
    }
}

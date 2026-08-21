import Foundation
import Testing
@testable import GModEngine

@Suite("Renderer-neutral Source Studio root mesh decoding")
struct SourceStudioModelMeshTests {
    private let checksum: Int32 = 0x1357_2468

    @Test("MDL, VVD, and VTX publish the original hierarchy and vertex attributes")
    func decodesHierarchyAndAttributes() throws {
        let payload = try loadPayload(files: fixture())
        let snapshot = try SourceStudioModelMeshDecoder.decodeRootLOD(
            payload,
            budget: decodeBudget()
        )

        #expect(snapshot.checksum == checksum)
        #expect(snapshot.modelName == "models/props/mesh_test.mdl")
        #expect(snapshot.lodIndex == 0)
        let body = try #require(snapshot.bodyParts.first)
        #expect(body.index == 0)
        #expect(body.name == "body")
        #expect(body.modelSelectionBase == 1)
        let model = try #require(body.models.first)
        #expect(model.index == 0)
        #expect(model.name == "mesh_test")
        #expect(model.boundingRadius == 32)
        #expect(model.rootLODVertexCount == 3)
        let mesh = try #require(model.meshes.first)
        #expect(mesh.index == 0)
        #expect(mesh.materialIndex == 7)
        #expect(mesh.meshID == 42)
        #expect(mesh.center == SourceVector3(4, 5, 6))
        let group = try #require(mesh.stripGroups.first)
        #expect(group.index == 0)
        #expect(group.flags == 0x02)
        #expect(group.indices == [0, 1, 2])
        #expect(group.vertices.map(\.stripGroupVertexIndex) == [0, 1, 2])
        #expect(group.vertices.map(\.originalMeshVertexIndex) == [2, 0, 1])
        #expect(group.vertices.map(\.rootLODVertexIndex) == [2, 0, 1])
        #expect(group.vertices.map(\.sourceVVDVertexIndex) == [2, 0, 1])
        #expect(group.vertices.map(\.position) == [
            SourceVector3(30, 31, 32),
            SourceVector3(10, 11, 12),
            SourceVector3(20, 21, 22)
        ])
        #expect(group.vertices.map(\.normal) == Array(repeating: SourceVector3(0, 0, 1), count: 3))
        #expect(group.vertices.map(\.textureCoordinate) == [
            SourceStudioTextureCoordinate(u: 0.3, v: 0.6),
            SourceStudioTextureCoordinate(u: 0.1, v: 0.2),
            SourceStudioTextureCoordinate(u: 0.2, v: 0.4)
        ])
        #expect(group.vertices[0].tangent == SourceStudioTangent(x: 3, y: 0, z: 0, w: 1))
        #expect(group.vertices[0].boneInfluences == [
            SourceStudioBoneInfluence(boneIndex: 0, weight: 1)
        ])
        #expect(group.vertices[0].optimizedBoneReferences == [
            SourceStudioOptimizedBoneReference(weightSlot: 0, boneID: 0)
        ])
        let strip = try #require(group.strips.first)
        #expect(strip.index == 0)
        #expect(strip.topology == .triangleList)
        #expect(strip.indexRange == SourceStudioMeshRange(offset: 0, count: 3))
        #expect(strip.vertexRange == SourceStudioMeshRange(offset: 0, count: 3))
        #expect(strip.boneCount == 1)
        #expect(strip.boneStateChanges == [
            SourceStudioBoneStateChangeSnapshot(
                hardwareBoneIndex: 0,
                newStudioBoneIndex: 0
            )
        ])
    }

    @Test("VVD root fixups deterministically remap logical vertices and tangents")
    func appliesRootFixups() throws {
        let payload = try loadPayload(files: fixture(
            fixups: [
                (lod: 0, source: 2, count: 1),
                (lod: 0, source: 0, count: 2)
            ],
            optimizedVertexOrder: [0, 1, 2]
        ))
        let snapshot = try SourceStudioModelMeshDecoder.decodeRootLOD(
            payload,
            budget: decodeBudget()
        )
        let vertices = try #require(
            snapshot.bodyParts.first?.models.first?.meshes.first?.stripGroups.first?.vertices
        )

        #expect(vertices.map(\.rootLODVertexIndex) == [0, 1, 2])
        #expect(vertices.map(\.sourceVVDVertexIndex) == [2, 0, 1])
        #expect(vertices.map(\.position) == [
            SourceVector3(30, 31, 32),
            SourceVector3(10, 11, 12),
            SourceVector3(20, 21, 22)
        ])
        #expect(vertices.map(\.tangent) == [
            SourceStudioTangent(x: 3, y: 0, z: 0, w: 1),
            SourceStudioTangent(x: 1, y: 0, z: 0, w: 1),
            SourceStudioTangent(x: 2, y: 0, z: 0, w: 1)
        ])
    }

    @Test("MDL and VTX hierarchy mismatches fail before a snapshot is returned")
    func rejectsHierarchyMismatch() throws {
        var files = fixture()
        var vtx = [UInt8](try #require(files[Paths.vtx]))
        putInt32(0, at: Offsets.vtxBodyPart, into: &vtx)
        files[Paths.vtx] = Data(vtx)
        let payload = try loadPayload(files: files)

        do {
            _ = try SourceStudioModelMeshDecoder.decodeRootLOD(
                payload,
                budget: decodeBudget()
            )
            Issue.record("expected hierarchy mismatch")
        } catch let error as SourceStudioModelMeshDecodeError {
            #expect(error == .hierarchyCountMismatch(
                field: "bodyPart[0].models",
                mdl: 1,
                vtx: 0
            ))
        }
    }

    @Test("flex geometry is an explicit unsupported boundary, not a base-mesh guess")
    func rejectsVertexFlexes() throws {
        var files = fixture()
        var mdl = [UInt8](try #require(files[Paths.mdl]))
        putInt32(1, at: Offsets.mdlMesh + 16, into: &mdl)
        files[Paths.mdl] = Data(mdl)
        let payload = try loadPayload(files: files)

        do {
            _ = try SourceStudioModelMeshDecoder.decodeRootLOD(
                payload,
                budget: decodeBudget()
            )
            Issue.record("expected typed unsupported flex boundary")
        } catch let error as SourceStudioModelMeshDecodeError {
            #expect(error == .unsupported(.vertexFlexes(
                bodyPart: 0,
                model: 0,
                mesh: 0,
                count: 1
            )))
        }
    }

    @Test("decoded vertex expansion obeys the caller's output budget")
    func enforcesDecodeBudget() throws {
        let payload = try loadPayload(files: fixture())
        let small = SourceStudioMeshDecodeBudget(
            maximumRootVertices: 3,
            maximumBodyParts: 1,
            maximumModels: 1,
            maximumMeshes: 1,
            maximumStripGroups: 1,
            maximumDecodedVertices: 2,
            maximumIndices: 3,
            maximumStrips: 1,
            maximumBoneStateChanges: 1
        )

        do {
            _ = try SourceStudioModelMeshDecoder.decodeRootLOD(payload, budget: small)
            Issue.record("expected decoded vertex budget failure")
        } catch let error as SourceStudioModelMeshDecodeError {
            #expect(error == .exceedsBudget(
                field: "decoded vertices",
                value: 3,
                cap: 2
            ))
        }
    }

    @Test("VTX indices must reference the preserved strip-group vertex array")
    func rejectsOutOfRangeOptimizedIndex() throws {
        var files = fixture()
        var vtx = [UInt8](try #require(files[Paths.vtx]))
        putUInt16(3, at: Offsets.vtxIndices, into: &vtx)
        files[Paths.vtx] = Data(vtx)
        let payload = try loadPayload(files: files)

        do {
            _ = try SourceStudioModelMeshDecoder.decodeRootLOD(
                payload,
                budget: decodeBudget()
            )
            Issue.record("expected VTX index failure")
        } catch let error as SourceStudioModelMeshDecodeError {
            #expect(error == .invalidReference(
                field: "bodyPart[0].model[0].mesh[0].stripGroup[0].index[0]",
                value: 3,
                upperBound: 3
            ))
        }
    }
}

private extension SourceStudioModelMeshTests {
    enum Paths {
        static let mdl = "models/props/mesh_test.mdl"
        static let vvd = "models/props/mesh_test.vvd"
        static let vtx = "models/props/mesh_test.dx90.vtx"
    }

    enum Offsets {
        static let mdlBone = 408
        static let mdlBodyPart = 640
        static let mdlModel = 664
        static let mdlMesh = 812
        static let vtxBodyPart = 44
        static let vtxModel = 52
        static let vtxLOD = 60
        static let vtxMesh = 72
        static let vtxStripGroup = 81
        static let vtxVertices = 106
        static let vtxIndices = 133
        static let vtxStrip = 139
        static let vtxBoneChange = 166
    }

    func decodeBudget() -> SourceStudioMeshDecodeBudget {
        SourceStudioMeshDecodeBudget(
            maximumRootVertices: 16,
            maximumBodyParts: 4,
            maximumModels: 8,
            maximumMeshes: 16,
            maximumStripGroups: 32,
            maximumDecodedVertices: 128,
            maximumIndices: 256,
            maximumStrips: 64,
            maximumBoneStateChanges: 64
        )
    }

    func assetBudget() -> SourceStudioModelAssetBudget {
        SourceStudioModelAssetBudget(
            maximumBytesByKind: [.mdl: 4_096, .vvd: 4_096, .vtx: 4_096],
            maximumTotalBytes: 12_288,
            maximumVVDVertices: 16,
            maximumVVDFixups: 16,
            maximumVTXBodyParts: 4
        )
    }

    func loadPayload(files: [String: Data]) throws -> SourceStudioImmutableRenderPayload {
        let loader = SourceStudioModelAssetLoader(
            reader: MeshMemoryAssetReader(files: files),
            budget: assetBudget()
        )
        let outcome = loader.load(
            paths: SourceStudioModelAssetPaths(
                mdl: Paths.mdl,
                vvd: Paths.vvd,
                vtx: Paths.vtx
            ),
            requirement: .render
        )
        return try #require(outcome.asset).renderPayload
    }

    func fixture(
        fixups: [(lod: Int32, source: Int32, count: Int32)] = [],
        optimizedVertexOrder: [UInt16] = [2, 0, 1]
    ) -> [String: Data] {
        [
            Paths.mdl: makeMDL(),
            Paths.vvd: makeVVD(fixups: fixups),
            Paths.vtx: makeVTX(optimizedVertexOrder: optimizedVertexOrder)
        ]
    }

    func makeMDL() -> Data {
        var bytes = [UInt8](repeating: 0, count: 928)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString(Paths.mdl, at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)

        putInt32(1, at: 156, into: &bytes)
        putInt32(Int32(Offsets.mdlBone), at: 160, into: &bytes)
        putInt32(1, at: 232, into: &bytes)
        putInt32(Int32(Offsets.mdlBodyPart), at: 236, into: &bytes)

        let bone = Offsets.mdlBone
        putInt32(216, at: bone, into: &bytes)
        putInt32(-1, at: bone + 4, into: &bytes)
        for controller in 0..<6 {
            putInt32(-1, at: bone + 8 + controller * 4, into: &bytes)
        }
        putFloat(1, at: bone + 56, into: &bytes)
        putFloat(1, at: bone + 96, into: &bytes)
        putFloat(1, at: bone + 116, into: &bytes)
        putFloat(1, at: bone + 136, into: &bytes)
        putFloat(1, at: bone + 156, into: &bytes)
        putInt32(221, at: bone + 176, into: &bytes)
        putCString("root", at: 624, capacity: 5, into: &bytes)
        putCString("default", at: 629, capacity: 8, into: &bytes)

        let body = Offsets.mdlBodyPart
        putInt32(16, at: body, into: &bytes)
        putInt32(1, at: body + 4, into: &bytes)
        putInt32(1, at: body + 8, into: &bytes)
        putInt32(24, at: body + 12, into: &bytes)
        putCString("body", at: 656, capacity: 5, into: &bytes)

        let model = Offsets.mdlModel
        putCString("mesh_test", at: model, capacity: 64, into: &bytes)
        putFloat(32, at: model + 68, into: &bytes)
        putInt32(1, at: model + 72, into: &bytes)
        putInt32(148, at: model + 76, into: &bytes)
        putInt32(3, at: model + 80, into: &bytes)
        putInt32(0, at: model + 84, into: &bytes)
        putInt32(0, at: model + 88, into: &bytes)

        let mesh = Offsets.mdlMesh
        putInt32(7, at: mesh, into: &bytes)
        putInt32(-148, at: mesh + 4, into: &bytes)
        putInt32(3, at: mesh + 8, into: &bytes)
        putInt32(0, at: mesh + 12, into: &bytes)
        putInt32(42, at: mesh + 32, into: &bytes)
        putVector(SourceVector3(4, 5, 6), at: mesh + 36, into: &bytes)
        putInt32(3, at: mesh + 52, into: &bytes)
        return Data(bytes)
    }

    func makeVVD(fixups: [(lod: Int32, source: Int32, count: Int32)]) -> Data {
        let headerSize = 64
        let fixupStart = fixups.isEmpty ? 0 : headerSize
        let vertexStart = headerSize + fixups.count * 12
        let tangentStart = vertexStart + 3 * 48
        var bytes = [UInt8](repeating: 0, count: tangentStart + 3 * 16)
        putUInt32(0x5653_4449, at: 0, into: &bytes)
        putInt32(4, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        putInt32(3, at: 16, into: &bytes)
        putInt32(Int32(fixups.count), at: 48, into: &bytes)
        putInt32(Int32(fixupStart), at: 52, into: &bytes)
        putInt32(Int32(vertexStart), at: 56, into: &bytes)
        putInt32(Int32(tangentStart), at: 60, into: &bytes)
        for (index, fixup) in fixups.enumerated() {
            let base = fixupStart + index * 12
            putInt32(fixup.lod, at: base, into: &bytes)
            putInt32(fixup.source, at: base + 4, into: &bytes)
            putInt32(fixup.count, at: base + 8, into: &bytes)
        }
        for index in 0..<3 {
            let base = vertexStart + index * 48
            putFloat(1, at: base, into: &bytes)
            bytes[base + 12] = 0
            bytes[base + 15] = 1
            let start = Float((index + 1) * 10)
            putVector(SourceVector3(start, start + 1, start + 2), at: base + 16, into: &bytes)
            putVector(SourceVector3(0, 0, 1), at: base + 28, into: &bytes)
            putFloat(Float(index + 1) / 10, at: base + 40, into: &bytes)
            putFloat(Float(index + 1) / 5, at: base + 44, into: &bytes)

            let tangent = tangentStart + index * 16
            putFloat(Float(index + 1), at: tangent, into: &bytes)
            putFloat(1, at: tangent + 12, into: &bytes)
        }
        return Data(bytes)
    }

    func makeVTX(optimizedVertexOrder: [UInt16]) -> Data {
        precondition(optimizedVertexOrder.count == 3)
        var bytes = [UInt8](repeating: 0, count: 174)
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
        putUInt16(32, at: 8, into: &bytes)
        putUInt16(3, at: 10, into: &bytes)
        putInt32(3, at: 12, into: &bytes)
        putInt32(checksum, at: 16, into: &bytes)
        putInt32(1, at: 20, into: &bytes)
        putInt32(36, at: 24, into: &bytes)
        putInt32(1, at: 28, into: &bytes)
        putInt32(Int32(Offsets.vtxBodyPart), at: 32, into: &bytes)

        putInt32(1, at: Offsets.vtxBodyPart, into: &bytes)
        putInt32(8, at: Offsets.vtxBodyPart + 4, into: &bytes)
        putInt32(1, at: Offsets.vtxModel, into: &bytes)
        putInt32(8, at: Offsets.vtxModel + 4, into: &bytes)
        putInt32(1, at: Offsets.vtxLOD, into: &bytes)
        putInt32(12, at: Offsets.vtxLOD + 4, into: &bytes)
        putFloat(0, at: Offsets.vtxLOD + 8, into: &bytes)
        putInt32(1, at: Offsets.vtxMesh, into: &bytes)
        putInt32(9, at: Offsets.vtxMesh + 4, into: &bytes)

        let group = Offsets.vtxStripGroup
        putInt32(3, at: group, into: &bytes)
        putInt32(25, at: group + 4, into: &bytes)
        putInt32(3, at: group + 8, into: &bytes)
        putInt32(52, at: group + 12, into: &bytes)
        putInt32(1, at: group + 16, into: &bytes)
        putInt32(58, at: group + 20, into: &bytes)
        bytes[group + 24] = 0x02

        for (index, originalVertex) in optimizedVertexOrder.enumerated() {
            let base = Offsets.vtxVertices + index * 9
            bytes[base] = 0
            bytes[base + 3] = 1
            putUInt16(originalVertex, at: base + 4, into: &bytes)
            bytes[base + 6] = 0
            bytes[base + 7] = 0xFF
            bytes[base + 8] = 0xFF
        }
        putUInt16(0, at: Offsets.vtxIndices, into: &bytes)
        putUInt16(1, at: Offsets.vtxIndices + 2, into: &bytes)
        putUInt16(2, at: Offsets.vtxIndices + 4, into: &bytes)

        let strip = Offsets.vtxStrip
        putInt32(3, at: strip, into: &bytes)
        putInt32(0, at: strip + 4, into: &bytes)
        putInt32(3, at: strip + 8, into: &bytes)
        putInt32(0, at: strip + 12, into: &bytes)
        putUInt16(1, at: strip + 16, into: &bytes)
        bytes[strip + 18] = SourceStudioMeshTopology.triangleList.rawValue
        putInt32(1, at: strip + 19, into: &bytes)
        putInt32(27, at: strip + 23, into: &bytes)
        putInt32(0, at: Offsets.vtxBoneChange, into: &bytes)
        putInt32(0, at: Offsets.vtxBoneChange + 4, into: &bytes)
        return Data(bytes)
    }
}

private struct MeshMemoryAssetReader: SourceStudioBoundedAssetReading {
    let files: [String: Data]

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        guard let data = files[path.lowercased()] else { return .missing }
        guard data.count <= maximumBytes else { return .exceeded(actual: data.count) }
        return .data(data)
    }
}

private func putCString(
    _ value: String,
    at offset: Int,
    capacity: Int,
    into bytes: inout [UInt8]
) {
    let encoded = Array(value.utf8.prefix(capacity - 1))
    bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
    bytes[offset + encoded.count] = 0
}

private func putVector(
    _ value: SourceVector3,
    at offset: Int,
    into bytes: inout [UInt8]
) {
    putFloat(value.x, at: offset, into: &bytes)
    putFloat(value.y, at: offset + 4, into: &bytes)
    putFloat(value.z, at: offset + 8, into: &bytes)
}

private func putFloat(_ value: Float, at offset: Int, into bytes: inout [UInt8]) {
    putUInt32(value.bitPattern, at: offset, into: &bytes)
}

private func putUInt16(_ value: UInt16, at offset: Int, into bytes: inout [UInt8]) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func putInt32(_ value: Int32, at offset: Int, into bytes: inout [UInt8]) {
    putUInt32(UInt32(bitPattern: value), at: offset, into: &bytes)
}

private func putUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

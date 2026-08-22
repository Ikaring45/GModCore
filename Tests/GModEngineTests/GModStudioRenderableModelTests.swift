import Foundation
import XCTest
import GModEngine
@testable import GModGameSession

final class GModStudioRenderableModelTests: XCTestCase {
    private let checksum: Int32 = 0x3141_5926

    func testTransactionallyCompilesGeometryAndSelectedSkinMaterials() throws {
        let snapshot = try GModStudioRenderableModelCompiler.compile(
            asset: makeAsset(files: fixture()),
            bodyValue: 0,
            skinFamilyIndex: 1,
            policy: compilePolicy()
        )

        XCTAssertEqual(snapshot.checksum, checksum)
        XCTAssertEqual(snapshot.modelName, Paths.mdl)
        XCTAssertEqual(snapshot.lodIndex, 0)
        XCTAssertEqual(snapshot.bodyValue, 0)
        XCTAssertEqual(snapshot.skinFamilyIndex, 1)
        XCTAssertEqual(snapshot.vertices.map(\.position), [
            SourceVector3(30, 31, 32),
            SourceVector3(10, 11, 12),
            SourceVector3(20, 21, 22),
        ])
        XCTAssertEqual(snapshot.indices, [0, 1, 2])

        let draw = try XCTUnwrap(snapshot.drawRanges.first)
        XCTAssertEqual(snapshot.drawRanges.count, 1)
        XCTAssertEqual(draw.bodyPartIndex, 0)
        XCTAssertEqual(draw.submodelIndex, 0)
        XCTAssertEqual(draw.meshIndex, 0)
        XCTAssertEqual(draw.firstIndex, 0)
        XCTAssertEqual(draw.indexCount, 3)
        XCTAssertEqual(draw.material.sourceMaterialIndex, 0)
        XCTAssertEqual(draw.material.skinFamilyIndex, 1)
        XCTAssertEqual(draw.material.textureIndex, 1)
        XCTAssertEqual(draw.material.textureName, "alternate")
        XCTAssertEqual(draw.material.vmtCandidates, [
            "materials/models/props/alternate.vmt",
        ])
    }

    func testWrapsUnsupportedMeshWithoutPublishingAPartialSnapshot() throws {
        var files = fixture()
        var mdl = [UInt8](try XCTUnwrap(files[Paths.mdl]))
        putInt32(1, at: Offsets.mdlMesh + 16, into: &mdl)
        files[Paths.mdl] = Data(mdl)

        XCTAssertThrowsError(try GModStudioRenderableModelCompiler.compile(
            asset: makeAsset(files: files),
            bodyValue: 0,
            skinFamilyIndex: 0,
            policy: compilePolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModStudioRenderableModelCompileError,
                .unsupportedMesh(.vertexFlexes(
                    bodyPart: 0,
                    model: 0,
                    mesh: 0,
                    count: 1
                ))
            )
        }
    }

    func testWrapsMaterialFailureAfterSuccessfulMeshDecode() throws {
        var files = fixture()
        var mdl = [UInt8](try XCTUnwrap(files[Paths.mdl]))
        putInt16(2, at: Offsets.skins + 2, into: &mdl)
        files[Paths.mdl] = Data(mdl)

        XCTAssertThrowsError(try GModStudioRenderableModelCompiler.compile(
            asset: makeAsset(files: files),
            bodyValue: 0,
            skinFamilyIndex: 1,
            policy: compilePolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModStudioRenderableModelCompileError,
                .materialDecode(.invalidSkinReference(
                    family: 1,
                    materialSlot: 0,
                    value: 2,
                    textureCount: 2
                ))
            )
        }
    }

    func testWrapsDynamicOutputBudgetFailure() throws {
        let base = compilePolicy()
        let constrained = GModStudioRenderableModelCompilePolicy(
            meshDecodeBudget: base.meshDecodeBudget,
            materialDecodeBudget: base.materialDecodeBudget,
            dynamicMeshBuildPolicy: GModDynamicModelMeshBuildPolicy(
                maximumVertices: 2,
                maximumIndices: 3
            )
        )

        XCTAssertThrowsError(try GModStudioRenderableModelCompiler.compile(
            asset: makeAsset(files: fixture()),
            bodyValue: 0,
            skinFamilyIndex: 0,
            policy: constrained
        )) { error in
            XCTAssertEqual(
                error as? GModStudioRenderableModelCompileError,
                .dynamicMeshBuild(.vertexBudgetExceeded(requested: 3, cap: 2))
            )
        }
    }

    func testRejectsEmptyVMTCandidateSetAtFinalResolution() throws {
        var files = fixture()
        var mdl = [UInt8](try XCTUnwrap(files[Paths.mdl]))
        putInt32(0, at: 212, into: &mdl)
        putInt32(0, at: 216, into: &mdl)
        files[Paths.mdl] = Data(mdl)

        XCTAssertThrowsError(try GModStudioRenderableModelCompiler.compile(
            asset: makeAsset(files: files),
            bodyValue: 0,
            skinFamilyIndex: 0,
            policy: compilePolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModStudioRenderableModelCompileError,
                .noVMTCandidates(
                    drawRangeIndex: 0,
                    textureIndex: 0,
                    textureName: "base"
                )
            )
        }
    }

    func testWrapsInvalidSkinSelectionAtDrawRangeResolution() throws {
        XCTAssertThrowsError(try GModStudioRenderableModelCompiler.compile(
            asset: makeAsset(files: fixture()),
            bodyValue: 0,
            skinFamilyIndex: 2,
            policy: compilePolicy()
        )) { error in
            XCTAssertEqual(
                error as? GModStudioRenderableModelCompileError,
                .materialResolution(
                    drawRangeIndex: 0,
                    error: .invalidSkinFamily(value: 2, available: 2)
                )
            )
        }
    }
}

private extension GModStudioRenderableModelTests {
    enum Paths {
        static let mdl = "models/props/renderable_test.mdl"
        static let vvd = "models/props/renderable_test.vvd"
        static let vtx = "models/props/renderable_test.dx90.vtx"
    }

    enum Offsets {
        static let mdlBodyPart = 408
        static let mdlModel = 432
        static let mdlMesh = 580
        static let textures = 696
        static let textureNames = 824
        static let cdTextureOffsets = 844
        static let cdTextureName = 848
        static let skins = 862

        static let vtxBodyPart = 44
        static let vtxModel = 52
        static let vtxLOD = 60
        static let vtxMesh = 72
        static let vtxStripGroup = 81
        static let vtxVertices = 106
        static let vtxIndices = 133
        static let vtxStrip = 139
    }

    func compilePolicy() -> GModStudioRenderableModelCompilePolicy {
        GModStudioRenderableModelCompilePolicy(
            meshDecodeBudget: SourceStudioMeshDecodeBudget(
                maximumRootVertices: 3,
                maximumBodyParts: 1,
                maximumModels: 1,
                maximumMeshes: 1,
                maximumStripGroups: 1,
                maximumDecodedVertices: 3,
                maximumIndices: 3,
                maximumStrips: 1,
                maximumBoneStateChanges: 0
            ),
            materialDecodeBudget: SourceStudioModelMaterialDecodeBudget(
                maximumTextures: 2,
                maximumCDTextureDirectories: 1,
                maximumSkinReferences: 1,
                maximumSkinFamilies: 2,
                maximumSkinEntries: 2,
                maximumStringBytes: 64,
                maximumTotalStringBytes: 128,
                maximumResolvedCandidateBytes: 128
            ),
            dynamicMeshBuildPolicy: GModDynamicModelMeshBuildPolicy(
                maximumVertices: 3,
                maximumIndices: 3
            )
        )
    }

    func makeAsset(files: [String: Data]) throws -> SourceStudioModelAsset {
        let loader = SourceStudioModelAssetLoader(
            reader: RenderableMemoryAssetReader(files: files),
            budget: SourceStudioModelAssetBudget(
                maximumBytesByKind: [.mdl: 1_024, .vvd: 256, .vtx: 256],
                maximumTotalBytes: 1_536,
                maximumVVDVertices: 3,
                maximumVVDFixups: 0,
                maximumVTXBodyParts: 1
            )
        )
        let outcome = loader.load(
            paths: SourceStudioModelAssetPaths(
                mdl: Paths.mdl,
                vvd: Paths.vvd,
                vtx: Paths.vtx
            ),
            requirement: .render
        )
        return try XCTUnwrap(outcome.asset)
    }

    func fixture() -> [String: Data] {
        [
            Paths.mdl: makeMDL(),
            Paths.vvd: makeVVD(),
            Paths.vtx: makeVTX(),
        ]
    }

    func makeMDL() -> Data {
        var bytes = [UInt8](repeating: 0, count: 896)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString(Paths.mdl, at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)

        putInt32(2, at: 204, into: &bytes)
        putInt32(Int32(Offsets.textures), at: 208, into: &bytes)
        putInt32(1, at: 212, into: &bytes)
        putInt32(Int32(Offsets.cdTextureOffsets), at: 216, into: &bytes)
        putInt32(1, at: 220, into: &bytes)
        putInt32(2, at: 224, into: &bytes)
        putInt32(Int32(Offsets.skins), at: 228, into: &bytes)
        putInt32(1, at: 232, into: &bytes)
        putInt32(Int32(Offsets.mdlBodyPart), at: 236, into: &bytes)

        let body = Offsets.mdlBodyPart
        putInt32(16, at: body, into: &bytes)
        putInt32(1, at: body + 4, into: &bytes)
        putInt32(1, at: body + 8, into: &bytes)
        putInt32(24, at: body + 12, into: &bytes)
        putCString("body", at: body + 16, capacity: 5, into: &bytes)

        let model = Offsets.mdlModel
        putCString("renderable_test", at: model, capacity: 64, into: &bytes)
        putFloat(32, at: model + 68, into: &bytes)
        putInt32(1, at: model + 72, into: &bytes)
        putInt32(148, at: model + 76, into: &bytes)
        putInt32(3, at: model + 80, into: &bytes)

        let mesh = Offsets.mdlMesh
        putInt32(0, at: mesh, into: &bytes)
        putInt32(-148, at: mesh + 4, into: &bytes)
        putInt32(3, at: mesh + 8, into: &bytes)
        putInt32(42, at: mesh + 32, into: &bytes)
        putVector(SourceVector3(4, 5, 6), at: mesh + 36, into: &bytes)
        putInt32(3, at: mesh + 52, into: &bytes)

        putInt32(128, at: Offsets.textures, into: &bytes)
        putInt32(72, at: Offsets.textures + 64, into: &bytes)
        putCString("base", at: Offsets.textureNames, capacity: 5, into: &bytes)
        putCString("alternate", at: Offsets.textureNames + 8, capacity: 10, into: &bytes)
        putInt32(Int32(Offsets.cdTextureName), at: Offsets.cdTextureOffsets, into: &bytes)
        putCString("models/props/", at: Offsets.cdTextureName, capacity: 14, into: &bytes)
        putInt16(0, at: Offsets.skins, into: &bytes)
        putInt16(1, at: Offsets.skins + 2, into: &bytes)
        return Data(bytes)
    }

    func makeVVD() -> Data {
        let vertexStart = 64
        var bytes = [UInt8](repeating: 0, count: vertexStart + 3 * 48)
        putUInt32(0x5653_4449, at: 0, into: &bytes)
        putInt32(4, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        putInt32(3, at: 16, into: &bytes)
        putInt32(Int32(vertexStart), at: 56, into: &bytes)
        for index in 0..<3 {
            let base = vertexStart + index * 48
            let start = Float((index + 1) * 10)
            putVector(SourceVector3(start, start + 1, start + 2), at: base + 16, into: &bytes)
            putVector(SourceVector3(0, 0, 1), at: base + 28, into: &bytes)
            putFloat(Float(index + 1) / 10, at: base + 40, into: &bytes)
            putFloat(Float(index + 1) / 5, at: base + 44, into: &bytes)
        }
        return Data(bytes)
    }

    func makeVTX() -> Data {
        var bytes = [UInt8](repeating: 0, count: 166)
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
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
        putInt32(1, at: Offsets.vtxMesh, into: &bytes)
        putInt32(9, at: Offsets.vtxMesh + 4, into: &bytes)

        let group = Offsets.vtxStripGroup
        putInt32(3, at: group, into: &bytes)
        putInt32(25, at: group + 4, into: &bytes)
        putInt32(3, at: group + 8, into: &bytes)
        putInt32(52, at: group + 12, into: &bytes)
        putInt32(1, at: group + 16, into: &bytes)
        putInt32(58, at: group + 20, into: &bytes)

        let optimizedOrder: [UInt16] = [2, 0, 1]
        for (index, originalVertex) in optimizedOrder.enumerated() {
            putUInt16(
                originalVertex,
                at: Offsets.vtxVertices + index * 9 + 4,
                into: &bytes
            )
        }
        putUInt16(0, at: Offsets.vtxIndices, into: &bytes)
        putUInt16(1, at: Offsets.vtxIndices + 2, into: &bytes)
        putUInt16(2, at: Offsets.vtxIndices + 4, into: &bytes)

        let strip = Offsets.vtxStrip
        putInt32(3, at: strip, into: &bytes)
        putInt32(3, at: strip + 8, into: &bytes)
        bytes[strip + 18] = SourceStudioMeshTopology.triangleList.rawValue
        return Data(bytes)
    }
}

private struct RenderableMemoryAssetReader: SourceStudioBoundedAssetReading {
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

private func putInt16(_ value: Int16, at offset: Int, into bytes: inout [UInt8]) {
    putUInt16(UInt16(bitPattern: value), at: offset, into: &bytes)
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

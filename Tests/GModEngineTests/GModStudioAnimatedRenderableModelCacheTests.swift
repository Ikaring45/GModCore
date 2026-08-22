import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModStudioAnimatedRenderableModelCacheTests: XCTestCase {
    private let checksum: Int32 = 0x1357_2468

    func testProductionRepositoryTripletProducesExactAnimatedSnapshot() throws {
        let reader = AnimatedStudioMemoryReader(files: fixture())
        let repository = GModStudioModelRepository(
            reader: reader,
            budget: assetBudget(),
            cachePolicy: GModStudioModelRepositoryCachePolicy(
                maximumEntryCount: 2,
                maximumRawByteCount: 4_096
            )
        )
        let cache = try GModStudioAnimatedRenderableModelCache(
            repository: repository,
            compilePolicy: compilePolicy(),
            cachePolicy: GModStudioAnimatedRenderableModelCachePolicy(
                maximumPreparedEntryCount: 2,
                maximumRetainedVertexCount: 12
            )
        )

        let first = cache.resolve(
            model: SourceEntityModelReference(Paths.mdl),
            bodyValue: 0,
            skinFamilyIndex: 1,
            lodIndex: 0,
            selection: GModStudioAnimationFrameSelection(
                sequenceIndex: 0,
                blendIndex: 0,
                frame: 5
            )
        )
        let resource: GModStudioAnimatedRenderableModelResource
        switch first {
        case let .resolved(value):
            resource = value
        case let .failed(failure):
            return XCTFail("unexpected production resolution failure: \(failure)")
        }

        XCTAssertEqual(resource.id.normalizedModelPath, Paths.mdl)
        XCTAssertEqual(resource.id.checksum, checksum)
        XCTAssertEqual(resource.id.lodIndex, 0)
        XCTAssertEqual(resource.id.bodyValue, 0)
        XCTAssertEqual(resource.id.skinFamilyIndex, 1)
        XCTAssertEqual(resource.id.sequenceIndex, 0)
        XCTAssertEqual(resource.id.blendIndex, 0)
        XCTAssertEqual(resource.id.animationIndex, 0)
        XCTAssertEqual(resource.id.frame, 5)
        XCTAssertEqual(resource.model.drawRanges.first?.material.textureName, "alternate")
        XCTAssertEqual(resource.model.vertices.map(\.position), [
            SourceVector3(8, 0, 0),
            SourceVector3(6, 0, 0),
            SourceVector3(7, 0, 0),
        ])
        XCTAssertEqual(cache.cachedPreparedEntryCount, 1)
        XCTAssertEqual(cache.cachedRetainedVertexCount, 6)
        XCTAssertEqual(reader.readCount(for: Paths.mdl), 1)
        XCTAssertEqual(reader.readCount(for: Paths.vvd), 1)
        XCTAssertEqual(reader.readCount(for: Paths.vtx), 1)

        let later = cache.resolve(
            model: SourceEntityModelReference(Paths.mdl.uppercased()),
            bodyValue: 0,
            skinFamilyIndex: 1,
            lodIndex: 0,
            selection: GModStudioAnimationFrameSelection(
                sequenceIndex: 0,
                blendIndex: 0,
                frame: 7
            )
        )
        switch later {
        case let .resolved(value):
            XCTAssertEqual(value.id.frame, 7)
            XCTAssertEqual(value.model.frame, 7)
            XCTAssertNotEqual(value.id, resource.id)
        case let .failed(failure):
            XCTFail("unexpected second-frame failure: \(failure)")
        }
        XCTAssertEqual(cache.cachedPreparedEntryCount, 1)
        XCTAssertEqual(reader.readCount(for: Paths.mdl), 1)
    }

    func testInvalidAuthoredFrameFailsWithoutBindPoseFallback() throws {
        let cache = try productionCache()
        let resolution = cache.resolve(
            model: SourceEntityModelReference(Paths.mdl),
            bodyValue: 0,
            skinFamilyIndex: 0,
            lodIndex: 0,
            selection: GModStudioAnimationFrameSelection(
                sequenceIndex: 0,
                blendIndex: 0,
                frame: 10
            )
        )

        XCTAssertEqual(
            resolution,
            .failed(.animation(.animation(.invalidFrame(
                animation: 0,
                value: 10,
                frameCount: 10
            ))))
        )
        XCTAssertEqual(cache.cachedPreparedEntryCount, 1)
    }

    func testInvalidModelPathDoesNotReachRepository() throws {
        let reader = AnimatedStudioMemoryReader(files: fixture())
        let repository = GModStudioModelRepository(
            reader: reader,
            budget: assetBudget()
        )
        let cache = try GModStudioAnimatedRenderableModelCache(
            repository: repository,
            compilePolicy: compilePolicy()
        )

        XCTAssertEqual(
            cache.resolve(
                model: SourceEntityModelReference("../outside.mdl"),
                bodyValue: 0,
                skinFamilyIndex: 0,
                lodIndex: 0,
                selection: GModStudioAnimationFrameSelection(
                    sequenceIndex: 0,
                    blendIndex: 0,
                    frame: 0
                )
            ),
            .failed(.cache(.invalidModelPath("../outside.mdl")))
        )
        XCTAssertEqual(reader.totalReadCount, 0)
        XCTAssertEqual(cache.cachedPreparedEntryCount, 0)
    }

    func testRejectsPreparedGeometryLargerThanCacheCap() throws {
        let reader = AnimatedStudioMemoryReader(files: fixture())
        let repository = GModStudioModelRepository(
            reader: reader,
            budget: assetBudget()
        )
        let cache = try GModStudioAnimatedRenderableModelCache(
            repository: repository,
            compilePolicy: compilePolicy(),
            cachePolicy: GModStudioAnimatedRenderableModelCachePolicy(
                maximumPreparedEntryCount: 1,
                maximumRetainedVertexCount: 5
            )
        )

        XCTAssertEqual(
            cache.resolve(
                model: SourceEntityModelReference(Paths.mdl),
                bodyValue: 0,
                skinFamilyIndex: 0,
                lodIndex: 0,
                selection: GModStudioAnimationFrameSelection(
                    sequenceIndex: 0,
                    blendIndex: 0,
                    frame: 0
                )
            ),
            .failed(.cache(.retainedVertexCountExceedsCache(
                model: Paths.mdl,
                requested: 6,
                cap: 5
            )))
        )
        XCTAssertEqual(cache.cachedRetainedVertexCount, 0)
    }
}

private extension GModStudioAnimatedRenderableModelCacheTests {
    enum Paths {
        static let mdl = "models/codex/animated_cache.mdl"
        static let vvd = "models/codex/animated_cache.vvd"
        static let vtx = "models/codex/animated_cache.dx90.vtx"
    }

    enum MDLOffsets {
        static let bone = 408
        static let bodyPart = 624
        static let model = 648
        static let mesh = 796
        static let animation = 912
        static let sequence = 1_012
        static let blendTable = 1_224
        static let animationRecord = 1_228
        static let textures = 1_280
        static let textureNames = 1_408
        static let cdTextureOffsets = 1_432
        static let cdTextureName = 1_436
        static let skins = 1_456
        static let bodyName = 1_460
        static let boneName = 1_468
        static let surfaceName = 1_476
        static let animationName = 1_484
        static let sequenceName = 1_500
        static let activityName = 1_516
    }

    enum VTXOffsets {
        static let bodyPart = 44
        static let model = 52
        static let lod = 60
        static let mesh = 72
        static let stripGroup = 81
        static let vertices = 106
        static let indices = 133
        static let strip = 139
    }

    func productionCache() throws -> GModStudioAnimatedRenderableModelCache {
        try GModStudioAnimatedRenderableModelCache(
            repository: GModStudioModelRepository(
                reader: AnimatedStudioMemoryReader(files: fixture()),
                budget: assetBudget()
            ),
            compilePolicy: compilePolicy(),
            cachePolicy: GModStudioAnimatedRenderableModelCachePolicy(
                maximumPreparedEntryCount: 2,
                maximumRetainedVertexCount: 12
            )
        )
    }

    func fixture() -> [String: Data] {
        [
            Paths.mdl: makeMDL(),
            Paths.vvd: makeVVD(),
            Paths.vtx: makeVTX(),
        ]
    }

    func assetBudget() -> SourceStudioModelAssetBudget {
        SourceStudioModelAssetBudget(
            maximumBytesByKind: [.mdl: 2_048, .vvd: 256, .vtx: 256],
            maximumTotalBytes: 2_560,
            maximumVVDVertices: 3,
            maximumVVDFixups: 0,
            maximumVTXBodyParts: 1
        )
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

    func makeMDL() -> Data {
        var bytes = [UInt8](repeating: 0, count: 1_536)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString(Paths.mdl, at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)

        putInt32(1, at: 156, into: &bytes)
        putInt32(Int32(MDLOffsets.bone), at: 160, into: &bytes)
        putInt32(1, at: 180, into: &bytes)
        putInt32(Int32(MDLOffsets.animation), at: 184, into: &bytes)
        putInt32(1, at: 188, into: &bytes)
        putInt32(Int32(MDLOffsets.sequence), at: 192, into: &bytes)
        putInt32(2, at: 204, into: &bytes)
        putInt32(Int32(MDLOffsets.textures), at: 208, into: &bytes)
        putInt32(1, at: 212, into: &bytes)
        putInt32(Int32(MDLOffsets.cdTextureOffsets), at: 216, into: &bytes)
        putInt32(1, at: 220, into: &bytes)
        putInt32(2, at: 224, into: &bytes)
        putInt32(Int32(MDLOffsets.skins), at: 228, into: &bytes)
        putInt32(1, at: 232, into: &bytes)
        putInt32(Int32(MDLOffsets.bodyPart), at: 236, into: &bytes)

        putCString("root", at: MDLOffsets.boneName, capacity: 5, into: &bytes)
        putCString("default", at: MDLOffsets.surfaceName, capacity: 8, into: &bytes)
        putInt32(
            Int32(MDLOffsets.boneName - MDLOffsets.bone),
            at: MDLOffsets.bone,
            into: &bytes
        )
        putInt32(-1, at: MDLOffsets.bone + 4, into: &bytes)
        for index in 0..<6 {
            putInt32(-1, at: MDLOffsets.bone + 8 + index * 4, into: &bytes)
        }
        putQuaternion(.identity, at: MDLOffsets.bone + 44, into: &bytes)
        putMatrix(.identity, at: MDLOffsets.bone + 96, into: &bytes)
        putQuaternion(.identity, at: MDLOffsets.bone + 144, into: &bytes)
        putInt32(
            Int32(MDLOffsets.surfaceName - MDLOffsets.bone),
            at: MDLOffsets.bone + 176,
            into: &bytes
        )

        putCString("body", at: MDLOffsets.bodyName, capacity: 5, into: &bytes)
        putInt32(
            Int32(MDLOffsets.bodyName - MDLOffsets.bodyPart),
            at: MDLOffsets.bodyPart,
            into: &bytes
        )
        putInt32(1, at: MDLOffsets.bodyPart + 4, into: &bytes)
        putInt32(1, at: MDLOffsets.bodyPart + 8, into: &bytes)
        putInt32(
            Int32(MDLOffsets.model - MDLOffsets.bodyPart),
            at: MDLOffsets.bodyPart + 12,
            into: &bytes
        )

        putCString("animated_cache", at: MDLOffsets.model, capacity: 64, into: &bytes)
        putFloat(32, at: MDLOffsets.model + 68, into: &bytes)
        putInt32(1, at: MDLOffsets.model + 72, into: &bytes)
        putInt32(
            Int32(MDLOffsets.mesh - MDLOffsets.model),
            at: MDLOffsets.model + 76,
            into: &bytes
        )
        putInt32(3, at: MDLOffsets.model + 80, into: &bytes)

        putInt32(0, at: MDLOffsets.mesh, into: &bytes)
        putInt32(
            Int32(MDLOffsets.model - MDLOffsets.mesh),
            at: MDLOffsets.mesh + 4,
            into: &bytes
        )
        putInt32(3, at: MDLOffsets.mesh + 8, into: &bytes)
        putInt32(42, at: MDLOffsets.mesh + 32, into: &bytes)
        putVector(SourceVector3(2, 0, 0), at: MDLOffsets.mesh + 36, into: &bytes)
        putInt32(3, at: MDLOffsets.mesh + 52, into: &bytes)

        putCString(
            "move_root",
            at: MDLOffsets.animationName,
            capacity: 10,
            into: &bytes
        )
        putInt32(-Int32(MDLOffsets.animation), at: MDLOffsets.animation, into: &bytes)
        putInt32(
            Int32(MDLOffsets.animationName - MDLOffsets.animation),
            at: MDLOffsets.animation + 4,
            into: &bytes
        )
        putFloat(30, at: MDLOffsets.animation + 8, into: &bytes)
        putInt32(10, at: MDLOffsets.animation + 16, into: &bytes)
        putInt32(0, at: MDLOffsets.animation + 52, into: &bytes)
        putInt32(
            Int32(MDLOffsets.animationRecord - MDLOffsets.animation),
            at: MDLOffsets.animation + 56,
            into: &bytes
        )

        putCString(
            "move_sequence",
            at: MDLOffsets.sequenceName,
            capacity: 14,
            into: &bytes
        )
        putCString("ACT_IDLE", at: MDLOffsets.activityName, capacity: 9, into: &bytes)
        putInt32(-Int32(MDLOffsets.sequence), at: MDLOffsets.sequence, into: &bytes)
        putInt32(
            Int32(MDLOffsets.sequenceName - MDLOffsets.sequence),
            at: MDLOffsets.sequence + 4,
            into: &bytes
        )
        putInt32(
            Int32(MDLOffsets.activityName - MDLOffsets.sequence),
            at: MDLOffsets.sequence + 8,
            into: &bytes
        )
        putInt32(1, at: MDLOffsets.sequence + 56, into: &bytes)
        putInt32(
            Int32(MDLOffsets.blendTable - MDLOffsets.sequence),
            at: MDLOffsets.sequence + 60,
            into: &bytes
        )
        putInt32(1, at: MDLOffsets.sequence + 68, into: &bytes)
        putInt32(1, at: MDLOffsets.sequence + 72, into: &bytes)
        putFloat(9, at: MDLOffsets.sequence + 132, into: &bytes)
        putInt32(-1, at: MDLOffsets.sequence + 136, into: &bytes)
        putInt32(-1, at: MDLOffsets.sequence + 140, into: &bytes)
        putInt16(0, at: MDLOffsets.blendTable, into: &bytes)

        bytes[MDLOffsets.animationRecord] = 0
        bytes[MDLOffsets.animationRecord + 1] = 0x01
        putInt16(10, at: MDLOffsets.animationRecord + 2, into: &bytes)
        putVector48(
            x: 0x4500,
            y: 0,
            z: 0,
            at: MDLOffsets.animationRecord + 4,
            into: &bytes
        )
        bytes[MDLOffsets.animationRecord + 10] = 255

        putInt32(128, at: MDLOffsets.textures, into: &bytes)
        putInt32(72, at: MDLOffsets.textures + 64, into: &bytes)
        putCString("base", at: MDLOffsets.textureNames, capacity: 5, into: &bytes)
        putCString(
            "alternate",
            at: MDLOffsets.textureNames + 8,
            capacity: 10,
            into: &bytes
        )
        putInt32(
            Int32(MDLOffsets.cdTextureName),
            at: MDLOffsets.cdTextureOffsets,
            into: &bytes
        )
        putCString(
            "models/codex/",
            at: MDLOffsets.cdTextureName,
            capacity: 14,
            into: &bytes
        )
        putInt16(0, at: MDLOffsets.skins, into: &bytes)
        putInt16(1, at: MDLOffsets.skins + 2, into: &bytes)
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
            putFloat(1, at: base, into: &bytes)
            bytes[base + 12] = 0
            bytes[base + 15] = 1
            putVector(SourceVector3(Float(index + 1), 0, 0), at: base + 16, into: &bytes)
            putVector(SourceVector3(0, 0, 1), at: base + 28, into: &bytes)
            putFloat(Float(index) / 2, at: base + 40, into: &bytes)
            putFloat(Float(index) / 4, at: base + 44, into: &bytes)
        }
        return Data(bytes)
    }

    func makeVTX() -> Data {
        var bytes = [UInt8](repeating: 0, count: 166)
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
        putUInt16(1, at: 8, into: &bytes)
        putUInt16(1, at: 10, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        putInt32(checksum, at: 16, into: &bytes)
        putInt32(1, at: 20, into: &bytes)
        putInt32(36, at: 24, into: &bytes)
        putInt32(1, at: 28, into: &bytes)
        putInt32(Int32(VTXOffsets.bodyPart), at: 32, into: &bytes)

        putInt32(1, at: VTXOffsets.bodyPart, into: &bytes)
        putInt32(8, at: VTXOffsets.bodyPart + 4, into: &bytes)
        putInt32(1, at: VTXOffsets.model, into: &bytes)
        putInt32(8, at: VTXOffsets.model + 4, into: &bytes)
        putInt32(1, at: VTXOffsets.lod, into: &bytes)
        putInt32(12, at: VTXOffsets.lod + 4, into: &bytes)
        putInt32(1, at: VTXOffsets.mesh, into: &bytes)
        putInt32(9, at: VTXOffsets.mesh + 4, into: &bytes)

        putInt32(3, at: VTXOffsets.stripGroup, into: &bytes)
        putInt32(25, at: VTXOffsets.stripGroup + 4, into: &bytes)
        putInt32(3, at: VTXOffsets.stripGroup + 8, into: &bytes)
        putInt32(52, at: VTXOffsets.stripGroup + 12, into: &bytes)
        putInt32(1, at: VTXOffsets.stripGroup + 16, into: &bytes)
        putInt32(58, at: VTXOffsets.stripGroup + 20, into: &bytes)

        for (index, originalVertex) in [UInt16(2), 0, 1].enumerated() {
            let base = VTXOffsets.vertices + index * 9
            bytes[base + 3] = 1
            putUInt16(originalVertex, at: base + 4, into: &bytes)
            bytes[base + 6] = 0
        }
        putUInt16(0, at: VTXOffsets.indices, into: &bytes)
        putUInt16(1, at: VTXOffsets.indices + 2, into: &bytes)
        putUInt16(2, at: VTXOffsets.indices + 4, into: &bytes)

        putInt32(3, at: VTXOffsets.strip, into: &bytes)
        putInt32(3, at: VTXOffsets.strip + 8, into: &bytes)
        putUInt16(1, at: VTXOffsets.strip + 16, into: &bytes)
        bytes[VTXOffsets.strip + 18] = SourceStudioMeshTopology.triangleList.rawValue
        return Data(bytes)
    }
}

private final class AnimatedStudioMemoryReader:
    SourceStudioBoundedAssetReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let files: [String: Data]
    private var counts: [String: Int] = [:]

    init(files: [String: Data]) {
        self.files = Dictionary(uniqueKeysWithValues: files.map {
            ($0.key.lowercased(), $0.value)
        })
    }

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        let key = path.lowercased()
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
        guard let data = files[key] else { return .missing }
        guard data.count <= maximumBytes else {
            return .exceeded(actual: data.count)
        }
        return .data(data)
    }

    func readCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path.lowercased(), default: 0]
    }

    var totalReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
}

private func putCString(
    _ value: String,
    at offset: Int,
    capacity: Int,
    into bytes: inout [UInt8]
) {
    let encoded = Array(value.utf8.prefix(capacity - 1))
    for index in 0..<capacity { bytes[offset + index] = 0 }
    for (index, byte) in encoded.enumerated() { bytes[offset + index] = byte }
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

private func putQuaternion(
    _ value: SourceStudioQuaternion,
    at offset: Int,
    into bytes: inout [UInt8]
) {
    putFloat(value.x, at: offset, into: &bytes)
    putFloat(value.y, at: offset + 4, into: &bytes)
    putFloat(value.z, at: offset + 8, into: &bytes)
    putFloat(value.w, at: offset + 12, into: &bytes)
}

private func putMatrix(
    _ value: SourceStudioMatrix3x4,
    at offset: Int,
    into bytes: inout [UInt8]
) {
    let elements = [
        value.m00, value.m01, value.m02, value.m03,
        value.m10, value.m11, value.m12, value.m13,
        value.m20, value.m21, value.m22, value.m23,
    ]
    for (index, element) in elements.enumerated() {
        putFloat(element, at: offset + index * 4, into: &bytes)
    }
}

private func putVector48(
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

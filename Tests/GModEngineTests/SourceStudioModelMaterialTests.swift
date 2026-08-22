import Foundation
import Testing
@testable import GModEngine

@Suite("Bounded Source Studio model material tables")
struct SourceStudioModelMaterialTests {
    private let checksum: Int32 = 0x2468_1357

    @Test("texture, CD-texture, and skin tables resolve ordered immutable candidates")
    func decodesAndResolvesSkinFamilies() throws {
        let table = try SourceStudioModelMaterialDecoder.decode(
            loadPayload(mdl: makeMDL()),
            budget: decodeBudget()
        )

        #expect(table.checksum == checksum)
        #expect(table.modelName == Paths.mdl)
        #expect(table.textures == [
            SourceStudioModelTextureSnapshot(index: 0, name: "brick", flags: 11, usedCount: 4),
            SourceStudioModelTextureSnapshot(index: 1, name: "metal\\panel", flags: 0, usedCount: 0),
            SourceStudioModelTextureSnapshot(index: 2, name: "alt", flags: 0, usedCount: 0)
        ])
        #expect(table.cdTextureDirectories == ["models/props/", "shared\\"])
        #expect(table.skinReferenceCount == 2)
        #expect(table.skinFamilies == [
            SourceStudioModelSkinFamilySnapshot(index: 0, textureIndices: [0, 1]),
            SourceStudioModelSkinFamilySnapshot(index: 1, textureIndices: [2, 1])
        ])

        let base = try table.resolve(meshMaterialIndex: 0, skinFamilyIndex: 0)
        #expect(base == SourceStudioResolvedModelMaterialSnapshot(
            meshMaterialIndex: 0,
            skinFamilyIndex: 0,
            textureIndex: 0,
            textureName: "brick",
            cdTextureCandidates: [
                "materials/models/props/brick.vmt",
                "materials/shared/brick.vmt"
            ]
        ))
        let alternate = try table.resolve(meshMaterialIndex: 0, skinFamilyIndex: 1)
        #expect(alternate.textureIndex == 2)
        #expect(alternate.textureName == "alt")
        let slashes = try table.resolve(meshMaterialIndex: 1, skinFamilyIndex: 1)
        #expect(slashes.cdTextureCandidates == [
            "materials/models/props/metal/panel.vmt",
            "materials/shared/metal/panel.vmt"
        ])
    }

    @Test("negative header counts are rejected before any table allocation")
    func rejectsNegativeCounts() throws {
        var bytes = [UInt8](makeMDL())
        putInt32(-1, at: 204, into: &bytes)
        let payload = try loadPayload(mdl: Data(bytes))

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: decodeBudget())
            Issue.record("expected negative texture count rejection")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .invalidCount(field: "studiohdr_t.numtextures", value: -1))
        }
    }

    @Test("misaligned material-table offsets are typed failures")
    func rejectsMisalignedTableOffset() throws {
        var bytes = [UInt8](makeMDL())
        putInt32(409, at: 208, into: &bytes)
        let payload = try loadPayload(mdl: Data(bytes))

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: decodeBudget())
            Issue.record("expected misaligned table rejection")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .misalignedOffset(
                field: "studiohdr_t.textures",
                value: 409,
                alignment: 4
            ))
        }
    }

    @Test("CD-texture entries must be positive absolute header offsets")
    func rejectsInvalidCDTextureOffset() throws {
        var bytes = [UInt8](makeMDL())
        putInt32(0, at: Offsets.cdTextureOffsets, into: &bytes)
        let payload = try loadPayload(mdl: Data(bytes))

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: decodeBudget())
            Issue.record("expected invalid CD-texture offset rejection")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .invalidOffset(field: "cdtexture[0]", value: 0))
        }
    }

    @Test("texture names must terminate within the validated MDL bytes")
    func rejectsUnterminatedTextureName() throws {
        var bytes = [UInt8](makeMDL())
        putInt32(Int32(bytes.count - 1 - Offsets.textures), at: Offsets.textures, into: &bytes)
        bytes[bytes.count - 1] = 0x41
        let payload = try loadPayload(mdl: Data(bytes))

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: decodeBudget())
            Issue.record("expected unterminated name rejection")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .unterminatedString(
                field: "texture[0].name",
                start: bytes.count - 1
            ))
        }
    }

    @Test("texture-name scanning stops at the caller byte cap")
    func enforcesStringBudget() throws {
        let payload = try loadPayload(mdl: makeMDL())
        let budget = SourceStudioModelMaterialDecodeBudget(
            maximumTextures: 8,
            maximumCDTextureDirectories: 8,
            maximumSkinReferences: 8,
            maximumSkinFamilies: 8,
            maximumSkinEntries: 64,
            maximumStringBytes: 4,
            maximumTotalStringBytes: 512,
            maximumResolvedCandidateBytes: 512
        )

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: budget)
            Issue.record("expected texture-name byte cap rejection")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .stringByteCountExceeded(
                field: "texture[0].name",
                value: 5,
                cap: 4
            ))
        }
    }

    @Test("every signed skin reference must name an existing texture")
    func rejectsInvalidSkinReference() throws {
        var bytes = [UInt8](makeMDL())
        putInt16(3, at: Offsets.skins, into: &bytes)
        let payload = try loadPayload(mdl: Data(bytes))

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: decodeBudget())
            Issue.record("expected invalid skin reference rejection")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .invalidSkinReference(
                family: 0,
                materialSlot: 0,
                value: 3,
                textureCount: 3
            ))
        }
    }

    @Test("mesh material and skin-family selections remain typed at lookup time")
    func rejectsInvalidSelections() throws {
        let table = try SourceStudioModelMaterialDecoder.decode(
            loadPayload(mdl: makeMDL()),
            budget: decodeBudget()
        )

        do {
            _ = try table.resolve(meshMaterialIndex: 2, skinFamilyIndex: 0)
            Issue.record("expected mesh material selection failure")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .invalidMeshMaterialIndex(value: 2, skinReferenceCount: 2))
        }
        do {
            _ = try table.resolve(meshMaterialIndex: 0, skinFamilyIndex: 2)
            Issue.record("expected skin family selection failure")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .invalidSkinFamily(value: 2, available: 2))
        }
    }

    @Test("caller caps bound texture-table expansion")
    func enforcesTextureBudget() throws {
        let payload = try loadPayload(mdl: makeMDL())
        let budget = SourceStudioModelMaterialDecodeBudget(
            maximumTextures: 2,
            maximumCDTextureDirectories: 2,
            maximumSkinReferences: 2,
            maximumSkinFamilies: 2,
            maximumSkinEntries: 4,
            maximumStringBytes: 64,
            maximumTotalStringBytes: 256,
            maximumResolvedCandidateBytes: 256
        )

        do {
            _ = try SourceStudioModelMaterialDecoder.decode(payload, budget: budget)
            Issue.record("expected texture count budget failure")
        } catch let error as SourceStudioModelMaterialDecodeError {
            #expect(error == .exceedsBudget(
                field: "studiohdr_t.numtextures",
                value: 3,
                cap: 2
            ))
        }
    }
}

private extension SourceStudioModelMaterialTests {
    enum Paths {
        static let mdl = "models/props/material_test.mdl"
        static let vvd = "models/props/material_test.vvd"
        static let vtx = "models/props/material_test.dx90.vtx"
    }

    enum Offsets {
        static let textures = 408
        static let cdTextureOffsets = 624
        static let skins = 654
    }

    func decodeBudget() -> SourceStudioModelMaterialDecodeBudget {
        SourceStudioModelMaterialDecodeBudget(
            maximumTextures: 8,
            maximumCDTextureDirectories: 8,
            maximumSkinReferences: 8,
            maximumSkinFamilies: 8,
            maximumSkinEntries: 64,
            maximumStringBytes: 64,
            maximumTotalStringBytes: 512,
            maximumResolvedCandidateBytes: 512
        )
    }

    func loadPayload(mdl: Data) throws -> SourceStudioImmutableRenderPayload {
        let reader = MaterialMemoryAssetReader(files: [
            Paths.mdl: mdl,
            Paths.vvd: makeVVD(),
            Paths.vtx: makeVTX()
        ])
        let loader = SourceStudioModelAssetLoader(
            reader: reader,
            budget: SourceStudioModelAssetBudget(
                maximumBytesByKind: [.mdl: 4_096, .vvd: 128, .vtx: 128],
                maximumTotalBytes: 4_352,
                maximumVVDVertices: 1,
                maximumVVDFixups: 0,
                maximumVTXBodyParts: 0
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
        return try #require(outcome.asset).renderPayload
    }

    func makeMDL() -> Data {
        var bytes = [UInt8](repeating: 0, count: 768)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString(Paths.mdl, at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)

        putInt32(3, at: 204, into: &bytes)
        putInt32(Int32(Offsets.textures), at: 208, into: &bytes)
        putInt32(2, at: 212, into: &bytes)
        putInt32(Int32(Offsets.cdTextureOffsets), at: 216, into: &bytes)
        putInt32(2, at: 220, into: &bytes)
        putInt32(2, at: 224, into: &bytes)
        putInt32(Int32(Offsets.skins), at: 228, into: &bytes)

        putInt32(192, at: 408, into: &bytes)
        putInt32(11, at: 412, into: &bytes)
        putInt32(4, at: 416, into: &bytes)
        putInt32(134, at: 472, into: &bytes)
        putInt32(82, at: 536, into: &bytes)
        putCString("brick", at: 600, capacity: 6, into: &bytes)
        putCString("metal\\panel", at: 606, capacity: 12, into: &bytes)
        putCString("alt", at: 618, capacity: 4, into: &bytes)

        putInt32(632, at: Offsets.cdTextureOffsets, into: &bytes)
        putInt32(646, at: Offsets.cdTextureOffsets + 4, into: &bytes)
        putCString("models/props/", at: 632, capacity: 14, into: &bytes)
        putCString("shared\\", at: 646, capacity: 8, into: &bytes)

        putInt16(0, at: Offsets.skins, into: &bytes)
        putInt16(1, at: Offsets.skins + 2, into: &bytes)
        putInt16(2, at: Offsets.skins + 4, into: &bytes)
        putInt16(1, at: Offsets.skins + 6, into: &bytes)
        return Data(bytes)
    }

    func makeVVD() -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        putUInt32(0x5653_4449, at: 0, into: &bytes)
        putInt32(4, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        return Data(bytes)
    }

    func makeVTX() -> Data {
        var bytes = [UInt8](repeating: 0, count: 44)
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
        putUInt16(3, at: 8, into: &bytes)
        putUInt16(3, at: 10, into: &bytes)
        putInt32(3, at: 12, into: &bytes)
        putInt32(checksum, at: 16, into: &bytes)
        putInt32(1, at: 20, into: &bytes)
        putInt32(36, at: 24, into: &bytes)
        return Data(bytes)
    }
}

private struct MaterialMemoryAssetReader: SourceStudioBoundedAssetReading {
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

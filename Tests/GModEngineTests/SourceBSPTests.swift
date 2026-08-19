import Foundation
import XCTest
@testable import GModEngine

final class SourceBSPTests: XCTestCase {
    func testInstalledMapDiagnostic() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_BSP_DIAGNOSTIC_PATH"],
              !path.isEmpty else {
            throw XCTSkip("Set GMOD_BSP_DIAGNOSTIC_PATH to a locally installed BSP")
        }

        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let bsp = try SourceBSP(data: bytes)
        let originLeaf = try bsp.leafIndex(containing: .zero)
        let verticalTrace = try bsp.traceWorld(
            SourceRay(
                start: SourceVector3(0, 0, 4096),
                end: SourceVector3(0, 0, -4096)
            ),
            mask: .solid
        )
        print(
            "SourceBSP diagnostic:",
            "path=\(path)",
            "version=\(bsp.header.version)",
            "revision=\(bsp.header.mapRevision)",
            "planes=\(bsp.planes.count)",
            "vertices=\(bsp.vertices.count)",
            "faces=\(bsp.faces.count)",
            "leaves=\(bsp.leaves.count)",
            "leafFaces=\(bsp.leafFaces.count)",
            "leafBrushes=\(bsp.leafBrushes.count)",
            "brushes=\(bsp.brushes.count)",
            "originLeaf=\(originLeaf)",
            "verticalSolidFraction=\(verticalTrace.fraction)"
        )
        XCTAssertTrue([20, 21].contains(bsp.header.version))
        XCTAssertEqual(bsp.header.lumps.count, 64)
        XCTAssertFalse(bsp.entities.rawBytes.isEmpty)
        XCTAssertFalse(bsp.models.isEmpty)
        XCTAssertTrue(verticalTrace.fraction.isFinite)
    }

    func testSyntheticVersion20ParsesSupportedCoreLumpsAndPreservesUnknownBytes() throws {
        let bsp = try SourceBSP(data: makeCompleteBSP(version: 20))

        XCTAssertEqual(bsp.header.magic, SourceBSP.magic)
        XCTAssertEqual(bsp.header.version, 20)
        XCTAssertEqual(bsp.header.mapRevision, 73)
        XCTAssertEqual(bsp.header.lumps.count, 64)
        XCTAssertEqual(bsp.lumps.count, 64)

        XCTAssertEqual(
            bsp.entities.rawBytes,
            Data("{\n\"classname\" \"worldspawn\"\n}\n\0".utf8)
        )
        XCTAssertEqual(bsp.entities.text, "{\n\"classname\" \"worldspawn\"\n}\n")

        XCTAssertEqual(bsp.planes.count, 1)
        XCTAssertEqual(bsp.planes[0].normal.x, 1)
        XCTAssertEqual(bsp.planes[0].normal.y, 0)
        XCTAssertEqual(bsp.planes[0].distance, 64)
        XCTAssertEqual(bsp.planes[0].type, 0)

        XCTAssertEqual(bsp.textureData.count, 1)
        XCTAssertEqual(bsp.textureData[0].nameStringTableID, 3)
        XCTAssertEqual(bsp.textureData[0].width, 512)
        XCTAssertEqual(bsp.textureData[0].viewHeight, 256)

        XCTAssertEqual(bsp.vertices.count, 3)
        XCTAssertEqual(bsp.vertices[0].point, SourceBSPVector3(x: 1, y: 2, z: 3))

        XCTAssertEqual(bsp.nodes.count, 1)
        XCTAssertEqual(bsp.nodes[0].children, [-1, -2])
        XCTAssertEqual(bsp.nodes[0].mins, SourceBSPShortVector3(x: -16, y: -8, z: -4))
        XCTAssertEqual(bsp.nodes[0].maxs, SourceBSPShortVector3(x: 16, y: 8, z: 4))
        XCTAssertEqual(bsp.nodes[0].area, -1)

        XCTAssertEqual(bsp.textureInfo.count, 1)
        XCTAssertEqual(bsp.textureInfo[0].textureVectors.count, 2)
        XCTAssertEqual(bsp.textureInfo[0].textureVectors[0].offset, 4)
        XCTAssertEqual(bsp.textureInfo[0].lightmapVectors[1].z, 15)
        XCTAssertEqual(bsp.textureInfo[0].flags, 0x80)

        XCTAssertEqual(bsp.faces.count, 1)
        XCTAssertEqual(bsp.faces[0].surfaceEdgeCount, 3)
        XCTAssertEqual(bsp.faces[0].lightStyles, [0, 255, 255, 255])
        XCTAssertEqual(bsp.faces[0].area, 128.5)
        XCTAssertEqual(bsp.faces[0].primitiveCount, 2)
        XCTAssertTrue(bsp.faces[0].dynamicShadowsEnabled)

        XCTAssertEqual(bsp.leaves.count, 2)
        XCTAssertEqual(bsp.leaves[0].formatVersion, 1)
        XCTAssertEqual(bsp.leaves[0].area, 7)
        XCTAssertEqual(bsp.leaves[0].flags, 3)
        XCTAssertNil(bsp.leaves[0].ambientLighting)

        XCTAssertEqual(
            bsp.edges,
            [
                SourceBSPEdge(firstVertex: 0, secondVertex: 1),
                SourceBSPEdge(firstVertex: 1, secondVertex: 2),
                SourceBSPEdge(firstVertex: 2, secondVertex: 0),
            ]
        )
        XCTAssertEqual(bsp.surfaceEdges, [0, 1, 2])

        XCTAssertEqual(bsp.models.count, 1)
        XCTAssertEqual(bsp.models[0].headNode, 0)
        XCTAssertEqual(bsp.models[0].faceCount, 1)

        XCTAssertEqual(bsp.leafFaces, [0, 0])
        XCTAssertEqual(bsp.leafBrushes, [0, 0])

        XCTAssertEqual(bsp.brushes.count, 1)
        XCTAssertEqual(bsp.brushes[0].sideCount, 1)
        XCTAssertEqual(bsp.brushSides.count, 1)
        XCTAssertEqual(bsp.brushSides[0].displacementInfoIndex, -1)

        let unknown = try bsp.lump(at: 63)
        XCTAssertEqual(unknown.descriptor.index, 63)
        XCTAssertEqual(unknown.data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(bsp.lump(.planes).data.count, 20)
    }

    func testVersion21RequiresExplicitUnverifiedCorpusResearchPolicy() throws {
        let data = makeCompleteBSP(version: 21)
        XCTAssertThrowsError(try SourceBSP(data: data)) { error in
            XCTAssertEqual(error as? SourceBSPError, .unsupportedVersion(21))
        }
        let bsp = try SourceBSP(
            data: data,
            versionPolicy: .permitUnverifiedVersion21ForResearch
        )
        XCTAssertEqual(bsp.header.version, 21)
        XCTAssertEqual(bsp.planes.count, 1)
        XCTAssertEqual(bsp.faces.count, 1)
        XCTAssertEqual(bsp.leaves.first?.formatVersion, 1)
    }

    func testVersion19HeaderIsWithinTheOfficialSDKRange() throws {
        let bsp = try SourceBSP(data: makeBSP(version: 19))
        XCTAssertEqual(bsp.header.version, 19)
        XCTAssertEqual(bsp.lumps.count, 64)
    }

    func testVersionZeroLeafPreservesSixAmbientLightSamples() throws {
        var leaf = makeLeafPrefix()
        for index in UInt8(0)..<6 {
            leaf.appendUInt8(index)
            leaf.appendUInt8(index &+ 10)
            leaf.appendUInt8(index &+ 20)
            leaf.appendUInt8(UInt8(bitPattern: Int8(index) - 3))
        }
        leaf.appendUInt16(0) // C struct tail alignment

        let data = makeBSP(lumps: [
            SourceBSPLumpKind.leaves.rawValue: SyntheticLump(data: leaf, version: 0)
        ])
        let bsp = try SourceBSP(data: data)

        let parsed = try XCTUnwrap(bsp.leaves.first)
        XCTAssertEqual(parsed.formatVersion, 0)
        let ambient = try XCTUnwrap(parsed.ambientLighting)
        XCTAssertEqual(ambient.count, 6)
        XCTAssertEqual(ambient[0].exponent, -3)
        XCTAssertEqual(ambient[5].red, 5)
        XCTAssertEqual(ambient[5].green, 15)
        XCTAssertEqual(ambient[5].blue, 25)
        XCTAssertEqual(ambient[5].exponent, 2)
    }

    func testInvalidUTF8EntityTextKeepsExactBytes() throws {
        let bytes = Data([0x7B, 0xFF, 0x7D, 0x00])
        let data = makeBSP(lumps: [
            SourceBSPLumpKind.entities.rawValue: SyntheticLump(data: bytes, version: 0)
        ])
        let bsp = try SourceBSP(data: data)
        XCTAssertEqual(bsp.entities.rawBytes, bytes)
        XCTAssertNil(bsp.entities.text)
    }

    func testRejectsTruncatedHeaderBadMagicAndUnsupportedOuterVersion() throws {
        XCTAssertThrowsError(try SourceBSP(data: Data(repeating: 0, count: 20))) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .truncatedHeader(actualByteCount: 20, requiredByteCount: SourceBSP.headerByteCount)
            )
        }

        var badMagic = makeBSP()
        badMagic.replaceUInt32(at: 0, with: 0x1234_5678)
        XCTAssertThrowsError(try SourceBSP(data: badMagic)) { error in
            XCTAssertEqual(error as? SourceBSPError, .invalidMagic(0x1234_5678))
        }

        var unsupportedVersion = makeBSP()
        unsupportedVersion.replaceInt32(at: 4, with: 18)
        XCTAssertThrowsError(try SourceBSP(data: unsupportedVersion)) { error in
            XCTAssertEqual(error as? SourceBSPError, .unsupportedVersion(18))
        }
    }

    func testRejectsNegativeAndOutOfFileLumpBoundsWithoutIntegerTruncation() throws {
        var negativeLength = makeBSP()
        negativeLength.replaceInt32(at: lumpDescriptorOffset(2) + 4, with: -1)
        XCTAssertThrowsError(try SourceBSP(data: negativeLength)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .invalidLumpBounds(
                    index: 2,
                    offset: 0,
                    length: -1,
                    fileByteCount: negativeLength.count
                )
            )
        }

        var hugeRange = makeBSP()
        hugeRange.replaceInt32(at: lumpDescriptorOffset(4), with: Int32.max - 4)
        hugeRange.replaceInt32(at: lumpDescriptorOffset(4) + 4, with: 16)
        XCTAssertThrowsError(try SourceBSP(data: hugeRange)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .invalidLumpBounds(
                    index: 4,
                    offset: Int64(Int32.max - 4),
                    length: 16,
                    fileByteCount: hugeRange.count
                )
            )
        }
    }

    func testRejectsNonemptyLumpThatAliasesHeaderBytes() throws {
        var headerAlias = makeBSP()
        headerAlias.replaceInt32(at: lumpDescriptorOffset(12), with: 8)
        headerAlias.replaceInt32(at: lumpDescriptorOffset(12) + 4, with: 4)
        XCTAssertThrowsError(try SourceBSP(data: headerAlias)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .lumpOverlapsHeader(index: 12, offset: 8, length: 4)
            )
        }
    }

    func testRejectsMalformedFixedRecordCountsAndUnknownTypedVersions() throws {
        let malformedPlanes = makeBSP(lumps: [
            SourceBSPLumpKind.planes.rawValue: SyntheticLump(
                data: Data(repeating: 0, count: 19),
                version: 0
            )
        ])
        XCTAssertThrowsError(try SourceBSP(data: malformedPlanes)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .invalidRecordByteCount(index: 1, byteCount: 19, recordByteCount: 20)
            )
        }

        let unknownFaceVersion = makeBSP(lumps: [
            SourceBSPLumpKind.faces.rawValue: SyntheticLump(
                data: Data(repeating: 0, count: 56),
                version: 0
            )
        ])
        XCTAssertThrowsError(try SourceBSP(data: unknownFaceVersion)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .unsupportedLumpVersion(index: 7, actual: 0, supported: [1])
            )
        }
    }

    func testUnknownCompressedLumpIsOpaqueButTypedCompressedLumpIsUnsupported() throws {
        let declaredCompressed = makeBSP(lumps: [
            40: SyntheticLump(
                data: Data("LZMApayload".utf8),
                version: 0,
                uncompressedSize: 4096
            )
        ])
        let bsp = try SourceBSP(data: declaredCompressed)
        XCTAssertTrue(bsp.lumps[40].descriptor.isCompressed)
        XCTAssertEqual(bsp.lumps[40].data, Data("LZMApayload".utf8))

        let typedCompressed = makeBSP(lumps: [
            SourceBSPLumpKind.planes.rawValue: SyntheticLump(
                data: Data("LZMApayload-for-plane".utf8),
                version: 0,
                uncompressedSize: 20
            )
        ])
        XCTAssertThrowsError(try SourceBSP(data: typedCompressed)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .unsupportedCompressedLump(
                    index: SourceBSPLumpKind.planes.rawValue,
                    declaredUncompressedSize: 20,
                    hasLZMASignature: true
                )
            )
        }

        // bspfile.h defines uncompressedSize == 0 as uncompressed. A coincidental
        // byte prefix in an opaque lump is not enough to override the header.
        let signatureOnly = makeBSP(lumps: [
            63: SyntheticLump(data: Data("LZMAnot-guessed-as-raw".utf8), version: 0)
        ])
        let signatureBSP = try SourceBSP(data: signatureOnly)
        XCTAssertFalse(signatureBSP.lumps[63].descriptor.isCompressed)
        XCTAssertEqual(signatureBSP.lumps[63].data, Data("LZMAnot-guessed-as-raw".utf8))
    }

    func testWorldNodeTraversalAndLeafContentsMask() throws {
        let bsp = try SourceBSP(
            data: makeSplitTreeBSP(
                frontContents: Int32(bitPattern: SourceContents.water.rawValue),
                backContents: Int32(bitPattern: SourceContents.solid.rawValue)
            )
        )

        XCTAssertEqual(try bsp.leafIndex(containing: SourceVector3(10, 0, 0)), 0)
        XCTAssertEqual(try bsp.leafIndex(containing: SourceVector3(0, 0, 0)), 0)
        XCTAssertEqual(try bsp.leafIndex(containing: SourceVector3(-10, 0, 0)), 1)

        XCTAssertEqual(
            try bsp.worldPointContents(at: SourceVector3(10, 0, 0), mask: .water),
            .water
        )
        XCTAssertEqual(
            try bsp.worldPointContents(at: SourceVector3(10, 0, 0), mask: .solid),
            .empty
        )
        XCTAssertEqual(
            try bsp.worldPointContents(at: SourceVector3(-10, 0, 0), mask: .solid),
            .solid
        )
    }

    func testWorldTraceTraversesLeafBrushTableAndHonorsContentsMask() throws {
        let bsp = try SourceBSP(data: makeBrushWorldBSP())
        let ray = SourceRay(
            start: SourceVector3(-10, 0, 0),
            end: SourceVector3(10, 0, 0)
        )

        let maskedOut = try bsp.traceWorld(ray, mask: .water)
        XCTAssertFalse(maskedOut.didHit)
        XCTAssertEqual(maskedOut.fraction, 1)

        let hit = try bsp.traceWorld(ray, mask: .solid)
        XCTAssertTrue(hit.didHit)
        XCTAssertTrue(hit.didHitWorld)
        XCTAssertFalse(hit.startSolid)
        XCTAssertEqual(hit.contents, .solid)
        XCTAssertEqual(hit.fraction, 0.3984375, accuracy: 0.000_001)
        XCTAssertEqual(hit.endPosition.x, -2.03125, accuracy: 0.000_001)
        XCTAssertEqual(hit.endPosition.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(hit.plane.normal, SourceVector3(-1, 0, 0))
        XCTAssertEqual(hit.plane.distance, 2)
        XCTAssertEqual(hit.surface.flags, 0x0080)

        XCTAssertEqual(bsp.collisionWorld(mask: .solid).primitives.count, 1)
        XCTAssertTrue(bsp.collisionWorld(mask: .water).primitives.isEmpty)
    }

    func testReferenceValidationRejectsLeafBrushOverflowInvalidPlaneAndNodeCycle() throws {
        var overflowingLeaf = makeLeafPrefix(firstLeafBrush: 0, leafBrushCount: 1)
        overflowingLeaf.appendUInt16(0)
        let badLeafRange = makeBSP(lumps: [
            SourceBSPLumpKind.leaves.rawValue: SyntheticLump(
                data: overflowingLeaf,
                version: 1
            )
        ])
        XCTAssertThrowsError(try SourceBSP(data: badLeafRange)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .invalidReferenceRange(
                    context: "leaf 0 brush table",
                    first: 0,
                    count: 1,
                    availableCount: 0
                )
            )
        }

        var brush = Data()
        brush.appendInt32(0)
        brush.appendInt32(1)
        brush.appendInt32(Int32(bitPattern: SourceContents.solid.rawValue))
        var invalidSide = Data()
        invalidSide.appendUInt16(7)
        invalidSide.appendInt16(-1)
        invalidSide.appendInt16(-1)
        invalidSide.appendInt16(0)
        let badPlane = makeBSP(lumps: [
            SourceBSPLumpKind.brushes.rawValue: SyntheticLump(data: brush, version: 0),
            SourceBSPLumpKind.brushSides.rawValue: SyntheticLump(data: invalidSide, version: 0),
        ])
        XCTAssertThrowsError(try SourceBSP(data: badPlane)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .invalidReference(
                    context: "brush side 0 plane",
                    index: 7,
                    availableCount: 0
                )
            )
        }

        var plane = Data()
        plane.appendVector3(1, 0, 0)
        plane.appendFloat32(0)
        plane.appendInt32(0)
        var cyclicNode = Data()
        cyclicNode.appendInt32(0)
        cyclicNode.appendInt32(0)
        cyclicNode.appendInt32(0)
        cyclicNode.appendShortVector3(-1, -1, -1)
        cyclicNode.appendShortVector3(1, 1, 1)
        cyclicNode.appendUInt16(0)
        cyclicNode.appendUInt16(0)
        cyclicNode.appendInt16(-1)
        cyclicNode.appendUInt16(0)
        let cycle = makeBSP(lumps: [
            SourceBSPLumpKind.planes.rawValue: SyntheticLump(data: plane, version: 0),
            SourceBSPLumpKind.nodes.rawValue: SyntheticLump(data: cyclicNode, version: 0),
        ])
        XCTAssertThrowsError(try SourceBSP(data: cycle)) { error in
            XCTAssertEqual(error as? SourceBSPError, .cyclicNodeGraph(nodeIndex: 0))
        }
    }

    func testLeafFaceAndLeafBrushLumpsRequireVersionZeroAndExactUInt16Records() throws {
        let wrongVersion = makeBSP(lumps: [
            SourceBSPLumpKind.leafBrushes.rawValue: SyntheticLump(
                data: Data([0, 0]),
                version: 1
            )
        ])
        XCTAssertThrowsError(try SourceBSP(data: wrongVersion)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .unsupportedLumpVersion(index: 17, actual: 1, supported: [0])
            )
        }

        let oddBytes = makeBSP(lumps: [
            SourceBSPLumpKind.leafFaces.rawValue: SyntheticLump(
                data: Data([0]),
                version: 0
            )
        ])
        XCTAssertThrowsError(try SourceBSP(data: oddBytes)) { error in
            XCTAssertEqual(
                error as? SourceBSPError,
                .invalidRecordByteCount(index: 16, byteCount: 1, recordByteCount: 2)
            )
        }
    }

    func testLumpIndexAccessRejectsValuesOutsideHeaderTable() throws {
        let bsp = try SourceBSP(data: makeBSP())
        XCTAssertThrowsError(try bsp.lump(at: -1)) { error in
            XCTAssertEqual(error as? SourceBSPError, .invalidLumpIndex(-1))
        }
        XCTAssertThrowsError(try bsp.lump(at: 64)) { error in
            XCTAssertEqual(error as? SourceBSPError, .invalidLumpIndex(64))
        }
    }
}

private struct SyntheticLump {
    let data: Data
    let version: Int32
    let uncompressedSize: UInt32

    init(data: Data, version: Int32, uncompressedSize: UInt32 = 0) {
        self.data = data
        self.version = version
        self.uncompressedSize = uncompressedSize
    }
}

private func makeSplitTreeBSP(frontContents: Int32, backContents: Int32) -> Data {
    var plane = Data()
    plane.appendVector3(1, 0, 0)
    plane.appendFloat32(0)
    plane.appendInt32(0)

    var node = Data()
    node.appendInt32(0)
    node.appendInt32(-1) // front leaf 0
    node.appendInt32(-2) // back leaf 1
    node.appendShortVector3(-128, -128, -128)
    node.appendShortVector3(128, 128, 128)
    node.appendUInt16(0)
    node.appendUInt16(0)
    node.appendInt16(-1)
    node.appendUInt16(0)

    var leaves = makeLeafPrefix(contents: frontContents)
    leaves.appendUInt16(0)
    leaves.append(makeLeafPrefix(contents: backContents))
    leaves.appendUInt16(0)

    var model = Data()
    model.appendVector3(-128, -128, -128)
    model.appendVector3(128, 128, 128)
    model.appendVector3(0, 0, 0)
    model.appendInt32(0)
    model.appendInt32(0)
    model.appendInt32(0)

    return makeBSP(lumps: [
        SourceBSPLumpKind.planes.rawValue: SyntheticLump(data: plane, version: 0),
        SourceBSPLumpKind.nodes.rawValue: SyntheticLump(data: node, version: 0),
        SourceBSPLumpKind.leaves.rawValue: SyntheticLump(data: leaves, version: 1),
        SourceBSPLumpKind.models.rawValue: SyntheticLump(data: model, version: 0),
    ])
}

private func makeBrushWorldBSP() -> Data {
    var planes = Data()
    let definitions: [(Float, Float, Float, Float, Int32)] = [
        (1, 0, 0, 0, 0),
        (-1, 0, 0, 0, 0),
        (1, 0, 0, 2, 0),
        (-1, 0, 0, 2, 0),
        (0, 1, 0, 2, 1),
        (0, -1, 0, 2, 1),
        (0, 0, 1, 2, 2),
        (0, 0, -1, 2, 2),
    ]
    for definition in definitions {
        planes.appendVector3(definition.0, definition.1, definition.2)
        planes.appendFloat32(definition.3)
        planes.appendInt32(definition.4)
    }

    var textureData = Data()
    textureData.appendVector3(0, 0, 0)
    textureData.appendInt32(0)
    textureData.appendInt32(64)
    textureData.appendInt32(64)
    textureData.appendInt32(64)
    textureData.appendInt32(64)

    var node = Data()
    node.appendInt32(0)
    node.appendInt32(-1)
    node.appendInt32(-2)
    node.appendShortVector3(-128, -128, -128)
    node.appendShortVector3(128, 128, 128)
    node.appendUInt16(0)
    node.appendUInt16(0)
    node.appendInt16(-1)
    node.appendUInt16(0)

    var textureInfo = Data()
    for _ in 0..<16 { textureInfo.appendFloat32(0) }
    textureInfo.appendInt32(0x0080)
    textureInfo.appendInt32(0)

    let solid = Int32(bitPattern: SourceContents.solid.rawValue)
    var leaves = makeLeafPrefix(
        contents: solid,
        firstLeafBrush: 0,
        leafBrushCount: 1
    )
    leaves.appendUInt16(0)
    leaves.append(
        makeLeafPrefix(
            contents: solid,
            firstLeafBrush: 1,
            leafBrushCount: 1
        )
    )
    leaves.appendUInt16(0)

    var model = Data()
    model.appendVector3(-128, -128, -128)
    model.appendVector3(128, 128, 128)
    model.appendVector3(0, 0, 0)
    model.appendInt32(0)
    model.appendInt32(0)
    model.appendInt32(0)

    var leafBrushes = Data()
    leafBrushes.appendUInt16(0)
    leafBrushes.appendUInt16(0)

    var brush = Data()
    brush.appendInt32(0)
    brush.appendInt32(6)
    brush.appendInt32(solid)

    var brushSides = Data()
    for planeIndex in UInt16(2)...UInt16(7) {
        brushSides.appendUInt16(planeIndex)
        brushSides.appendInt16(0)
        brushSides.appendInt16(-1)
        brushSides.appendInt16(0)
    }

    return makeBSP(lumps: [
        SourceBSPLumpKind.planes.rawValue: SyntheticLump(data: planes, version: 0),
        SourceBSPLumpKind.textureData.rawValue: SyntheticLump(data: textureData, version: 0),
        SourceBSPLumpKind.nodes.rawValue: SyntheticLump(data: node, version: 0),
        SourceBSPLumpKind.textureInfo.rawValue: SyntheticLump(data: textureInfo, version: 0),
        SourceBSPLumpKind.leaves.rawValue: SyntheticLump(data: leaves, version: 1),
        SourceBSPLumpKind.models.rawValue: SyntheticLump(data: model, version: 0),
        SourceBSPLumpKind.leafBrushes.rawValue: SyntheticLump(data: leafBrushes, version: 0),
        SourceBSPLumpKind.brushes.rawValue: SyntheticLump(data: brush, version: 0),
        SourceBSPLumpKind.brushSides.rawValue: SyntheticLump(data: brushSides, version: 0),
    ])
}

private func makeCompleteBSP(version: Int32) -> Data {
    var plane = Data()
    plane.appendVector3(1, 0, 0)
    plane.appendFloat32(64)
    plane.appendInt32(0)

    var textureData = Data()
    textureData.appendVector3(0.1, 0.2, 0.3)
    textureData.appendInt32(3)
    textureData.appendInt32(512)
    textureData.appendInt32(256)
    textureData.appendInt32(512)
    textureData.appendInt32(256)

    var vertex = Data()
    vertex.appendVector3(1, 2, 3)
    vertex.appendVector3(4, 5, 6)
    vertex.appendVector3(7, 8, 9)

    var node = Data()
    node.appendInt32(0)
    node.appendInt32(-1)
    node.appendInt32(-2)
    node.appendShortVector3(-16, -8, -4)
    node.appendShortVector3(16, 8, 4)
    node.appendUInt16(0)
    node.appendUInt16(1)
    node.appendInt16(-1)
    node.appendUInt16(0) // C struct tail alignment

    var textureInfo = Data()
    for value in 1...16 {
        textureInfo.appendFloat32(Float(value))
    }
    textureInfo.appendInt32(0x80)
    textureInfo.appendInt32(0)

    var face = Data()
    face.appendUInt16(0)
    face.appendUInt8(1)
    face.appendUInt8(1)
    face.appendInt32(0)
    face.appendInt16(3)
    face.appendInt16(0)
    face.appendInt16(-1)
    face.appendInt16(-1)
    face.append(contentsOf: [0, 255, 255, 255])
    face.appendInt32(-1)
    face.appendFloat32(128.5)
    face.appendInt32(0)
    face.appendInt32(0)
    face.appendInt32(15)
    face.appendInt32(15)
    face.appendInt32(-1)
    face.appendUInt16(2)
    face.appendUInt16(0)
    face.appendUInt32(1)

    var leaf = makeLeafPrefix(
        firstLeafFace: 0,
        leafFaceCount: 1,
        firstLeafBrush: 0,
        leafBrushCount: 1
    )
    leaf.appendUInt16(0) // C struct tail alignment
    leaf.append(
        makeLeafPrefix(
            firstLeafFace: 1,
            leafFaceCount: 1,
            firstLeafBrush: 1,
            leafBrushCount: 1
        )
    )
    leaf.appendUInt16(0) // C struct tail alignment

    var edge = Data()
    edge.appendUInt16(0)
    edge.appendUInt16(1)
    edge.appendUInt16(1)
    edge.appendUInt16(2)
    edge.appendUInt16(2)
    edge.appendUInt16(0)

    var surfaceEdge = Data()
    surfaceEdge.appendInt32(0)
    surfaceEdge.appendInt32(1)
    surfaceEdge.appendInt32(2)

    var leafFaces = Data()
    leafFaces.appendUInt16(0)
    leafFaces.appendUInt16(0)

    var leafBrushes = Data()
    leafBrushes.appendUInt16(0)
    leafBrushes.appendUInt16(0)

    var model = Data()
    model.appendVector3(-16, -16, -16)
    model.appendVector3(16, 16, 16)
    model.appendVector3(0, 0, 0)
    model.appendInt32(0)
    model.appendInt32(0)
    model.appendInt32(1)

    var brush = Data()
    brush.appendInt32(0)
    brush.appendInt32(1)
    brush.appendInt32(1)

    var brushSide = Data()
    brushSide.appendUInt16(0)
    brushSide.appendInt16(0)
    brushSide.appendInt16(-1)
    brushSide.appendInt16(0)

    return makeBSP(
        version: version,
        revision: 73,
        lumps: [
            0: SyntheticLump(
                data: Data("{\n\"classname\" \"worldspawn\"\n}\n\0".utf8),
                version: 0
            ),
            1: SyntheticLump(data: plane, version: 0),
            2: SyntheticLump(data: textureData, version: 0),
            3: SyntheticLump(data: vertex, version: 0),
            5: SyntheticLump(data: node, version: 0),
            6: SyntheticLump(data: textureInfo, version: 0),
            7: SyntheticLump(data: face, version: 1),
            10: SyntheticLump(data: leaf, version: 1),
            12: SyntheticLump(data: edge, version: 0),
            13: SyntheticLump(data: surfaceEdge, version: 0),
            14: SyntheticLump(data: model, version: 0),
            16: SyntheticLump(data: leafFaces, version: 0),
            17: SyntheticLump(data: leafBrushes, version: 0),
            18: SyntheticLump(data: brush, version: 0),
            19: SyntheticLump(data: brushSide, version: 0),
            63: SyntheticLump(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), version: 27)
        ]
    )
}

private func makeLeafPrefix(
    contents: Int32 = 1,
    firstLeafFace: UInt16 = 0,
    leafFaceCount: UInt16 = 0,
    firstLeafBrush: UInt16 = 0,
    leafBrushCount: UInt16 = 0
) -> Data {
    var leaf = Data()
    leaf.appendInt32(contents)
    leaf.appendInt16(0)
    leaf.appendUInt16(7 | (3 << 9))
    leaf.appendShortVector3(-16, -8, -4)
    leaf.appendShortVector3(16, 8, 4)
    leaf.appendUInt16(firstLeafFace)
    leaf.appendUInt16(leafFaceCount)
    leaf.appendUInt16(firstLeafBrush)
    leaf.appendUInt16(leafBrushCount)
    leaf.appendInt16(-1)
    return leaf
}

private func makeBSP(
    version: Int32 = 20,
    revision: Int32 = 1,
    lumps: [Int: SyntheticLump] = [:]
) -> Data {
    var payloadOffsets: [Int: Int32] = [:]
    var nextOffset = SourceBSP.headerByteCount
    for index in 0..<64 {
        guard let lump = lumps[index], !lump.data.isEmpty else { continue }
        payloadOffsets[index] = Int32(nextOffset)
        nextOffset += lump.data.count
    }

    var result = Data()
    result.appendUInt32(SourceBSP.magic)
    result.appendInt32(version)
    for index in 0..<64 {
        if let lump = lumps[index], !lump.data.isEmpty {
            result.appendInt32(payloadOffsets[index]!)
            result.appendInt32(Int32(lump.data.count))
            result.appendInt32(lump.version)
            result.appendUInt32(lump.uncompressedSize)
        } else {
            result.appendInt32(0)
            result.appendInt32(0)
            result.appendInt32(lumps[index]?.version ?? 0)
            result.appendUInt32(lumps[index]?.uncompressedSize ?? 0)
        }
    }
    result.appendInt32(revision)
    XCTAssertEqual(result.count, SourceBSP.headerByteCount)

    for index in 0..<64 {
        if let lump = lumps[index], !lump.data.isEmpty {
            result.append(lump.data)
        }
    }
    return result
}

private func lumpDescriptorOffset(_ index: Int) -> Int {
    8 + index * 16
}

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        appendUInt8(UInt8(truncatingIfNeeded: value))
        appendUInt8(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendInt16(_ value: Int16) {
        appendUInt16(UInt16(bitPattern: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt8(UInt8(truncatingIfNeeded: value))
        appendUInt8(UInt8(truncatingIfNeeded: value >> 8))
        appendUInt8(UInt8(truncatingIfNeeded: value >> 16))
        appendUInt8(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendFloat32(_ value: Float) {
        appendUInt32(value.bitPattern)
    }

    mutating func appendVector3(_ x: Float, _ y: Float, _ z: Float) {
        appendFloat32(x)
        appendFloat32(y)
        appendFloat32(z)
    }

    mutating func appendShortVector3(_ x: Int16, _ y: Int16, _ z: Int16) {
        appendInt16(x)
        appendInt16(y)
        appendInt16(z)
    }

    mutating func replaceUInt32(at offset: Int, with value: UInt32) {
        replaceSubrange(
            offset..<(offset + 4),
            with: [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 24)
            ]
        )
    }

    mutating func replaceInt32(at offset: Int, with value: Int32) {
        replaceUInt32(at: offset, with: UInt32(bitPattern: value))
    }
}

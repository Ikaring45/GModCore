import Foundation
import Testing
@testable import GModEngine

@Suite("Bounded modern VPhysics COLLIDE_POLY decoding")
struct SourceVPhysicsCollisionTests {
    private let checksum: Int32 = 0x1020_3040

    @Test("solid zero retains raw IVP bytes and iteratively walks both leaves")
    func decodesSyntheticTwoLedgeTreeWithoutAttestingIt() throws {
        let fixture = try decode(makeModernPayload())
        guard case let .decoded(snapshot) = fixture.outcome else {
            Issue.record("expected a structurally decoded synthetic VPHY solid")
            return
        }

        #expect(snapshot.sourceData == fixture.sourceData)
        #expect(snapshot.solidIndex == 0)
        #expect(snapshot.payloadByteRange.offset == 20)
        #expect(snapshot.payloadByteRange.byteCount == 448)
        #expect(snapshot.collideHeader.serializationIdentifier == 0x5948_5056)
        #expect(snapshot.collideHeader.version == 0x0100)
        #expect(snapshot.collideHeader.modelType == 0)
        #expect(snapshot.surfaceHeader.surfaceByteCount == 420)
        #expect(snapshot.surfaceHeader.rawDragAxisAreas.x == 1)
        #expect(snapshot.surfaceHeader.rawDragAxisAreas.y == 2)
        #expect(snapshot.surfaceHeader.rawDragAxisAreas.z == 3)
        #expect(snapshot.compactSurface.rawMassCenter.x == 4)
        #expect(snapshot.compactSurface.rawMassCenter.y == 5)
        #expect(snapshot.compactSurface.rawMassCenter.z == 6)
        #expect(snapshot.compactSurface.rawRotationInertia.x == 7)
        #expect(snapshot.compactSurface.rawRotationInertia.y == 8)
        #expect(snapshot.compactSurface.rawRotationInertia.z == 9)
        #expect(snapshot.compactSurface.rawUpperLimitRadius == 10)
        #expect(snapshot.compactSurface.rawMaximumDeviation == 11)
        #expect(snapshot.compactSurface.declaredByteCount == 420)

        #expect(snapshot.treeNodes.map(\.byteRange.offset) == [96, 124, 152])
        #expect(snapshot.treeNodes.map(\.depth) == [0, 1, 1])
        #expect(snapshot.treeNodes.map(\.isTerminal) == [false, true, true])
        #expect(snapshot.ledges.map(\.headerByteRange.offset) == [180, 324])
        #expect(snapshot.ledges.map(\.pointTableByteRange.offset) == [260, 404])
        #expect(snapshot.ledges.map { $0.triangles.count } == [4, 4])
        #expect(snapshot.ledges.map { $0.points.count } == [4, 4])
        #expect(snapshot.ledges[0].triangles.map(\.materialIndex) == [1, 2, 3, 4])
        #expect(snapshot.ledges[1].triangles.map(\.materialIndex) == [5, 6, 7, 8])
        #expect(snapshot.ledges[0].points[3].position.z == 1)
        #expect(snapshot.ledges[1].points[0].position.x == 20)
        #expect(snapshot.verification == .unattested)
    }

    @Test("byte order, version, model type, and axis maps stay typed unavailable")
    func distinguishesUnsupportedFormatsFromMalformedData() throws {
        var swapped = makeModernPayload()
        replaceUInt32(at: 0, with: 0x5650_4859, in: &swapped)
        #expect(try decode(swapped).outcome == .unavailable(
            .unsupportedByteOrder(.bigEndian)
        ))

        var version = makeModernPayload()
        replaceUInt16(at: 4, with: 0x0200, in: &version)
        #expect(try decode(version).outcome == .unavailable(
            .unsupportedVersion(0x0200)
        ))

        var modelType = makeModernPayload()
        replaceInt16(at: 6, with: 1, in: &modelType)
        #expect(try decode(modelType).outcome == .unavailable(
            .unsupportedModelType(1)
        ))

        var axisMap = makeModernPayload()
        replaceInt32(at: 24, with: 16, in: &axisMap)
        #expect(try decode(axisMap).outcome == .unavailable(
            .unsupportedAxisMap(byteCount: 16)
        ))
    }

    @Test("tree traversal rejects misalignment, alias cycles, depth, and overlap")
    func rejectsUnsafeTreeStructure() throws {
        var misaligned = makeModernPayload()
        replaceInt32(at: 60, with: 49, in: &misaligned)
        #expect(try decode(misaligned).outcome == .invalid(.misaligned(
            field: "ledge tree root",
            offset: 97,
            alignment: 4
        )))

        var aliasedChild = makeModernPayload()
        replaceInt32(at: 76, with: 28, in: &aliasedChild)
        #expect(try decode(aliasedChild).outcome == .invalid(
            .nodeCycleOrAlias(offset: 124)
        ))

        let depthZero = SourceVPhysicsCollisionDecodeBudget(
            maximumSourceDataBytes: 2_048,
            maximumPayloadBytes: 1_024,
            maximumTreeNodes: 16,
            maximumTreeDepth: 0,
            maximumLedges: 8,
            maximumTriangles: 64,
            maximumPoints: 64
        )
        #expect(try decode(makeModernPayload(), budget: depthZero).outcome == .invalid(
            .treeDepthExceeded(actual: 1, cap: 0)
        ))

        var overlap = makeModernPayload()
        replaceInt32(at: 76, with: 0, in: &overlap)
        replaceInt32(at: 80, with: 4, in: &overlap)
        #expect(try decode(overlap).outcome == .invalid(.overlappingRanges(
            firstField: "compactledgenode_t@96",
            secondField: "compactledge_t@100"
        )))
    }

    @Test("ranges, finite coordinates, declared sizes, and solid geometry are verified")
    func rejectsMalformedGeometryAndMismatchedSourceData() throws {
        let original = makePHY(payload: makeModernPayload())
        let envelope = try decodeEnvelope(original)
        var changedSource = original
        changedSource[20] ^= 0x01
        #expect(SourceVPhysicsCollisionDecoder.decodeSolidZero(
            in: changedSource,
            envelope: envelope,
            budget: standardBudget()
        ) == .invalid(.solidFrameDoesNotMatchSourceData))

        var nonFinite = makeModernPayload()
        replaceFloat(at: 240, with: .nan, in: &nonFinite)
        #expect(try decode(nonFinite).outcome == .invalid(
            .nonFinite(field: "IVP point[0]")
        ))

        var tooSmall = makeModernPayload()
        let compactFlag = UInt32(1 << 2) | (UInt32(4) << 8)
        replaceUInt32(at: 168, with: compactFlag, in: &tooSmall)
        #expect(try decode(tooSmall).outcome == .invalid(
            .invalidDeclaredLedgeByteCount(
                ledgeOffset: 180,
                declared: 64,
                required: 80
            )
        ))

        var degenerate = makeModernPayload()
        let thirdPoint = Data(degenerate[272..<288])
        degenerate.replaceSubrange(288..<304, with: thirdPoint)
        #expect(try decode(degenerate).outcome == .invalid(
            .degenerateTriangle(ledgeOffset: 180, triangle: 2)
        ))

        let threePointBudget = SourceVPhysicsCollisionDecodeBudget(
            maximumSourceDataBytes: 2_048,
            maximumPayloadBytes: 1_024,
            maximumTreeNodes: 16,
            maximumTreeDepth: 8,
            maximumLedges: 8,
            maximumTriangles: 64,
            maximumPoints: 3
        )
        #expect(try decode(makeModernPayload(), budget: threePointBudget).outcome == .invalid(
            .pointCountExceeded(actual: 4, cap: 3)
        ))
    }
}

private extension SourceVPhysicsCollisionTests {
    func standardBudget() -> SourceVPhysicsCollisionDecodeBudget {
        SourceVPhysicsCollisionDecodeBudget(
            maximumSourceDataBytes: 2_048,
            maximumPayloadBytes: 1_024,
            maximumTreeNodes: 16,
            maximumTreeDepth: 8,
            maximumLedges: 8,
            maximumTriangles: 64,
            maximumPoints: 64
        )
    }

    func decode(
        _ payload: Data,
        budget: SourceVPhysicsCollisionDecodeBudget? = nil
    ) throws -> (
        sourceData: Data,
        outcome: SourceVPhysicsCollisionDecodeOutcome
    ) {
        let sourceData = makePHY(payload: payload)
        let envelope = try decodeEnvelope(sourceData)
        return (
            sourceData,
            SourceVPhysicsCollisionDecoder.decodeSolidZero(
                in: sourceData,
                envelope: envelope,
                budget: budget ?? standardBudget()
            )
        )
    }

    func decodeEnvelope(_ data: Data) throws -> SourcePHYCollisionEnvelopeSnapshot {
        try SourcePHYCollisionDecoder.decodeEnvelope(
            data,
            expectedSourceModelChecksum: checksum,
            budget: SourcePHYCollisionDecodeBudget(
                maximumFileBytes: 2_048,
                maximumSolids: 1,
                maximumBytesPerSolid: 1_024,
                maximumTotalSolidBytes: 1_024,
                maximumKeyValuesBytes: 16
            )
        )
    }

    func makePHY(payload: Data) -> Data {
        var data = Data()
        appendInt32(16, to: &data)
        appendInt32(0, to: &data)
        appendInt32(1, to: &data)
        appendInt32(checksum, to: &data)
        appendInt32(Int32(payload.count), to: &data)
        data.append(payload)
        data.append(0)
        return data
    }

    /// Two terminal compact ledges under one internal root. Offsets are local
    /// to the serialized solid payload; the PHY frame places the payload at 20.
    func makeModernPayload() -> Data {
        var data = Data(repeating: 0, count: 448)

        replaceUInt32(at: 0, with: 0x5948_5056, in: &data)
        replaceUInt16(at: 4, with: 0x0100, in: &data)
        replaceInt16(at: 6, with: 0, in: &data)
        replaceInt32(at: 8, with: 420, in: &data)
        replaceVector3(at: 12, with: (1, 2, 3), in: &data)
        replaceInt32(at: 24, with: 0, in: &data)

        replaceVector3(at: 28, with: (4, 5, 6), in: &data)
        replaceVector3(at: 40, with: (7, 8, 9), in: &data)
        replaceFloat(at: 52, with: 10, in: &data)
        replaceUInt32(at: 56, with: UInt32(11) | (UInt32(420) << 8), in: &data)
        replaceInt32(at: 60, with: 48, in: &data)
        replaceInt32(at: 64, with: 101, in: &data)
        replaceInt32(at: 68, with: 102, in: &data)
        replaceInt32(at: 72, with: 103, in: &data)

        writeNode(at: 76, rightRelativeOffset: 56, ledgeRelativeOffset: 0, in: &data)
        writeNode(at: 104, rightRelativeOffset: 0, ledgeRelativeOffset: 56, in: &data)
        writeNode(at: 132, rightRelativeOffset: 0, ledgeRelativeOffset: 172, in: &data)

        writeTetraLedge(
            at: 160,
            pointOffset: 240,
            translation: (0, 0, 0),
            firstMaterial: 1,
            clientData: 70,
            in: &data
        )
        writeTetraLedge(
            at: 304,
            pointOffset: 384,
            translation: (20, 30, 40),
            firstMaterial: 5,
            clientData: 80,
            in: &data
        )
        return data
    }

    func writeNode(
        at offset: Int,
        rightRelativeOffset: Int32,
        ledgeRelativeOffset: Int32,
        in data: inout Data
    ) {
        replaceInt32(at: offset, with: rightRelativeOffset, in: &data)
        replaceInt32(at: offset + 4, with: ledgeRelativeOffset, in: &data)
        replaceVector3(at: offset + 8, with: (0, 0, 0), in: &data)
        replaceFloat(at: offset + 20, with: 2, in: &data)
        data[offset + 24] = 1
        data[offset + 25] = 2
        data[offset + 26] = 3
        data[offset + 27] = 0
    }

    func writeTetraLedge(
        at ledgeOffset: Int,
        pointOffset: Int,
        translation: (Float, Float, Float),
        firstMaterial: UInt8,
        clientData: Int32,
        in data: inout Data
    ) {
        replaceInt32(
            at: ledgeOffset,
            with: Int32(pointOffset - ledgeOffset),
            in: &data
        )
        replaceInt32(at: ledgeOffset + 4, with: clientData, in: &data)
        let flags = UInt32(1 << 2) | (UInt32(5) << 8)
        replaceUInt32(at: ledgeOffset + 8, with: flags, in: &data)
        replaceInt16(at: ledgeOffset + 12, with: 4, in: &data)
        replaceInt16(at: ledgeOffset + 14, with: 0, in: &data)

        let triangles: [(UInt16, UInt16, UInt16)] = [
            (0, 2, 1),
            (0, 1, 3),
            (0, 3, 2),
            (1, 2, 3)
        ]
        for (index, triangle) in triangles.enumerated() {
            let triangleOffset = ledgeOffset + 16 + (index * 16)
            let rawTriangle = UInt32(index)
                | (UInt32(firstMaterial + UInt8(index)) << 24)
            replaceUInt32(at: triangleOffset, with: rawTriangle, in: &data)
            replaceUInt32(at: triangleOffset + 4, with: UInt32(triangle.0), in: &data)
            replaceUInt32(at: triangleOffset + 8, with: UInt32(triangle.1), in: &data)
            replaceUInt32(at: triangleOffset + 12, with: UInt32(triangle.2), in: &data)
        }

        let points: [(Float, Float, Float)] = [
            (0, 0, 0),
            (1, 0, 0),
            (0, 1, 0),
            (0, 0, 1)
        ]
        for (index, point) in points.enumerated() {
            replaceVector3(
                at: pointOffset + (index * 16),
                with: (
                    point.0 + translation.0,
                    point.1 + translation.1,
                    point.2 + translation.2
                ),
                in: &data
            )
            replaceUInt32(
                at: pointOffset + (index * 16) + 12,
                with: UInt32(index),
                in: &data
            )
        }
    }

    func replaceVector3(
        at offset: Int,
        with value: (Float, Float, Float),
        in data: inout Data
    ) {
        replaceFloat(at: offset, with: value.0, in: &data)
        replaceFloat(at: offset + 4, with: value.1, in: &data)
        replaceFloat(at: offset + 8, with: value.2, in: &data)
    }

    func appendInt32(_ value: Int32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func replaceInt16(at offset: Int, with value: Int16, in data: inout Data) {
        replaceUInt16(at: offset, with: UInt16(bitPattern: value), in: &data)
    }

    func replaceUInt16(at offset: Int, with value: UInt16, in data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.replaceSubrange(offset..<(offset + 2), with: $0)
        }
    }

    func replaceInt32(at offset: Int, with value: Int32, in data: inout Data) {
        replaceUInt32(at: offset, with: UInt32(bitPattern: value), in: &data)
    }

    func replaceUInt32(at offset: Int, with value: UInt32, in data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.replaceSubrange(offset..<(offset + 4), with: $0)
        }
    }

    func replaceFloat(at offset: Int, with value: Float, in data: inout Data) {
        replaceUInt32(at: offset, with: value.bitPattern, in: &data)
    }
}

import Foundation
import XCTest
@testable import GModEngine

final class SourceStudioAnimationTests: XCTestCase {
    func testDecodesBoneBindPoseAnimationAndAuthoredSequenceTable() throws {
        let model = try SourceStudioAnimationDecoder.decode(mdlData: makeAnimationModel())

        XCTAssertEqual(model.header.name, "models/codex/animation_golden.mdl")
        XCTAssertEqual(model.skeleton.bones.count, 2)
        XCTAssertEqual(model.skeleton.bones[0].name, "root")
        XCTAssertNil(model.skeleton.bones[0].parentIndex)
        XCTAssertEqual(model.skeleton.bones[1].name, "child")
        XCTAssertEqual(model.skeleton.bones[1].parentIndex, 0)
        assertVector(model.skeleton.bones[0].bindPosition, SourceVector3(1, 0, 0))
        assertVector(model.skeleton.bones[1].bindPosition, SourceVector3(2, 0, 0))
        assertVector(model.skeleton.bones[0].bindModelTransform.position, SourceVector3(1, 0, 0))
        assertVector(model.skeleton.bones[1].bindModelTransform.position, SourceVector3(3, 0, 0))

        XCTAssertEqual(model.animations.count, 1)
        let animation = try XCTUnwrap(model.animations.first)
        XCTAssertEqual(animation.name, "raw_pose")
        XCTAssertEqual(animation.framesPerSecond, 30)
        XCTAssertEqual(animation.frameCount, 30)
        XCTAssertEqual(animation.animationBlock, 0)
        XCTAssertEqual(animation.animationOffset, 320)
        XCTAssertEqual(animation.boneChannels.count, 2)
        XCTAssertEqual(animation.boneChannels[0].boneIndex, 0)
        XCTAssertEqual(animation.boneChannels[0].constantRotationFormat, .quaternion48)
        XCTAssertEqual(animation.boneChannels[1].boneIndex, 1)
        XCTAssertEqual(animation.boneChannels[1].constantRotationFormat, .quaternion64)

        XCTAssertEqual(model.sequences.count, 1)
        let sequence = try XCTUnwrap(model.sequences.first)
        XCTAssertEqual(sequence.label, "raw_sequence")
        XCTAssertEqual(sequence.groupSizeX, 1)
        XCTAssertEqual(sequence.groupSizeY, 1)
        XCTAssertEqual(sequence.animationIndices, [0])
        XCTAssertEqual(try sequence.animationIndex(x: 0, y: 0), 0)
        XCTAssertEqual(try model.animationIndex(sequenceIndex: 0, blendIndex: 0), 0)
    }

    func testEvaluatesExactRawFrameAndConcatenatesLocalToModelPose() throws {
        let model = try SourceStudioAnimationDecoder.decode(mdlData: makeAnimationModel())

        let pose = try model.pose(animationIndex: 0, frame: 17)
        XCTAssertEqual(pose.animationIndex, 0)
        XCTAssertEqual(pose.frame, 17)
        XCTAssertEqual(pose.bones.count, 2)
        assertVector(pose.bones[0].position, SourceVector3(5, 0, 0))
        assertVector(pose.bones[1].position, SourceVector3(2, 0, 0))
        assertVector(pose.bones[0].modelTransform.position, SourceVector3(5, 0, 0))
        // The root RAWROT Quaternion48 is an authored +90 degree yaw, so the
        // child's local +X translation becomes model +Y.
        assertVector(
            pose.bones[1].modelTransform.position,
            SourceVector3(5, 2, 0),
            accuracy: 0.001
        )

        let rootTransform = SourceStudioQuaternion.identity.matrix(
            position: SourceVector3(100, 0, 0)
        )
        let rooted = try model.pose(
            animationIndex: 0,
            frame: 29,
            rootTransform: rootTransform
        )
        assertVector(rooted.bones[0].modelTransform.position, SourceVector3(105, 0, 0))
        assertVector(
            rooted.bones[1].modelTransform.position,
            SourceVector3(105, 2, 0),
            accuracy: 0.001
        )
    }

    func testVector48UsesSourceInfinityNaNAndDenormalRules() throws {
        var bytes = bytes(of: makeAnimationModel())
        putUInt16(0x7C00, at: 1_170, into: &bytes) // +infinity -> +65504 in Source
        putUInt16(0x7E00, at: 1_172, into: &bytes) // NaN -> zero in Source
        putUInt16(0x0001, at: 1_174, into: &bytes) // smallest positive denormal

        let model = try SourceStudioAnimationDecoder.decode(mdlData: Data(bytes))
        let position = try XCTUnwrap(model.animations[0].boneChannels[0].constantPosition)
        XCTAssertEqual(position.x, 65_504)
        XCTAssertEqual(position.y, 0)
        XCTAssertEqual(position.z, 1 / 16_777_216.0, accuracy: 0.000_000_000_1)
    }

    func testRejectsMalformedDescriptorAndAnimationRecordChain() {
        var invalidBasePointer = bytes(of: makeAnimationModel())
        putInt32(-836, at: 840, into: &invalidBasePointer)
        assertDecodeError(
            Data(invalidBasePointer),
            equals: .invalidAnimationBasePointer(animation: 0, value: -836)
        )

        var missingInlineOffset = bytes(of: makeAnimationModel())
        putInt32(0, at: 840 + 56, into: &missingInlineOffset)
        assertDecodeError(
            Data(missingInlineOffset),
            equals: .invalidInlineAnimationOffset(animation: 0, value: 0)
        )

        var overlappingNext = bytes(of: makeAnimationModel())
        putInt16(8, at: 1_162, into: &overlappingNext)
        assertDecodeError(
            Data(overlappingNext),
            equals: .animationRecordPayloadOverlapsNext(
                animation: 0,
                recordOffset: 1_160,
                payloadEnd: 1_176,
                nextOffset: 1_168
            )
        )

        var duplicateBone = bytes(of: makeAnimationModel())
        duplicateBone[1_176] = 0
        assertDecodeError(
            Data(duplicateBone),
            equals: .nonIncreasingAnimationRecordBone(animation: 0, previous: 0, value: 0)
        )

        var unknownFlags = bytes(of: makeAnimationModel())
        unknownFlags[1_161] = 0x80
        assertDecodeError(
            Data(unknownFlags),
            equals: .invalidAnimationRecordFlags(animation: 0, bone: 0, flags: 0x80)
        )

        var invalidQuaternion = bytes(of: makeAnimationModel())
        putUInt16(0xFFFF, at: 1_164, into: &invalidQuaternion)
        putUInt16(0xFFFF, at: 1_166, into: &invalidQuaternion)
        putUInt16(0x7FFF, at: 1_168, into: &invalidQuaternion)
        XCTAssertThrowsError(
            try SourceStudioAnimationDecoder.decode(mdlData: Data(invalidQuaternion))
        ) { error in
            guard case let .invalidCompressedQuaternion(animation, bone, format, squaredXYZ)? =
                error as? SourceStudioAnimationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(animation, 0)
            XCTAssertEqual(bone, 0)
            XCTAssertEqual(format, .quaternion48)
            XCTAssertGreaterThan(squaredXYZ, 1)
        }
    }

    func testUnsupportedAnimationStructuresFailTypedWithoutApproximation() throws {
        try assertPoseUnsupported(
            mutating: { putInt32(0x0004, at: 840 + 12, into: &$0) },
            equals: .deltaAnimation(animation: 0)
        )
        try assertPoseUnsupported(
            mutating: { putInt32(1, at: 840 + 20, into: &$0) },
            equals: .movementBlocks(animation: 0, count: 1)
        )
        try assertPoseUnsupported(
            mutating: { putInt32(-1, at: 840 + 52, into: &$0) },
            equals: .animationNeedsRecompile(animation: 0)
        )
        try assertPoseUnsupported(
            mutating: { putInt32(2, at: 840 + 52, into: &$0) },
            equals: .externalAnimationBlock(animation: 0, block: 2)
        )
        try assertPoseUnsupported(
            mutating: { putInt32(10, at: 840 + 84, into: &$0) },
            equals: .animationSections(animation: 0, framesPerSection: 10)
        )
        try assertPoseUnsupported(
            mutating: { putInt32(1, at: 840 + 60, into: &$0) },
            equals: .inverseKinematics(animation: 0, count: 1)
        )
        try assertPoseUnsupported(
            mutating: { putInt32(1, at: 840 + 72, into: &$0) },
            equals: .localHierarchy(animation: 0, count: 1)
        )
        try assertPoseUnsupported(
            mutating: { putInt16(1, at: 840 + 90, into: &$0) },
            equals: .zeroFrameData(animation: 0, count: 1)
        )
        try assertPoseUnsupported(
            mutating: { $0[1_161] = 0x04 },
            equals: .compressedBoneValues(animation: 0, bone: 0, flags: 0x04)
        )
    }

    func testSequenceReferencesAndEvaluationBoundsAreValidated() throws {
        var mismatch = bytes(of: makeAnimationModel())
        putInt32(2, at: 940 + 56, into: &mismatch)
        assertDecodeError(
            Data(mismatch),
            equals: .sequenceBlendCountMismatch(sequence: 0, declared: 2, tableCount: 1)
        )

        var invalidReference = bytes(of: makeAnimationModel())
        putInt16(1, at: 1_152, into: &invalidReference)
        assertDecodeError(
            Data(invalidReference),
            equals: .invalidAnimationReference(
                sequence: 0,
                blend: 0,
                value: 1,
                animationCount: 1
            )
        )

        let model = try SourceStudioAnimationDecoder.decode(mdlData: makeAnimationModel())
        XCTAssertThrowsError(try model.pose(animationIndex: 1, frame: 0)) { error in
            XCTAssertEqual(
                error as? SourceStudioAnimationError,
                .invalidAnimationIndex(value: 1, animationCount: 1)
            )
        }
        XCTAssertThrowsError(try model.pose(animationIndex: 0, frame: 30)) { error in
            XCTAssertEqual(
                error as? SourceStudioAnimationError,
                .invalidFrame(animation: 0, value: 30, frameCount: 30)
            )
        }
        XCTAssertThrowsError(try model.animationIndex(sequenceIndex: 0, blendIndex: 1)) { error in
            XCTAssertEqual(
                error as? SourceStudioAnimationError,
                .invalidBlendIndex(sequence: 0, value: 1, blendCount: 1)
            )
        }
    }
}

private extension SourceStudioAnimationTests {
    func makeAnimationModel() -> Data {
        let boneStart = 408
        let childBoneStart = 624
        let animationStart = 840
        let sequenceStart = 940
        let blendTableStart = 1_152
        let firstRecordStart = 1_160
        let secondRecordStart = 1_176
        var result = [UInt8](repeating: 0, count: 1_200)

        putUInt32(SourceStudioModel.magic, at: 0, into: &result)
        putInt32(48, at: 4, into: &result)
        putInt32(0x1234_5678, at: 8, into: &result)
        putFixedCString(
            "models/codex/animation_golden.mdl",
            at: 12,
            capacity: 64,
            into: &result
        )
        putInt32(2, at: 156, into: &result)
        putInt32(Int32(boneStart), at: 160, into: &result)
        putInt32(1, at: 180, into: &result)
        putInt32(Int32(animationStart), at: 184, into: &result)
        putInt32(1, at: 188, into: &result)
        putInt32(Int32(sequenceStart), at: 192, into: &result)

        let rootName = appendCString("root", to: &result)
        let childName = appendCString("child", to: &result)
        let surfaceName = appendCString("default", to: &result)
        let animationName = appendCString("raw_pose", to: &result)
        let sequenceName = appendCString("raw_sequence", to: &result)
        let activityName = appendCString("ACT_IDLE", to: &result)

        writeBone(
            at: boneStart,
            nameOffset: rootName,
            parent: -1,
            position: SourceVector3(1, 0, 0),
            surfaceOffset: surfaceName,
            into: &result
        )
        writeBone(
            at: childBoneStart,
            nameOffset: childName,
            parent: 0,
            position: SourceVector3(2, 0, 0),
            surfaceOffset: surfaceName,
            into: &result
        )

        putInt32(Int32(-animationStart), at: animationStart, into: &result)
        putInt32(Int32(animationName - animationStart), at: animationStart + 4, into: &result)
        putFloat(30, at: animationStart + 8, into: &result)
        putInt32(30, at: animationStart + 16, into: &result)
        putInt32(0, at: animationStart + 52, into: &result)
        putInt32(
            Int32(firstRecordStart - animationStart),
            at: animationStart + 56,
            into: &result
        )

        putInt32(Int32(-sequenceStart), at: sequenceStart, into: &result)
        putInt32(Int32(sequenceName - sequenceStart), at: sequenceStart + 4, into: &result)
        putInt32(Int32(activityName - sequenceStart), at: sequenceStart + 8, into: &result)
        putInt32(1, at: sequenceStart + 12, into: &result)
        putInt32(1, at: sequenceStart + 56, into: &result)
        putInt32(
            Int32(blendTableStart - sequenceStart),
            at: sequenceStart + 60,
            into: &result
        )
        putInt32(1, at: sequenceStart + 68, into: &result)
        putInt32(1, at: sequenceStart + 72, into: &result)
        putFloat(29, at: sequenceStart + 132, into: &result)
        putInt32(-1, at: sequenceStart + 136, into: &result)
        putInt32(-1, at: sequenceStart + 140, into: &result)
        putInt16(0, at: blendTableStart, into: &result)

        result[firstRecordStart] = 0
        result[firstRecordStart + 1] = 0x03 // RAWPOS | RAWROT
        putInt16(16, at: firstRecordStart + 2, into: &result)
        putQuaternion48(
            SourceStudioQAngle(pitch: 0, yaw: 90, roll: 0).quaternion,
            at: firstRecordStart + 4,
            into: &result
        )
        putVector48(x: 0x4500, y: 0, z: 0, at: firstRecordStart + 10, into: &result)

        result[secondRecordStart] = 1
        result[secondRecordStart + 1] = 0x21 // RAWPOS | RAWROT2
        putInt16(0, at: secondRecordStart + 2, into: &result)
        putQuaternion64(.identity, at: secondRecordStart + 4, into: &result)
        putVector48(x: 0x4000, y: 0, z: 0, at: secondRecordStart + 12, into: &result)

        putInt32(Int32(result.count), at: 76, into: &result)
        return Data(result)
    }

    func writeBone(
        at base: Int,
        nameOffset: Int,
        parent: Int32,
        position: SourceVector3,
        surfaceOffset: Int,
        into bytes: inout [UInt8]
    ) {
        putInt32(Int32(nameOffset - base), at: base, into: &bytes)
        putInt32(parent, at: base + 4, into: &bytes)
        for index in 0..<6 {
            putInt32(-1, at: base + 8 + index * 4, into: &bytes)
        }
        putVector(position, at: base + 32, into: &bytes)
        putQuaternion(.identity, at: base + 44, into: &bytes)
        putQuaternion(.identity, at: base + 144, into: &bytes)
        putInt32(Int32(surfaceOffset - base), at: base + 176, into: &bytes)
    }

    func assertDecodeError(
        _ data: Data,
        equals expected: SourceStudioAnimationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SourceStudioAnimationDecoder.decode(mdlData: data),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? SourceStudioAnimationError, expected, file: file, line: line)
        }
    }

    func assertPoseUnsupported(
        mutating: (inout [UInt8]) -> Void,
        equals expected: SourceStudioAnimationUnsupportedFeature,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var data = bytes(of: makeAnimationModel())
        mutating(&data)
        let model = try SourceStudioAnimationDecoder.decode(mdlData: Data(data))
        XCTAssertThrowsError(
            try model.pose(animationIndex: 0, frame: 7),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioAnimationError,
                .unsupported(expected),
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

    func putUInt64(_ value: UInt64, at offset: Int, into bytes: inout [UInt8]) {
        for byte in 0..<8 {
            bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt64(byte * 8))
        }
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

    func putQuaternion64(
        _ value: SourceStudioQuaternion,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        let mask: UInt64 = 0x1F_FFFF
        let x = UInt64(clamping: Int(value.x * 1_048_576) + 1_048_576) & mask
        let y = UInt64(clamping: Int(value.y * 1_048_576) + 1_048_576) & mask
        let z = UInt64(clamping: Int(value.z * 1_048_576) + 1_048_576) & mask
        var packed = x | (y << 21) | (z << 42)
        if value.w < 0 { packed |= UInt64(1) << 63 }
        putUInt64(packed, at: offset, into: &bytes)
    }
}

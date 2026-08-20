import Foundation
import XCTest
@testable import GModEngine

final class SourceStudioTests: XCTestCase {
    func testSyntheticV48ParsesHeaderBonesHitboxesAndSequenceMetadata() throws {
        let model = try SourceStudioModel(data: makeStudioModel())

        XCTAssertEqual(model.header.magic, SourceStudioModel.magic)
        XCTAssertEqual(model.header.version, 48)
        XCTAssertEqual(model.header.checksum, 0x1234_5678)
        XCTAssertEqual(model.header.name, "models/codex/source_studio_golden.mdl")
        XCTAssertEqual(model.header.length, Int32(makeStudioModel().count))
        XCTAssertEqual(model.header.flags, 0x0008_0000)

        XCTAssertEqual(model.bones.count, 2)
        XCTAssertEqual(model.bones[0].name, "root")
        XCTAssertEqual(model.bones[0].parent, -1)
        XCTAssertEqual(model.bones[0].position, SourceVector3(1, 2, 3))
        XCTAssertEqual(model.bones[0].surfaceProperty, "flesh")
        XCTAssertEqual(model.bones[0].contents, 0x2000_0000)
        XCTAssertEqual(model.bones[1].name, "child")
        XCTAssertEqual(model.bones[1].parent, 0)
        XCTAssertEqual(model.bones[1].position, SourceVector3(10, 0, 0))

        XCTAssertEqual(model.hitboxSets.count, 1)
        XCTAssertEqual(model.hitboxSets[0].name, "default")
        XCTAssertEqual(model.hitboxSets[0].hitboxes.count, 1)
        XCTAssertEqual(model.hitboxSets[0].hitboxes[0].bone, 1)
        XCTAssertEqual(model.hitboxSets[0].hitboxes[0].group, 3)
        XCTAssertEqual(model.hitboxSets[0].hitboxes[0].minimum, SourceVector3(-1, -2, -3))
        XCTAssertEqual(model.hitboxSets[0].hitboxes[0].maximum, SourceVector3(4, 5, 6))
        XCTAssertEqual(model.hitboxSets[0].hitboxes[0].name, "child_box")

        XCTAssertEqual(model.sequences.count, 1)
        let sequence = model.sequences[0]
        XCTAssertEqual(sequence.label, "run_all")
        XCTAssertEqual(sequence.activityName, "ACT_RUN")
        XCTAssertEqual(sequence.flags, 1)
        XCTAssertEqual(sequence.activity, 10)
        XCTAssertEqual(sequence.activityWeight, 7)
        XCTAssertEqual(sequence.blendCount, 1)
        XCTAssertEqual(sequence.groupSize.0, 1)
        XCTAssertEqual(sequence.groupSize.1, 1)
        XCTAssertEqual(sequence.fadeInTime, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(sequence.fadeOutTime, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(sequence.lastFrame, 29)
        XCTAssertEqual(sequence.nextSequence, -1)
        XCTAssertEqual(sequence.pose, -1)
        XCTAssertEqual(sequence.activityModifiers, [SourceStudioActivityModifier(name: "moving")])

        XCTAssertFalse(SourceStudioModel.decodesCompressedAnimations)
        XCTAssertFalse(SourceStudioModel.parsesVTX)
        XCTAssertFalse(SourceStudioModel.parsesVVD)
        XCTAssertEqual(SourceStudioModel.supportedVersions, [48])
    }

    func testDefaultBoneWorldUsesParentTimesLocalSourceOrder() throws {
        let model = try SourceStudioModel(data: makeStudioModel())
        let transforms = model.defaultBoneToWorld()

        XCTAssertEqual(transforms.count, 2)
        assertVector(transforms[0].position, SourceVector3(1, 2, 3))
        // Root has +90 degrees Source yaw. parent.rotation * child(+X 10)
        // therefore becomes +Y 10 before root translation is added.
        assertVector(transforms[1].position, SourceVector3(1, 12, 3), accuracy: 0.000_01)
        assertVector(
            transforms[0].transformPoint(SourceVector3(1, 0, 0)),
            SourceVector3(1, 3, 3),
            accuracy: 0.000_01
        )

        let rootTransform = SourceStudioQAngle(pitch: 0, yaw: 0, roll: 0)
            .quaternion
            .matrix(position: SourceVector3(100, 0, 0))
        let rooted = model.defaultBoneToWorld(rootTransform: rootTransform)
        assertVector(rooted[0].position, SourceVector3(101, 2, 3))
        assertVector(rooted[1].position, SourceVector3(101, 12, 3), accuracy: 0.000_01)
    }

    func testQAngleToQuaternionUsesSourcePitchYawRollConvention() {
        let yaw = SourceStudioQAngle(pitch: 0, yaw: 90, roll: 0).quaternion
        XCTAssertEqual(yaw.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(yaw.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(yaw.z, Float(0.5).squareRoot(), accuracy: 0.000_001)
        XCTAssertEqual(yaw.w, Float(0.5).squareRoot(), accuracy: 0.000_001)
        assertVector(
            yaw.matrix().transformPoint(SourceVector3(1, 0, 0)),
            SourceVector3(0, 1, 0),
            accuracy: 0.000_01
        )

        let pitch = SourceStudioQAngle(pitch: 90, yaw: 0, roll: 0).quaternion
        assertVector(
            pitch.matrix().transformPoint(SourceVector3(1, 0, 0)),
            SourceVector3(0, 0, -1),
            accuracy: 0.000_01
        )
    }

    func testRejectsTruncatedMagicVersionLengthAndHeaderName() {
        XCTAssertThrowsError(try SourceStudioModel(data: Data(repeating: 0, count: 407))) { error in
            XCTAssertEqual(error as? SourceStudioError, .truncatedHeader(required: 408, actual: 407))
        }

        var invalidMagic = bytes(of: makeStudioModel())
        putUInt32(0x5053_4449, at: 0, into: &invalidMagic)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(invalidMagic))) { error in
            XCTAssertEqual(error as? SourceStudioError, .invalidMagic(0x5053_4449))
        }

        var invalidVersion = bytes(of: makeStudioModel())
        putInt32(49, at: 4, into: &invalidVersion)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(invalidVersion))) { error in
            XCTAssertEqual(error as? SourceStudioError, .unsupportedVersion(49))
        }

        XCTAssertThrowsError(
            try SourceStudioModel(data: makeStudioModel(), expectedChecksum: 0x1020_3040)
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioError,
                .checksumMismatch(expected: 0x1020_3040, actual: 0x1234_5678)
            )
        }

        var invalidLength = bytes(of: makeStudioModel())
        putInt32(Int32(invalidLength.count - 1), at: 76, into: &invalidLength)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(invalidLength))) { error in
            XCTAssertEqual(
                error as? SourceStudioError,
                .invalidLength(declared: Int32(invalidLength.count - 1), actual: invalidLength.count)
            )
        }

        var unterminatedName = bytes(of: makeStudioModel())
        for offset in 12..<76 { unterminatedName[offset] = 0x41 }
        XCTAssertThrowsError(try SourceStudioModel(data: Data(unterminatedName))) { error in
            XCTAssertEqual(error as? SourceStudioError, .unterminatedHeaderName)
        }
    }

    func testRejectsMisalignedAndOutOfBoundsRelativeTables() {
        var misalignedBones = bytes(of: makeStudioModel())
        putInt32(410, at: 160, into: &misalignedBones)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(misalignedBones))) { error in
            XCTAssertEqual(
                error as? SourceStudioError,
                .misalignedOffset(field: "studiohdr_t.bones", offset: 410)
            )
        }

        var outOfBoundsHitboxes = bytes(of: makeStudioModel())
        putInt32(4_096, at: 840 + 8, into: &outOfBoundsHitboxes)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(outOfBoundsHitboxes))) { error in
            guard case let .outOfBounds(field, _, _, _)? = error as? SourceStudioError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(field, "hitboxset[0].hitboxes")
        }

        var outOfBoundsString = bytes(of: makeStudioModel())
        putInt32(Int32.max, at: 408, into: &outOfBoundsString)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(outOfBoundsString))) { error in
            guard case let .outOfBounds(field, _, _, _)? = error as? SourceStudioError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(field, "bone[0].name")
        }
    }

    func testRejectsInvalidBoneParentAndParentCycle() {
        var invalidParent = bytes(of: makeStudioModel())
        putInt32(2, at: 408 + 4, into: &invalidParent)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(invalidParent))) { error in
            XCTAssertEqual(error as? SourceStudioError, .invalidBoneParent(bone: 0, parent: 2))
        }

        var cycle = bytes(of: makeStudioModel())
        putInt32(1, at: 408 + 4, into: &cycle)
        putInt32(0, at: 624 + 4, into: &cycle)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(cycle))) { error in
            XCTAssertEqual(error as? SourceStudioError, .boneParentCycle([0, 1, 0]))
        }
    }

    func testRejectsHitboxBoneSequenceBackPointerAndNonFinitePose() {
        var invalidHitboxBone = bytes(of: makeStudioModel())
        putInt32(2, at: 852, into: &invalidHitboxBone)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(invalidHitboxBone))) { error in
            XCTAssertEqual(
                error as? SourceStudioError,
                .invalidHitboxBone(set: 0, hitbox: 0, bone: 2)
            )
        }

        var invalidBasePointer = bytes(of: makeStudioModel())
        putInt32(-916, at: 920, into: &invalidBasePointer)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(invalidBasePointer))) { error in
            XCTAssertEqual(
                error as? SourceStudioError,
                .invalidSequenceBasePointer(sequence: 0, value: -916)
            )
        }

        var infinity = bytes(of: makeStudioModel())
        putUInt32(Float.infinity.bitPattern, at: 408 + 44, into: &infinity)
        XCTAssertThrowsError(try SourceStudioModel(data: Data(infinity))) { error in
            XCTAssertEqual(
                error as? SourceStudioError,
                .nonFiniteFloat(field: "bone[0].quat.x", offset: 452)
            )
        }
    }

    func testInstalledOwnedModelDiagnosticIsReadOnlyAndOptIn() throws {
        let environment = ProcessInfo.processInfo.environment
        let data: Data
        let displayPath: String
        if let path = environment["SOURCE_MDL_DIAGNOSTIC_PATH"], !path.isEmpty {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            displayPath = path
        } else if let vpkPath = environment["SOURCE_MDL_DIAGNOSTIC_VPK"],
                  !vpkPath.isEmpty,
                  let entry = environment["SOURCE_MDL_DIAGNOSTIC_ENTRY"],
                  !entry.isEmpty {
            let archive = try GMLuaVPKArchive(
                directoryFileURL: URL(fileURLWithPath: vpkPath)
            )
            guard let archiveData = try archive.data(for: entry) else {
                return XCTFail("VPK does not contain \(entry)")
            }
            data = archiveData
            displayPath = "\(vpkPath)::\(entry)"
        } else {
            throw XCTSkip(
                "Set SOURCE_MDL_DIAGNOSTIC_PATH, or SOURCE_MDL_DIAGNOSTIC_VPK plus "
                    + "SOURCE_MDL_DIAGNOSTIC_ENTRY, to an owned Source v48 MDL"
            )
        }

        let model = try SourceStudioModel(data: data)
        let pose = model.defaultBoneToWorld()
        print(
            "SourceStudio diagnostic:",
            "path=\(displayPath)",
            "version=\(model.header.version)",
            "checksum=\(model.header.checksum)",
            "name=\(model.header.name)",
            "bones=\(model.bones.count)",
            "hitboxsets=\(model.hitboxSets.count)",
            "sequences=\(model.sequences.count)",
            "defaultPoseMatrices=\(pose.count)"
        )
        XCTAssertEqual(model.header.version, 48)
        XCTAssertEqual(model.header.length, Int32(data.count))
        XCTAssertEqual(pose.count, model.bones.count)
    }
}

private extension SourceStudioTests {
    func makeStudioModel() -> Data {
        let boneStart = 408
        let secondBone = 624
        let hitboxSetStart = 840
        let hitboxStart = 852
        let sequenceStart = 920
        let modifierStart = 1_132
        var result = [UInt8](repeating: 0, count: 1_136)

        putUInt32(SourceStudioModel.magic, at: 0, into: &result)
        putInt32(48, at: 4, into: &result)
        putInt32(0x1234_5678, at: 8, into: &result)
        putFixedCString("models/codex/source_studio_golden.mdl", at: 12, capacity: 64, into: &result)
        putInt32(0x0008_0000, at: 152, into: &result)
        putInt32(2, at: 156, into: &result)
        putInt32(Int32(boneStart), at: 160, into: &result)
        putInt32(1, at: 172, into: &result)
        putInt32(Int32(hitboxSetStart), at: 176, into: &result)
        putInt32(1, at: 188, into: &result)
        putInt32(Int32(sequenceStart), at: 192, into: &result)

        let rootName = appendCString("root", to: &result)
        let childName = appendCString("child", to: &result)
        let flesh = appendCString("flesh", to: &result)
        let hitboxSetName = appendCString("default", to: &result)
        let hitboxName = appendCString("child_box", to: &result)
        let sequenceLabel = appendCString("run_all", to: &result)
        let activityName = appendCString("ACT_RUN", to: &result)
        let modifierName = appendCString("moving", to: &result)

        putInt32(Int32(rootName - boneStart), at: boneStart, into: &result)
        putInt32(-1, at: boneStart + 4, into: &result)
        for index in 0..<6 { putInt32(-1, at: boneStart + 8 + index * 4, into: &result) }
        putVector(SourceVector3(1, 2, 3), at: boneStart + 32, into: &result)
        putQuaternion(
            SourceStudioQAngle(pitch: 0, yaw: 90, roll: 0).quaternion,
            at: boneStart + 44,
            into: &result
        )
        putVector(SourceVector3(1, 1, 1), at: boneStart + 72, into: &result)
        putVector(SourceVector3(1, 1, 1), at: boneStart + 84, into: &result)
        putMatrix(.identity, at: boneStart + 96, into: &result)
        putQuaternion(.identity, at: boneStart + 144, into: &result)
        putInt32(Int32(flesh - boneStart), at: boneStart + 176, into: &result)
        putInt32(0x2000_0000, at: boneStart + 180, into: &result)

        putInt32(Int32(childName - secondBone), at: secondBone, into: &result)
        putInt32(0, at: secondBone + 4, into: &result)
        for index in 0..<6 { putInt32(-1, at: secondBone + 8 + index * 4, into: &result) }
        putVector(SourceVector3(10, 0, 0), at: secondBone + 32, into: &result)
        putQuaternion(.identity, at: secondBone + 44, into: &result)
        putVector(SourceVector3(1, 1, 1), at: secondBone + 72, into: &result)
        putVector(SourceVector3(1, 1, 1), at: secondBone + 84, into: &result)
        putMatrix(.identity, at: secondBone + 96, into: &result)
        putQuaternion(.identity, at: secondBone + 144, into: &result)
        putInt32(Int32(flesh - secondBone), at: secondBone + 176, into: &result)
        putInt32(0x2000_0000, at: secondBone + 180, into: &result)

        putInt32(Int32(hitboxSetName - hitboxSetStart), at: hitboxSetStart, into: &result)
        putInt32(1, at: hitboxSetStart + 4, into: &result)
        putInt32(Int32(hitboxStart - hitboxSetStart), at: hitboxSetStart + 8, into: &result)
        putInt32(1, at: hitboxStart, into: &result)
        putInt32(3, at: hitboxStart + 4, into: &result)
        putVector(SourceVector3(-1, -2, -3), at: hitboxStart + 8, into: &result)
        putVector(SourceVector3(4, 5, 6), at: hitboxStart + 20, into: &result)
        putInt32(Int32(hitboxName - hitboxStart), at: hitboxStart + 32, into: &result)

        putInt32(Int32(-sequenceStart), at: sequenceStart, into: &result)
        putInt32(Int32(sequenceLabel - sequenceStart), at: sequenceStart + 4, into: &result)
        putInt32(Int32(activityName - sequenceStart), at: sequenceStart + 8, into: &result)
        putInt32(1, at: sequenceStart + 12, into: &result)
        putInt32(10, at: sequenceStart + 16, into: &result)
        putInt32(7, at: sequenceStart + 20, into: &result)
        putVector(SourceVector3(-16, -16, 0), at: sequenceStart + 32, into: &result)
        putVector(SourceVector3(16, 16, 72), at: sequenceStart + 44, into: &result)
        putInt32(1, at: sequenceStart + 56, into: &result)
        putInt32(1, at: sequenceStart + 68, into: &result)
        putInt32(1, at: sequenceStart + 72, into: &result)
        putInt32(-1, at: sequenceStart + 76, into: &result)
        putInt32(-1, at: sequenceStart + 80, into: &result)
        putFloat(0.2, at: sequenceStart + 104, into: &result)
        putFloat(0.3, at: sequenceStart + 108, into: &result)
        putFloat(29, at: sequenceStart + 132, into: &result)
        putInt32(-1, at: sequenceStart + 136, into: &result)
        putInt32(-1, at: sequenceStart + 140, into: &result)
        putInt32(Int32(modifierStart - sequenceStart), at: sequenceStart + 184, into: &result)
        putInt32(1, at: sequenceStart + 188, into: &result)
        putInt32(Int32(modifierName - modifierStart), at: modifierStart, into: &result)

        putInt32(Int32(result.count), at: 76, into: &result)
        return Data(result)
    }

    func assertVector(
        _ actual: SourceVector3,
        _ expected: SourceVector3,
        accuracy: Float = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    func bytes(of data: Data) -> [UInt8] { Array(data) }

    func appendCString(_ value: String, to bytes: inout [UInt8]) -> Int {
        let start = bytes.count
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
        return start
    }

    func putFixedCString(
        _ value: String,
        at offset: Int,
        capacity: Int,
        into bytes: inout [UInt8]
    ) {
        let encoded = Array(value.utf8)
        precondition(encoded.count < capacity)
        for index in 0..<capacity { bytes[offset + index] = 0 }
        for (index, byte) in encoded.enumerated() { bytes[offset + index] = byte }
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
}

import Foundation

/// Structural errors reported while reading a Source 1 `.mdl` studio header.
///
/// This parser is intentionally fail-closed. Source's on-disk structures use
/// offsets relative to several different objects; retaining the field name in
/// every error makes malformed addon content diagnosable without dereferencing
/// an untrusted pointer.
public enum SourceStudioError: Error, Equatable, CustomStringConvertible {
    case truncatedHeader(required: Int, actual: Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(Int32)
    case checksumMismatch(expected: Int32, actual: Int32)
    case invalidLength(declared: Int32, actual: Int)
    case unterminatedHeaderName
    case invalidCount(field: String, value: Int32)
    case tooManyBones(Int32)
    case zeroOffset(field: String)
    case misalignedOffset(field: String, offset: Int32)
    case offsetOverflow(field: String, base: Int, offset: Int32)
    case outOfBounds(field: String, start: Int, byteCount: Int, length: Int)
    case unterminatedString(field: String, start: Int)
    case nonFiniteFloat(field: String, offset: Int)
    case invalidBoneParent(bone: Int, parent: Int32)
    case boneParentCycle([Int])
    case invalidHitboxBone(set: Int, hitbox: Int, bone: Int32)
    case invalidSequenceBasePointer(sequence: Int, value: Int32)

    public var description: String {
        switch self {
        case let .truncatedHeader(required, actual):
            return "studiohdr_t requires \(required) bytes, got \(actual)"
        case let .invalidMagic(value):
            return String(format: "invalid studio magic 0x%08X", value)
        case let .unsupportedVersion(value):
            return "unsupported studio version \(value)"
        case let .checksumMismatch(expected, actual):
            return "studio checksum \(actual) does not match companion checksum \(expected)"
        case let .invalidLength(declared, actual):
            return "studio length \(declared) does not match \(actual) input bytes"
        case .unterminatedHeaderName:
            return "studio header name is not NUL-terminated within 64 bytes"
        case let .invalidCount(field, value):
            return "negative \(field) count \(value)"
        case let .tooManyBones(value):
            return "studio has \(value) bones; Source MAXSTUDIOBONES is 128"
        case let .zeroOffset(field):
            return "\(field) has a required zero offset"
        case let .misalignedOffset(field, offset):
            return "\(field) offset \(offset) is not 4-byte aligned"
        case let .offsetOverflow(field, base, offset):
            return "\(field) base \(base) plus relative offset \(offset) overflows"
        case let .outOfBounds(field, start, byteCount, length):
            return "\(field) range starts at \(start) for \(byteCount) bytes, exceeding studio length \(length)"
        case let .unterminatedString(field, start):
            return "\(field) string at \(start) has no NUL terminator"
        case let .nonFiniteFloat(field, offset):
            return "\(field) contains a non-finite Float at byte \(offset)"
        case let .invalidBoneParent(bone, parent):
            return "bone \(bone) has invalid parent \(parent)"
        case let .boneParentCycle(path):
            return "bone parent cycle: \(path.map(String.init).joined(separator: " -> "))"
        case let .invalidHitboxBone(set, hitbox, bone):
            return "hitbox \(set):\(hitbox) references invalid bone \(bone)"
        case let .invalidSequenceBasePointer(sequence, value):
            return "sequence \(sequence) baseptr \(value) does not point back to studiohdr_t"
        }
    }
}

/// Source's degree-valued `QAngle`: x=pitch, y=yaw, z=roll.
public struct SourceStudioQAngle: Equatable, Hashable, Sendable {
    public var pitch: Float
    public var yaw: Float
    public var roll: Float

    public init(pitch: Float = 0, yaw: Float = 0, roll: Float = 0) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
    }

    /// Matches Source `AngleQuaternion(QAngle)` ordering: half-angle yaw (Y),
    /// pitch (X), and roll (Z) terms are combined into the stored x/y/z/w
    /// quaternion. It is not a generic "Euler XYZ" convention.
    public var quaternion: SourceStudioQuaternion {
        let degreesToHalfRadians = Float.pi / 360
        let sy = sin(yaw * degreesToHalfRadians)
        let cy = cos(yaw * degreesToHalfRadians)
        let sp = sin(pitch * degreesToHalfRadians)
        let cp = cos(pitch * degreesToHalfRadians)
        let sr = sin(roll * degreesToHalfRadians)
        let cr = cos(roll * degreesToHalfRadians)

        return SourceStudioQuaternion(
            x: sr * cp * cy - cr * sp * sy,
            y: cr * sp * cy + sr * cp * sy,
            z: cr * cp * sy - sr * sp * cy,
            w: cr * cp * cy + sr * sp * sy
        )
    }
}

/// Source `RadianEuler` storage order as present in `mstudiobone_t`.
/// The default bone pose uses the adjacent compiled quaternion, not this field.
public struct SourceStudioRadianEuler: Equatable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float = 0, y: Float = 0, z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Source's Float quaternion layout (`x`, `y`, `z`, `w`).
public struct SourceStudioQuaternion: Equatable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(x: Float = 0, y: Float = 0, z: Float = 0, w: Float = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = SourceStudioQuaternion()

    /// Source `QuaternionMatrix(q, pos)` convention. The quaternion is consumed
    /// as stored (Source does not normalize it at this call site), and the
    /// `SourceVector3` position becomes the fourth column of a row-major 3x4.
    public func matrix(position: SourceVector3 = .zero) -> SourceStudioMatrix3x4 {
        let x2 = x + x
        let y2 = y + y
        let z2 = z + z
        let xx = x * x2
        let xy = x * y2
        let xz = x * z2
        let yy = y * y2
        let yz = y * z2
        let zz = z * z2
        let wx = w * x2
        let wy = w * y2
        let wz = w * z2

        return SourceStudioMatrix3x4(
            1 - yy - zz, xy - wz, xz + wy, position.x,
            xy + wz, 1 - xx - zz, yz - wx, position.y,
            xz - wy, yz + wx, 1 - xx - yy, position.z
        )
    }
}

/// Row-major Source `matrix3x4_t` affine transform.
public struct SourceStudioMatrix3x4: Equatable, Hashable, Sendable {
    public var m00: Float
    public var m01: Float
    public var m02: Float
    public var m03: Float
    public var m10: Float
    public var m11: Float
    public var m12: Float
    public var m13: Float
    public var m20: Float
    public var m21: Float
    public var m22: Float
    public var m23: Float

    public init(
        _ m00: Float, _ m01: Float, _ m02: Float, _ m03: Float,
        _ m10: Float, _ m11: Float, _ m12: Float, _ m13: Float,
        _ m20: Float, _ m21: Float, _ m22: Float, _ m23: Float
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m03 = m03
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
        self.m13 = m13
        self.m20 = m20
        self.m21 = m21
        self.m22 = m22
        self.m23 = m23
    }

    public static let identity = SourceStudioMatrix3x4(
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0
    )

    /// Source `ConcatTransforms(self, local, out)` ordering: `self * local`.
    /// Rotation is parent-then-local and translation is
    /// `parent.rotation * local.translation + parent.translation`.
    public func concatenating(_ local: SourceStudioMatrix3x4) -> SourceStudioMatrix3x4 {
        SourceStudioMatrix3x4(
            m00 * local.m00 + m01 * local.m10 + m02 * local.m20,
            m00 * local.m01 + m01 * local.m11 + m02 * local.m21,
            m00 * local.m02 + m01 * local.m12 + m02 * local.m22,
            m00 * local.m03 + m01 * local.m13 + m02 * local.m23 + m03,
            m10 * local.m00 + m11 * local.m10 + m12 * local.m20,
            m10 * local.m01 + m11 * local.m11 + m12 * local.m21,
            m10 * local.m02 + m11 * local.m12 + m12 * local.m22,
            m10 * local.m03 + m11 * local.m13 + m12 * local.m23 + m13,
            m20 * local.m00 + m21 * local.m10 + m22 * local.m20,
            m20 * local.m01 + m21 * local.m11 + m22 * local.m21,
            m20 * local.m02 + m21 * local.m12 + m22 * local.m22,
            m20 * local.m03 + m21 * local.m13 + m22 * local.m23 + m23
        )
    }

    public func transformPoint(_ point: SourceVector3) -> SourceVector3 {
        SourceVector3(
            m00 * point.x + m01 * point.y + m02 * point.z + m03,
            m10 * point.x + m11 * point.y + m12 * point.z + m13,
            m20 * point.x + m21 * point.y + m22 * point.z + m23
        )
    }

    public var position: SourceVector3 { SourceVector3(m03, m13, m23) }
}

public struct SourceStudioHeader: Equatable, Sendable {
    public let magic: UInt32
    public let version: Int32
    public let checksum: Int32
    public let name: String
    public let length: Int32
    public let flags: Int32
}

public struct SourceStudioBone: Equatable, Sendable {
    public let name: String
    public let parent: Int32
    public let boneControllers: [Int32]
    public let position: SourceVector3
    public let quaternion: SourceStudioQuaternion
    public let eulerRadians: SourceStudioRadianEuler
    public let positionScale: SourceVector3
    public let rotationScale: SourceVector3
    public let poseToBone: SourceStudioMatrix3x4
    public let alignment: SourceStudioQuaternion
    public let flags: Int32
    public let procedureType: Int32
    public let physicsBone: Int32
    public let surfaceProperty: String
    public let contents: Int32
}

public struct SourceStudioHitbox: Equatable, Sendable {
    public let bone: Int32
    public let group: Int32
    public let minimum: SourceVector3
    public let maximum: SourceVector3
    /// Source `mstudiobbox_t::pszHitboxName()` returns an empty string when
    /// `szhitboxnameindex` is zero.
    public let name: String
}

public struct SourceStudioHitboxSet: Equatable, Sendable {
    public let name: String
    public let hitboxes: [SourceStudioHitbox]
}

public struct SourceStudioActivityModifier: Equatable, Sendable {
    public let name: String?
}

public struct SourceStudioSequence: Equatable, Sendable {
    public let label: String
    public let activityName: String
    public let flags: Int32
    public let activity: Int32
    public let activityWeight: Int32
    public let boundingBoxMinimum: SourceVector3
    public let boundingBoxMaximum: SourceVector3
    public let blendCount: Int32
    public let groupSize: (Int32, Int32)
    public let parameterIndices: (Int32, Int32)
    public let fadeInTime: Float
    public let fadeOutTime: Float
    public let lastFrame: Float
    public let nextSequence: Int32
    public let pose: Int32
    public let activityModifiers: [SourceStudioActivityModifier]

    public static func == (lhs: SourceStudioSequence, rhs: SourceStudioSequence) -> Bool {
        lhs.label == rhs.label &&
            lhs.activityName == rhs.activityName &&
            lhs.flags == rhs.flags &&
            lhs.activity == rhs.activity &&
            lhs.activityWeight == rhs.activityWeight &&
            lhs.boundingBoxMinimum == rhs.boundingBoxMinimum &&
            lhs.boundingBoxMaximum == rhs.boundingBoxMaximum &&
            lhs.blendCount == rhs.blendCount &&
            lhs.groupSize.0 == rhs.groupSize.0 &&
            lhs.groupSize.1 == rhs.groupSize.1 &&
            lhs.parameterIndices.0 == rhs.parameterIndices.0 &&
            lhs.parameterIndices.1 == rhs.parameterIndices.1 &&
            lhs.fadeInTime == rhs.fadeInTime &&
            lhs.fadeOutTime == rhs.fadeOutTime &&
            lhs.lastFrame == rhs.lastFrame &&
            lhs.nextSequence == rhs.nextSequence &&
            lhs.pose == rhs.pose &&
            lhs.activityModifiers == rhs.activityModifiers
    }
}

/// Validated, read-only core of a Source 1 v48 MDL.
///
/// Grounding: Source SDK 2013 `studio.h` (`STUDIO_VERSION`, `studiohdr_t`,
/// `mstudiobone_t`, `mstudiohitboxset_t`, `mstudiobbox_t`, and
/// `mstudioseqdesc_t`) and `bone_setup.cpp`'s `QuaternionMatrix` followed by
/// parent-first `ConcatTransforms` calls.
///
/// Deliberate current boundary: compressed animation stream decoding, ANI
/// blocks, virtual/included model sequence remapping, and VTX/VVD parsing are
/// not implemented. This type therefore exposes metadata and the compiled
/// default bone pose; it does not claim to evaluate animated poses or meshes.
public struct SourceStudioModel: Sendable {
    public static let magic: UInt32 = 0x5453_4449 // little-endian bytes "IDST"
    public static let supportedVersions: Set<Int32> = [48]
    public static let studioHeaderSize = 408
    public static let boneRecordSize = 216
    public static let hitboxSetRecordSize = 12
    public static let hitboxRecordSize = 68
    public static let sequenceRecordSize = 212

    public static let decodesCompressedAnimations = false
    public static let parsesVTX = false
    public static let parsesVVD = false

    public let header: SourceStudioHeader
    public let bones: [SourceStudioBone]
    public let hitboxSets: [SourceStudioHitboxSet]
    public let sequences: [SourceStudioSequence]

    /// `expectedChecksum` is the checksum read from a companion PHY/VTX/VVD
    /// header. A standalone MDL has no independent checksum oracle, so callers
    /// that are loading a model bundle should pass the peer value here.
    public init(data: Data, expectedChecksum: Int32? = nil) throws {
        let reader = SourceStudioReader(data: data)
        guard reader.length >= Self.studioHeaderSize else {
            throw SourceStudioError.truncatedHeader(
                required: Self.studioHeaderSize,
                actual: reader.length
            )
        }

        let magic = try reader.uint32(at: 0, field: "studiohdr_t.id")
        guard magic == Self.magic else { throw SourceStudioError.invalidMagic(magic) }

        let version = try reader.int32(at: 4, field: "studiohdr_t.version")
        guard Self.supportedVersions.contains(version) else {
            throw SourceStudioError.unsupportedVersion(version)
        }

        let checksum = try reader.int32(at: 8, field: "studiohdr_t.checksum")
        if let expectedChecksum, checksum != expectedChecksum {
            throw SourceStudioError.checksumMismatch(
                expected: expectedChecksum,
                actual: checksum
            )
        }
        let name = try reader.fixedCString(
            at: 12,
            byteCount: 64,
            field: "studiohdr_t.name",
            headerName: true
        )
        let declaredLength = try reader.int32(at: 76, field: "studiohdr_t.length")
        guard declaredLength == Int32(exactly: reader.length) else {
            throw SourceStudioError.invalidLength(declared: declaredLength, actual: reader.length)
        }
        let flags = try reader.int32(at: 152, field: "studiohdr_t.flags")

        let boneCount = try reader.validatedCount(at: 156, field: "studiohdr_t.numbones")
        guard boneCount <= 128 else { throw SourceStudioError.tooManyBones(Int32(boneCount)) }
        let boneIndex = try reader.int32(at: 160, field: "studiohdr_t.boneindex")
        let boneStart = try reader.tableStart(
            base: 0,
            relativeOffset: boneIndex,
            count: boneCount,
            stride: Self.boneRecordSize,
            field: "studiohdr_t.bones"
        )

        var parsedBones: [SourceStudioBone] = []
        parsedBones.reserveCapacity(boneCount)
        for index in 0..<boneCount {
            let base = boneStart + index * Self.boneRecordSize
            parsedBones.append(try Self.readBone(reader: reader, base: base, index: index))
        }
        try Self.validateBoneParents(parsedBones)

        let hitboxSetCount = try reader.validatedCount(
            at: 172,
            field: "studiohdr_t.numhitboxsets"
        )
        let hitboxSetIndex = try reader.int32(at: 176, field: "studiohdr_t.hitboxsetindex")
        let hitboxSetStart = try reader.tableStart(
            base: 0,
            relativeOffset: hitboxSetIndex,
            count: hitboxSetCount,
            stride: Self.hitboxSetRecordSize,
            field: "studiohdr_t.hitboxsets"
        )

        var parsedHitboxSets: [SourceStudioHitboxSet] = []
        parsedHitboxSets.reserveCapacity(hitboxSetCount)
        for setIndex in 0..<hitboxSetCount {
            let base = hitboxSetStart + setIndex * Self.hitboxSetRecordSize
            parsedHitboxSets.append(
                try Self.readHitboxSet(
                    reader: reader,
                    base: base,
                    setIndex: setIndex,
                    boneCount: boneCount
                )
            )
        }

        let sequenceCount = try reader.validatedCount(at: 188, field: "studiohdr_t.numlocalseq")
        let sequenceIndex = try reader.int32(at: 192, field: "studiohdr_t.localseqindex")
        let sequenceStart = try reader.tableStart(
            base: 0,
            relativeOffset: sequenceIndex,
            count: sequenceCount,
            stride: Self.sequenceRecordSize,
            field: "studiohdr_t.localsequences"
        )

        var parsedSequences: [SourceStudioSequence] = []
        parsedSequences.reserveCapacity(sequenceCount)
        for sequenceIndex in 0..<sequenceCount {
            let base = sequenceStart + sequenceIndex * Self.sequenceRecordSize
            parsedSequences.append(
                try Self.readSequence(reader: reader, base: base, index: sequenceIndex)
            )
        }

        header = SourceStudioHeader(
            magic: magic,
            version: version,
            checksum: checksum,
            name: name,
            length: declaredLength,
            flags: flags
        )
        bones = parsedBones
        hitboxSets = parsedHitboxSets
        sequences = parsedSequences
    }

    /// Builds the default compiled bone pose exactly in Source's order:
    /// `QuaternionMatrix(bone.quat, bone.pos)`, then
    /// `ConcatTransforms(parentWorld, boneLocal)`. Root bones use
    /// `ConcatTransforms(rootTransform, boneLocal)`.
    public func defaultBoneToWorld(
        rootTransform: SourceStudioMatrix3x4 = .identity
    ) -> [SourceStudioMatrix3x4] {
        var results = Array(repeating: SourceStudioMatrix3x4.identity, count: bones.count)
        var resolved = Array(repeating: false, count: bones.count)

        func resolve(_ index: Int) -> SourceStudioMatrix3x4 {
            if resolved[index] { return results[index] }
            let bone = bones[index]
            let local = bone.quaternion.matrix(position: bone.position)
            let world: SourceStudioMatrix3x4
            if bone.parent == -1 {
                world = rootTransform.concatenating(local)
            } else {
                world = resolve(Int(bone.parent)).concatenating(local)
            }
            results[index] = world
            resolved[index] = true
            return world
        }

        for index in bones.indices { _ = resolve(index) }
        return results
    }

    private static func readBone(
        reader: SourceStudioReader,
        base: Int,
        index: Int
    ) throws -> SourceStudioBone {
        let prefix = "bone[\(index)]"
        let nameOffset = try reader.int32(at: base, field: "\(prefix).sznameindex")
        let name = try reader.relativeCString(
            base: base,
            relativeOffset: nameOffset,
            field: "\(prefix).name",
            required: true
        )!
        let parent = try reader.int32(at: base + 4, field: "\(prefix).parent")
        var controllers: [Int32] = []
        controllers.reserveCapacity(6)
        for controller in 0..<6 {
            controllers.append(
                try reader.int32(
                    at: base + 8 + controller * 4,
                    field: "\(prefix).bonecontroller[\(controller)]"
                )
            )
        }

        let position = try reader.vector(at: base + 32, field: "\(prefix).pos")
        let quaternion = try reader.quaternion(at: base + 44, field: "\(prefix).quat")
        let euler = try reader.radianEuler(at: base + 60, field: "\(prefix).rot")
        let positionScale = try reader.vector(at: base + 72, field: "\(prefix).posscale")
        let rotationScale = try reader.vector(at: base + 84, field: "\(prefix).rotscale")
        let poseToBone = try reader.matrix(at: base + 96, field: "\(prefix).poseToBone")
        let alignment = try reader.quaternion(at: base + 144, field: "\(prefix).qAlignment")
        let flags = try reader.int32(at: base + 160, field: "\(prefix).flags")
        let procedureType = try reader.int32(at: base + 164, field: "\(prefix).proctype")
        _ = try reader.int32(at: base + 168, field: "\(prefix).procindex")
        let physicsBone = try reader.int32(at: base + 172, field: "\(prefix).physicsbone")
        let surfaceOffset = try reader.int32(at: base + 176, field: "\(prefix).surfacepropidx")
        let surfaceProperty = try reader.relativeCString(
            base: base,
            relativeOffset: surfaceOffset,
            field: "\(prefix).surfaceprop",
            required: true
        )!
        let contents = try reader.int32(at: base + 180, field: "\(prefix).contents")

        return SourceStudioBone(
            name: name,
            parent: parent,
            boneControllers: controllers,
            position: position,
            quaternion: quaternion,
            eulerRadians: euler,
            positionScale: positionScale,
            rotationScale: rotationScale,
            poseToBone: poseToBone,
            alignment: alignment,
            flags: flags,
            procedureType: procedureType,
            physicsBone: physicsBone,
            surfaceProperty: surfaceProperty,
            contents: contents
        )
    }

    private static func validateBoneParents(_ bones: [SourceStudioBone]) throws {
        for (index, bone) in bones.enumerated() {
            guard bone.parent == -1 || (bone.parent >= 0 && bone.parent < Int32(bones.count)) else {
                throw SourceStudioError.invalidBoneParent(bone: index, parent: bone.parent)
            }
        }

        enum Mark { case unseen, visiting, done }
        var marks = Array(repeating: Mark.unseen, count: bones.count)
        var stack: [Int] = []

        func visit(_ index: Int) throws {
            switch marks[index] {
            case .done:
                return
            case .visiting:
                let start = stack.firstIndex(of: index) ?? 0
                throw SourceStudioError.boneParentCycle(Array(stack[start...]) + [index])
            case .unseen:
                marks[index] = .visiting
                stack.append(index)
                if bones[index].parent >= 0 { try visit(Int(bones[index].parent)) }
                _ = stack.popLast()
                marks[index] = .done
            }
        }

        for index in bones.indices { try visit(index) }
    }

    private static func readHitboxSet(
        reader: SourceStudioReader,
        base: Int,
        setIndex: Int,
        boneCount: Int
    ) throws -> SourceStudioHitboxSet {
        let prefix = "hitboxset[\(setIndex)]"
        let nameOffset = try reader.int32(at: base, field: "\(prefix).sznameindex")
        let name = try reader.relativeCString(
            base: base,
            relativeOffset: nameOffset,
            field: "\(prefix).name",
            required: true
        )!
        let count = try reader.validatedCount(at: base + 4, field: "\(prefix).numhitboxes")
        let index = try reader.int32(at: base + 8, field: "\(prefix).hitboxindex")
        let start = try reader.tableStart(
            base: base,
            relativeOffset: index,
            count: count,
            stride: Self.hitboxRecordSize,
            field: "\(prefix).hitboxes"
        )

        var hitboxes: [SourceStudioHitbox] = []
        hitboxes.reserveCapacity(count)
        for hitboxIndex in 0..<count {
            let hitboxBase = start + hitboxIndex * Self.hitboxRecordSize
            let hitboxPrefix = "\(prefix).hitbox[\(hitboxIndex)]"
            let bone = try reader.int32(at: hitboxBase, field: "\(hitboxPrefix).bone")
            guard bone >= 0 && bone < Int32(boneCount) else {
                throw SourceStudioError.invalidHitboxBone(
                    set: setIndex,
                    hitbox: hitboxIndex,
                    bone: bone
                )
            }
            let group = try reader.int32(at: hitboxBase + 4, field: "\(hitboxPrefix).group")
            let minimum = try reader.vector(at: hitboxBase + 8, field: "\(hitboxPrefix).bbmin")
            let maximum = try reader.vector(at: hitboxBase + 20, field: "\(hitboxPrefix).bbmax")
            let nameOffset = try reader.int32(
                at: hitboxBase + 32,
                field: "\(hitboxPrefix).szhitboxnameindex"
            )
            let name = try reader.relativeCString(
                base: hitboxBase,
                relativeOffset: nameOffset,
                field: "\(hitboxPrefix).name",
                required: false
            ) ?? ""
            hitboxes.append(
                SourceStudioHitbox(
                    bone: bone,
                    group: group,
                    minimum: minimum,
                    maximum: maximum,
                    name: name
                )
            )
        }
        return SourceStudioHitboxSet(name: name, hitboxes: hitboxes)
    }

    private static func readSequence(
        reader: SourceStudioReader,
        base: Int,
        index: Int
    ) throws -> SourceStudioSequence {
        let prefix = "sequence[\(index)]"
        let basePointer = try reader.int32(at: base, field: "\(prefix).baseptr")
        let headerAddress = try reader.relativeAddress(
            base: base,
            relativeOffset: basePointer,
            field: "\(prefix).baseptr"
        )
        guard headerAddress == 0 else {
            throw SourceStudioError.invalidSequenceBasePointer(sequence: index, value: basePointer)
        }

        let labelOffset = try reader.int32(at: base + 4, field: "\(prefix).szlabelindex")
        let label = try reader.relativeCString(
            base: base,
            relativeOffset: labelOffset,
            field: "\(prefix).label",
            required: true
        )!
        let activityNameOffset = try reader.int32(
            at: base + 8,
            field: "\(prefix).szactivitynameindex"
        )
        let activityName = try reader.relativeCString(
            base: base,
            relativeOffset: activityNameOffset,
            field: "\(prefix).activityname",
            required: true
        )!
        let flags = try reader.int32(at: base + 12, field: "\(prefix).flags")
        let activity = try reader.int32(at: base + 16, field: "\(prefix).activity")
        let activityWeight = try reader.int32(at: base + 20, field: "\(prefix).actweight")
        let minimum = try reader.vector(at: base + 32, field: "\(prefix).bbmin")
        let maximum = try reader.vector(at: base + 44, field: "\(prefix).bbmax")
        let blendCount = try reader.int32(at: base + 56, field: "\(prefix).numblends")
        guard blendCount >= 0 else {
            throw SourceStudioError.invalidCount(field: "\(prefix).numblends", value: blendCount)
        }
        let groupSize = (
            try reader.int32(at: base + 68, field: "\(prefix).groupsize[0]"),
            try reader.int32(at: base + 72, field: "\(prefix).groupsize[1]")
        )
        let parameterIndices = (
            try reader.int32(at: base + 76, field: "\(prefix).paramindex[0]"),
            try reader.int32(at: base + 80, field: "\(prefix).paramindex[1]")
        )
        let fadeIn = try reader.float(at: base + 104, field: "\(prefix).fadeintime")
        let fadeOut = try reader.float(at: base + 108, field: "\(prefix).fadeouttime")
        let lastFrame = try reader.float(at: base + 132, field: "\(prefix).lastframe")
        let nextSequence = try reader.int32(at: base + 136, field: "\(prefix).nextseq")
        let pose = try reader.int32(at: base + 140, field: "\(prefix).pose")

        let modifierOffset = try reader.int32(
            at: base + 184,
            field: "\(prefix).activitymodifierindex"
        )
        let modifierCount = try reader.validatedCount(
            at: base + 188,
            field: "\(prefix).numactivitymodifiers"
        )
        let modifierStart = try reader.tableStart(
            base: base,
            relativeOffset: modifierOffset,
            count: modifierCount,
            stride: 4,
            field: "\(prefix).activitymodifiers"
        )
        var modifiers: [SourceStudioActivityModifier] = []
        modifiers.reserveCapacity(modifierCount)
        for modifierIndex in 0..<modifierCount {
            let modifierBase = modifierStart + modifierIndex * 4
            let nameOffset = try reader.int32(
                at: modifierBase,
                field: "\(prefix).activitymodifier[\(modifierIndex)].sznameindex"
            )
            let name = try reader.relativeCString(
                base: modifierBase,
                relativeOffset: nameOffset,
                field: "\(prefix).activitymodifier[\(modifierIndex)].name",
                required: false
            )
            modifiers.append(SourceStudioActivityModifier(name: name))
        }

        return SourceStudioSequence(
            label: label,
            activityName: activityName,
            flags: flags,
            activity: activity,
            activityWeight: activityWeight,
            boundingBoxMinimum: minimum,
            boundingBoxMaximum: maximum,
            blendCount: blendCount,
            groupSize: groupSize,
            parameterIndices: parameterIndices,
            fadeInTime: fadeIn,
            fadeOutTime: fadeOut,
            lastFrame: lastFrame,
            nextSequence: nextSequence,
            pose: pose,
            activityModifiers: modifiers
        )
    }
}

private struct SourceStudioReader {
    let bytes: [UInt8]
    var length: Int { bytes.count }

    init(data: Data) {
        bytes = Array(data)
    }

    func uint32(at offset: Int, field: String) throws -> UInt32 {
        try requireRange(start: offset, byteCount: 4, field: field)
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    func int32(at offset: Int, field: String) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset, field: field))
    }

    func float(at offset: Int, field: String) throws -> Float {
        let value = Float(bitPattern: try uint32(at: offset, field: field))
        guard value.isFinite else {
            throw SourceStudioError.nonFiniteFloat(field: field, offset: offset)
        }
        return value
    }

    func vector(at offset: Int, field: String) throws -> SourceVector3 {
        SourceVector3(
            try float(at: offset, field: "\(field).x"),
            try float(at: offset + 4, field: "\(field).y"),
            try float(at: offset + 8, field: "\(field).z")
        )
    }

    func quaternion(at offset: Int, field: String) throws -> SourceStudioQuaternion {
        SourceStudioQuaternion(
            x: try float(at: offset, field: "\(field).x"),
            y: try float(at: offset + 4, field: "\(field).y"),
            z: try float(at: offset + 8, field: "\(field).z"),
            w: try float(at: offset + 12, field: "\(field).w")
        )
    }

    func radianEuler(at offset: Int, field: String) throws -> SourceStudioRadianEuler {
        SourceStudioRadianEuler(
            x: try float(at: offset, field: "\(field).x"),
            y: try float(at: offset + 4, field: "\(field).y"),
            z: try float(at: offset + 8, field: "\(field).z")
        )
    }

    func matrix(at offset: Int, field: String) throws -> SourceStudioMatrix3x4 {
        var values: [Float] = []
        values.reserveCapacity(12)
        for element in 0..<12 {
            values.append(
                try float(at: offset + element * 4, field: "\(field)[\(element / 4)][\(element % 4)]")
            )
        }
        return SourceStudioMatrix3x4(
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11]
        )
    }

    func fixedCString(
        at offset: Int,
        byteCount: Int,
        field: String,
        headerName: Bool
    ) throws -> String {
        try requireRange(start: offset, byteCount: byteCount, field: field)
        guard let end = bytes[offset..<(offset + byteCount)].firstIndex(of: 0) else {
            if headerName { throw SourceStudioError.unterminatedHeaderName }
            throw SourceStudioError.unterminatedString(field: field, start: offset)
        }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    func relativeCString(
        base: Int,
        relativeOffset: Int32,
        field: String,
        required: Bool
    ) throws -> String? {
        if relativeOffset == 0 {
            if required { throw SourceStudioError.zeroOffset(field: field) }
            return nil
        }
        let start = try relativeAddress(base: base, relativeOffset: relativeOffset, field: field)
        guard start < length else {
            throw SourceStudioError.outOfBounds(
                field: field,
                start: start,
                byteCount: 1,
                length: length
            )
        }
        guard let end = bytes[start...].firstIndex(of: 0) else {
            throw SourceStudioError.unterminatedString(field: field, start: start)
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func validatedCount(at offset: Int, field: String) throws -> Int {
        let value = try int32(at: offset, field: field)
        guard value >= 0 else { throw SourceStudioError.invalidCount(field: field, value: value) }
        return Int(value)
    }

    func tableStart(
        base: Int,
        relativeOffset: Int32,
        count: Int,
        stride: Int,
        field: String
    ) throws -> Int {
        if count == 0 { return base }
        guard relativeOffset != 0 else { throw SourceStudioError.zeroOffset(field: field) }
        guard relativeOffset % 4 == 0 else {
            throw SourceStudioError.misalignedOffset(field: field, offset: relativeOffset)
        }
        let start = try relativeAddress(base: base, relativeOffset: relativeOffset, field: field)
        guard count <= (length - start) / stride else {
            let byteCount = count > Int.max / stride ? Int.max : count * stride
            throw SourceStudioError.outOfBounds(
                field: field,
                start: start,
                byteCount: byteCount,
                length: length
            )
        }
        return start
    }

    func relativeAddress(base: Int, relativeOffset: Int32, field: String) throws -> Int {
        let address = Int64(base) + Int64(relativeOffset)
        guard address >= 0, let exact = Int(exactly: address) else {
            throw SourceStudioError.offsetOverflow(
                field: field,
                base: base,
                offset: relativeOffset
            )
        }
        guard exact <= length else {
            throw SourceStudioError.outOfBounds(
                field: field,
                start: exact,
                byteCount: 0,
                length: length
            )
        }
        return exact
    }

    private func requireRange(start: Int, byteCount: Int, field: String) throws {
        guard start >= 0, byteCount >= 0, start <= length, byteCount <= length - start else {
            throw SourceStudioError.outOfBounds(
                field: field,
                start: start,
                byteCount: byteCount,
                length: length
            )
        }
    }
}

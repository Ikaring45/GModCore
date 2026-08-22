import Foundation

/// Source Studio animation failures that are specific to animation descriptors
/// and `mstudioanim_t` streams. Base MDL/header failures continue to surface as
/// `SourceStudioError` from `SourceStudioModel`.
public enum SourceStudioAnimationError: Error, Equatable, CustomStringConvertible {
    case invalidCount(field: String, value: Int32)
    case invalidShortCount(field: String, value: Int16)
    case zeroOffset(field: String)
    case misalignedOffset(field: String, offset: Int32, alignment: Int)
    case offsetOverflow(field: String, base: Int, offset: Int32)
    case outOfBounds(field: String, start: Int, byteCount: Int, length: Int)
    case unterminatedString(field: String, start: Int)
    case nonFiniteFloat(field: String, offset: Int)
    case invalidAnimationBasePointer(animation: Int, value: Int32)
    case invalidFrameCount(animation: Int, value: Int32)
    case invalidAnimationBlock(animation: Int, value: Int32)
    case invalidInlineAnimationOffset(animation: Int, value: Int32)
    case invalidSequenceGroupSize(sequence: Int, x: Int32, y: Int32)
    case sequenceBlendCountMismatch(sequence: Int, declared: Int32, tableCount: Int)
    case invalidAnimationReference(
        sequence: Int,
        blend: Int,
        value: Int16,
        animationCount: Int
    )
    case invalidAnimationIndex(value: Int, animationCount: Int)
    case invalidSequenceIndex(value: Int, sequenceCount: Int)
    case invalidBlendIndex(sequence: Int, value: Int, blendCount: Int)
    case invalidFrame(animation: Int, value: Int, frameCount: Int)
    case invalidAnimationRecordFlags(animation: Int, bone: Int, flags: UInt8)
    case conflictingAnimationRecordFlags(animation: Int, bone: Int, flags: UInt8)
    case invalidAnimationRecordBone(
        animation: Int,
        value: Int,
        boneCount: Int
    )
    case nonIncreasingAnimationRecordBone(animation: Int, previous: Int, value: Int)
    case invalidAnimationRecordNextOffset(animation: Int, recordOffset: Int, value: Int16)
    case animationRecordPayloadOverlapsNext(
        animation: Int,
        recordOffset: Int,
        payloadEnd: Int,
        nextOffset: Int
    )
    case invalidAnimationSentinel(animation: Int, flags: UInt8, nextOffset: Int16)
    case invalidCompressedQuaternion(
        animation: Int,
        bone: Int,
        format: SourceStudioConstantRotationFormat,
        squaredXYZ: Float
    )
    case unsupported(SourceStudioAnimationUnsupportedFeature)

    public var description: String {
        switch self {
        case let .invalidCount(field, value):
            return "negative \(field) count \(value)"
        case let .invalidShortCount(field, value):
            return "negative \(field) count \(value)"
        case let .zeroOffset(field):
            return "\(field) has a required zero offset"
        case let .misalignedOffset(field, offset, alignment):
            return "\(field) offset \(offset) is not \(alignment)-byte aligned"
        case let .offsetOverflow(field, base, offset):
            return "\(field) base \(base) plus relative offset \(offset) overflows"
        case let .outOfBounds(field, start, byteCount, length):
            return "\(field) range starts at \(start) for \(byteCount) bytes, exceeding studio length \(length)"
        case let .unterminatedString(field, start):
            return "\(field) string at \(start) has no NUL terminator"
        case let .nonFiniteFloat(field, offset):
            return "\(field) contains a non-finite Float at byte \(offset)"
        case let .invalidAnimationBasePointer(animation, value):
            return "animation \(animation) baseptr \(value) does not point back to studiohdr_t"
        case let .invalidFrameCount(animation, value):
            return "animation \(animation) has invalid frame count \(value)"
        case let .invalidAnimationBlock(animation, value):
            return "animation \(animation) has invalid animation block \(value)"
        case let .invalidInlineAnimationOffset(animation, value):
            return "animation \(animation) has invalid inline animation offset \(value)"
        case let .invalidSequenceGroupSize(sequence, x, y):
            return "sequence \(sequence) has invalid group size \(x)x\(y)"
        case let .sequenceBlendCountMismatch(sequence, declared, tableCount):
            return "sequence \(sequence) declares \(declared) blends but its authored table has \(tableCount) entries"
        case let .invalidAnimationReference(sequence, blend, value, animationCount):
            return "sequence \(sequence) blend \(blend) references animation \(value), outside 0..<\(animationCount)"
        case let .invalidAnimationIndex(value, animationCount):
            return "animation index \(value) is outside 0..<\(animationCount)"
        case let .invalidSequenceIndex(value, sequenceCount):
            return "sequence index \(value) is outside 0..<\(sequenceCount)"
        case let .invalidBlendIndex(sequence, value, blendCount):
            return "sequence \(sequence) blend index \(value) is outside 0..<\(blendCount)"
        case let .invalidFrame(animation, value, frameCount):
            return "animation \(animation) frame \(value) is outside 0..<\(frameCount)"
        case let .invalidAnimationRecordFlags(animation, bone, flags):
            return String(
                format: "animation %d bone %d has unknown mstudioanim_t flags 0x%02X",
                animation,
                bone,
                flags
            )
        case let .conflictingAnimationRecordFlags(animation, bone, flags):
            return String(
                format: "animation %d bone %d has conflicting mstudioanim_t flags 0x%02X",
                animation,
                bone,
                flags
            )
        case let .invalidAnimationRecordBone(animation, value, boneCount):
            return "animation \(animation) record references bone \(value), outside 0..<\(boneCount)"
        case let .nonIncreasingAnimationRecordBone(animation, previous, value):
            return "animation \(animation) bone records are not strictly increasing: \(previous), then \(value)"
        case let .invalidAnimationRecordNextOffset(animation, recordOffset, value):
            return "animation \(animation) record at \(recordOffset) has invalid nextoffset \(value)"
        case let .animationRecordPayloadOverlapsNext(animation, recordOffset, payloadEnd, nextOffset):
            return "animation \(animation) record at \(recordOffset) payload ends at \(payloadEnd), beyond next record at \(nextOffset)"
        case let .invalidAnimationSentinel(animation, flags, nextOffset):
            return String(
                format: "animation %d bone-255 sentinel has flags 0x%02X and nextoffset %d",
                animation,
                flags,
                nextOffset
            )
        case let .invalidCompressedQuaternion(animation, bone, format, squaredXYZ):
            return "animation \(animation) bone \(bone) has invalid \(format) squared xyz length \(squaredXYZ)"
        case let .unsupported(feature):
            return feature.description
        }
    }
}

/// Features whose structures are present in Source v48 but are deliberately
/// not approximated by the first renderer-neutral evaluator.
public enum SourceStudioAnimationUnsupportedFeature: Equatable, Sendable, CustomStringConvertible {
    case deltaAnimation(animation: Int)
    case movementBlocks(animation: Int, count: Int)
    case animationNeedsRecompile(animation: Int)
    case externalAnimationBlock(animation: Int, block: Int)
    case animationSections(animation: Int, framesPerSection: Int)
    case inverseKinematics(animation: Int, count: Int)
    case localHierarchy(animation: Int, count: Int)
    case zeroFrameData(animation: Int, count: Int)
    case compressedBoneValues(animation: Int, bone: Int, flags: UInt8)

    public var description: String {
        switch self {
        case let .deltaAnimation(animation):
            return "animation \(animation) is delta data and requires an authored base pose"
        case let .movementBlocks(animation, count):
            return "animation \(animation) has \(count) unsupported movement blocks"
        case let .animationNeedsRecompile(animation):
            return "animation \(animation) uses animblock -1 and must be recompiled"
        case let .externalAnimationBlock(animation, block):
            return "animation \(animation) requires external ANI block \(block)"
        case let .animationSections(animation, framesPerSection):
            return "animation \(animation) uses unsupported \(framesPerSection)-frame sections"
        case let .inverseKinematics(animation, count):
            return "animation \(animation) has \(count) unsupported IK rules"
        case let .localHierarchy(animation, count):
            return "animation \(animation) has \(count) unsupported local hierarchy overrides"
        case let .zeroFrameData(animation, count):
            return "animation \(animation) has unsupported zero-frame data with \(count) spans"
        case let .compressedBoneValues(animation, bone, flags):
            return String(
                format: "animation %d bone %d uses unsupported compressed values (flags 0x%02X)",
                animation,
                bone,
                flags
            )
        }
    }
}

/// Bit-exact `mstudioanim_t::flags` values from Source SDK 2013 `studio.h`.
public struct SourceStudioAnimationValueFlags: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let rawPosition = Self(rawValue: 0x01)
    public static let rawRotation48 = Self(rawValue: 0x02)
    public static let animatedPosition = Self(rawValue: 0x04)
    public static let animatedRotation = Self(rawValue: 0x08)
    public static let delta = Self(rawValue: 0x10)
    public static let rawRotation64 = Self(rawValue: 0x20)

    fileprivate static let knownMask: UInt8 = 0x3F
}

public enum SourceStudioConstantRotationFormat: String, Equatable, Sendable, CustomStringConvertible {
    case quaternion48
    case quaternion64

    public var description: String { rawValue }
}

/// One authored `mstudioanim_t` channel. Constant raw values are decoded; RLE
/// value channels remain represented by their flags and fail explicitly if a
/// caller asks for a pose.
public struct SourceStudioAnimationBoneChannel: Equatable, Sendable {
    public let boneIndex: Int
    public let flags: SourceStudioAnimationValueFlags
    public let constantPosition: SourceVector3?
    public let constantRotation: SourceStudioQuaternion?
    public let constantRotationFormat: SourceStudioConstantRotationFormat?
}

public struct SourceStudioAnimationDescriptor: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let framesPerSecond: Float
    public let flags: Int32
    public let frameCount: Int
    public let movementCount: Int
    public let movementOffset: Int32
    public let animationBlock: Int32
    public let animationOffset: Int32
    public let inverseKinematicsRuleCount: Int
    public let inverseKinematicsRuleOffset: Int32
    public let animationBlockInverseKinematicsRuleOffset: Int32
    public let localHierarchyCount: Int
    public let localHierarchyOffset: Int32
    public let sectionOffset: Int32
    public let framesPerSection: Int
    public let zeroFrameSpan: Int
    public let zeroFrameCount: Int
    public let zeroFrameOffset: Int32
    public let zeroFrameStallTime: Float
    public let boneChannels: [SourceStudioAnimationBoneChannel]

    public var isDelta: Bool { (flags & 0x0004) != 0 }
}

public struct SourceStudioAnimationSequenceDescriptor: Equatable, Sendable {
    public let index: Int
    public let label: String
    public let flags: Int32
    public let groupSizeX: Int
    public let groupSizeY: Int
    public let animationIndices: [Int]

    /// Returns exactly the authored short-table entry. It does not choose or
    /// interpolate a blend based on a guessed pose-parameter threshold.
    public func animationIndex(blendIndex: Int) throws -> Int {
        guard animationIndices.indices.contains(blendIndex) else {
            throw SourceStudioAnimationError.invalidBlendIndex(
                sequence: index,
                value: blendIndex,
                blendCount: animationIndices.count
            )
        }
        return animationIndices[blendIndex]
    }

    public func animationIndex(x: Int, y: Int) throws -> Int {
        guard x >= 0, x < groupSizeX, y >= 0, y < groupSizeY else {
            let flattened = y * groupSizeX + x
            throw SourceStudioAnimationError.invalidBlendIndex(
                sequence: index,
                value: flattened,
                blendCount: animationIndices.count
            )
        }
        return animationIndices[y * groupSizeX + x]
    }
}

public struct SourceStudioAnimationBoneDescriptor: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let parentIndex: Int?
    public let bindPosition: SourceVector3
    public let bindRotation: SourceStudioQuaternion
    public let bindLocalTransform: SourceStudioMatrix3x4
    public let bindModelTransform: SourceStudioMatrix3x4
}

public struct SourceStudioAnimationSkeleton: Equatable, Sendable {
    public let bones: [SourceStudioAnimationBoneDescriptor]

    /// Re-applies the decoded local bind pose below an arbitrary model root.
    public func bindModelTransforms(
        rootTransform: SourceStudioMatrix3x4 = .identity
    ) -> [SourceStudioMatrix3x4] {
        var result = Array(repeating: SourceStudioMatrix3x4.identity, count: bones.count)
        var resolved = Array(repeating: false, count: bones.count)

        func resolve(_ index: Int) -> SourceStudioMatrix3x4 {
            if resolved[index] { return result[index] }
            let bone = bones[index]
            if let parentIndex = bone.parentIndex {
                result[index] = resolve(parentIndex).concatenating(bone.bindLocalTransform)
            } else {
                result[index] = rootTransform.concatenating(bone.bindLocalTransform)
            }
            resolved[index] = true
            return result[index]
        }

        for index in bones.indices { _ = resolve(index) }
        return result
    }
}

public struct SourceStudioAnimationBonePose: Equatable, Sendable {
    public let position: SourceVector3
    public let rotation: SourceStudioQuaternion
    public let localTransform: SourceStudioMatrix3x4
    public let modelTransform: SourceStudioMatrix3x4
}

public struct SourceStudioAnimationPose: Equatable, Sendable {
    public let animationIndex: Int
    public let frame: Int
    public let bones: [SourceStudioAnimationBonePose]

    public var localTransforms: [SourceStudioMatrix3x4] {
        bones.map(\.localTransform)
    }

    public var modelTransforms: [SourceStudioMatrix3x4] {
        bones.map(\.modelTransform)
    }
}

/// Safe, renderer-neutral Source v48 animation data.
///
/// Grounding is the fixed Source SDK 2013 commit
/// `c8f4c6351162fbff83bfa5a428d45d1e6eed3824`: `studio.h` defines
/// `mstudioanimdesc_t`, `mstudioanim_t`, Quaternion48/64 and Vector48, while
/// `bone_setup.cpp` defines raw-value precedence and parent-first transform
/// concatenation. This is an independent parser; no Source code is copied.
public struct SourceStudioAnimationModel: Sendable {
    public let header: SourceStudioHeader
    public let skeleton: SourceStudioAnimationSkeleton
    public let animations: [SourceStudioAnimationDescriptor]
    public let sequences: [SourceStudioAnimationSequenceDescriptor]

    fileprivate init(
        header: SourceStudioHeader,
        skeleton: SourceStudioAnimationSkeleton,
        animations: [SourceStudioAnimationDescriptor],
        sequences: [SourceStudioAnimationSequenceDescriptor]
    ) {
        self.header = header
        self.skeleton = skeleton
        self.animations = animations
        self.sequences = sequences
    }

    public func animationIndex(sequenceIndex: Int, blendIndex: Int) throws -> Int {
        guard sequences.indices.contains(sequenceIndex) else {
            throw SourceStudioAnimationError.invalidSequenceIndex(
                value: sequenceIndex,
                sequenceCount: sequences.count
            )
        }
        return try sequences[sequenceIndex].animationIndex(blendIndex: blendIndex)
    }

    /// Evaluates one exact integer frame. Constant RAWPOS/RAWROT/RAWROT2
    /// channels are frame-invariant by definition. RLE channels and animation
    /// blocks that require interpolation or other runtime state fail with a
    /// typed `unsupported` error instead of being guessed.
    public func pose(
        animationIndex: Int,
        frame: Int,
        rootTransform: SourceStudioMatrix3x4 = .identity
    ) throws -> SourceStudioAnimationPose {
        guard animations.indices.contains(animationIndex) else {
            throw SourceStudioAnimationError.invalidAnimationIndex(
                value: animationIndex,
                animationCount: animations.count
            )
        }
        let animation = animations[animationIndex]
        guard frame >= 0, frame < animation.frameCount else {
            throw SourceStudioAnimationError.invalidFrame(
                animation: animationIndex,
                value: frame,
                frameCount: animation.frameCount
            )
        }

        if animation.isDelta {
            throw SourceStudioAnimationError.unsupported(
                .deltaAnimation(animation: animationIndex)
            )
        }
        if animation.movementCount > 0 {
            throw SourceStudioAnimationError.unsupported(
                .movementBlocks(animation: animationIndex, count: animation.movementCount)
            )
        }
        if animation.animationBlock == -1 {
            throw SourceStudioAnimationError.unsupported(
                .animationNeedsRecompile(animation: animationIndex)
            )
        }
        if animation.animationBlock > 0 {
            throw SourceStudioAnimationError.unsupported(
                .externalAnimationBlock(
                    animation: animationIndex,
                    block: Int(animation.animationBlock)
                )
            )
        }
        if animation.framesPerSection > 0 {
            throw SourceStudioAnimationError.unsupported(
                .animationSections(
                    animation: animationIndex,
                    framesPerSection: animation.framesPerSection
                )
            )
        }
        if animation.inverseKinematicsRuleCount > 0 {
            throw SourceStudioAnimationError.unsupported(
                .inverseKinematics(
                    animation: animationIndex,
                    count: animation.inverseKinematicsRuleCount
                )
            )
        }
        if animation.localHierarchyCount > 0 {
            throw SourceStudioAnimationError.unsupported(
                .localHierarchy(
                    animation: animationIndex,
                    count: animation.localHierarchyCount
                )
            )
        }
        if animation.zeroFrameCount > 0 || animation.zeroFrameOffset != 0 {
            throw SourceStudioAnimationError.unsupported(
                .zeroFrameData(animation: animationIndex, count: animation.zeroFrameCount)
            )
        }

        var positions = skeleton.bones.map(\.bindPosition)
        var rotations = skeleton.bones.map(\.bindRotation)

        for channel in animation.boneChannels {
            if channel.flags.contains(.animatedPosition) ||
                channel.flags.contains(.animatedRotation) {
                throw SourceStudioAnimationError.unsupported(
                    .compressedBoneValues(
                        animation: animationIndex,
                        bone: channel.boneIndex,
                        flags: channel.flags.rawValue
                    )
                )
            }

            if let constantRotation = channel.constantRotation {
                rotations[channel.boneIndex] = constantRotation
            } else if channel.flags.contains(.delta) {
                rotations[channel.boneIndex] = .identity
            }

            if let constantPosition = channel.constantPosition {
                positions[channel.boneIndex] = constantPosition
            } else if channel.flags.contains(.delta) {
                positions[channel.boneIndex] = .zero
            }
        }

        let locals = zip(rotations, positions).map { pair in
            pair.0.matrix(position: pair.1)
        }
        var models = Array(repeating: SourceStudioMatrix3x4.identity, count: locals.count)
        var resolved = Array(repeating: false, count: locals.count)

        func resolve(_ index: Int) -> SourceStudioMatrix3x4 {
            if resolved[index] { return models[index] }
            let bone = skeleton.bones[index]
            if let parentIndex = bone.parentIndex {
                models[index] = resolve(parentIndex).concatenating(locals[index])
            } else {
                models[index] = rootTransform.concatenating(locals[index])
            }
            resolved[index] = true
            return models[index]
        }
        for index in skeleton.bones.indices { _ = resolve(index) }

        var bonePoses: [SourceStudioAnimationBonePose] = []
        bonePoses.reserveCapacity(skeleton.bones.count)
        for index in skeleton.bones.indices {
            bonePoses.append(
                SourceStudioAnimationBonePose(
                    position: positions[index],
                    rotation: rotations[index],
                    localTransform: locals[index],
                    modelTransform: models[index]
                )
            )
        }
        return SourceStudioAnimationPose(
            animationIndex: animationIndex,
            frame: frame,
            bones: bonePoses
        )
    }
}

public enum SourceStudioAnimationDecoder {
    private static let animationDescriptorSize = 100

    public static func decode(
        mdlData: Data,
        expectedChecksum: Int32? = nil
    ) throws -> SourceStudioAnimationModel {
        let studio = try SourceStudioModel(
            data: mdlData,
            expectedChecksum: expectedChecksum
        )
        let reader = SourceStudioAnimationReader(data: mdlData)

        let animationCount = try reader.count32(
            at: 180,
            field: "studiohdr_t.numlocalanim"
        )
        let animationTableOffset = try reader.int32(
            at: 184,
            field: "studiohdr_t.localanimindex"
        )
        let animationStart = try reader.tableStart(
            base: 0,
            relativeOffset: animationTableOffset,
            count: animationCount,
            stride: animationDescriptorSize,
            alignment: 4,
            field: "studiohdr_t.localanimations"
        )

        var animations: [SourceStudioAnimationDescriptor] = []
        animations.reserveCapacity(animationCount)
        for index in 0..<animationCount {
            let base = animationStart + index * animationDescriptorSize
            animations.append(
                try decodeAnimation(
                    reader: reader,
                    base: base,
                    index: index,
                    boneCount: studio.bones.count
                )
            )
        }

        let sequenceCount = try reader.count32(
            at: 188,
            field: "studiohdr_t.numlocalseq"
        )
        let sequenceTableOffset = try reader.int32(
            at: 192,
            field: "studiohdr_t.localseqindex"
        )
        let sequenceStart = try reader.tableStart(
            base: 0,
            relativeOffset: sequenceTableOffset,
            count: sequenceCount,
            stride: SourceStudioModel.sequenceRecordSize,
            alignment: 4,
            field: "studiohdr_t.localsequences"
        )

        var sequences: [SourceStudioAnimationSequenceDescriptor] = []
        sequences.reserveCapacity(sequenceCount)
        for index in 0..<sequenceCount {
            let base = sequenceStart + index * SourceStudioModel.sequenceRecordSize
            sequences.append(
                try decodeSequence(
                    reader: reader,
                    base: base,
                    index: index,
                    source: studio.sequences[index],
                    animationCount: animationCount
                )
            )
        }

        let bindModelTransforms = studio.defaultBoneToWorld()
        let bones = studio.bones.enumerated().map { index, bone in
            SourceStudioAnimationBoneDescriptor(
                index: index,
                name: bone.name,
                parentIndex: bone.parent >= 0 ? Int(bone.parent) : nil,
                bindPosition: bone.position,
                bindRotation: bone.quaternion,
                bindLocalTransform: bone.quaternion.matrix(position: bone.position),
                bindModelTransform: bindModelTransforms[index]
            )
        }

        return SourceStudioAnimationModel(
            header: studio.header,
            skeleton: SourceStudioAnimationSkeleton(bones: bones),
            animations: animations,
            sequences: sequences
        )
    }

    private static func decodeAnimation(
        reader: SourceStudioAnimationReader,
        base: Int,
        index: Int,
        boneCount: Int
    ) throws -> SourceStudioAnimationDescriptor {
        let prefix = "animation[\(index)]"
        let basePointer = try reader.int32(at: base, field: "\(prefix).baseptr")
        let headerAddress = try reader.relativeAddress(
            base: base,
            relativeOffset: basePointer,
            field: "\(prefix).baseptr"
        )
        guard headerAddress == 0 else {
            throw SourceStudioAnimationError.invalidAnimationBasePointer(
                animation: index,
                value: basePointer
            )
        }

        let nameOffset = try reader.int32(at: base + 4, field: "\(prefix).sznameindex")
        let name = try reader.relativeCString(
            base: base,
            relativeOffset: nameOffset,
            field: "\(prefix).name"
        )
        let fps = try reader.float(at: base + 8, field: "\(prefix).fps")
        let flags = try reader.int32(at: base + 12, field: "\(prefix).flags")
        let frameCountValue = try reader.int32(at: base + 16, field: "\(prefix).numframes")
        guard frameCountValue > 0 else {
            throw SourceStudioAnimationError.invalidFrameCount(
                animation: index,
                value: frameCountValue
            )
        }

        let movementCount = try reader.count32(at: base + 20, field: "\(prefix).nummovements")
        let movementOffset = try reader.int32(at: base + 24, field: "\(prefix).movementindex")
        let animationBlock = try reader.int32(at: base + 52, field: "\(prefix).animblock")
        guard animationBlock >= -1 else {
            throw SourceStudioAnimationError.invalidAnimationBlock(
                animation: index,
                value: animationBlock
            )
        }
        let animationOffset = try reader.int32(at: base + 56, field: "\(prefix).animindex")
        guard animationOffset >= 0 else {
            throw SourceStudioAnimationError.invalidInlineAnimationOffset(
                animation: index,
                value: animationOffset
            )
        }

        let ikCount = try reader.count32(at: base + 60, field: "\(prefix).numikrules")
        let ikOffset = try reader.int32(at: base + 64, field: "\(prefix).ikruleindex")
        let blockIKOffset = try reader.int32(
            at: base + 68,
            field: "\(prefix).animblockikruleindex"
        )
        let hierarchyCount = try reader.count32(
            at: base + 72,
            field: "\(prefix).numlocalhierarchy"
        )
        let hierarchyOffset = try reader.int32(
            at: base + 76,
            field: "\(prefix).localhierarchyindex"
        )
        let sectionOffset = try reader.int32(at: base + 80, field: "\(prefix).sectionindex")
        let framesPerSectionValue = try reader.int32(
            at: base + 84,
            field: "\(prefix).sectionframes"
        )
        guard framesPerSectionValue >= 0 else {
            throw SourceStudioAnimationError.invalidCount(
                field: "\(prefix).sectionframes",
                value: framesPerSectionValue
            )
        }
        let zeroFrameSpanValue = try reader.int16(
            at: base + 88,
            field: "\(prefix).zeroframespan"
        )
        guard zeroFrameSpanValue >= 0 else {
            throw SourceStudioAnimationError.invalidShortCount(
                field: "\(prefix).zeroframespan",
                value: zeroFrameSpanValue
            )
        }
        let zeroFrameCountValue = try reader.int16(
            at: base + 90,
            field: "\(prefix).zeroframecount"
        )
        guard zeroFrameCountValue >= 0 else {
            throw SourceStudioAnimationError.invalidShortCount(
                field: "\(prefix).zeroframecount",
                value: zeroFrameCountValue
            )
        }
        let zeroFrameOffset = try reader.int32(
            at: base + 92,
            field: "\(prefix).zeroframeindex"
        )
        let zeroFrameStallTime = try reader.float(
            at: base + 96,
            field: "\(prefix).zeroframestalltime"
        )

        let hasSections = framesPerSectionValue > 0
        let canHaveInlineRecords = animationBlock == 0 && !hasSections
        var channels: [SourceStudioAnimationBoneChannel] = []
        if canHaveInlineRecords {
            if animationOffset == 0 {
                if zeroFrameCountValue == 0 && zeroFrameOffset == 0 {
                    throw SourceStudioAnimationError.invalidInlineAnimationOffset(
                        animation: index,
                        value: animationOffset
                    )
                }
            } else {
                channels = try decodeAnimationRecords(
                    reader: reader,
                    descriptorBase: base,
                    relativeOffset: animationOffset,
                    animationIndex: index,
                    boneCount: boneCount
                )
            }
        }

        return SourceStudioAnimationDescriptor(
            index: index,
            name: name,
            framesPerSecond: fps,
            flags: flags,
            frameCount: Int(frameCountValue),
            movementCount: movementCount,
            movementOffset: movementOffset,
            animationBlock: animationBlock,
            animationOffset: animationOffset,
            inverseKinematicsRuleCount: ikCount,
            inverseKinematicsRuleOffset: ikOffset,
            animationBlockInverseKinematicsRuleOffset: blockIKOffset,
            localHierarchyCount: hierarchyCount,
            localHierarchyOffset: hierarchyOffset,
            sectionOffset: sectionOffset,
            framesPerSection: Int(framesPerSectionValue),
            zeroFrameSpan: Int(zeroFrameSpanValue),
            zeroFrameCount: Int(zeroFrameCountValue),
            zeroFrameOffset: zeroFrameOffset,
            zeroFrameStallTime: zeroFrameStallTime,
            boneChannels: channels
        )
    }

    private static func decodeAnimationRecords(
        reader: SourceStudioAnimationReader,
        descriptorBase: Int,
        relativeOffset: Int32,
        animationIndex: Int,
        boneCount: Int
    ) throws -> [SourceStudioAnimationBoneChannel] {
        var offset = try reader.relativeAddress(
            base: descriptorBase,
            relativeOffset: relativeOffset,
            field: "animation[\(animationIndex)].animindex"
        )
        guard offset % 2 == 0 else {
            throw SourceStudioAnimationError.misalignedOffset(
                field: "animation[\(animationIndex)].animindex",
                offset: relativeOffset,
                alignment: 2
            )
        }

        var channels: [SourceStudioAnimationBoneChannel] = []
        channels.reserveCapacity(min(boneCount, 128))
        var previousBone = -1

        while true {
            let recordField = "animation[\(animationIndex)].record@\(offset)"
            let bone = Int(try reader.uint8(at: offset, field: "\(recordField).bone"))
            let rawFlags = try reader.uint8(at: offset + 1, field: "\(recordField).flags")
            let nextOffset = try reader.int16(at: offset + 2, field: "\(recordField).nextoffset")

            if bone == 255 {
                guard rawFlags == 0, nextOffset == 0 else {
                    throw SourceStudioAnimationError.invalidAnimationSentinel(
                        animation: animationIndex,
                        flags: rawFlags,
                        nextOffset: nextOffset
                    )
                }
                break
            }

            guard bone < boneCount else {
                throw SourceStudioAnimationError.invalidAnimationRecordBone(
                    animation: animationIndex,
                    value: bone,
                    boneCount: boneCount
                )
            }
            guard bone > previousBone else {
                throw SourceStudioAnimationError.nonIncreasingAnimationRecordBone(
                    animation: animationIndex,
                    previous: previousBone,
                    value: bone
                )
            }
            guard rawFlags & ~SourceStudioAnimationValueFlags.knownMask == 0 else {
                throw SourceStudioAnimationError.invalidAnimationRecordFlags(
                    animation: animationIndex,
                    bone: bone,
                    flags: rawFlags
                )
            }

            let flags = SourceStudioAnimationValueFlags(rawValue: rawFlags)
            let rotationEncodingCount =
                (flags.contains(.rawRotation48) ? 1 : 0) +
                (flags.contains(.rawRotation64) ? 1 : 0) +
                (flags.contains(.animatedRotation) ? 1 : 0)
            let positionEncodingCount =
                (flags.contains(.rawPosition) ? 1 : 0) +
                (flags.contains(.animatedPosition) ? 1 : 0)
            let hasRawEncoding = flags.contains(.rawPosition) ||
                flags.contains(.rawRotation48) ||
                flags.contains(.rawRotation64)
            let hasAnimatedEncoding = flags.contains(.animatedPosition) ||
                flags.contains(.animatedRotation)
            // `mstudioanim_t::pData()` has two mutually exclusive layouts in
            // studio.h: the RAW fields share one constant-value payload while
            // ANIMPOS/ANIMROT share an offset-pointer payload. Cross-layout
            // combinations cannot be addressed by Source's own accessors.
            guard rotationEncodingCount <= 1,
                  positionEncodingCount <= 1,
                  !(hasRawEncoding && hasAnimatedEncoding) else {
                throw SourceStudioAnimationError.conflictingAnimationRecordFlags(
                    animation: animationIndex,
                    bone: bone,
                    flags: rawFlags
                )
            }

            var cursor = offset + 4
            var constantRotation: SourceStudioQuaternion?
            var rotationFormat: SourceStudioConstantRotationFormat?
            if flags.contains(.rawRotation48) {
                constantRotation = try reader.quaternion48(
                    at: cursor,
                    animation: animationIndex,
                    bone: bone
                )
                rotationFormat = .quaternion48
                cursor += 6
            } else if flags.contains(.rawRotation64) {
                constantRotation = try reader.quaternion64(
                    at: cursor,
                    animation: animationIndex,
                    bone: bone
                )
                rotationFormat = .quaternion64
                cursor += 8
            } else if flags.contains(.animatedRotation) {
                try reader.requireRange(
                    start: cursor,
                    byteCount: 6,
                    field: "\(recordField).animatedRotationOffsets"
                )
                cursor += 6
            }

            var constantPosition: SourceVector3?
            if flags.contains(.rawPosition) {
                constantPosition = try reader.vector48(
                    at: cursor,
                    field: "\(recordField).rawPosition"
                )
                cursor += 6
            } else if flags.contains(.animatedPosition) {
                try reader.requireRange(
                    start: cursor,
                    byteCount: 6,
                    field: "\(recordField).animatedPositionOffsets"
                )
                cursor += 6
            }

            try reader.requireRange(
                start: offset,
                byteCount: cursor - offset,
                field: recordField
            )

            channels.append(
                SourceStudioAnimationBoneChannel(
                    boneIndex: bone,
                    flags: flags,
                    constantPosition: constantPosition,
                    constantRotation: constantRotation,
                    constantRotationFormat: rotationFormat
                )
            )
            previousBone = bone

            if nextOffset == 0 { break }
            guard nextOffset > 0, nextOffset % 2 == 0 else {
                throw SourceStudioAnimationError.invalidAnimationRecordNextOffset(
                    animation: animationIndex,
                    recordOffset: offset,
                    value: nextOffset
                )
            }
            let next = try reader.relativeAddress(
                base: offset,
                relativeOffset: Int32(nextOffset),
                field: "\(recordField).nextoffset"
            )
            guard cursor <= next else {
                throw SourceStudioAnimationError.animationRecordPayloadOverlapsNext(
                    animation: animationIndex,
                    recordOffset: offset,
                    payloadEnd: cursor,
                    nextOffset: next
                )
            }
            offset = next
        }

        return channels
    }

    private static func decodeSequence(
        reader: SourceStudioAnimationReader,
        base: Int,
        index: Int,
        source: SourceStudioSequence,
        animationCount: Int
    ) throws -> SourceStudioAnimationSequenceDescriptor {
        let prefix = "sequence[\(index)]"
        let declaredBlendCount = try reader.int32(at: base + 56, field: "\(prefix).numblends")
        guard declaredBlendCount >= 0 else {
            throw SourceStudioAnimationError.invalidCount(
                field: "\(prefix).numblends",
                value: declaredBlendCount
            )
        }
        let groupX = try reader.int32(at: base + 68, field: "\(prefix).groupsize[0]")
        let groupY = try reader.int32(at: base + 72, field: "\(prefix).groupsize[1]")
        guard groupX > 0, groupY > 0 else {
            throw SourceStudioAnimationError.invalidSequenceGroupSize(
                sequence: index,
                x: groupX,
                y: groupY
            )
        }
        let product = Int64(groupX) * Int64(groupY)
        guard product > 0, let tableCount = Int(exactly: product) else {
            throw SourceStudioAnimationError.invalidSequenceGroupSize(
                sequence: index,
                x: groupX,
                y: groupY
            )
        }
        guard let exactTableCount = Int32(exactly: tableCount),
              declaredBlendCount == exactTableCount else {
            throw SourceStudioAnimationError.sequenceBlendCountMismatch(
                sequence: index,
                declared: declaredBlendCount,
                tableCount: tableCount
            )
        }

        let blendTableOffset = try reader.int32(
            at: base + 60,
            field: "\(prefix).animindexindex"
        )
        let blendStart = try reader.tableStart(
            base: base,
            relativeOffset: blendTableOffset,
            count: tableCount,
            stride: 2,
            alignment: 2,
            field: "\(prefix).animationIndices"
        )
        var animationIndices: [Int] = []
        animationIndices.reserveCapacity(tableCount)
        for blend in 0..<tableCount {
            let value = try reader.int16(
                at: blendStart + blend * 2,
                field: "\(prefix).animationIndices[\(blend)]"
            )
            guard value >= 0, Int(value) < animationCount else {
                throw SourceStudioAnimationError.invalidAnimationReference(
                    sequence: index,
                    blend: blend,
                    value: value,
                    animationCount: animationCount
                )
            }
            animationIndices.append(Int(value))
        }

        return SourceStudioAnimationSequenceDescriptor(
            index: index,
            label: source.label,
            flags: source.flags,
            groupSizeX: Int(groupX),
            groupSizeY: Int(groupY),
            animationIndices: animationIndices
        )
    }
}

private struct SourceStudioAnimationReader {
    let bytes: [UInt8]
    var length: Int { bytes.count }

    init(data: Data) {
        bytes = Array(data)
    }

    func uint8(at offset: Int, field: String) throws -> UInt8 {
        try requireRange(start: offset, byteCount: 1, field: field)
        return bytes[offset]
    }

    func uint16(at offset: Int, field: String) throws -> UInt16 {
        try requireRange(start: offset, byteCount: 2, field: field)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func int16(at offset: Int, field: String) throws -> Int16 {
        Int16(bitPattern: try uint16(at: offset, field: field))
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

    func uint64(at offset: Int, field: String) throws -> UInt64 {
        try requireRange(start: offset, byteCount: 8, field: field)
        var result: UInt64 = 0
        for byte in 0..<8 {
            result |= UInt64(bytes[offset + byte]) << UInt64(byte * 8)
        }
        return result
    }

    func float(at offset: Int, field: String) throws -> Float {
        let value = Float(bitPattern: try uint32(at: offset, field: field))
        guard value.isFinite else {
            throw SourceStudioAnimationError.nonFiniteFloat(field: field, offset: offset)
        }
        return value
    }

    func count32(at offset: Int, field: String) throws -> Int {
        let value = try int32(at: offset, field: field)
        guard value >= 0 else {
            throw SourceStudioAnimationError.invalidCount(field: field, value: value)
        }
        return Int(value)
    }

    func relativeCString(
        base: Int,
        relativeOffset: Int32,
        field: String
    ) throws -> String {
        guard relativeOffset != 0 else {
            throw SourceStudioAnimationError.zeroOffset(field: field)
        }
        let start = try relativeAddress(
            base: base,
            relativeOffset: relativeOffset,
            field: field
        )
        guard start < length else {
            throw SourceStudioAnimationError.outOfBounds(
                field: field,
                start: start,
                byteCount: 1,
                length: length
            )
        }
        guard let end = bytes[start...].firstIndex(of: 0) else {
            throw SourceStudioAnimationError.unterminatedString(field: field, start: start)
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func tableStart(
        base: Int,
        relativeOffset: Int32,
        count: Int,
        stride: Int,
        alignment: Int,
        field: String
    ) throws -> Int {
        if count == 0 { return base }
        guard relativeOffset != 0 else {
            throw SourceStudioAnimationError.zeroOffset(field: field)
        }
        guard relativeOffset % Int32(alignment) == 0 else {
            throw SourceStudioAnimationError.misalignedOffset(
                field: field,
                offset: relativeOffset,
                alignment: alignment
            )
        }
        let start = try relativeAddress(
            base: base,
            relativeOffset: relativeOffset,
            field: field
        )
        guard count <= (length - start) / stride else {
            let byteCount = count > Int.max / stride ? Int.max : count * stride
            throw SourceStudioAnimationError.outOfBounds(
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
            throw SourceStudioAnimationError.offsetOverflow(
                field: field,
                base: base,
                offset: relativeOffset
            )
        }
        guard exact <= length else {
            throw SourceStudioAnimationError.outOfBounds(
                field: field,
                start: exact,
                byteCount: 0,
                length: length
            )
        }
        return exact
    }

    func quaternion48(
        at offset: Int,
        animation: Int,
        bone: Int
    ) throws -> SourceStudioQuaternion {
        let rawX = try uint16(at: offset, field: "Quaternion48.x")
        let rawY = try uint16(at: offset + 2, field: "Quaternion48.y")
        let rawZW = try uint16(at: offset + 4, field: "Quaternion48.z/wneg")
        let x = (Float(Int(rawX) - 32_768)) * (1 / 32_768.0)
        let y = (Float(Int(rawY) - 32_768)) * (1 / 32_768.0)
        let z = (Float(Int(rawZW & 0x7FFF) - 16_384)) * (1 / 16_384.0)
        let squaredXYZ = x * x + y * y + z * z
        guard squaredXYZ <= 1 else {
            throw SourceStudioAnimationError.invalidCompressedQuaternion(
                animation: animation,
                bone: bone,
                format: .quaternion48,
                squaredXYZ: squaredXYZ
            )
        }
        var w = (1 - squaredXYZ).squareRoot()
        if (rawZW & 0x8000) != 0 { w = -w }
        return SourceStudioQuaternion(x: x, y: y, z: z, w: w)
    }

    func quaternion64(
        at offset: Int,
        animation: Int,
        bone: Int
    ) throws -> SourceStudioQuaternion {
        let raw = try uint64(at: offset, field: "Quaternion64")
        let mask: UInt64 = 0x1F_FFFF
        let rawX = Int(raw & mask)
        let rawY = Int((raw >> 21) & mask)
        let rawZ = Int((raw >> 42) & mask)
        let scale: Float = 1 / 1_048_576.5
        let x = Float(rawX - 1_048_576) * scale
        let y = Float(rawY - 1_048_576) * scale
        let z = Float(rawZ - 1_048_576) * scale
        let squaredXYZ = x * x + y * y + z * z
        guard squaredXYZ <= 1 else {
            throw SourceStudioAnimationError.invalidCompressedQuaternion(
                animation: animation,
                bone: bone,
                format: .quaternion64,
                squaredXYZ: squaredXYZ
            )
        }
        var w = (1 - squaredXYZ).squareRoot()
        if (raw >> 63) != 0 { w = -w }
        return SourceStudioQuaternion(x: x, y: y, z: z, w: w)
    }

    func vector48(at offset: Int, field: String) throws -> SourceVector3 {
        SourceVector3(
            decodeSourceFloat16(try uint16(at: offset, field: "\(field).x")),
            decodeSourceFloat16(try uint16(at: offset + 2, field: "\(field).y")),
            decodeSourceFloat16(try uint16(at: offset + 4, field: "\(field).z"))
        )
    }

    /// Matches Source `float16::Convert16bitFloatTo32bits`, including its
    /// deliberate infinity-to-65504 and NaN-to-zero behavior.
    private func decodeSourceFloat16(_ raw: UInt16) -> Float {
        let sign = raw & 0x8000
        let exponent = (raw >> 10) & 0x1F
        let mantissa = raw & 0x03FF
        if exponent == 31 {
            if mantissa != 0 { return 0 }
            return sign == 0 ? 65_504 : -65_504
        }
        if exponent == 0, mantissa != 0 {
            let magnitude = (Float(mantissa) / 1_024) * (1 / 16_384.0)
            return sign == 0 ? magnitude : -magnitude
        }
        let floatSign = UInt32(sign) << 16
        let floatExponent = UInt32(
            (Int(exponent) - 15 + 127) * (exponent == 0 ? 0 : 1)
        ) << 23
        let floatMantissa = UInt32(mantissa) << 13
        return Float(bitPattern: floatSign | floatExponent | floatMantissa)
    }

    func requireRange(start: Int, byteCount: Int, field: String) throws {
        guard start >= 0, byteCount >= 0, start <= length, byteCount <= length - start else {
            throw SourceStudioAnimationError.outOfBounds(
                field: field,
                start: start,
                byteCount: byteCount,
                length: length
            )
        }
    }
}

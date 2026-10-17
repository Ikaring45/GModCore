import Foundation

public struct SourceStudioBoneMergeBone: Sendable, Equatable {
    public let name: String
    public let parent: Int
    public let flags: Int32

    public init(name: String, parent: Int, flags: Int32) {
        self.name = name
        self.parent = parent
        self.flags = flags
    }

    public init(_ bone: SourceStudioBone) {
        self.init(name: bone.name, parent: Int(bone.parent), flags: bone.flags)
    }
}

/// Followed matrices must already be in the same coordinate space as the
/// owner's root transform. No model-space/world-space guess is made here.
public struct SourceStudioBoneMergeInput: Sendable, Equatable {
    public let followedBones: [SourceStudioBoneMergeBone]
    public let followedTransforms: [SourceStudioMatrix3x4]
    public let boneMask: Int32

    public init(followedBones: [SourceStudioBoneMergeBone],
                followedTransforms: [SourceStudioMatrix3x4], boneMask: Int32) {
        self.followedBones = followedBones
        self.followedTransforms = followedTransforms
        self.boneMask = boneMask
    }
}

public enum SourceStudioBoneMergeError: Error, Sendable, Equatable {
    case transformCount(bones: Int, transforms: Int)
    case invalidParent(bone: Int, parent: Int)
    case invalidName(bone: Int)
    case duplicateName(String)
    case nonFiniteTransform(bone: Int)
}

/// Independent implementation of Source's named-bone follow contract.
/// See Valve's bone_merge_cache.cpp (MergeMatchingBones) and bone_setup.cpp
/// (Studio_BoneIndexByName). Masked matching owner bones copy the followed
/// transform; unmatched children are then built from their actual local pose.
/// This does not implement IK, procedural bones, or a failed SetupBones fallback.
public enum SourceStudioBoneMerge {
    public static func modelTransforms(
        ownerBones: [SourceStudioBoneMergeBone],
        ownerLocalTransforms: [SourceStudioMatrix3x4],
        following input: SourceStudioBoneMergeInput,
        ownerRootTransform: SourceStudioMatrix3x4 = .identity
    ) throws -> [SourceStudioMatrix3x4] {
        guard ownerBones.count == ownerLocalTransforms.count else {
            throw SourceStudioBoneMergeError.transformCount(bones: ownerBones.count, transforms: ownerLocalTransforms.count)
        }
        guard input.followedBones.count == input.followedTransforms.count else {
            throw SourceStudioBoneMergeError.transformCount(bones: input.followedBones.count, transforms: input.followedTransforms.count)
        }
        var followed: [String: Int] = [:]
        for (index, bone) in input.followedBones.enumerated() {
            let name = try key(bone.name, index: index)
            guard followed.updateValue(index, forKey: name) == nil else {
                throw SourceStudioBoneMergeError.duplicateName(bone.name)
            }
            try validate(input.followedTransforms[index], index: index)
        }
        try validate(ownerRootTransform, index: -1)
        var ownerNames: Set<String> = []
        var result: [SourceStudioMatrix3x4] = []
        result.reserveCapacity(ownerBones.count)
        for (index, bone) in ownerBones.enumerated() {
            let name = try key(bone.name, index: index)
            guard ownerNames.insert(name).inserted else { throw SourceStudioBoneMergeError.duplicateName(bone.name) }
            guard bone.parent >= -1, bone.parent < index else {
                throw SourceStudioBoneMergeError.invalidParent(bone: index, parent: bone.parent)
            }
            try validate(ownerLocalTransforms[index], index: index)
            let transform: SourceStudioMatrix3x4
            if bone.flags & input.boneMask != 0, let target = followed[name] {
                transform = input.followedTransforms[target]
            } else {
                let parent = bone.parent < 0 ? ownerRootTransform : result[bone.parent]
                transform = parent.concatenating(ownerLocalTransforms[index])
            }
            try validate(transform, index: index)
            result.append(transform)
        }
        return result
    }

    private static func key(_ name: String, index: Int) throws -> String {
        guard !name.isEmpty, !name.utf8.contains(0), name.utf8.allSatisfy({ $0 < 128 }) else {
            throw SourceStudioBoneMergeError.invalidName(bone: index)
        }
        // Q_stricmp-style ASCII matching, not locale-dependent case folding.
        return String(decoding: name.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }

    private static func validate(_ matrix: SourceStudioMatrix3x4, index: Int) throws {
        guard [matrix.m00, matrix.m01, matrix.m02, matrix.m03,
               matrix.m10, matrix.m11, matrix.m12, matrix.m13,
               matrix.m20, matrix.m21, matrix.m22, matrix.m23].allSatisfy(\.isFinite) else {
            throw SourceStudioBoneMergeError.nonFiniteTransform(bone: index)
        }
    }
}

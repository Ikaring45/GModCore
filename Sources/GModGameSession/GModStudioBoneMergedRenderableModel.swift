import GModEngine

/// A merged mesh is not identified by the owner's animation frame alone.
/// Parent appearance, sequence and frame also participate in GPU/cache identity.
public struct GModStudioBoneMergedRenderableModelResourceID: Sendable, Equatable, Hashable {
    public let owner: GModStudioAnimatedRenderableModelResourceID
    public let followed: GModStudioAnimatedRenderableModelResourceID
    public let boneMask: Int32
}

public struct GModStudioBoneMergedRenderableModelResource: Sendable, Equatable {
    public let id: GModStudioBoneMergedRenderableModelResourceID
    public let model: GModStudioAnimatedRenderableModelSnapshot
}

public struct GModStudioBoneMergeModelRequest: Sendable, Equatable {
    public let model: SourceEntityModelReference
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let lodIndex: Int
    public let selection: GModStudioAnimationFrameSelection

    public init(model: SourceEntityModelReference, bodyValue: Int, skinFamilyIndex: Int,
                lodIndex: Int = 0, selection: GModStudioAnimationFrameSelection) {
        self.model = model
        self.bodyValue = bodyValue
        self.skinFamilyIndex = skinFamilyIndex
        self.lodIndex = lodIndex
        self.selection = selection
    }
}

public enum GModStudioBoneMergedRenderableResolutionError: Error, Sendable, Equatable {
    case owner(GModStudioAnimatedRenderableModelResolutionFailure)
    case followed(GModStudioAnimatedRenderableModelResolutionFailure)
}

extension GModStudioPreparedAnimatedRenderableModel {
    /// Combines two decoded asset-backed models in their shared model space.
    /// The followed model only supplies a skeletal pose: it need not have any
    /// drawable geometry (e.g. a weapon's animation-driving base viewmodel).
    /// Both frame selections are explicit; no wall-clock or activity guess is
    /// introduced here. No existing cached frame or bind-pose array is mutated.
    public func snapshotFollowing(
        _ followed: GModStudioPreparedAnimatedRenderableModel,
        ownerSelection: GModStudioAnimationFrameSelection,
        followedSelection: GModStudioAnimationFrameSelection,
        boneMask: Int32
    ) throws -> GModStudioBoneMergedRenderableModelResource {
        let animationIndex = try followed.animationModel.animationIndex(
            sequenceIndex: followedSelection.sequenceIndex,
            blendIndex: followedSelection.blendIndex)
        let pose = try followed.animationModel.pose(animationIndex: animationIndex,
                                                     frame: followedSelection.frame)
        let merged = try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: renderable, sourceMesh: weightedMesh, studioModel: studioModel,
            animationModel: animationModel, sequenceIndex: ownerSelection.sequenceIndex,
            blendIndex: ownerSelection.blendIndex, frame: ownerSelection.frame,
            boneMerge: SourceStudioBoneMergeInput(
                followedBones: followed.studioModel.bones.map(SourceStudioBoneMergeBone.init),
                followedTransforms: pose.modelTransforms, boneMask: boneMask))
        return GModStudioBoneMergedRenderableModelResource(
            id: GModStudioBoneMergedRenderableModelResourceID(
                owner: resourceID(selection: ownerSelection, animationIndex: merged.animationIndex),
                followed: followed.resourceID(selection: followedSelection, animationIndex: animationIndex),
                boneMask: boneMask), model: merged)
    }

    private func resourceID(selection: GModStudioAnimationFrameSelection,
                            animationIndex: Int) -> GModStudioAnimatedRenderableModelResourceID {
        GModStudioAnimatedRenderableModelResourceID(
            normalizedModelPath: normalizedModelPath, checksum: checksum,
            lodIndex: lodIndex, bodyValue: bodyValue, skinFamilyIndex: skinFamilyIndex,
            sequenceIndex: selection.sequenceIndex, blendIndex: selection.blendIndex,
            animationIndex: animationIndex, frame: selection.frame)
    }
}

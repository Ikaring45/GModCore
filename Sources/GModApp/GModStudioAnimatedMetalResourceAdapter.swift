import Foundation
import GModGameSession
import GModMetal

enum GModStudioAnimatedMetalResourceAdapterError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case resourceIdentityMismatch(field: String)
    case bindPoseIdentityMismatch(field: String)
    case topologyMismatch(field: String)

    var description: String {
        switch self {
        case let .resourceIdentityMismatch(field):
            return "animated Studio resource mismatches snapshot \(field)"
        case let .bindPoseIdentityMismatch(field):
            return "animated Studio resource mismatches bind-pose \(field)"
        case let .topologyMismatch(field):
            return "animated Studio resource changes bind-pose \(field)"
        }
    }
}

/// Exact App boundary from the session-owned CPU-skinned resource to one
/// immutable Metal geometry publication. The bind-pose resource supplies only
/// already-resolved material outcomes; every vertex, index, and draw-range
/// identity comes from the authored animated snapshot after strict topology
/// agreement has been verified.
enum GModStudioAnimatedMetalResourceAdapter {
    static func resourceID(
        _ source: GModStudioAnimatedRenderableModelResource
    ) -> GModMetalDynamicEntityResourceID {
        GModMetalDynamicEntityResourceID(
            normalizedModelPath: source.id.normalizedModelPath,
            checksum: source.id.checksum,
            lodIndex: source.id.lodIndex,
            bodyValue: source.id.bodyValue,
            skinFamilyIndex: source.id.skinFamilyIndex,
            geometryIdentity: .animated(
                sequenceIndex: source.id.sequenceIndex,
                blendIndex: source.id.blendIndex,
                animationIndex: source.id.animationIndex,
                frame: source.id.frame
            )
        )
    }

    static func resourceInput(
        animated: GModStudioAnimatedRenderableModelResource,
        bindPose: GModStudioRenderableModelResource,
        resolvedBindPose: GModMetalDynamicEntityResourceInput
    ) throws -> GModMetalDynamicEntityResourceInput {
        try validate(animated: animated, bindPose: bindPose)

        let expectedBindPoseID = GModMetalDynamicEntityResourceID(
            normalizedModelPath: bindPose.id.normalizedModelPath,
            checksum: bindPose.id.checksum,
            lodIndex: bindPose.id.lodIndex,
            bodyValue: bindPose.id.bodyValue,
            skinFamilyIndex: bindPose.id.skinFamilyIndex
        )
        guard resolvedBindPose.id == expectedBindPoseID else {
            throw GModStudioAnimatedMetalResourceAdapterError
                .bindPoseIdentityMismatch(field: "resolved Metal identity")
        }
        let resolvedFields: [(String, Bool)] = [
            ("resolved checksum", resolvedBindPose.checksum == bindPose.model.checksum),
            ("resolved model name", resolvedBindPose.modelName == bindPose.model.modelName),
            ("resolved LOD", resolvedBindPose.lodIndex == bindPose.model.lodIndex),
            ("resolved body", resolvedBindPose.bodyValue == bindPose.model.bodyValue),
            (
                "resolved skin",
                resolvedBindPose.skinFamilyIndex ==
                    bindPose.model.skinFamilyIndex
            ),
            (
                "resolved vertex count",
                resolvedBindPose.vertices.count == bindPose.model.vertices.count
            ),
            ("resolved indices", resolvedBindPose.indices == bindPose.model.indices),
        ]
        if let invalid = resolvedFields.first(where: { !$0.1 }) {
            throw GModStudioAnimatedMetalResourceAdapterError
                .bindPoseIdentityMismatch(field: invalid.0)
        }
        guard animated.model.drawRanges.count ==
                resolvedBindPose.drawRanges.count else {
            throw GModStudioAnimatedMetalResourceAdapterError
                .topologyMismatch(field: "draw ranges")
        }
        for (source, resolved) in zip(
            bindPose.model.drawRanges,
            resolvedBindPose.drawRanges
        ) {
            let expectedMaterial = GModMetalDynamicEntityMaterialBinding(
                sourceMaterialIndex: source.material.sourceMaterialIndex,
                skinFamilyIndex: source.material.skinFamilyIndex,
                textureIndex: source.material.textureIndex,
                textureName: source.material.textureName,
                vmtCandidates: source.material.vmtCandidates
            )
            guard resolved.bodyPartIndex == source.bodyPartIndex,
                  resolved.submodelIndex == source.submodelIndex,
                  resolved.meshIndex == source.meshIndex,
                  resolved.firstIndex == source.firstIndex,
                  resolved.indexCount == source.indexCount,
                  resolved.material == expectedMaterial else {
                throw GModStudioAnimatedMetalResourceAdapterError
                    .bindPoseIdentityMismatch(
                        field: "resolved draw-range topology"
                    )
            }
        }

        let vertices = animated.model.vertices.map {
            GModMetalDynamicEntitySourceVertex(
                position: $0.position,
                normal: $0.normal,
                textureCoordinate: SIMD2<Float>(
                    $0.textureCoordinate.u,
                    $0.textureCoordinate.v
                )
            )
        }
        let drawRanges = zip(
            animated.model.drawRanges,
            resolvedBindPose.drawRanges
        ).map { source, resolved in
            GModMetalDynamicEntityDrawRange(
                bodyPartIndex: source.bodyPartIndex,
                submodelIndex: source.submodelIndex,
                meshIndex: source.meshIndex,
                firstIndex: source.firstIndex,
                indexCount: source.indexCount,
                material: GModMetalDynamicEntityMaterialBinding(
                    sourceMaterialIndex: source.material.sourceMaterialIndex,
                    skinFamilyIndex: source.material.skinFamilyIndex,
                    textureIndex: source.material.textureIndex,
                    textureName: source.material.textureName,
                    vmtCandidates: source.material.vmtCandidates
                ),
                materialResolution: resolved.materialResolution,
                usesPlayerWeaponColor: resolved.usesPlayerWeaponColor
            )
        }
        return GModMetalDynamicEntityResourceInput(
            id: resourceID(animated),
            checksum: animated.model.checksum,
            modelName: animated.model.modelName,
            lodIndex: animated.model.lodIndex,
            bodyValue: animated.model.bodyValue,
            skinFamilyIndex: animated.model.skinFamilyIndex,
            vertices: vertices,
            indices: animated.model.indices,
            drawRanges: drawRanges
        )
    }

    static func validate(
        animated: GModStudioAnimatedRenderableModelResource,
        bindPose: GModStudioRenderableModelResource
    ) throws {
        try validateResourceIdentity(animated)
        try validateBindPoseIdentity(animated, bindPose: bindPose)
        guard animated.model.vertices.count == bindPose.model.vertices.count else {
            throw GModStudioAnimatedMetalResourceAdapterError
                .topologyMismatch(field: "vertex count")
        }
        guard zip(animated.model.vertices, bindPose.model.vertices).allSatisfy({
            $0.textureCoordinate == $1.textureCoordinate
        }) else {
            throw GModStudioAnimatedMetalResourceAdapterError
                .topologyMismatch(field: "texture coordinates")
        }
        guard animated.model.indices == bindPose.model.indices else {
            throw GModStudioAnimatedMetalResourceAdapterError
                .topologyMismatch(field: "indices")
        }
        guard animated.model.drawRanges == bindPose.model.drawRanges else {
            throw GModStudioAnimatedMetalResourceAdapterError
                .topologyMismatch(field: "draw ranges")
        }
    }
}

private extension GModStudioAnimatedMetalResourceAdapter {
    static func validateResourceIdentity(
        _ source: GModStudioAnimatedRenderableModelResource
    ) throws {
        let id = source.id
        let model = source.model
        let fields: [(String, Bool)] = [
            ("checksum", id.checksum == model.checksum),
            ("LOD", id.lodIndex == model.lodIndex),
            ("body", id.bodyValue == model.bodyValue),
            ("skin", id.skinFamilyIndex == model.skinFamilyIndex),
            ("sequence", id.sequenceIndex == model.sequenceIndex),
            ("blend", id.blendIndex == model.blendIndex),
            ("animation", id.animationIndex == model.animationIndex),
            ("frame", id.frame == model.frame),
        ]
        if let invalid = fields.first(where: { !$0.1 }) {
            throw GModStudioAnimatedMetalResourceAdapterError
                .resourceIdentityMismatch(field: invalid.0)
        }
    }

    static func validateBindPoseIdentity(
        _ animated: GModStudioAnimatedRenderableModelResource,
        bindPose: GModStudioRenderableModelResource
    ) throws {
        let fields: [(String, Bool)] = [
            (
                "normalized model path",
                animated.id.normalizedModelPath ==
                    bindPose.id.normalizedModelPath
            ),
            ("checksum", animated.model.checksum == bindPose.model.checksum),
            ("model name", animated.model.modelName == bindPose.model.modelName),
            ("LOD", animated.model.lodIndex == bindPose.model.lodIndex),
            ("body", animated.model.bodyValue == bindPose.model.bodyValue),
            (
                "skin",
                animated.model.skinFamilyIndex ==
                    bindPose.model.skinFamilyIndex
            ),
        ]
        if let invalid = fields.first(where: { !$0.1 }) {
            throw GModStudioAnimatedMetalResourceAdapterError
                .bindPoseIdentityMismatch(field: invalid.0)
        }
    }
}

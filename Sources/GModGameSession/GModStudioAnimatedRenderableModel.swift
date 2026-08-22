import Foundation
import GModEngine

/// A CPU-skinned Studio vertex. Tangent xyz is the skinned tangent-S direction;
/// w remains Source's authored binormal handedness sign.
public struct GModStudioAnimatedRenderableVertex: Sendable, Equatable {
    public let position: SourceVector3
    public let normal: SourceVector3
    public let textureCoordinate: SourceStudioTextureCoordinate
    public let tangent: SourceStudioTangent?

    public init(
        position: SourceVector3,
        normal: SourceVector3,
        textureCoordinate: SourceStudioTextureCoordinate,
        tangent: SourceStudioTangent?
    ) {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
        self.tangent = tangent
    }
}

/// Immutable renderer handoff for one explicitly selected Source sequence
/// table entry and integer animation frame.
public struct GModStudioAnimatedRenderableModelSnapshot: Sendable, Equatable {
    public let checksum: Int32
    public let modelName: String
    public let lodIndex: Int
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let sequenceIndex: Int
    public let blendIndex: Int
    public let animationIndex: Int
    public let frame: Int
    public let boneModelTransforms: [SourceStudioMatrix3x4]
    public let vertices: [GModStudioAnimatedRenderableVertex]
    public let indices: [UInt32]
    public let drawRanges: [GModStudioRenderableDrawRange]
}

public enum GModStudioAnimatedRenderableInput: String, Sendable, Equatable {
    case sourceMesh
    case studioModel
    case animationModel
}

public enum GModStudioAnimatedRenderableDirection: String, Sendable, Equatable {
    case normal
    case tangent
}

public enum GModStudioAnimatedRenderableModelError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case animation(SourceStudioAnimationError)
    case checksumMismatch(
        input: GModStudioAnimatedRenderableInput,
        expected: Int32,
        actual: Int32
    )
    case modelNameMismatch(
        input: GModStudioAnimatedRenderableInput,
        expected: String,
        actual: String
    )
    case lodMismatch(expected: Int, actual: Int)
    case invalidBodyValue(Int)
    case invalidBodyPartBase(bodyPart: Int, base: Int32, modelCount: Int)
    case boneCountMismatch(studio: Int, animation: Int)
    case boneIdentityMismatch(bone: Int)
    case vertexCountMismatch(renderable: Int, source: Int)
    case vertexOrderMismatch(vertex: Int)
    case invalidRenderableIndex(index: Int, value: UInt32, vertexCount: Int)
    case invalidBoneInfluence(
        vertex: Int,
        influence: Int,
        bone: Int,
        boneCount: Int
    )
    case invalidBoneWeight(vertex: Int, influence: Int, value: Float)
    case nonFiniteSkinnedPosition(vertex: Int)
    case invalidSkinnedDirection(
        vertex: Int,
        direction: GModStudioAnimatedRenderableDirection
    )

    public var description: String {
        switch self {
        case let .animation(error):
            return "Studio animation evaluation failed: \(error)"
        case let .checksumMismatch(input, expected, actual):
            return "animated Studio \(input.rawValue) checksum \(actual) does not match \(expected)"
        case let .modelNameMismatch(input, expected, actual):
            return "animated Studio \(input.rawValue) model '\(actual)' does not match '\(expected)'"
        case let .lodMismatch(expected, actual):
            return "animated Studio mesh LOD \(actual) does not match renderable LOD \(expected)"
        case let .invalidBodyValue(value):
            return "invalid animated Studio body value \(value)"
        case let .invalidBodyPartBase(bodyPart, base, modelCount):
            return "animated Studio body part \(bodyPart) base \(base) is invalid for \(modelCount) models"
        case let .boneCountMismatch(studio, animation):
            return "Studio model has \(studio) bones but animation skeleton has \(animation)"
        case let .boneIdentityMismatch(bone):
            return "Studio model and animation skeleton disagree at bone \(bone)"
        case let .vertexCountMismatch(renderable, source):
            return "renderable has \(renderable) vertices but selected weighted source geometry has \(source)"
        case let .vertexOrderMismatch(vertex):
            return "renderable vertex \(vertex) no longer matches selected Studio source order"
        case let .invalidRenderableIndex(index, value, vertexCount):
            return "renderable index \(index) references \(value), outside 0..<\(vertexCount)"
        case let .invalidBoneInfluence(vertex, influence, bone, boneCount):
            return "vertex \(vertex) influence \(influence) references bone \(bone), outside 0..<\(boneCount)"
        case let .invalidBoneWeight(vertex, influence, value):
            return "vertex \(vertex) influence \(influence) has invalid weight \(value)"
        case let .nonFiniteSkinnedPosition(vertex):
            return "vertex \(vertex) produced a non-finite skinned position"
        case let .invalidSkinnedDirection(vertex, direction):
            return "vertex \(vertex) produced a non-finite or zero-length skinned \(direction.rawValue)"
        }
    }
}

/// Renderer-neutral CPU skinning boundary for Source Studio geometry.
///
/// `animatedBoneToModel * mstudiobone_t.poseToBone` builds the same model-space
/// skin matrix consumed by Source's model path. The VVD's canonical bone
/// indices and weights drive linear matrix blending; VTX palette IDs remain an
/// optimization detail and are not reinterpreted as Studio bone indices.
/// Position uses the affine 3x4 matrix, while normal and tangent use its 3x3
/// portion and are normalized after blending, matching Source's model shaders.
public enum GModStudioAnimatedRenderableModelCompiler {
    public static func compile(
        renderable: GModStudioRenderableModelSnapshot,
        sourceMesh: SourceStudioModelMeshSnapshot,
        studioModel: SourceStudioModel,
        animationModel: SourceStudioAnimationModel,
        sequenceIndex: Int,
        blendIndex: Int,
        frame: Int
    ) throws -> GModStudioAnimatedRenderableModelSnapshot {
        try validateIdentity(
            renderable: renderable,
            sourceMesh: sourceMesh,
            studioModel: studioModel,
            animationModel: animationModel
        )

        let animationIndex: Int
        let pose: SourceStudioAnimationPose
        do {
            animationIndex = try animationModel.animationIndex(
                sequenceIndex: sequenceIndex,
                blendIndex: blendIndex
            )
            pose = try animationModel.pose(
                animationIndex: animationIndex,
                frame: frame
            )
        } catch let error as SourceStudioAnimationError {
            throw GModStudioAnimatedRenderableModelError.animation(error)
        }

        guard studioModel.bones.count == pose.bones.count else {
            throw GModStudioAnimatedRenderableModelError.boneCountMismatch(
                studio: studioModel.bones.count,
                animation: pose.bones.count
            )
        }
        let skinMatrices = zip(pose.bones, studioModel.bones).map { pair in
            pair.0.modelTransform.concatenating(pair.1.poseToBone)
        }

        let selectedVertices = try selectedSourceVertices(
            sourceMesh,
            bodyValue: renderable.bodyValue
        )
        guard renderable.vertices.count == selectedVertices.count else {
            throw GModStudioAnimatedRenderableModelError.vertexCountMismatch(
                renderable: renderable.vertices.count,
                source: selectedVertices.count
            )
        }

        var skinnedVertices: [GModStudioAnimatedRenderableVertex] = []
        skinnedVertices.reserveCapacity(selectedVertices.count)
        for (index, source) in selectedVertices.enumerated() {
            let bindVertex = renderable.vertices[index]
            guard bindVertex.position == source.position,
                  bindVertex.normal == source.normal,
                  bindVertex.textureCoordinate == source.textureCoordinate else {
                throw GModStudioAnimatedRenderableModelError.vertexOrderMismatch(
                    vertex: index
                )
            }
            skinnedVertices.append(
                try skin(
                    source,
                    vertexIndex: index,
                    matrices: skinMatrices
                )
            )
        }

        for (index, value) in renderable.indices.enumerated() {
            guard Int(value) < skinnedVertices.count else {
                throw GModStudioAnimatedRenderableModelError.invalidRenderableIndex(
                    index: index,
                    value: value,
                    vertexCount: skinnedVertices.count
                )
            }
        }

        return GModStudioAnimatedRenderableModelSnapshot(
            checksum: renderable.checksum,
            modelName: renderable.modelName,
            lodIndex: renderable.lodIndex,
            bodyValue: renderable.bodyValue,
            skinFamilyIndex: renderable.skinFamilyIndex,
            sequenceIndex: sequenceIndex,
            blendIndex: blendIndex,
            animationIndex: animationIndex,
            frame: frame,
            boneModelTransforms: pose.modelTransforms,
            vertices: skinnedVertices,
            indices: renderable.indices,
            drawRanges: renderable.drawRanges
        )
    }
}

private extension GModStudioAnimatedRenderableModelCompiler {
    static func validateIdentity(
        renderable: GModStudioRenderableModelSnapshot,
        sourceMesh: SourceStudioModelMeshSnapshot,
        studioModel: SourceStudioModel,
        animationModel: SourceStudioAnimationModel
    ) throws {
        guard sourceMesh.checksum == renderable.checksum else {
            throw GModStudioAnimatedRenderableModelError.checksumMismatch(
                input: .sourceMesh,
                expected: renderable.checksum,
                actual: sourceMesh.checksum
            )
        }
        guard sourceMesh.modelName == renderable.modelName else {
            throw GModStudioAnimatedRenderableModelError.modelNameMismatch(
                input: .sourceMesh,
                expected: renderable.modelName,
                actual: sourceMesh.modelName
            )
        }
        guard sourceMesh.lodIndex == renderable.lodIndex else {
            throw GModStudioAnimatedRenderableModelError.lodMismatch(
                expected: renderable.lodIndex,
                actual: sourceMesh.lodIndex
            )
        }
        guard studioModel.header.checksum == renderable.checksum else {
            throw GModStudioAnimatedRenderableModelError.checksumMismatch(
                input: .studioModel,
                expected: renderable.checksum,
                actual: studioModel.header.checksum
            )
        }
        guard studioModel.header.name == renderable.modelName else {
            throw GModStudioAnimatedRenderableModelError.modelNameMismatch(
                input: .studioModel,
                expected: renderable.modelName,
                actual: studioModel.header.name
            )
        }
        guard animationModel.header.checksum == renderable.checksum else {
            throw GModStudioAnimatedRenderableModelError.checksumMismatch(
                input: .animationModel,
                expected: renderable.checksum,
                actual: animationModel.header.checksum
            )
        }
        guard animationModel.header.name == renderable.modelName else {
            throw GModStudioAnimatedRenderableModelError.modelNameMismatch(
                input: .animationModel,
                expected: renderable.modelName,
                actual: animationModel.header.name
            )
        }
        guard studioModel.bones.count == animationModel.skeleton.bones.count else {
            throw GModStudioAnimatedRenderableModelError.boneCountMismatch(
                studio: studioModel.bones.count,
                animation: animationModel.skeleton.bones.count
            )
        }
        for index in studioModel.bones.indices {
            let studio = studioModel.bones[index]
            let animation = animationModel.skeleton.bones[index]
            let studioParent = studio.parent >= 0 ? Int(studio.parent) : nil
            guard studio.name == animation.name,
                  studioParent == animation.parentIndex else {
                throw GModStudioAnimatedRenderableModelError.boneIdentityMismatch(
                    bone: index
                )
            }
        }
    }

    static func selectedSourceVertices(
        _ source: SourceStudioModelMeshSnapshot,
        bodyValue: Int
    ) throws -> [SourceStudioMeshVertexSnapshot] {
        guard bodyValue >= 0 else {
            throw GModStudioAnimatedRenderableModelError.invalidBodyValue(bodyValue)
        }
        var vertices: [SourceStudioMeshVertexSnapshot] = []
        for bodyPart in source.bodyParts {
            guard !bodyPart.models.isEmpty else { continue }
            let selectedModelIndex: Int
            if bodyPart.models.count == 1 {
                selectedModelIndex = 0
            } else {
                let base = Int(bodyPart.modelSelectionBase)
                guard base > 0 else {
                    throw GModStudioAnimatedRenderableModelError.invalidBodyPartBase(
                        bodyPart: bodyPart.index,
                        base: bodyPart.modelSelectionBase,
                        modelCount: bodyPart.models.count
                    )
                }
                selectedModelIndex = (bodyValue / base) % bodyPart.models.count
            }
            let submodel = bodyPart.models[selectedModelIndex]
            for mesh in submodel.meshes {
                for group in mesh.stripGroups {
                    vertices.append(contentsOf: group.vertices)
                }
            }
        }
        return vertices
    }

    static func skin(
        _ source: SourceStudioMeshVertexSnapshot,
        vertexIndex: Int,
        matrices: [SourceStudioMatrix3x4]
    ) throws -> GModStudioAnimatedRenderableVertex {
        guard !source.boneInfluences.isEmpty else {
            return GModStudioAnimatedRenderableVertex(
                position: source.position,
                normal: source.normal,
                textureCoordinate: source.textureCoordinate,
                tangent: source.tangent
            )
        }

        var position = SourceVector3.zero
        var normal = SourceVector3.zero
        var tangent = SourceVector3.zero
        for (influenceIndex, influence) in source.boneInfluences.enumerated() {
            guard matrices.indices.contains(influence.boneIndex) else {
                throw GModStudioAnimatedRenderableModelError.invalidBoneInfluence(
                    vertex: vertexIndex,
                    influence: influenceIndex,
                    bone: influence.boneIndex,
                    boneCount: matrices.count
                )
            }
            guard influence.weight.isFinite, influence.weight >= 0 else {
                throw GModStudioAnimatedRenderableModelError.invalidBoneWeight(
                    vertex: vertexIndex,
                    influence: influenceIndex,
                    value: influence.weight
                )
            }
            let matrix = matrices[influence.boneIndex]
            position += matrix.transformPoint(source.position) * influence.weight
            normal += transformDirection(source.normal, by: matrix) * influence.weight
            if let sourceTangent = source.tangent {
                tangent += transformDirection(
                    SourceVector3(sourceTangent.x, sourceTangent.y, sourceTangent.z),
                    by: matrix
                ) * influence.weight
            }
        }

        guard isFinite(position) else {
            throw GModStudioAnimatedRenderableModelError.nonFiniteSkinnedPosition(
                vertex: vertexIndex
            )
        }
        let normalizedNormal = try normalized(
            normal,
            vertexIndex: vertexIndex,
            direction: .normal
        )
        let skinnedTangent: SourceStudioTangent?
        if let sourceTangent = source.tangent {
            let normalizedTangent = try normalized(
                tangent,
                vertexIndex: vertexIndex,
                direction: .tangent
            )
            skinnedTangent = SourceStudioTangent(
                x: normalizedTangent.x,
                y: normalizedTangent.y,
                z: normalizedTangent.z,
                w: sourceTangent.w
            )
        } else {
            skinnedTangent = nil
        }

        return GModStudioAnimatedRenderableVertex(
            position: position,
            normal: normalizedNormal,
            textureCoordinate: source.textureCoordinate,
            tangent: skinnedTangent
        )
    }

    static func transformDirection(
        _ vector: SourceVector3,
        by matrix: SourceStudioMatrix3x4
    ) -> SourceVector3 {
        SourceVector3(
            matrix.m00 * vector.x + matrix.m01 * vector.y + matrix.m02 * vector.z,
            matrix.m10 * vector.x + matrix.m11 * vector.y + matrix.m12 * vector.z,
            matrix.m20 * vector.x + matrix.m21 * vector.y + matrix.m22 * vector.z
        )
    }

    static func normalized(
        _ vector: SourceVector3,
        vertexIndex: Int,
        direction: GModStudioAnimatedRenderableDirection
    ) throws -> SourceVector3 {
        guard isFinite(vector), vector.lengthSquared > 0 else {
            throw GModStudioAnimatedRenderableModelError.invalidSkinnedDirection(
                vertex: vertexIndex,
                direction: direction
            )
        }
        let length = vector.length
        guard length.isFinite, length > 0 else {
            throw GModStudioAnimatedRenderableModelError.invalidSkinnedDirection(
                vertex: vertexIndex,
                direction: direction
            )
        }
        return vector / length
    }

    static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}

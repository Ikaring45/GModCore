import Foundation
import GModEngine

/// Explicit host allocation guards for compiling one Studio prop into a
/// renderer-neutral snapshot. These values are deployment policy, not Source
/// format limits or measured physical-iPad performance claims.
public struct GModStudioRenderableModelCompilePolicy: Sendable, Equatable {
    public let meshDecodeBudget: SourceStudioMeshDecodeBudget
    public let materialDecodeBudget: SourceStudioModelMaterialDecodeBudget
    public let dynamicMeshBuildPolicy: GModDynamicModelMeshBuildPolicy

    public init(
        meshDecodeBudget: SourceStudioMeshDecodeBudget,
        materialDecodeBudget: SourceStudioModelMaterialDecodeBudget,
        dynamicMeshBuildPolicy: GModDynamicModelMeshBuildPolicy
    ) {
        self.meshDecodeBudget = meshDecodeBudget
        self.materialDecodeBudget = materialDecodeBudget
        self.dynamicMeshBuildPolicy = dynamicMeshBuildPolicy
    }

    /// Initial iPad host allocation guard. Every component remains injectable;
    /// these caps must be tuned from real-device measurements rather than
    /// reinterpreted as compatibility maxima.
    public static let initialIpadProp = GModStudioRenderableModelCompilePolicy(
        meshDecodeBudget: SourceStudioMeshDecodeBudget(
            maximumRootVertices: 65_536,
            maximumBodyParts: 1_024,
            maximumModels: 4_096,
            maximumMeshes: 16_384,
            maximumStripGroups: 65_536,
            maximumDecodedVertices: 262_144,
            maximumIndices: 1_572_864,
            maximumStrips: 262_144,
            maximumBoneStateChanges: 1_572_864
        ),
        materialDecodeBudget: SourceStudioModelMaterialDecodeBudget(
            maximumTextures: 4_096,
            maximumCDTextureDirectories: 256,
            maximumSkinReferences: 4_096,
            maximumSkinFamilies: 256,
            maximumSkinEntries: 262_144,
            maximumStringBytes: 4_096,
            maximumTotalStringBytes: 1_048_576,
            maximumResolvedCandidateBytes: 1_048_576
        ),
        dynamicMeshBuildPolicy: .initialIpadProp
    )
}

public struct GModStudioRenderableMaterial: Sendable, Equatable {
    public let sourceMaterialIndex: Int32
    public let skinFamilyIndex: Int
    public let textureIndex: Int
    public let textureName: String
    /// Ordered logical VMT paths. Existence and VMT/VTF decoding are later
    /// filesystem stages and are not claimed by this snapshot.
    public let vmtCandidates: [String]
}

public struct GModStudioRenderableDrawRange: Sendable, Equatable {
    public let bodyPartIndex: Int
    public let submodelIndex: Int
    public let meshIndex: Int
    public let firstIndex: Int
    public let indexCount: Int
    public let material: GModStudioRenderableMaterial
}

/// Complete immutable handoff for a bind-pose Studio prop. No decoded Source
/// hierarchy or material table is published separately if any later stage
/// fails.
public struct GModStudioRenderableModelSnapshot: Sendable, Equatable {
    public let checksum: Int32
    public let modelName: String
    public let lodIndex: Int
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let vertices: [GModDynamicModelVertex]
    public let indices: [UInt32]
    public let drawRanges: [GModStudioRenderableDrawRange]
}

public enum GModStudioRenderableModelCompileStage: String, Sendable, Equatable {
    case meshDecode
    case materialDecode
    case dynamicMeshBuild
    case materialResolution
}

public enum GModStudioRenderableModelCompileError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case unsupportedMesh(SourceStudioMeshUnsupportedFeature)
    case meshDecode(SourceStudioModelMeshDecodeError)
    case materialDecode(SourceStudioModelMaterialDecodeError)
    case dynamicMeshBuild(GModDynamicModelMeshBuildError)
    case materialResolution(
        drawRangeIndex: Int,
        error: SourceStudioModelMaterialDecodeError
    )
    case noVMTCandidates(drawRangeIndex: Int, textureIndex: Int, textureName: String)
    case inconsistentChecksum(stage: GModStudioRenderableModelCompileStage,
                              expected: Int32, actual: Int32)
    case inconsistentModelName(stage: GModStudioRenderableModelCompileStage,
                               expected: String, actual: String)
    case unexpected(stage: GModStudioRenderableModelCompileStage, type: String)

    public var description: String {
        switch self {
        case let .unsupportedMesh(feature):
            return "unsupported Studio renderable mesh feature: \(feature)"
        case let .meshDecode(error):
            return "Studio renderable mesh decode failed: \(error)"
        case let .materialDecode(error):
            return "Studio renderable material decode failed: \(error)"
        case let .dynamicMeshBuild(error):
            return "Studio renderable dynamic mesh build failed: \(error)"
        case let .materialResolution(index, error):
            return "Studio draw range \(index) material resolution failed: \(error)"
        case let .noVMTCandidates(index, textureIndex, textureName):
            return "Studio draw range \(index) texture \(textureIndex) '\(textureName)' has no VMT candidate"
        case let .inconsistentChecksum(stage, expected, actual):
            return "Studio renderable \(stage.rawValue) checksum \(actual) does not match \(expected)"
        case let .inconsistentModelName(stage, expected, actual):
            return "Studio renderable \(stage.rawValue) model '\(actual)' does not match '\(expected)'"
        case let .unexpected(stage, type):
            return "Studio renderable \(stage.rawValue) failed with unexpected \(type)"
        }
    }
}

/// Transactionally compiles an already validated Studio asset into the single
/// value accepted by a later material/filesystem/Metal integration boundary.
public enum GModStudioRenderableModelCompiler {
    public static func compile(
        asset: SourceStudioModelAsset,
        bodyValue: Int,
        skinFamilyIndex: Int,
        policy: GModStudioRenderableModelCompilePolicy
    ) throws -> GModStudioRenderableModelSnapshot {
        let mesh = try decodeMesh(asset: asset, budget: policy.meshDecodeBudget)
        try requireIdentity(
            expectedChecksum: asset.validation.checksum,
            expectedName: asset.renderPayload.model.header.name,
            checksum: mesh.checksum,
            name: mesh.modelName,
            stage: .meshDecode
        )

        let materials = try decodeMaterials(
            asset: asset,
            budget: policy.materialDecodeBudget
        )
        try requireIdentity(
            expectedChecksum: asset.validation.checksum,
            expectedName: mesh.modelName,
            checksum: materials.checksum,
            name: materials.modelName,
            stage: .materialDecode
        )

        let dynamicMesh = try buildDynamicMesh(
            mesh,
            bodyValue: bodyValue,
            policy: policy.dynamicMeshBuildPolicy
        )
        try requireIdentity(
            expectedChecksum: asset.validation.checksum,
            expectedName: mesh.modelName,
            checksum: dynamicMesh.checksum,
            name: dynamicMesh.modelName,
            stage: .dynamicMeshBuild
        )

        var materialCache: [Int32: GModStudioRenderableMaterial] = [:]
        var drawRanges: [GModStudioRenderableDrawRange] = []
        drawRanges.reserveCapacity(dynamicMesh.ranges.count)
        for (rangeIndex, range) in dynamicMesh.ranges.enumerated() {
            let material: GModStudioRenderableMaterial
            if let cached = materialCache[range.materialIndex] {
                material = cached
            } else {
                let resolved = try resolveMaterial(
                    materials,
                    materialIndex: range.materialIndex,
                    skinFamilyIndex: skinFamilyIndex,
                    drawRangeIndex: rangeIndex
                )
                guard !resolved.cdTextureCandidates.isEmpty else {
                    throw GModStudioRenderableModelCompileError.noVMTCandidates(
                        drawRangeIndex: rangeIndex,
                        textureIndex: resolved.textureIndex,
                        textureName: resolved.textureName
                    )
                }
                material = GModStudioRenderableMaterial(
                    sourceMaterialIndex: range.materialIndex,
                    skinFamilyIndex: skinFamilyIndex,
                    textureIndex: resolved.textureIndex,
                    textureName: resolved.textureName,
                    vmtCandidates: resolved.cdTextureCandidates
                )
                materialCache[range.materialIndex] = material
            }
            drawRanges.append(GModStudioRenderableDrawRange(
                bodyPartIndex: range.bodyPartIndex,
                submodelIndex: range.submodelIndex,
                meshIndex: range.meshIndex,
                firstIndex: range.firstIndex,
                indexCount: range.indexCount,
                material: material
            ))
        }

        return GModStudioRenderableModelSnapshot(
            checksum: dynamicMesh.checksum,
            modelName: dynamicMesh.modelName,
            lodIndex: mesh.lodIndex,
            bodyValue: dynamicMesh.bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            vertices: dynamicMesh.vertices,
            indices: dynamicMesh.indices,
            drawRanges: drawRanges
        )
    }
}

private extension GModStudioRenderableModelCompiler {
    static func decodeMesh(
        asset: SourceStudioModelAsset,
        budget: SourceStudioMeshDecodeBudget
    ) throws -> SourceStudioModelMeshSnapshot {
        do {
            return try SourceStudioModelMeshDecoder.decodeRootLOD(
                asset.renderPayload,
                budget: budget
            )
        } catch let error as SourceStudioModelMeshDecodeError {
            if case let .unsupported(feature) = error {
                throw GModStudioRenderableModelCompileError.unsupportedMesh(feature)
            }
            throw GModStudioRenderableModelCompileError.meshDecode(error)
        } catch {
            throw GModStudioRenderableModelCompileError.unexpected(
                stage: .meshDecode,
                type: String(reflecting: type(of: error))
            )
        }
    }

    static func decodeMaterials(
        asset: SourceStudioModelAsset,
        budget: SourceStudioModelMaterialDecodeBudget
    ) throws -> SourceStudioModelMaterialTableSnapshot {
        do {
            return try SourceStudioModelMaterialDecoder.decode(
                asset.renderPayload,
                budget: budget
            )
        } catch let error as SourceStudioModelMaterialDecodeError {
            throw GModStudioRenderableModelCompileError.materialDecode(error)
        } catch {
            throw GModStudioRenderableModelCompileError.unexpected(
                stage: .materialDecode,
                type: String(reflecting: type(of: error))
            )
        }
    }

    static func buildDynamicMesh(
        _ mesh: SourceStudioModelMeshSnapshot,
        bodyValue: Int,
        policy: GModDynamicModelMeshBuildPolicy
    ) throws -> GModDynamicModelMesh {
        do {
            return try GModDynamicModelMeshBuilder.build(
                from: mesh,
                bodyValue: bodyValue,
                policy: policy
            )
        } catch let error as GModDynamicModelMeshBuildError {
            throw GModStudioRenderableModelCompileError.dynamicMeshBuild(error)
        } catch {
            throw GModStudioRenderableModelCompileError.unexpected(
                stage: .dynamicMeshBuild,
                type: String(reflecting: type(of: error))
            )
        }
    }

    static func resolveMaterial(
        _ materials: SourceStudioModelMaterialTableSnapshot,
        materialIndex: Int32,
        skinFamilyIndex: Int,
        drawRangeIndex: Int
    ) throws -> SourceStudioResolvedModelMaterialSnapshot {
        do {
            return try materials.resolve(
                meshMaterialIndex: materialIndex,
                skinFamilyIndex: skinFamilyIndex
            )
        } catch let error as SourceStudioModelMaterialDecodeError {
            throw GModStudioRenderableModelCompileError.materialResolution(
                drawRangeIndex: drawRangeIndex,
                error: error
            )
        } catch {
            throw GModStudioRenderableModelCompileError.unexpected(
                stage: .materialResolution,
                type: String(reflecting: type(of: error))
            )
        }
    }

    static func requireIdentity(
        expectedChecksum: Int32,
        expectedName: String,
        checksum: Int32,
        name: String,
        stage: GModStudioRenderableModelCompileStage
    ) throws {
        guard checksum == expectedChecksum else {
            throw GModStudioRenderableModelCompileError.inconsistentChecksum(
                stage: stage,
                expected: expectedChecksum,
                actual: checksum
            )
        }
        guard name == expectedName else {
            throw GModStudioRenderableModelCompileError.inconsistentModelName(
                stage: stage,
                expected: expectedName,
                actual: name
            )
        }
    }
}

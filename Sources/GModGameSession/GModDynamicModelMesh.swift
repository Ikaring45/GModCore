import Foundation
import GModEngine

public struct GModDynamicModelMeshBuildPolicy: Sendable, Equatable {
    public let maximumVertices: Int
    public let maximumIndices: Int

    public init(maximumVertices: Int, maximumIndices: Int) {
        self.maximumVertices = maximumVertices
        self.maximumIndices = maximumIndices
    }

    public static let initialIpadProp = GModDynamicModelMeshBuildPolicy(
        maximumVertices: 262_144,
        maximumIndices: 1_572_864
    )
}

public struct GModDynamicModelVertex: Sendable, Equatable {
    public let position: SourceVector3
    public let normal: SourceVector3
    public let textureCoordinate: SourceStudioTextureCoordinate

    public init(
        position: SourceVector3,
        normal: SourceVector3,
        textureCoordinate: SourceStudioTextureCoordinate
    ) {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
    }
}

public struct GModDynamicModelDrawRange: Sendable, Equatable {
    public let bodyPartIndex: Int
    public let submodelIndex: Int
    public let meshIndex: Int
    public let materialIndex: Int32
    public let firstIndex: Int
    public let indexCount: Int

    public init(
        bodyPartIndex: Int,
        submodelIndex: Int,
        meshIndex: Int,
        materialIndex: Int32,
        firstIndex: Int,
        indexCount: Int
    ) {
        self.bodyPartIndex = bodyPartIndex
        self.submodelIndex = submodelIndex
        self.meshIndex = meshIndex
        self.materialIndex = materialIndex
        self.firstIndex = firstIndex
        self.indexCount = indexCount
    }
}

/// Flat, renderer-neutral bind-pose geometry for one Source Studio model.
/// Animation and bodygroup mutation remain separate Source-owned stages.
public struct GModDynamicModelMesh: Sendable, Equatable {
    public let checksum: Int32
    public let modelName: String
    public let bodyValue: Int
    public let vertices: [GModDynamicModelVertex]
    public let indices: [UInt32]
    public let ranges: [GModDynamicModelDrawRange]

    public init(
        checksum: Int32,
        modelName: String,
        bodyValue: Int,
        vertices: [GModDynamicModelVertex],
        indices: [UInt32],
        ranges: [GModDynamicModelDrawRange]
    ) {
        self.checksum = checksum
        self.modelName = modelName
        self.bodyValue = bodyValue
        self.vertices = vertices
        self.indices = indices
        self.ranges = ranges
    }
}

public enum GModDynamicModelMeshBuildError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidPolicy(vertices: Int, indices: Int)
    case invalidBodyValue(Int)
    case invalidBodyPartBase(bodyPart: Int, base: Int32, modelCount: Int)
    case vertexBudgetExceeded(requested: Int, cap: Int)
    case indexBudgetExceeded(requested: Int, cap: Int)
    case invalidIndexRange(offset: Int, count: Int, available: Int)
    case invalidVertexIndex(value: Int, available: Int)
    case triangleListIndexCount(Int)
    case uint32VertexIndexOverflow(Int)

    public var description: String {
        switch self {
        case let .invalidPolicy(vertices, indices):
            return "invalid dynamic model policy vertices=\(vertices) indices=\(indices)"
        case let .invalidBodyValue(value):
            return "invalid Source body value \(value)"
        case let .invalidBodyPartBase(bodyPart, base, modelCount):
            return "body part \(bodyPart) base \(base) is invalid for \(modelCount) models"
        case let .vertexBudgetExceeded(requested, cap):
            return "dynamic model needs \(requested) vertices; cap is \(cap)"
        case let .indexBudgetExceeded(requested, cap):
            return "dynamic model needs \(requested) indices; cap is \(cap)"
        case let .invalidIndexRange(offset, count, available):
            return "strip index range \(offset)..<\(offset + count) exceeds \(available)"
        case let .invalidVertexIndex(value, available):
            return "strip vertex index \(value) exceeds \(available) vertices"
        case let .triangleListIndexCount(count):
            return "triangle-list strip has non-multiple-of-three index count \(count)"
        case let .uint32VertexIndexOverflow(value):
            return "dynamic vertex index \(value) exceeds UInt32"
        }
    }
}

public enum GModDynamicModelMeshBuilder {
    public static func build(
        from source: SourceStudioModelMeshSnapshot,
        bodyValue: Int = 0,
        policy: GModDynamicModelMeshBuildPolicy = .initialIpadProp
    ) throws -> GModDynamicModelMesh {
        guard policy.maximumVertices > 0, policy.maximumIndices > 0 else {
            throw GModDynamicModelMeshBuildError.invalidPolicy(
                vertices: policy.maximumVertices,
                indices: policy.maximumIndices
            )
        }
        guard bodyValue >= 0 else {
            throw GModDynamicModelMeshBuildError.invalidBodyValue(bodyValue)
        }

        var vertices: [GModDynamicModelVertex] = []
        var indices: [UInt32] = []
        var ranges: [GModDynamicModelDrawRange] = []

        for bodyPart in source.bodyParts {
            guard !bodyPart.models.isEmpty else { continue }
            let selectedModelIndex: Int
            if bodyPart.models.count == 1 {
                selectedModelIndex = 0
            } else {
                let base = Int(bodyPart.modelSelectionBase)
                guard base > 0 else {
                    throw GModDynamicModelMeshBuildError.invalidBodyPartBase(
                        bodyPart: bodyPart.index,
                        base: bodyPart.modelSelectionBase,
                        modelCount: bodyPart.models.count
                    )
                }
                selectedModelIndex = (bodyValue / base) % bodyPart.models.count
            }
            let submodel = bodyPart.models[selectedModelIndex]

            for mesh in submodel.meshes {
                let rangeStart = indices.count
                for group in mesh.stripGroups {
                    let requestedVertices = try checkedSum(
                        vertices.count,
                        group.vertices.count,
                        cap: policy.maximumVertices,
                        isVertex: true
                    )
                    let baseVertex = vertices.count
                    vertices.reserveCapacity(requestedVertices)
                    vertices.append(contentsOf: group.vertices.map {
                        GModDynamicModelVertex(
                            position: $0.position,
                            normal: $0.normal,
                            textureCoordinate: $0.textureCoordinate
                        )
                    })

                    for strip in group.strips {
                        let offset = strip.indexRange.offset
                        let count = strip.indexRange.count
                        guard offset >= 0, count >= 0,
                              offset <= group.indices.count,
                              count <= group.indices.count - offset else {
                            throw GModDynamicModelMeshBuildError.invalidIndexRange(
                                offset: offset,
                                count: count,
                                available: group.indices.count
                            )
                        }
                        let raw = group.indices[offset..<(offset + count)]
                        switch strip.topology {
                        case .triangleList:
                            guard count.isMultiple(of: 3) else {
                                throw GModDynamicModelMeshBuildError
                                    .triangleListIndexCount(count)
                            }
                            try appendTriangleList(
                                raw,
                                baseVertex: baseVertex,
                                availableVertices: group.vertices.count,
                                policy: policy,
                                into: &indices
                            )
                        case .triangleStrip:
                            try appendTriangleStrip(
                                raw,
                                baseVertex: baseVertex,
                                availableVertices: group.vertices.count,
                                policy: policy,
                                into: &indices
                            )
                        }
                    }
                }
                let emitted = indices.count - rangeStart
                if emitted > 0 {
                    ranges.append(GModDynamicModelDrawRange(
                        bodyPartIndex: bodyPart.index,
                        submodelIndex: submodel.index,
                        meshIndex: mesh.index,
                        materialIndex: mesh.materialIndex,
                        firstIndex: rangeStart,
                        indexCount: emitted
                    ))
                }
            }
        }

        return GModDynamicModelMesh(
            checksum: source.checksum,
            modelName: source.modelName,
            bodyValue: bodyValue,
            vertices: vertices,
            indices: indices,
            ranges: ranges
        )
    }

    private static func appendTriangleList(
        _ raw: ArraySlice<UInt16>,
        baseVertex: Int,
        availableVertices: Int,
        policy: GModDynamicModelMeshBuildPolicy,
        into indices: inout [UInt32]
    ) throws {
        _ = try checkedSum(
            indices.count,
            raw.count,
            cap: policy.maximumIndices,
            isVertex: false
        )
        for value in raw {
            indices.append(try resolvedIndex(
                Int(value),
                baseVertex: baseVertex,
                availableVertices: availableVertices
            ))
        }
    }

    private static func appendTriangleStrip(
        _ raw: ArraySlice<UInt16>,
        baseVertex: Int,
        availableVertices: Int,
        policy: GModDynamicModelMeshBuildPolicy,
        into indices: inout [UInt32]
    ) throws {
        guard raw.count >= 3 else { return }
        let values = Array(raw)
        for triangle in 0..<(values.count - 2) {
            let a: UInt16
            let b: UInt16
            if triangle.isMultiple(of: 2) {
                a = values[triangle]
                b = values[triangle + 1]
            } else {
                a = values[triangle + 1]
                b = values[triangle]
            }
            let c = values[triangle + 2]
            if a == b || b == c || a == c { continue }
            _ = try checkedSum(
                indices.count,
                3,
                cap: policy.maximumIndices,
                isVertex: false
            )
            indices.append(try resolvedIndex(
                Int(a),
                baseVertex: baseVertex,
                availableVertices: availableVertices
            ))
            indices.append(try resolvedIndex(
                Int(b),
                baseVertex: baseVertex,
                availableVertices: availableVertices
            ))
            indices.append(try resolvedIndex(
                Int(c),
                baseVertex: baseVertex,
                availableVertices: availableVertices
            ))
        }
    }

    private static func resolvedIndex(
        _ value: Int,
        baseVertex: Int,
        availableVertices: Int
    ) throws -> UInt32 {
        guard value >= 0, value < availableVertices else {
            throw GModDynamicModelMeshBuildError.invalidVertexIndex(
                value: value,
                available: availableVertices
            )
        }
        let (resolved, overflow) = baseVertex.addingReportingOverflow(value)
        guard !overflow, let result = UInt32(exactly: resolved) else {
            throw GModDynamicModelMeshBuildError.uint32VertexIndexOverflow(
                overflow ? Int.max : resolved
            )
        }
        return result
    }

    private static func checkedSum(
        _ current: Int,
        _ addition: Int,
        cap: Int,
        isVertex: Bool
    ) throws -> Int {
        let (requested, overflow) = current.addingReportingOverflow(addition)
        let value = overflow ? Int.max : requested
        guard !overflow, value <= cap else {
            if isVertex {
                throw GModDynamicModelMeshBuildError.vertexBudgetExceeded(
                    requested: value,
                    cap: cap
                )
            }
            throw GModDynamicModelMeshBuildError.indexBudgetExceeded(
                requested: value,
                cap: cap
            )
        }
        return value
    }
}

import Foundation
import GModEngine
import GModGameAssets

/// Minimal content reader used by the independent attestation loader. The
/// production content-pack source conforms directly; tests can supply exact
/// owned MDL/PHY bytes without creating a ZIP.
public protocol GModAttestedPropPhysicsContentReading: Sendable {
    func data(
        for logicalPath: String,
        maximumByteCount: UInt64
    ) throws -> Data?
}

extension GModContentPackAssetSource: GModAttestedPropPhysicsContentReading {}

public enum GModAttestedPropPhysicsManifestError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case manifestTooLarge(actual: Int, maximum: Int)
    case malformedManifest(String)
    case unsupportedSchema(format: String, version: Int)
    case invalidProvenance(String)
    case assetCountOutsideBudget(Int)
    case duplicateModelPath(String)
    case missingContent(String)
    case contentReadFailed(path: String, reason: String)
    case digestMismatch(path: String, expected: String, actual: String)
    case invalidStudio(path: String, reason: String)
    case invalidPHY(path: String, reason: String)
    case solidIndexUnavailable(path: String, index: Int, count: Int)
    case geometryBudgetExceeded(path: String, field: String, actual: Int, limit: Int)
    case collisionBoundsDoNotContainGeometry(String)
    case invalidAsset(path: String, reason: String)

    public var description: String {
        switch self {
        case let .manifestTooLarge(actual, maximum):
            return "attested prop manifest is \(actual) bytes; maximum is \(maximum)"
        case let .malformedManifest(reason):
            return "attested prop manifest is malformed: \(reason)"
        case let .unsupportedSchema(format, version):
            return "unsupported attested prop manifest \(format) v\(version)"
        case let .invalidProvenance(reason):
            return "attested prop provenance is invalid: \(reason)"
        case let .assetCountOutsideBudget(count):
            return "attested prop manifest asset count is outside budget: \(count)"
        case let .duplicateModelPath(path):
            return "attested prop manifest repeats model path \(path)"
        case let .missingContent(path):
            return "attested prop content is missing: \(path)"
        case let .contentReadFailed(path, reason):
            return "attested prop content read failed for \(path): \(reason)"
        case let .digestMismatch(path, expected, actual):
            return "attested prop digest mismatch for \(path): expected \(expected), got \(actual)"
        case let .invalidStudio(path, reason):
            return "attested prop MDL is invalid for \(path): \(reason)"
        case let .invalidPHY(path, reason):
            return "attested prop PHY is invalid for \(path): \(reason)"
        case let .solidIndexUnavailable(path, index, count):
            return "attested prop \(path) selects solid \(index), PHY contains \(count)"
        case let .geometryBudgetExceeded(path, field, actual, limit):
            return "attested prop \(path) \(field)=\(actual) exceeds \(limit)"
        case let .collisionBoundsDoNotContainGeometry(path):
            return "attested collision bounds do not contain every vertex for \(path)"
        case let .invalidAsset(path, reason):
            return "attested prop \(path) violates the physics contract: \(reason)"
        }
    }
}

/// Loads a manifest supplied by an independent trust source and binds every
/// record to exact MDL and PHY bytes from the mounted content pack.
///
/// This API intentionally does not search the pack for its own attestation:
/// allowing arbitrary game content to self-attest would collapse the trust
/// boundary. The application must supply `independentManifestData` from an
/// owned/bundled or otherwise authenticated source.
public enum GModAttestedPropPhysicsManifestLoader {
    public struct Budget: Equatable, Sendable {
        public let maximumManifestBytes: Int
        public let maximumAssets: Int
        public let maximumPartsPerAsset: Int
        public let maximumVerticesPerAsset: Int
        public let maximumTrianglesPerAsset: Int
        public let maximumMDLBytes: UInt64
        public let maximumPHYBytes: UInt64

        public init(
            maximumManifestBytes: Int = 16 * 1_024 * 1_024,
            maximumAssets: Int = 512,
            maximumPartsPerAsset: Int = 1_024,
            maximumVerticesPerAsset: Int = 1_000_000,
            maximumTrianglesPerAsset: Int = 2_000_000,
            maximumMDLBytes: UInt64 = 32 * 1_024 * 1_024,
            maximumPHYBytes: UInt64 = 32 * 1_024 * 1_024
        ) {
            precondition(maximumManifestBytes > 0)
            precondition(maximumAssets > 0)
            precondition(maximumPartsPerAsset > 0)
            precondition(maximumVerticesPerAsset > 0)
            precondition(maximumTrianglesPerAsset > 0)
            precondition(maximumMDLBytes > 0)
            precondition(maximumPHYBytes > 0)
            self.maximumManifestBytes = maximumManifestBytes
            self.maximumAssets = maximumAssets
            self.maximumPartsPerAsset = maximumPartsPerAsset
            self.maximumVerticesPerAsset = maximumVerticesPerAsset
            self.maximumTrianglesPerAsset = maximumTrianglesPerAsset
            self.maximumMDLBytes = maximumMDLBytes
            self.maximumPHYBytes = maximumPHYBytes
        }

        public static let iPadValidated = Budget()
    }

    public static let format = "GarrysPADAttestedPropPhysics"
    public static let schemaVersion = 1
    public static let sourceAxisConvention =
        "source-x-forward-y-left-z-up"

    public static func load(
        independentManifestData: Data,
        content: any GModAttestedPropPhysicsContentReading,
        budget: Budget = .iPadValidated
    ) throws -> [SourceAttestedPropPhysicsAsset] {
        guard independentManifestData.count <= budget.maximumManifestBytes else {
            throw GModAttestedPropPhysicsManifestError.manifestTooLarge(
                actual: independentManifestData.count,
                maximum: budget.maximumManifestBytes
            )
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(
                Manifest.self,
                from: independentManifestData
            )
        } catch {
            throw GModAttestedPropPhysicsManifestError.malformedManifest(
                String(describing: error)
            )
        }
        guard manifest.format == format,
              manifest.schemaVersion == schemaVersion else {
            throw GModAttestedPropPhysicsManifestError.unsupportedSchema(
                format: manifest.format,
                version: manifest.schemaVersion
            )
        }
        guard manifest.axisConvention == sourceAxisConvention else {
            throw GModAttestedPropPhysicsManifestError.invalidProvenance(
                "axisConvention must be \(sourceAxisConvention)"
            )
        }
        guard !manifest.attestationAuthority
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isCanonicalSHA256(manifest.evidenceSHA256) else {
            throw GModAttestedPropPhysicsManifestError.invalidProvenance(
                "authority and a lowercase evidence SHA-256 are required"
            )
        }
        guard !manifest.assets.isEmpty,
              manifest.assets.count <= budget.maximumAssets else {
            throw GModAttestedPropPhysicsManifestError
                .assetCountOutsideBudget(manifest.assets.count)
        }

        var seenPaths = Set<String>()
        var result: [SourceAttestedPropPhysicsAsset] = []
        result.reserveCapacity(manifest.assets.count)
        for record in manifest.assets {
            let canonicalPath: SourceAttestedPropModelPath
            do {
                canonicalPath = try SourceAttestedPropModelPath(record.modelPath)
            } catch {
                throw GModAttestedPropPhysicsManifestError.invalidAsset(
                    path: record.modelPath,
                    reason: String(describing: error)
                )
            }
            guard seenPaths.insert(canonicalPath.value).inserted else {
                throw GModAttestedPropPhysicsManifestError
                    .duplicateModelPath(canonicalPath.value)
            }
            result.append(try load(
                record,
                canonicalPath: canonicalPath.value,
                content: content,
                budget: budget
            ))
        }
        return result
    }

    private static func load(
        _ record: AssetRecord,
        canonicalPath: String,
        content: any GModAttestedPropPhysicsContentReading,
        budget: Budget
    ) throws -> SourceAttestedPropPhysicsAsset {
        guard isCanonicalSHA256(record.mdlSHA256),
              isCanonicalSHA256(record.phySHA256) else {
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: canonicalPath,
                reason: "MDL and PHY digests must be lowercase SHA-256"
            )
        }
        let phyPath = String(canonicalPath.dropLast(4)) + ".phy"
        let mdlData = try read(
            canonicalPath,
            maximumByteCount: budget.maximumMDLBytes,
            from: content
        )
        let phyData = try read(
            phyPath,
            maximumByteCount: budget.maximumPHYBytes,
            from: content
        )
        try verifyDigest(mdlData, path: canonicalPath, expected: record.mdlSHA256)
        try verifyDigest(phyData, path: phyPath, expected: record.phySHA256)

        do {
            _ = try SourceStudioModel(
                data: mdlData,
                expectedChecksum: record.studioChecksum
            )
        } catch {
            throw GModAttestedPropPhysicsManifestError.invalidStudio(
                path: canonicalPath,
                reason: String(describing: error)
            )
        }
        let envelope: SourcePHYCollisionEnvelopeSnapshot
        do {
            envelope = try SourcePHYCollisionDecoder.decodeEnvelope(
                phyData,
                expectedSourceModelChecksum: record.studioChecksum,
                budget: SourcePHYCollisionDecodeBudget(
                    maximumFileBytes: Int(budget.maximumPHYBytes),
                    maximumSolids: 1_024,
                    maximumBytesPerSolid: Int(budget.maximumPHYBytes),
                    maximumTotalSolidBytes: Int(budget.maximumPHYBytes),
                    maximumKeyValuesBytes: 4 * 1_024 * 1_024
                )
            )
        } catch {
            throw GModAttestedPropPhysicsManifestError.invalidPHY(
                path: phyPath,
                reason: String(describing: error)
            )
        }
        guard envelope.serializedSolids.indices.contains(record.solidIndex) else {
            throw GModAttestedPropPhysicsManifestError.solidIndexUnavailable(
                path: canonicalPath,
                index: record.solidIndex,
                count: envelope.serializedSolids.count
            )
        }

        let shape = try makeShape(
            record,
            path: canonicalPath,
            budget: budget
        )
        let collisionProperty: SourceCollisionProperty
        do {
            collisionProperty = try SourceCollisionProperty(
                mins: record.collisionBounds.minimum.vector,
                maxs: record.collisionBounds.maximum.vector
            )
        } catch {
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: canonicalPath,
                reason: String(describing: error)
            )
        }
        let tolerance: Float = 1.0 / 32.0
        guard shape.parts.flatMap(\.vertices).allSatisfy({ vertex in
            vertex.x >= collisionProperty.mins.x - tolerance &&
                vertex.x <= collisionProperty.maxs.x + tolerance &&
                vertex.y >= collisionProperty.mins.y - tolerance &&
                vertex.y <= collisionProperty.maxs.y + tolerance &&
                vertex.z >= collisionProperty.mins.z - tolerance &&
                vertex.z <= collisionProperty.maxs.z + tolerance
        }) else {
            throw GModAttestedPropPhysicsManifestError
                .collisionBoundsDoNotContainGeometry(canonicalPath)
        }

        let motionType: SourcePhysicsMotionType
        switch record.bodyBehavior.motionType {
        case "static": motionType = .staticBody
        case "dynamic": motionType = .dynamicBody
        case "kinematic": motionType = .kinematicBody
        default:
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: canonicalPath,
                reason: "unknown motionType \(record.bodyBehavior.motionType)"
            )
        }
        guard (0 ... 127).contains(record.materialIndex) else {
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: canonicalPath,
                reason: "materialIndex is outside VPhysics seven-bit range"
            )
        }
        do {
            return try SourceAttestedPropPhysicsAsset(
                normalizedModelPath: canonicalPath,
                mdlSHA256: record.mdlSHA256,
                phySHA256: record.phySHA256,
                studioChecksum: record.studioChecksum,
                collisionProperty: collisionProperty,
                shapeEvidence: .independentlyAttested(shape),
                massProperties: SourcePhysicsMassProperties(
                    massKilograms: record.massKilograms,
                    principalInertia: record.principalInertia.vector
                ),
                solidIndex: record.solidIndex,
                materialIndex: record.materialIndex,
                bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                    motionType: motionType,
                    isGravityEnabled: record.bodyBehavior.isGravityEnabled,
                    isCollisionEnabled: record.bodyBehavior.isCollisionEnabled,
                    startsAwake: record.bodyBehavior.startsAwake
                )
            )
        } catch {
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: canonicalPath,
                reason: String(describing: error)
            )
        }
    }

    private static func makeShape(
        _ record: AssetRecord,
        path: String,
        budget: Budget
    ) throws -> SourcePhysicsShapeSnapshot {
        guard record.shape.topology == "convexParts" else {
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: path,
                reason: "prop shape topology must be convexParts"
            )
        }
        guard !record.shape.parts.isEmpty,
              record.shape.parts.count <= budget.maximumPartsPerAsset else {
            throw GModAttestedPropPhysicsManifestError.geometryBudgetExceeded(
                path: path,
                field: "parts",
                actual: record.shape.parts.count,
                limit: budget.maximumPartsPerAsset
            )
        }
        var totalVertices = 0
        var totalTriangles = 0
        var parts: [SourcePhysicsMeshPartSnapshot] = []
        parts.reserveCapacity(record.shape.parts.count)
        do {
            for part in record.shape.parts {
                totalVertices += part.vertices.count
                totalTriangles += part.triangles.count
                guard totalVertices <= budget.maximumVerticesPerAsset else {
                    throw GModAttestedPropPhysicsManifestError.geometryBudgetExceeded(
                        path: path,
                        field: "vertices",
                        actual: totalVertices,
                        limit: budget.maximumVerticesPerAsset
                    )
                }
                guard totalTriangles <= budget.maximumTrianglesPerAsset else {
                    throw GModAttestedPropPhysicsManifestError.geometryBudgetExceeded(
                        path: path,
                        field: "triangles",
                        actual: totalTriangles,
                        limit: budget.maximumTrianglesPerAsset
                    )
                }
                let triangles = try part.triangles.map {
                    try SourcePhysicsIndexedTriangle(
                        first: $0.first,
                        second: $0.second,
                        third: $0.third,
                        materialIndex: $0.materialIndex
                    )
                }
                parts.append(try SourcePhysicsMeshPartSnapshot(
                    vertices: part.vertices.map(\.vector),
                    triangles: triangles
                ))
            }
            return try SourcePhysicsShapeSnapshot(
                topology: .convexParts,
                parts: parts
            )
        } catch let error as GModAttestedPropPhysicsManifestError {
            throw error
        } catch {
            throw GModAttestedPropPhysicsManifestError.invalidAsset(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private static func read(
        _ path: String,
        maximumByteCount: UInt64,
        from content: any GModAttestedPropPhysicsContentReading
    ) throws -> Data {
        do {
            guard let data = try content.data(
                for: path,
                maximumByteCount: maximumByteCount
            ) else {
                throw GModAttestedPropPhysicsManifestError.missingContent(path)
            }
            return data
        } catch let error as GModAttestedPropPhysicsManifestError {
            throw error
        } catch {
            throw GModAttestedPropPhysicsManifestError.contentReadFailed(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private static func verifyDigest(
        _ data: Data,
        path: String,
        expected: String
    ) throws {
        var hasher = GModContentSHA256()
        hasher.update(data)
        let actual = hasher.hexadecimalDigest()
        guard actual == expected else {
            throw GModAttestedPropPhysicsManifestError.digestMismatch(
                path: path,
                expected: expected,
                actual: actual
            )
        }
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let format: String
    let attestationAuthority: String
    let evidenceSHA256: String
    let axisConvention: String
    let assets: [AssetRecord]
}

private struct AssetRecord: Decodable {
    let modelPath: String
    let mdlSHA256: String
    let phySHA256: String
    let studioChecksum: Int32
    let collisionBounds: BoundsRecord
    let shape: ShapeRecord
    let massKilograms: Float
    let principalInertia: VectorRecord
    let solidIndex: Int
    let materialIndex: Int
    let bodyBehavior: BodyBehaviorRecord
}

private struct BoundsRecord: Decodable {
    let minimum: VectorRecord
    let maximum: VectorRecord
}

private struct ShapeRecord: Decodable {
    let topology: String
    let parts: [PartRecord]
}

private struct PartRecord: Decodable {
    let vertices: [VectorRecord]
    let triangles: [TriangleRecord]
}

private struct TriangleRecord: Decodable {
    let first: Int
    let second: Int
    let third: Int
    let materialIndex: Int
}

private struct BodyBehaviorRecord: Decodable {
    let motionType: String
    let isGravityEnabled: Bool
    let isCollisionEnabled: Bool
    let startsAwake: Bool
}

private struct VectorRecord: Decodable {
    let x: Float
    let y: Float
    let z: Float

    var vector: SourceVector3 { SourceVector3(x, y, z) }
}

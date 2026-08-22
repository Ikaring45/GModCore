import Foundation
import GModEngine

/// Host allocation guards for one immutable dynamic-prop renderer handoff.
/// These are deployment limits, not Source format or physical-device claims.
public struct GModMetalDynamicEntityScenePolicy: Sendable, Equatable {
    public let maximumResourceCount: Int
    public let maximumInstanceCount: Int
    public let maximumTotalVertexCount: Int
    public let maximumTotalIndexCount: Int
    public let maximumTotalDrawRangeCount: Int
    public let maximumGeometryByteCount: Int
    public let maximumMetadataUTF8ByteCount: Int

    public init(
        maximumResourceCount: Int,
        maximumInstanceCount: Int,
        maximumTotalVertexCount: Int,
        maximumTotalIndexCount: Int,
        maximumTotalDrawRangeCount: Int,
        maximumGeometryByteCount: Int,
        maximumMetadataUTF8ByteCount: Int
    ) {
        self.maximumResourceCount = maximumResourceCount
        self.maximumInstanceCount = maximumInstanceCount
        self.maximumTotalVertexCount = maximumTotalVertexCount
        self.maximumTotalIndexCount = maximumTotalIndexCount
        self.maximumTotalDrawRangeCount = maximumTotalDrawRangeCount
        self.maximumGeometryByteCount = maximumGeometryByteCount
        self.maximumMetadataUTF8ByteCount = maximumMetadataUTF8ByteCount
    }

    public static let initialIpadPropScene = Self(
        maximumResourceCount: 128,
        maximumInstanceCount: 1_024,
        maximumTotalVertexCount: 1_048_576,
        maximumTotalIndexCount: 6_291_456,
        maximumTotalDrawRangeCount: 65_536,
        maximumGeometryByteCount: 128 * 1_024 * 1_024,
        maximumMetadataUTF8ByteCount: 4 * 1_024 * 1_024
    )
}

/// Metal-owned identity for the immutable vertex payload behind one Studio
/// resource. Bind-pose geometry remains shared by appearance, while an
/// authored animation frame keeps every discriminator from the CPU-skinned
/// GameSession resource. A sequence/frame change therefore cannot alias an
/// already-uploaded bind-pose or prior-frame vertex buffer.
public enum GModMetalStudioGeometryIdentity:
    Sendable,
    Equatable,
    Hashable,
    Comparable
{
    case bindPose
    case animated(
        sequenceIndex: Int,
        blendIndex: Int,
        animationIndex: Int,
        frame: Int
    )

    public static func < (
        lhs: GModMetalStudioGeometryIdentity,
        rhs: GModMetalStudioGeometryIdentity
    ) -> Bool {
        switch (lhs, rhs) {
        case (.bindPose, .bindPose):
            return false
        case (.bindPose, .animated):
            return true
        case (.animated, .bindPose):
            return false
        case let (
            .animated(lhsSequence, lhsBlend, lhsAnimation, lhsFrame),
            .animated(rhsSequence, rhsBlend, rhsAnimation, rhsFrame)
        ):
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            if lhsBlend != rhsBlend { return lhsBlend < rhsBlend }
            if lhsAnimation != rhsAnimation {
                return lhsAnimation < rhsAnimation
            }
            return lhsFrame < rhsFrame
        }
    }
}

/// Metal-owned copy of the complete Studio geometry identity. The App
/// boundary can map the GameSession value into this type without making
/// GModMetal depend on the session, filesystem, or Lua targets.
public struct GModMetalDynamicEntityResourceID:
    Sendable,
    Equatable,
    Hashable,
    Comparable
{
    public let normalizedModelPath: String
    public let checksum: Int32
    public let lodIndex: Int
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let geometryIdentity: GModMetalStudioGeometryIdentity

    public init(
        normalizedModelPath: String,
        checksum: Int32,
        lodIndex: Int = 0,
        bodyValue: Int,
        skinFamilyIndex: Int,
        geometryIdentity: GModMetalStudioGeometryIdentity = .bindPose
    ) {
        self.normalizedModelPath = normalizedModelPath
        self.checksum = checksum
        self.lodIndex = lodIndex
        self.bodyValue = bodyValue
        self.skinFamilyIndex = skinFamilyIndex
        self.geometryIdentity = geometryIdentity
    }

    public static func < (
        lhs: GModMetalDynamicEntityResourceID,
        rhs: GModMetalDynamicEntityResourceID
    ) -> Bool {
        if lhs.normalizedModelPath != rhs.normalizedModelPath {
            return lhs.normalizedModelPath < rhs.normalizedModelPath
        }
        if lhs.checksum != rhs.checksum { return lhs.checksum < rhs.checksum }
        if lhs.lodIndex != rhs.lodIndex { return lhs.lodIndex < rhs.lodIndex }
        if lhs.bodyValue != rhs.bodyValue { return lhs.bodyValue < rhs.bodyValue }
        if lhs.skinFamilyIndex != rhs.skinFamilyIndex {
            return lhs.skinFamilyIndex < rhs.skinFamilyIndex
        }
        return lhs.geometryIdentity < rhs.geometryIdentity
    }
}

/// Pure cache decisions shared by the real Metal renderer and contract tests.
/// Geometry reuse requires the complete immutable payload identity, not merely
/// matching array counts. Texture reuse is intentionally appearance-scoped so
/// a viewmodel animation does not evict unchanged material bitmaps each frame.
enum GModMetalStudioGeometryCacheContract {
    static func hasSameAppearance(
        _ lhs: GModMetalDynamicEntityResourceID,
        _ rhs: GModMetalDynamicEntityResourceID
    ) -> Bool {
        lhs.normalizedModelPath == rhs.normalizedModelPath &&
            lhs.checksum == rhs.checksum &&
            lhs.lodIndex == rhs.lodIndex &&
            lhs.bodyValue == rhs.bodyValue &&
            lhs.skinFamilyIndex == rhs.skinFamilyIndex
    }

    static func canReuseGeometry(
        cachedID: GModMetalDynamicEntityResourceID,
        cachedVertexCount: Int,
        cachedIndexCount: Int,
        publishedID: GModMetalDynamicEntityResourceID,
        publishedVertexCount: Int,
        publishedIndexCount: Int
    ) -> Bool {
        cachedID == publishedID &&
            cachedVertexCount == publishedVertexCount &&
            cachedIndexCount == publishedIndexCount
    }
}

struct GModMetalStudioGeometryUploadLimits: Sendable, Equatable {
    let maximumResourceCount: Int
    let maximumByteCount: Int
}

/// Static resource admission keeps the established one-resource/16 MiB frame
/// pacing. A publication containing animated geometry may attempt every
/// referenced resource in one bounded callback, up to the already-enforced
/// 128 MiB scene/cache cap; otherwise continually advancing poses could retire
/// unuploaded resource IDs before later entities ever receive a vertex buffer.
enum GModMetalStudioGeometryUploadContract {
    static let ordinaryMaximumByteCount = 16 * 1_024 * 1_024
    static let animatedMaximumByteCount = 128 * 1_024 * 1_024

    static func limits(
        for resourceIDs: Set<GModMetalDynamicEntityResourceID>
    ) -> GModMetalStudioGeometryUploadLimits {
        let containsAnimation = resourceIDs.contains {
            if case .animated = $0.geometryIdentity { return true }
            return false
        }
        return GModMetalStudioGeometryUploadLimits(
            maximumResourceCount: containsAnimation
                ? Swift.max(1, resourceIDs.count)
                : 1,
            maximumByteCount: containsAnimation
                ? animatedMaximumByteCount
                : ordinaryMaximumByteCount
        )
    }
}

/// Renderer-neutral Studio vertex accepted at the GModMetal boundary.
public struct GModMetalDynamicEntitySourceVertex: Sendable, Equatable {
    public let position: SourceVector3
    public let normal: SourceVector3
    public let textureCoordinate: SIMD2<Float>

    public init(
        position: SourceVector3,
        normal: SourceVector3,
        textureCoordinate: SIMD2<Float>
    ) {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
    }
}

public struct GModMetalDynamicEntityMaterialBinding: Sendable, Equatable {
    public let sourceMaterialIndex: Int32
    public let skinFamilyIndex: Int
    public let textureIndex: Int
    public let textureName: String
    /// Ordered logical VMT candidates from the decoded Studio table.
    public let vmtCandidates: [String]

    public init(
        sourceMaterialIndex: Int32,
        skinFamilyIndex: Int,
        textureIndex: Int,
        textureName: String,
        vmtCandidates: [String]
    ) {
        self.sourceMaterialIndex = sourceMaterialIndex
        self.skinFamilyIndex = skinFamilyIndex
        self.textureIndex = textureIndex
        self.textureName = textureName
        self.vmtCandidates = vmtCandidates
    }
}

/// Records the exact host-side outcome for one ordered Studio material lookup.
/// A missing or failed Source material never becomes a fabricated bitmap.
public enum GModMetalDynamicEntityMaterialResolution: Sendable, Equatable {
    /// Used only by renderer-neutral callers that have not crossed the App
    /// material boundary yet.
    case unresolved
    case resolved(candidate: String, bitmap: GModMetalSurfaceBitmap)
    case sourceMissing
    case materialWithoutBaseTexture(candidate: String)
    case baseTextureMissing(candidate: String)
    case decodeFailed(candidate: String, detail: String)
    case retentionCapacityExceeded(
        candidate: String,
        requiredByteCount: Int,
        retainedByteCount: Int,
        maximumByteCount: Int
    )

    public var bitmap: GModMetalSurfaceBitmap? {
        guard case let .resolved(_, bitmap) = self else { return nil }
        return bitmap
    }
}

public struct GModMetalDynamicEntityDrawRange: Sendable, Equatable {
    public let bodyPartIndex: Int
    public let submodelIndex: Int
    public let meshIndex: Int
    public let firstIndex: Int
    public let indexCount: Int
    public let material: GModMetalDynamicEntityMaterialBinding
    public let materialResolution: GModMetalDynamicEntityMaterialResolution
    /// True only when the resolved VMT declares PlayerWeaponColor with
    /// `resultvar "$color2"`. Viewmodel rendering evaluates that exact
    /// proxy; ordinary ranges remain untinted.
    public let usesPlayerWeaponColor: Bool

    public init(
        bodyPartIndex: Int,
        submodelIndex: Int,
        meshIndex: Int,
        firstIndex: Int,
        indexCount: Int,
        material: GModMetalDynamicEntityMaterialBinding,
        materialResolution: GModMetalDynamicEntityMaterialResolution =
            .unresolved,
        usesPlayerWeaponColor: Bool = false
    ) {
        self.bodyPartIndex = bodyPartIndex
        self.submodelIndex = submodelIndex
        self.meshIndex = meshIndex
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.material = material
        self.materialResolution = materialResolution
        self.usesPlayerWeaponColor = usesPlayerWeaponColor
    }
}

/// One complete renderer-neutral Studio resource. Redundant identity fields
/// are intentional: the boundary verifies that no stale cache key can be
/// paired with geometry compiled for a different body, skin, or checksum.
public struct GModMetalDynamicEntityResourceInput: Sendable, Equatable {
    public let id: GModMetalDynamicEntityResourceID
    public let checksum: Int32
    public let modelName: String
    public let lodIndex: Int
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let vertices: [GModMetalDynamicEntitySourceVertex]
    public let indices: [UInt32]
    public let drawRanges: [GModMetalDynamicEntityDrawRange]

    public init(
        id: GModMetalDynamicEntityResourceID,
        checksum: Int32,
        modelName: String,
        lodIndex: Int,
        bodyValue: Int,
        skinFamilyIndex: Int,
        vertices: [GModMetalDynamicEntitySourceVertex],
        indices: [UInt32],
        drawRanges: [GModMetalDynamicEntityDrawRange]
    ) {
        self.id = id
        self.checksum = checksum
        self.modelName = modelName
        self.lodIndex = lodIndex
        self.bodyValue = bodyValue
        self.skinFamilyIndex = skinFamilyIndex
        self.vertices = vertices
        self.indices = indices
        self.drawRanges = drawRanges
    }
}

public struct GModMetalDynamicEntityInstanceInput: Sendable, Equatable {
    public let identity: SourceCanonicalEntityIdentity
    public let sourceEntityRevision: UInt64
    public let transform: SourceEntityTransform
    public let resourceID: GModMetalDynamicEntityResourceID
    public let colorModulation: SourceEntityRenderColor
    public let renderMode: SourceEntityRenderMode
    public let renderFX: SourceEntityRenderFX

    public init(
        identity: SourceCanonicalEntityIdentity,
        sourceEntityRevision: UInt64,
        transform: SourceEntityTransform,
        resourceID: GModMetalDynamicEntityResourceID,
        colorModulation: SourceEntityRenderColor = .white,
        renderMode: SourceEntityRenderMode = .normal,
        renderFX: SourceEntityRenderFX = .none
    ) {
        self.identity = identity
        self.sourceEntityRevision = sourceEntityRevision
        self.transform = transform
        self.resourceID = resourceID
        self.colorModulation = colorModulation
        self.renderMode = renderMode
        self.renderFX = renderFX
    }
}

/// The subset of Source `RenderMode_t` whose fixed-function blend equation is
/// completely specified by SDK 2013. Special sprite/glow/frame-blend modes do
/// not fall back to one of these paths because that would silently change
/// Source semantics.
enum GModMetalDynamicEntityBlendMode: Sendable, Equatable, CaseIterable {
    case opaque
    case sourceAlpha
    case additive
}

enum GModMetalDynamicEntityFragmentMode: Sendable, Equatable {
    case material
    case constantColor
}

enum GModMetalDynamicEntityRenderDisposition: Sendable, Equatable {
    case draw(
        blendMode: GModMetalDynamicEntityBlendMode,
        fragmentMode: GModMetalDynamicEntityFragmentMode
    )
    case hidden
    case unsupported
}

enum GModMetalDynamicEntityRenderContract {
    /// Fixed Valve SDK `RenderMode_t` equations from `const.h` at
    /// c8f4c6351162fbff83bfa5a428d45d1e6eed3824. `transColor` is
    /// `c*a + dest*(1-a)`, `transTexture` is `src*a + dest*(1-a)`, and
    /// `transAdd` is `src*a + dest`.
    static func disposition(
        for mode: SourceEntityRenderMode
    ) -> GModMetalDynamicEntityRenderDisposition {
        switch mode {
        case .normal:
            return .draw(blendMode: .opaque, fragmentMode: .material)
        case .transColor:
            return .draw(
                blendMode: .sourceAlpha,
                fragmentMode: .constantColor
            )
        case .transTexture:
            return .draw(
                blendMode: .sourceAlpha,
                fragmentMode: .material
            )
        case .transAdd:
            return .draw(blendMode: .additive, fragmentMode: .material)
        case .environmental, .none:
            return .hidden
        case .glow, .transAlpha, .transAddFrameBlend, .transAlphaAdd,
                .worldGlow:
            return .unsupported
        }
    }

    /// Source exposes RGB modulation as byte-normalized `color32` channels.
    /// Alpha is the fixed blend amount for the supported translucent/additive
    /// modes; SDK `ComputeFxBlend` forces normal mode to 255 when RenderFX is
    /// none, so the opaque route deliberately ignores color alpha.
    static func displayRGBAndAlpha(
        color: SourceEntityRenderColor,
        blendMode: GModMetalDynamicEntityBlendMode
    ) -> SIMD4<Float> {
        let scale = 1 / Float(UInt8.max)
        return SIMD4<Float>(
            Float(color.red) * scale,
            Float(color.green) * scale,
            Float(color.blue) * scale,
            blendMode == .opaque ? 1 : Float(color.alpha) * scale
        )
    }
}

/// GPU-ready local vertex. Positions and normals have undergone only the
/// orthonormal Source-to-Metal basis change; entity pose stays instanced.
public struct GModMetalDynamicEntityVertex: Sendable, Equatable {
    public let metalLocalPosition: SIMD3<Float>
    public let metalLocalNormal: SIMD3<Float>
    public let textureCoordinate: SIMD2<Float>
}

/// Column form of `C * SourceLocalToWorld * C^-1`, where
/// `C(x,y,z) = (-y,z,-x)`. This lets one immutable Studio resource serve every
/// pose without duplicating transformed CPU vertices.
public struct GModMetalDynamicEntityTransform: Sendable, Equatable {
    public let metalXAxis: SIMD3<Float>
    public let metalYAxis: SIMD3<Float>
    public let metalZAxis: SIMD3<Float>
    public let metalTranslation: SIMD3<Float>

    public init(sourceTransform: SourceEntityTransform) {
        let basis = sourceTransform.angles.sourceBasis
        metalXAxis = GModMetalWorldScene.convertSourceVector(Self.simd(basis.right))
        metalYAxis = GModMetalWorldScene.convertSourceVector(Self.simd(basis.up))
        metalZAxis = -GModMetalWorldScene.convertSourceVector(Self.simd(basis.forward))
        metalTranslation = GModMetalWorldScene.convertSourceVector(
            Self.simd(sourceTransform.origin)
        )
    }

    public func transformPoint(_ metalLocal: SIMD3<Float>) -> SIMD3<Float> {
        metalTranslation + transformDirection(metalLocal)
    }

    public func transformDirection(
        _ metalLocal: SIMD3<Float>
    ) -> SIMD3<Float> {
        metalXAxis * metalLocal.x +
            metalYAxis * metalLocal.y +
            metalZAxis * metalLocal.z
    }

    fileprivate var isFinite: Bool {
        metalXAxis.isGModMetalFinite &&
            metalYAxis.isGModMetalFinite &&
            metalZAxis.isGModMetalFinite &&
            metalTranslation.isGModMetalFinite
    }

    private static func simd(_ value: SourceVector3) -> SIMD3<Float> {
        SIMD3<Float>(value.x, value.y, value.z)
    }
}

public struct GModMetalDynamicEntityResource: Sendable, Equatable {
    public let id: GModMetalDynamicEntityResourceID
    public let modelName: String
    public let lodIndex: Int
    public let vertices: [GModMetalDynamicEntityVertex]
    public let indices: [UInt32]
    public let drawRanges: [GModMetalDynamicEntityDrawRange]
    public let geometryByteCount: Int
    public let metadataUTF8ByteCount: Int
}

public struct GModMetalDynamicEntityInstance: Sendable, Equatable {
    /// Complete EHANDLE, including serial generation; never an entry-only ID.
    public let identity: SourceCanonicalEntityIdentity
    public let sourceEntityRevision: UInt64
    public let sourceTransform: SourceEntityTransform
    public let metalTransform: GModMetalDynamicEntityTransform
    public let resourceID: GModMetalDynamicEntityResourceID
    /// Authoritative Source `color32`; conversion to linear RGB happens in
    /// the fragment shader beside the existing world color-space contract.
    public let colorModulation: SourceEntityRenderColor
    public let renderMode: SourceEntityRenderMode
    /// Retained exactly. Time-varying RenderFX evaluation is intentionally not
    /// approximated by this renderer slice.
    public let renderFX: SourceEntityRenderFX
}

/// Complete publication identity. Source connection generations restart in a
/// newly allocated shared session, so they cannot distinguish App session
/// replacement by themselves.
public struct GModMetalDynamicEntitySceneGeneration:
    Sendable,
    Equatable,
    Hashable
{
    public let application: UInt64
    public let lane: UInt64
    public let sourceConnection: SourceEntityReplicationConnectionGeneration

    public init(
        application: UInt64,
        lane: UInt64,
        sourceConnection: SourceEntityReplicationConnectionGeneration
    ) {
        self.application = application
        self.lane = lane
        self.sourceConnection = sourceConnection
    }
}

public enum GModMetalDynamicEntitySceneError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidPolicy(field: String, value: Int)
    case invalidSceneGeneration(field: String, value: UInt64)
    case revisionNotIncreasing(previous: UInt64, received: UInt64)
    case sourceEntityRevisionWentBackwards(
        handle: UInt32,
        previous: UInt64,
        received: UInt64
    )
    case countBudgetExceeded(kind: String, requested: Int, cap: Int)
    case geometryByteCountOverflow
    case geometryByteBudgetExceeded(requested: Int, cap: Int)
    case metadataByteCountOverflow
    case metadataByteBudgetExceeded(requested: Int, cap: Int)
    case duplicateResourceID(GModMetalDynamicEntityResourceID)
    case nonCanonicalModelPath(String)
    case invalidResourceIdentity(
        id: GModMetalDynamicEntityResourceID,
        field: String
    )
    case emptyResourceGeometry(GModMetalDynamicEntityResourceID)
    case invalidVertex(
        id: GModMetalDynamicEntityResourceID,
        index: Int,
        field: String
    )
    case invalidIndex(
        id: GModMetalDynamicEntityResourceID,
        position: Int,
        value: UInt32,
        vertexCount: Int
    )
    case invalidDrawRange(
        id: GModMetalDynamicEntityResourceID,
        index: Int,
        reason: String
    )
    case drawRangesDoNotCoverIndices(
        id: GModMetalDynamicEntityResourceID,
        covered: Int,
        indexCount: Int
    )
    case duplicateEntityHandle(UInt32)
    case duplicateEntityEntryIndex(
        entryIndex: Int,
        firstHandle: UInt32,
        secondHandle: UInt32
    )
    case missingInstanceResource(
        handle: UInt32,
        resourceID: GModMetalDynamicEntityResourceID
    )
    case invalidInstanceTransform(handle: UInt32)

    public var description: String {
        switch self {
        case let .invalidPolicy(field, value):
            return "invalid dynamic Metal policy \(field)=\(value)"
        case let .invalidSceneGeneration(field, value):
            return "invalid dynamic Metal scene generation \(field)=\(value)"
        case let .revisionNotIncreasing(previous, received):
            return "dynamic Metal revision \(received) does not follow \(previous)"
        case let .sourceEntityRevisionWentBackwards(handle, previous, received):
            return "dynamic Metal EHANDLE \(handle) revision \(received) precedes \(previous)"
        case let .countBudgetExceeded(kind, requested, cap):
            return "dynamic Metal \(kind) count \(requested) exceeds \(cap)"
        case .geometryByteCountOverflow:
            return "dynamic Metal geometry byte count overflows"
        case let .geometryByteBudgetExceeded(requested, cap):
            return "dynamic Metal geometry needs \(requested) bytes; cap is \(cap)"
        case .metadataByteCountOverflow:
            return "dynamic Metal metadata byte count overflows"
        case let .metadataByteBudgetExceeded(requested, cap):
            return "dynamic Metal metadata needs \(requested) bytes; cap is \(cap)"
        case let .duplicateResourceID(id):
            return "duplicate dynamic Metal resource \(id.normalizedModelPath)"
        case let .nonCanonicalModelPath(path):
            return "non-canonical dynamic Metal model path '\(path)'"
        case let .invalidResourceIdentity(id, field):
            return "dynamic Metal resource \(id.normalizedModelPath) mismatches \(field)"
        case let .emptyResourceGeometry(id):
            return "dynamic Metal resource \(id.normalizedModelPath) has empty geometry"
        case let .invalidVertex(id, index, field):
            return "dynamic Metal resource \(id.normalizedModelPath) vertex \(index) has invalid \(field)"
        case let .invalidIndex(id, position, value, vertexCount):
            return "dynamic Metal resource \(id.normalizedModelPath) index \(position)=\(value) exceeds \(vertexCount) vertices"
        case let .invalidDrawRange(id, index, reason):
            return "dynamic Metal resource \(id.normalizedModelPath) range \(index) is invalid: \(reason)"
        case let .drawRangesDoNotCoverIndices(id, covered, count):
            return "dynamic Metal resource \(id.normalizedModelPath) ranges cover \(covered) of \(count) indices"
        case let .duplicateEntityHandle(handle):
            return "duplicate dynamic Metal EHANDLE \(handle)"
        case let .duplicateEntityEntryIndex(entry, first, second):
            return "dynamic Metal entry \(entry) has simultaneous handles \(first) and \(second)"
        case let .missingInstanceResource(handle, id):
            return "dynamic Metal EHANDLE \(handle) references missing resource \(id.normalizedModelPath)"
        case let .invalidInstanceTransform(handle):
            return "dynamic Metal EHANDLE \(handle) has a non-finite transform"
        }
    }
}

/// Immutable, deterministically ordered renderer input. Construction is
/// transactional: no partially converted resource escapes after any failure.
public struct GModMetalDynamicEntityScene: Sendable, Equatable {
    /// Session/lane/replication identity. Scene revisions may restart after a
    /// replacement, so renderer caches must key on this value as well.
    public let generation: GModMetalDynamicEntitySceneGeneration
    public let revision: UInt64
    public let resources: [GModMetalDynamicEntityResource]
    public let instances: [GModMetalDynamicEntityInstance]
    public let retainedGeometryByteCount: Int
    public let retainedMetadataUTF8ByteCount: Int
    private let policy: GModMetalDynamicEntityScenePolicy

    public init(
        generation: GModMetalDynamicEntitySceneGeneration,
        revision: UInt64,
        resources sourceResources: [GModMetalDynamicEntityResourceInput],
        instances sourceInstances: [GModMetalDynamicEntityInstanceInput],
        policy: GModMetalDynamicEntityScenePolicy = .initialIpadPropScene
    ) throws {
        try Self.validate(policy)
        try Self.validate(generation)
        try Self.requireCount(
            sourceResources.count,
            cap: policy.maximumResourceCount,
            kind: "resource"
        )
        try Self.requireCount(
            sourceInstances.count,
            cap: policy.maximumInstanceCount,
            kind: "instance"
        )

        var resourceIDs = Set<GModMetalDynamicEntityResourceID>()
        var convertedResources: [GModMetalDynamicEntityResource] = []
        var totalVertices = 0
        var totalIndices = 0
        var totalRanges = 0
        var geometryBytes = 0
        var metadataBytes = 0
        convertedResources.reserveCapacity(sourceResources.count)

        for source in sourceResources.sorted(by: { $0.id < $1.id }) {
            guard resourceIDs.insert(source.id).inserted else {
                throw GModMetalDynamicEntitySceneError.duplicateResourceID(source.id)
            }
            let converted = try Self.convert(source)
            totalVertices = try Self.addingCount(
                converted.vertices.count,
                to: totalVertices,
                cap: policy.maximumTotalVertexCount,
                kind: "vertex"
            )
            totalIndices = try Self.addingCount(
                converted.indices.count,
                to: totalIndices,
                cap: policy.maximumTotalIndexCount,
                kind: "index"
            )
            totalRanges = try Self.addingCount(
                converted.drawRanges.count,
                to: totalRanges,
                cap: policy.maximumTotalDrawRangeCount,
                kind: "draw range"
            )
            geometryBytes = try Self.addingBytes(
                converted.geometryByteCount,
                to: geometryBytes,
                cap: policy.maximumGeometryByteCount,
                isMetadata: false
            )
            metadataBytes = try Self.addingBytes(
                converted.metadataUTF8ByteCount,
                to: metadataBytes,
                cap: policy.maximumMetadataUTF8ByteCount,
                isMetadata: true
            )
            convertedResources.append(converted)
        }

        let convertedInstances = try Self.convertInstances(
            sourceInstances,
            resourceIDs: resourceIDs,
            maximumInstanceCount: policy.maximumInstanceCount
        )

        self.generation = generation
        self.revision = revision
        resources = convertedResources
        instances = convertedInstances
        retainedGeometryByteCount = geometryBytes
        retainedMetadataUTF8ByteCount = metadataBytes
        self.policy = policy
    }

    /// Fast path for movement/physics ticks. The immutable resource arrays are
    /// copied by value and retain their COW storage; only instance transforms
    /// are validated and rebuilt.
    public func updatingInstances(
        revision: UInt64,
        instances sourceInstances: [GModMetalDynamicEntityInstanceInput]
    ) throws -> Self {
        guard revision > self.revision else {
            throw GModMetalDynamicEntitySceneError.revisionNotIncreasing(
                previous: self.revision,
                received: revision
            )
        }
        let resourceIDs = Set(resources.map(\.id))
        let priorRevisions = Dictionary(uniqueKeysWithValues: instances.map {
            ($0.identity.handle.rawValue, $0.sourceEntityRevision)
        })
        let convertedInstances = try Self.convertInstances(
            sourceInstances,
            resourceIDs: resourceIDs,
            maximumInstanceCount: policy.maximumInstanceCount,
            minimumRevisionByHandle: priorRevisions
        )
        return Self(
            generation: generation,
            revision: revision,
            resources: resources,
            instances: convertedInstances,
            retainedGeometryByteCount: retainedGeometryByteCount,
            retainedMetadataUTF8ByteCount: retainedMetadataUTF8ByteCount,
            policy: policy
        )
    }

    private init(
        generation: GModMetalDynamicEntitySceneGeneration,
        revision: UInt64,
        resources: [GModMetalDynamicEntityResource],
        instances: [GModMetalDynamicEntityInstance],
        retainedGeometryByteCount: Int,
        retainedMetadataUTF8ByteCount: Int,
        policy: GModMetalDynamicEntityScenePolicy
    ) {
        self.generation = generation
        self.revision = revision
        self.resources = resources
        self.instances = instances
        self.retainedGeometryByteCount = retainedGeometryByteCount
        self.retainedMetadataUTF8ByteCount = retainedMetadataUTF8ByteCount
        self.policy = policy
    }
}

private extension GModMetalDynamicEntityScene {
    static func validate(_ policy: GModMetalDynamicEntityScenePolicy) throws {
        let fields = [
            ("maximumResourceCount", policy.maximumResourceCount),
            ("maximumInstanceCount", policy.maximumInstanceCount),
            ("maximumTotalVertexCount", policy.maximumTotalVertexCount),
            ("maximumTotalIndexCount", policy.maximumTotalIndexCount),
            ("maximumTotalDrawRangeCount", policy.maximumTotalDrawRangeCount),
            ("maximumGeometryByteCount", policy.maximumGeometryByteCount),
            ("maximumMetadataUTF8ByteCount", policy.maximumMetadataUTF8ByteCount),
        ]
        if let invalid = fields.first(where: { $0.1 <= 0 }) {
            throw GModMetalDynamicEntitySceneError.invalidPolicy(
                field: invalid.0,
                value: invalid.1
            )
        }
    }

    static func validate(
        _ generation: GModMetalDynamicEntitySceneGeneration
    ) throws {
        let fields = [
            ("application", generation.application),
            ("lane", generation.lane),
            ("sourceConnection", generation.sourceConnection.rawValue),
        ]
        if let invalid = fields.first(where: { $0.1 == 0 }) {
            throw GModMetalDynamicEntitySceneError.invalidSceneGeneration(
                field: invalid.0,
                value: invalid.1
            )
        }
    }

    static func convert(
        _ source: GModMetalDynamicEntityResourceInput
    ) throws -> GModMetalDynamicEntityResource {
        guard canonicalModelPath(source.id.normalizedModelPath) ==
                source.id.normalizedModelPath else {
            throw GModMetalDynamicEntitySceneError.nonCanonicalModelPath(
                source.id.normalizedModelPath
            )
        }
        guard source.id.checksum == source.checksum else {
            throw GModMetalDynamicEntitySceneError.invalidResourceIdentity(
                id: source.id,
                field: "checksum"
            )
        }
        guard source.id.lodIndex == source.lodIndex,
              source.lodIndex >= 0 else {
            throw GModMetalDynamicEntitySceneError.invalidResourceIdentity(
                id: source.id,
                field: "LOD index"
            )
        }
        guard source.id.bodyValue == source.bodyValue, source.bodyValue >= 0 else {
            throw GModMetalDynamicEntitySceneError.invalidResourceIdentity(
                id: source.id,
                field: "body value"
            )
        }
        guard source.id.skinFamilyIndex == source.skinFamilyIndex,
              source.skinFamilyIndex >= 0 else {
            throw GModMetalDynamicEntitySceneError.invalidResourceIdentity(
                id: source.id,
                field: "skin family"
            )
        }
        if case let .animated(sequence, blend, animation, frame) =
            source.id.geometryIdentity {
            guard sequence >= 0, blend >= 0, animation >= 0, frame >= 0 else {
                throw GModMetalDynamicEntitySceneError.invalidResourceIdentity(
                    id: source.id,
                    field: "animation geometry identity"
                )
            }
        }
        guard !source.modelName.isEmpty,
              !source.modelName.utf8.contains(0) else {
            throw GModMetalDynamicEntitySceneError.invalidResourceIdentity(
                id: source.id,
                field: "model name"
            )
        }
        guard !source.vertices.isEmpty, !source.indices.isEmpty,
              !source.drawRanges.isEmpty else {
            throw GModMetalDynamicEntitySceneError.emptyResourceGeometry(source.id)
        }
        guard source.indices.count.isMultiple(of: 3) else {
            throw GModMetalDynamicEntitySceneError.invalidDrawRange(
                id: source.id,
                index: 0,
                reason: "triangle index count is \(source.indices.count)"
            )
        }

        var vertices: [GModMetalDynamicEntityVertex] = []
        vertices.reserveCapacity(source.vertices.count)
        for (index, vertex) in source.vertices.enumerated() {
            let position = simd(vertex.position)
            let normal = simd(vertex.normal)
            guard position.isGModMetalFinite else {
                throw GModMetalDynamicEntitySceneError.invalidVertex(
                    id: source.id,
                    index: index,
                    field: "position"
                )
            }
            let normalLengthSquared = normal.x * normal.x +
                normal.y * normal.y + normal.z * normal.z
            guard normal.isGModMetalFinite,
                  normalLengthSquared.isFinite,
                  normalLengthSquared > 0 else {
                throw GModMetalDynamicEntitySceneError.invalidVertex(
                    id: source.id,
                    index: index,
                    field: "normal"
                )
            }
            guard vertex.textureCoordinate.x.isFinite,
                  vertex.textureCoordinate.y.isFinite else {
                throw GModMetalDynamicEntitySceneError.invalidVertex(
                    id: source.id,
                    index: index,
                    field: "texture coordinate"
                )
            }
            vertices.append(GModMetalDynamicEntityVertex(
                metalLocalPosition: GModMetalWorldScene.convertSourceVector(position),
                metalLocalNormal: GModMetalWorldScene.convertSourceVector(normal),
                textureCoordinate: vertex.textureCoordinate
            ))
        }

        for (position, value) in source.indices.enumerated() {
            guard UInt64(value) < UInt64(vertices.count) else {
                throw GModMetalDynamicEntitySceneError.invalidIndex(
                    id: source.id,
                    position: position,
                    value: value,
                    vertexCount: vertices.count
                )
            }
        }

        var coveredIndexCount = 0
        var metadataBytes = stringBytes(source.id.normalizedModelPath)
        metadataBytes = try addMetadataBytes(
            stringBytes(source.modelName),
            to: metadataBytes
        )
        for (index, range) in source.drawRanges.enumerated() {
            guard range.bodyPartIndex >= 0,
                  range.submodelIndex >= 0,
                  range.meshIndex >= 0 else {
                throw GModMetalDynamicEntitySceneError.invalidDrawRange(
                    id: source.id,
                    index: index,
                    reason: "negative Studio mesh identity"
                )
            }
            guard range.firstIndex == coveredIndexCount,
                  range.indexCount > 0,
                  range.indexCount.isMultiple(of: 3),
                  range.firstIndex <= source.indices.count,
                  range.indexCount <= source.indices.count - range.firstIndex else {
                throw GModMetalDynamicEntitySceneError.invalidDrawRange(
                    id: source.id,
                    index: index,
                    reason: "non-contiguous or out-of-bounds index span"
                )
            }
            guard range.material.sourceMaterialIndex >= 0,
                  range.material.textureIndex >= 0,
                  range.material.skinFamilyIndex == source.skinFamilyIndex,
                  !range.material.textureName.isEmpty,
                  !range.material.textureName.utf8.contains(0),
                  !range.material.vmtCandidates.isEmpty else {
                throw GModMetalDynamicEntitySceneError.invalidDrawRange(
                    id: source.id,
                    index: index,
                    reason: "invalid Studio material identity"
                )
            }
            metadataBytes = try addMetadataBytes(
                stringBytes(range.material.textureName),
                to: metadataBytes
            )
            for candidate in range.material.vmtCandidates {
                guard isLogicalVMTPath(candidate) else {
                    throw GModMetalDynamicEntitySceneError.invalidDrawRange(
                        id: source.id,
                        index: index,
                        reason: "invalid VMT candidate '\(candidate)'"
                    )
                }
                metadataBytes = try addMetadataBytes(
                    stringBytes(candidate),
                    to: metadataBytes
                )
            }
            coveredIndexCount += range.indexCount
        }
        guard coveredIndexCount == source.indices.count else {
            throw GModMetalDynamicEntitySceneError.drawRangesDoNotCoverIndices(
                id: source.id,
                covered: coveredIndexCount,
                indexCount: source.indices.count
            )
        }

        let vertexBytes = try multipliedBytes(
            vertices.count,
            by: MemoryLayout<GModMetalDynamicEntityVertex>.stride
        )
        let indexBytes = try multipliedBytes(
            source.indices.count,
            by: MemoryLayout<UInt32>.stride
        )
        let (geometryBytes, geometryOverflow) = vertexBytes
            .addingReportingOverflow(indexBytes)
        guard !geometryOverflow else {
            throw GModMetalDynamicEntitySceneError.geometryByteCountOverflow
        }
        return GModMetalDynamicEntityResource(
            id: source.id,
            modelName: source.modelName,
            lodIndex: source.lodIndex,
            vertices: vertices,
            indices: source.indices,
            drawRanges: source.drawRanges,
            geometryByteCount: geometryBytes,
            metadataUTF8ByteCount: metadataBytes
        )
    }

    static func instanceOrder(
        _ lhs: GModMetalDynamicEntityInstanceInput,
        _ rhs: GModMetalDynamicEntityInstanceInput
    ) -> Bool {
        if lhs.identity.entryIndex != rhs.identity.entryIndex {
            return lhs.identity.entryIndex < rhs.identity.entryIndex
        }
        return lhs.identity.handle.rawValue < rhs.identity.handle.rawValue
    }

    static func convertInstances(
        _ sourceInstances: [GModMetalDynamicEntityInstanceInput],
        resourceIDs: Set<GModMetalDynamicEntityResourceID>,
        maximumInstanceCount: Int,
        minimumRevisionByHandle: [UInt32: UInt64] = [:]
    ) throws -> [GModMetalDynamicEntityInstance] {
        try requireCount(
            sourceInstances.count,
            cap: maximumInstanceCount,
            kind: "instance"
        )
        var handles = Set<UInt32>()
        var handlesByEntry: [Int: UInt32] = [:]
        var converted: [GModMetalDynamicEntityInstance] = []
        converted.reserveCapacity(sourceInstances.count)
        for source in sourceInstances.sorted(by: instanceOrder) {
            let handle = source.identity.handle.rawValue
            guard handles.insert(handle).inserted else {
                throw GModMetalDynamicEntitySceneError.duplicateEntityHandle(handle)
            }
            if let first = handlesByEntry[source.identity.entryIndex] {
                throw GModMetalDynamicEntitySceneError.duplicateEntityEntryIndex(
                    entryIndex: source.identity.entryIndex,
                    firstHandle: first,
                    secondHandle: handle
                )
            }
            handlesByEntry[source.identity.entryIndex] = handle
            if let priorRevision = minimumRevisionByHandle[handle],
               source.sourceEntityRevision < priorRevision {
                throw GModMetalDynamicEntitySceneError
                    .sourceEntityRevisionWentBackwards(
                        handle: handle,
                        previous: priorRevision,
                        received: source.sourceEntityRevision
                    )
            }
            guard resourceIDs.contains(source.resourceID) else {
                throw GModMetalDynamicEntitySceneError.missingInstanceResource(
                    handle: handle,
                    resourceID: source.resourceID
                )
            }
            guard isFinite(source.transform) else {
                throw GModMetalDynamicEntitySceneError.invalidInstanceTransform(
                    handle: handle
                )
            }
            let metalTransform = GModMetalDynamicEntityTransform(
                sourceTransform: source.transform
            )
            guard metalTransform.isFinite else {
                throw GModMetalDynamicEntitySceneError.invalidInstanceTransform(
                    handle: handle
                )
            }
            converted.append(GModMetalDynamicEntityInstance(
                identity: source.identity,
                sourceEntityRevision: source.sourceEntityRevision,
                sourceTransform: source.transform,
                metalTransform: metalTransform,
                resourceID: source.resourceID,
                colorModulation: source.colorModulation,
                renderMode: source.renderMode,
                renderFX: source.renderFX
            ))
        }
        return converted
    }

    static func requireCount(_ count: Int, cap: Int, kind: String) throws {
        guard count <= cap else {
            throw GModMetalDynamicEntitySceneError.countBudgetExceeded(
                kind: kind,
                requested: count,
                cap: cap
            )
        }
    }

    static func addingCount(
        _ addition: Int,
        to current: Int,
        cap: Int,
        kind: String
    ) throws -> Int {
        let (result, overflow) = current.addingReportingOverflow(addition)
        guard !overflow, result <= cap else {
            throw GModMetalDynamicEntitySceneError.countBudgetExceeded(
                kind: kind,
                requested: overflow ? Int.max : result,
                cap: cap
            )
        }
        return result
    }

    static func addingBytes(
        _ addition: Int,
        to current: Int,
        cap: Int,
        isMetadata: Bool
    ) throws -> Int {
        let (result, overflow) = current.addingReportingOverflow(addition)
        guard !overflow else {
            throw isMetadata
                ? GModMetalDynamicEntitySceneError.metadataByteCountOverflow
                : GModMetalDynamicEntitySceneError.geometryByteCountOverflow
        }
        guard result <= cap else {
            throw isMetadata
                ? GModMetalDynamicEntitySceneError.metadataByteBudgetExceeded(
                    requested: result,
                    cap: cap
                )
                : GModMetalDynamicEntitySceneError.geometryByteBudgetExceeded(
                    requested: result,
                    cap: cap
                )
        }
        return result
    }

    static func multipliedBytes(_ count: Int, by stride: Int) throws -> Int {
        let (result, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow else {
            throw GModMetalDynamicEntitySceneError.geometryByteCountOverflow
        }
        return result
    }

    static func addMetadataBytes(_ addition: Int, to current: Int) throws -> Int {
        let (result, overflow) = current.addingReportingOverflow(addition)
        guard !overflow else {
            throw GModMetalDynamicEntitySceneError.metadataByteCountOverflow
        }
        return result
    }

    static func stringBytes(_ value: String) -> Int {
        value.utf8.count
    }

    static func canonicalModelPath(_ path: String) -> String? {
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        let lowercased = slashed.lowercased()
        guard !slashed.isEmpty,
              slashed == path,
              lowercased == path,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              lowercased.hasPrefix("models/"),
              lowercased.hasSuffix(".mdl"),
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              !path.utf8.contains(0) else { return nil }
        return path
    }

    static func isLogicalVMTPath(_ path: String) -> Bool {
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        let lowercased = slashed.lowercased()
        return !path.isEmpty && slashed == path &&
            path == path.trimmingCharacters(in: .whitespacesAndNewlines) &&
            lowercased.hasPrefix("materials/") &&
            lowercased.hasSuffix(".vmt") &&
            !path.hasPrefix("/") &&
            !path.split(separator: "/").contains("..") &&
            !path.utf8.contains(0)
    }

    static func isFinite(_ transform: SourceEntityTransform) -> Bool {
        let origin = transform.origin
        let angles = transform.angles
        return origin.x.isFinite && origin.y.isFinite && origin.z.isFinite &&
            angles.pitch.isFinite && angles.yaw.isFinite && angles.roll.isFinite
    }

    static func simd(_ value: SourceVector3) -> SIMD3<Float> {
        SIMD3<Float>(value.x, value.y, value.z)
    }
}

private extension SIMD3 where Scalar == Float {
    var isGModMetalFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

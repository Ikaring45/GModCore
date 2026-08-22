import Foundation

/// Source's `fov_desired` is authored as a horizontal angle for a 4:3 base
/// viewport. Metal's perspective matrix accepts a vertical angle; feeding it
/// 75 degrees directly distorts terrain and weapon scale on iPad.
public enum GModMetalSourceFOVContract {
    public static func verticalRadians(
        baseHorizontalDegrees: Float,
        baseAspectRatio: Float = 4.0 / 3.0
    ) -> Float? {
        guard baseHorizontalDegrees.isFinite,
              baseHorizontalDegrees > 0,
              baseHorizontalDegrees < 180,
              baseAspectRatio.isFinite,
              baseAspectRatio > 0 else { return nil }
        let horizontal = baseHorizontalDegrees * .pi / 180
        return 2 * atan(tan(horizontal * 0.5) / baseAspectRatio)
    }

    public static let defaultWorldVerticalRadians =
        verticalRadians(baseHorizontalDegrees: 75)!
}

public enum GModMetalSkyboxFace: String, CaseIterable, Sendable, Equatable, Hashable {
    case right = "rt"
    case back = "bk"
    case left = "lf"
    case front = "ft"
    case up = "up"
    case down = "dn"
}

public enum GModMetalWorldRenderLayer: String, Sendable, Equatable, Hashable {
    case world
    case sky3D
    case sky2D
}

public enum GModMetalSkyboxVisibility: Sendable, Equatable {
    case notVisible
    case sky3D
    case sky2D
}

enum GModMetalSkyVisibilityRenderContract {
    static func draws2D(_ visibility: GModMetalSkyboxVisibility) -> Bool {
        visibility == .sky3D || visibility == .sky2D
    }

    static func draws3D(_ visibility: GModMetalSkyboxVisibility) -> Bool {
        visibility == .sky3D
    }
}

public struct GModMetalWorldSky3D: Sendable, Equatable {
    /// `sky_camera` origin in Source coordinates before mesh baking.
    public let sourceOrigin: SIMD3<Float>
    /// Positive Source `sky_camera` scale used by `(vertex - origin) * scale`.
    public let scale: Float

    public init(sourceOrigin: SIMD3<Float>, scale: Float) {
        self.sourceOrigin = sourceOrigin
        self.scale = scale
    }
}

/// Renderer-facing form of Source's compiled `light_environment` pair.
/// The original direction is retained for diagnostics while the Metal-space
/// surface-to-light vector is derived by the same orthonormal basis conversion
/// used for world normals.
public struct GModMetalWorldEnvironmentLighting: Sendable, Equatable {
    public let sourceDirectionFromLight: SIMD3<Float>
    public let metalDirectionToLight: SIMD3<Float>
    public let directLinearRGB: SIMD3<Float>
    public let ambientLinearRGB: SIMD3<Float>

    public init(
        sourceDirectionFromLight: SIMD3<Float>,
        directLinearRGB: SIMD3<Float>,
        ambientLinearRGB: SIMD3<Float>
    ) {
        self.sourceDirectionFromLight = sourceDirectionFromLight
        self.metalDirectionToLight = GModMetalWorldScene.convertSourceVector(
            -sourceDirectionFromLight
        )
        self.directLinearRGB = directLinearRGB
        self.ambientLinearRGB = ambientLinearRGB
    }
}

public struct GModMetalWorldSunSpriteLayer: Sendable, Equatable {
    public let materialName: String
    public let displayRGB: SIMD3<Float>
    public let size: Float
    public let materialResolution: GModMetalWorldMaterialResolution
    public var bitmap: GModMetalSurfaceBitmap? { materialResolution.bitmap }

    public init(
        materialName: String,
        displayRGB: SIMD3<Float>,
        size: Float,
        materialResolution: GModMetalWorldMaterialResolution
    ) {
        self.materialName = materialName
        self.displayRGB = displayRGB
        self.size = size
        self.materialResolution = materialResolution
    }
}

public struct GModMetalWorldSunSprite: Sendable, Equatable {
    public let sourceDirectionToSun: SIMD3<Float>
    public let metalDirectionToSun: SIMD3<Float>
    public let hdrColorScale: Float
    public let core: GModMetalWorldSunSpriteLayer
    public let overlay: GModMetalWorldSunSpriteLayer

    public init(
        sourceDirectionToSun: SIMD3<Float>,
        hdrColorScale: Float,
        core: GModMetalWorldSunSpriteLayer,
        overlay: GModMetalWorldSunSpriteLayer
    ) {
        self.sourceDirectionToSun = sourceDirectionToSun
        self.metalDirectionToSun = GModMetalWorldScene.convertSourceVector(
            sourceDirectionToSun
        )
        self.hdrColorScale = hdrColorScale
        self.core = core
        self.overlay = overlay
    }
}

struct GModMetalSunSpriteDrawParameters: Sendable, Equatable {
    let basePosition: SIMD3<Float>
    let rightExtent: SIMD3<Float>
    let upExtent: SIMD3<Float>
    let displayRGB: SIMD3<Float>
    let opacity: Float
    let hdrColorScale: Float
}

enum GModMetalSunSpriteLayerRole: Sendable, Equatable {
    case core
    case overlay
}

/// Source SDK 2013 `C_SunGlowOverlay` sizing/color modulation and inherited
/// directional billboard math. Static/dynamic opaque geometry is rendered
/// after this sky pass and provides the geometry obstruction boundary.
enum GModMetalSunSpriteRenderContract {
    static let distance: Float = 100
    static let overlayFadeStartDot: Float = 0.9
    static let overlayMaximumOpacity: Float = 0.75
    static let overlaySizeMultiplier: Float = 6

    static func parameters(
        sun: GModMetalWorldSunSprite,
        layer: GModMetalWorldSunSpriteLayer,
        role: GModMetalSunSpriteLayerRole,
        cameraEye: SIMD3<Float>,
        cameraForward: SIMD3<Float>
    ) -> GModMetalSunSpriteDrawParameters? {
        guard let direction = normalized(sun.metalDirectionToSun),
              let forward = normalized(cameraForward),
              layer.size.isFinite, layer.size > 0,
              sun.hdrColorScale.isFinite, sun.hdrColorScale >= 0,
              finite(layer.displayRGB) else { return nil }
        let viewDot = dot(direction, forward)
        let opacity: Float
        let sizeMultiplier: Float
        switch role {
        case .core:
            opacity = 1
            sizeMultiplier = 1
        case .overlay:
            opacity = Swift.min(
                overlayMaximumOpacity,
                Swift.max(
                    0,
                    (viewDot - overlayFadeStartDot) /
                        (1 - overlayFadeStartDot) * overlayMaximumOpacity
                )
            )
            sizeMultiplier = overlaySizeMultiplier
            guard opacity > 0 else { return nil }
        }
        let extent = layer.size * sizeMultiplier
        let worldUp = SIMD3<Float>(0, 1, 0)
        guard let right = normalized(cross(direction, worldUp)),
              let up = normalized(cross(right, direction)) else { return nil }
        return GModMetalSunSpriteDrawParameters(
            basePosition: cameraEye + direction * distance,
            rightExtent: right * extent,
            upExtent: up * extent,
            displayRGB: layer.displayRGB,
            opacity: opacity,
            hdrColorScale: sun.hdrColorScale
        )
    }

    private static func finite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func dot(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func normalized(
        _ value: SIMD3<Float>
    ) -> SIMD3<Float>? {
        guard finite(value) else { return nil }
        let lengthSquared = dot(value, value)
        guard lengthSquared > Float.ulpOfOne else { return nil }
        return value / lengthSquared.squareRoot()
    }
}

public enum GModMetalTextureFilter: Sendable, Equatable, Hashable {
    case nearest
    case linear
}

public enum GModMetalTextureMipFilter: Sendable, Equatable, Hashable {
    case notMipmapped
    case nearest
    case linear
}

public enum GModMetalTextureAddressMode: Sendable, Equatable, Hashable {
    case `repeat`
    case clampToEdge
}

/// Metal-independent sampler policy derived from the real VTF header. This is
/// intentionally test-visible so point/no-mip/clamp semantics cannot regress
/// into a blanket blur workaround.
public struct GModMetalWorldSamplerConfiguration: Sendable, Equatable, Hashable {
    public let minFilter: GModMetalTextureFilter
    public let magFilter: GModMetalTextureFilter
    public let mipFilter: GModMetalTextureMipFilter
    public let sAddressMode: GModMetalTextureAddressMode
    public let tAddressMode: GModMetalTextureAddressMode
    public let maximumAnisotropy: Int

    public init(
        bitmap: GModMetalSurfaceBitmap,
        renderLayer: GModMetalWorldRenderLayer
    ) {
        let flags = bitmap.sourceTextureFlags ?? []
        let point = flags.contains(.pointSample)
        minFilter = point ? .nearest : .linear
        magFilter = point ? .nearest : .linear
        if bitmap.mipLevels.count <= 1 || flags.contains(.noMip) {
            mipFilter = .notMipmapped
        } else if flags.contains(.trilinear) || flags.contains(.anisotropic) {
            mipFilter = .linear
        } else {
            mipFilter = .nearest
        }
        let forceSkyClamp = renderLayer == .sky2D
        sAddressMode = forceSkyClamp || flags.contains(.clampS)
            ? .clampToEdge
            : .repeat
        tAddressMode = forceSkyClamp || flags.contains(.clampT)
            ? .clampToEdge
            : .repeat
        maximumAnisotropy = flags.contains(.anisotropic) &&
            mipFilter != .notMipmapped
                ? GModMetalSamplerContract.maximumAnisotropy
                : 1
    }
}

/// App-side CPU retention budget for immutable world textures. Material ranges
/// can reference the same decoded bitmap in multiple Source render layers; the
/// bytes are charged once by cache identity while every range keeps the value.
public struct GModMetalWorldBitmapRetentionBudget: Sendable, Equatable {
    public static let defaultMaximumByteCount = 128 * 1_024 * 1_024

    public let maximumByteCount: Int
    public private(set) var retainedByteCount = 0
    private var retainedIdentifiers = Set<String>()

    public init(maximumByteCount: Int) {
        self.maximumByteCount = Swift.max(0, maximumByteCount)
    }

    public mutating func retain(_ bitmap: GModMetalSurfaceBitmap) -> Bool {
        if retainedIdentifiers.contains(bitmap.cacheIdentifier) {
            return true
        }
        let required = bitmap.totalByteCount
        guard required <= maximumByteCount,
              retainedByteCount <= maximumByteCount - required else {
            return false
        }
        retainedIdentifiers.insert(bitmap.cacheIdentifier)
        retainedByteCount += required
        return true
    }
}

/// Test-visible policy shared by scene construction and the Metal pass. A
/// Source 2D sky follows camera rotation only, is drawn as the background, and
/// must never occlude ordinary world geometry.
enum GModMetalSkyboxRenderContract {
    static let cameraEye = SIMD3<Float>.zero
    static let depthCompareAlwaysPasses = true
    static let depthWritesEnabled = false
}

enum GModMetalWorldPassOrderContract {
    static let orderedLayers: [GModMetalWorldRenderLayer] = [
        .sky2D, .sky3D, .world,
    ]
    static let clearsDepthBetweenSkyAndWorld = true
}

/// Valve's `CSkyboxView::DrawInternal` uses zNear 2 and
/// `MAX_TRACE_LENGTH` in miniature sky space. Because this renderer bakes
/// `(vertex - skyOrigin) * scale`, both clip planes must be multiplied by the
/// same real `sky_camera` scale to remain projection-equivalent.
enum GModMetalSky3DProjectionContract {
    static let sourceNear: Float = 2
    static let maximumCoordinate: Float = 16_384
    static let sourceFar: Float = Float(3).squareRoot() * 2 * maximumCoordinate

    static func bakedClipPlanes(scale: Float) -> (near: Float, far: Float) {
        (sourceNear * scale, sourceFar * scale)
    }

    static func sourceCameraEye(
        worldEye: SIMD3<Float>,
        sky: GModMetalWorldSky3D
    ) -> SIMD3<Float> {
        sky.sourceOrigin + worldEye / sky.scale
    }
}

public struct GModMetalWorldWaterSurface: Sendable, Equatable {
    public let surfaceZ: Float
    public let minimumZ: Float

    public init(surfaceZ: Float, minimumZ: Float) {
        self.surfaceZ = surfaceZ
        self.minimumZ = minimumZ
    }
}

public struct GModMetalWorldWaterMaterial: Sendable, Equatable {
    public let resourceIdentifier: String
    public let isAboveWater: Bool
    public let fogColor: SIMD3<Float>
    public let fogStart: Float?
    public let fogEnd: Float?
    public let reflectionAmount: Float?
    public let refractionAmount: Float?
    public let normalBitmap: GModMetalSurfaceBitmap?
    public let textureScrollRate: Float?
    public let textureScrollAngleDegrees: Float?
    public let unsupportedBumpTextureFormat: String?

    public init(
        resourceIdentifier: String,
        isAboveWater: Bool,
        fogColor: SIMD3<Float>,
        fogStart: Float?,
        fogEnd: Float?,
        reflectionAmount: Float?,
        refractionAmount: Float?,
        normalBitmap: GModMetalSurfaceBitmap?,
        textureScrollRate: Float?,
        textureScrollAngleDegrees: Float?,
        unsupportedBumpTextureFormat: String?
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.isAboveWater = isAboveWater
        self.fogColor = fogColor
        self.fogStart = fogStart
        self.fogEnd = fogEnd
        self.reflectionAmount = reflectionAmount
        self.refractionAmount = refractionAmount
        self.normalBitmap = normalBitmap
        self.textureScrollRate = textureScrollRate
        self.textureScrollAngleDegrees = textureScrollAngleDegrees
        self.unsupportedBumpTextureFormat = unsupportedBumpTextureFormat
    }

    /// Preserves every authored Water VMT value while allowing the shared
    /// scene-retention boundary to fall back to the solid-water pipeline.
    public func withoutNormalBitmap() -> Self {
        guard normalBitmap != nil else { return self }
        return Self(
            resourceIdentifier: resourceIdentifier,
            isAboveWater: isAboveWater,
            fogColor: fogColor,
            fogStart: fogStart,
            fogEnd: fogEnd,
            reflectionAmount: reflectionAmount,
            refractionAmount: refractionAmount,
            normalBitmap: nil,
            textureScrollRate: textureScrollRate,
            textureScrollAngleDegrees: textureScrollAngleDegrees,
            unsupportedBumpTextureFormat: unsupportedBumpTextureFormat
        )
    }
}

enum GModMetalWaterRenderContract {
    static func shouldRender(
        _ material: GModMetalWorldWaterMaterial,
        surface: GModMetalWorldWaterSurface,
        cameraZ: Float
    ) -> Bool {
        (cameraZ >= surface.surfaceZ) == material.isAboveWater
    }
}

/// Cache ownership follows the immutable scene's complete texture references,
/// not the current PVS/sky/water visibility. Camera-only scene replacements
/// therefore keep valid bindings without retaining assets removed by a real
/// replacement scene.
enum GModMetalWorldTextureCacheContract {
    static func key(
        for bitmap: GModMetalSurfaceBitmap,
        isSRGB: Bool
    ) -> String {
        (isSRGB ? "srgb:" : "linear:") + bitmap.cacheIdentifier
    }

    static func retainedKeys(for scene: GModMetalWorldScene) -> Set<String> {
        var keys = Set<String>()
        for range in scene.materialRanges {
            if let bitmap = range.bitmap {
                keys.insert(key(for: bitmap, isSRGB: true))
            }
            if let normalBitmap = range.waterMaterial?.normalBitmap {
                keys.insert(key(for: normalBitmap, isSRGB: false))
            }
        }
        for sun in scene.sunSprites {
            for layer in [sun.core, sun.overlay] {
                if let bitmap = layer.bitmap {
                    keys.insert(key(for: bitmap, isSRGB: true))
                }
            }
        }
        return keys
    }

    static func staleKeys(
        cachedKeys: Set<String>,
        for scene: GModMetalWorldScene
    ) -> Set<String> {
        cachedKeys.subtracting(retainedKeys(for: scene))
    }
}

struct GModMetalWaterDependentTextureCoordinates: Sendable, Equatable {
    let reflection: SIMD2<Float>
    let refraction: SIMD2<Float>
}

/// Source's Water pixel shader treats `$reflectamount` and `$refractamount`
/// as independent, signed distortion scales. They are not opacity values and
/// are not normalized by render-target dimensions.
enum GModMetalWaterSamplingContract {
    /// Mirrors `water_ps2x_helper.h`: the tangent-space eye vector has already
    /// been normalized before `saturate(dot(eye, normal))` is evaluated.
    static func fresnel(
        normal: SIMD3<Float>,
        normalizedEyeVector: SIMD3<Float>
    ) -> Float {
        let dotProduct = normal.x * normalizedEyeVector.x +
            normal.y * normalizedEyeVector.y +
            normal.z * normalizedEyeVector.z
        let nDotV = Swift.min(1, Swift.max(0, dotProduct))
        let oneMinusNDotV = 1 - nDotV
        let squared = oneMinusNDotV * oneMinusNDotV
        return squared * squared * oneMinusNDotV
    }

    /// Mirrors the dependent texture-coordinate calculation in
    /// `water_ps2x_helper.h`. Normal alpha scales both offsets, while each VMT
    /// amount remains separate and signed.
    static func dependentTextureCoordinates(
        reflectionBase: SIMD2<Float>,
        refractionBase: SIMD2<Float>,
        decodedNormal: SIMD4<Float>,
        reflectionAmount: Float,
        refractionAmount: Float
    ) -> GModMetalWaterDependentTextureCoordinates {
        let normalOffset = SIMD2<Float>(
            decodedNormal.x * decodedNormal.w,
            decodedNormal.y * decodedNormal.w
        )
        return GModMetalWaterDependentTextureCoordinates(
            reflection: reflectionBase + normalOffset * reflectionAmount,
            refraction: refractionBase + normalOffset * refractionAmount
        )
    }
}

/// A single Source water plane can share one reflected view for every material
/// range on that plane. Multiple visible heights require separate reflected
/// views and therefore stay on the diagnosed fallback path instead of sampling
/// a render target produced for the wrong plane.
struct GModMetalWaterRenderTargetPlan: Sendable, Equatable {
    let sourceSurfaceZ: Float
    let requiresReflection: Bool
    let requiresRefraction: Bool
}

enum GModMetalWaterRenderTargetContract {
    static func plan(
        materialRanges: [GModMetalWorldMaterialRange],
        cameraZ: Float
    ) -> GModMetalWaterRenderTargetPlan? {
        let visible = materialRanges.compactMap {
            range -> (surface: GModMetalWorldWaterSurface,
                      material: GModMetalWorldWaterMaterial)? in
            guard range.renderLayer == .world,
                  let surface = range.waterSurface,
                  let material = range.waterMaterial,
                  GModMetalWaterRenderContract.shouldRender(
                    material,
                    surface: surface,
                    cameraZ: cameraZ
                  ) else { return nil }
            guard material.reflectionAmount != nil ||
                    material.refractionAmount != nil else { return nil }
            return (surface, material)
        }
        guard let first = visible.first else { return nil }
        let surfaceBits = Set(visible.map { $0.surface.surfaceZ.bitPattern })
        guard surfaceBits.count == 1 else { return nil }
        return GModMetalWaterRenderTargetPlan(
            sourceSurfaceZ: first.surface.surfaceZ,
            // `CUnderWaterView` creates only an out-of-water refraction view;
            // Source's reflected view belongs to `CAboveWaterView`.
            requiresReflection: cameraZ >= first.surface.surfaceZ &&
                visible.contains { $0.material.reflectionAmount != nil },
            requiresRefraction: visible.contains {
                $0.material.refractionAmount != nil
            }
        )
    }
}

struct GModMetalWaterReflectedCamera: Sendable, Equatable {
    let eye: SIMD3<Float>
    let forward: SIMD3<Float>
    let up: SIMD3<Float>
}

enum GModMetalWaterReflectionContract {
    /// Source Z maps to Metal Y. Forward is reflected across the water plane;
    /// up is reflected and then negated. This lets `makeViewMatrix` rebuild a
    /// reflected right vector instead of horizontally mirroring the image.
    static func reflectedCamera(
        eye: SIMD3<Float>,
        forward: SIMD3<Float>,
        up: SIMD3<Float>,
        sourceSurfaceZ: Float
    ) -> GModMetalWaterReflectedCamera {
        GModMetalWaterReflectedCamera(
            eye: SIMD3<Float>(
                eye.x,
                sourceSurfaceZ * 2 - eye.y,
                eye.z
            ),
            forward: SIMD3<Float>(forward.x, -forward.y, forward.z),
            up: SIMD3<Float>(-up.x, up.y, -up.z)
        )
    }
}

/// Signed Metal-space clipping planes for Source water render targets.
/// Source Z maps to Metal Y; positions whose signed distance is non-negative
/// are retained. Refraction keeps the half-space across the water from the
/// real camera, while reflection keeps the camera's own half-space.
enum GModMetalWaterClipPlaneContract {
    static let disabled = SIMD4<Float>(0, 0, 0, 1)
    /// `CBaseWorldView::PushView` expands the retained side by two Source
    /// units to keep geometry at the water boundary from leaving a seam.
    static let sourceFudge: Float = 2

    static func underwaterMain(sourceSurfaceZ: Float) -> SIMD4<Float> {
        SIMD4<Float>(0, -1, 0, sourceSurfaceZ + sourceFudge)
    }

    static func refraction(
        sourceSurfaceZ: Float,
        sourceCameraZ: Float
    ) -> SIMD4<Float> {
        if sourceCameraZ >= sourceSurfaceZ {
            return SIMD4<Float>(
                0,
                -1,
                0,
                sourceSurfaceZ + sourceFudge
            )
        }
        return SIMD4<Float>(
            0,
            1,
            0,
            -sourceSurfaceZ + sourceFudge
        )
    }

    static func reflection(
        sourceSurfaceZ: Float,
        sourceCameraZ: Float
    ) -> SIMD4<Float> {
        if sourceCameraZ >= sourceSurfaceZ {
            return SIMD4<Float>(
                0,
                1,
                0,
                -sourceSurfaceZ + sourceFudge
            )
        }
        return SIMD4<Float>(
            0,
            -1,
            0,
            sourceSurfaceZ + sourceFudge
        )
    }

    static func retains(
        metalPosition: SIMD3<Float>,
        plane: SIMD4<Float>
    ) -> Bool {
        metalPosition.x * plane.x +
            metalPosition.y * plane.y +
            metalPosition.z * plane.z + plane.w >= 0
    }
}

/// Preserves why a Source material did or did not become a retained CPU
/// bitmap. Renderer upload readiness waits only for `.resolved`; every other
/// outcome is permanent for this immutable scene and remains available to the
/// Problems model instead of being collapsed into a nil bitmap.
public enum GModMetalWorldMaterialResolution: Sendable, Equatable {
    case notApplicable
    case resolved(GModMetalSurfaceBitmap)
    case sourceMissing
    case decodeFailed(String)
    case retentionCapacityExceeded(
        requiredByteCount: Int,
        retainedByteCount: Int,
        maximumByteCount: Int
    )

    public var bitmap: GModMetalSurfaceBitmap? {
        guard case let .resolved(bitmap) = self else { return nil }
        return bitmap
    }
}

public struct GModMetalWorldMaterialRange: Sendable, Equatable {
    public let materialName: String?
    public let firstIndex: Int
    public let indexCount: Int
    public let materialResolution: GModMetalWorldMaterialResolution
    public var bitmap: GModMetalSurfaceBitmap? { materialResolution.bitmap }
    public let skyboxName: String?
    public let skyboxFace: GModMetalSkyboxFace?
    public let waterSurface: GModMetalWorldWaterSurface?
    public let waterMaterial: GModMetalWorldWaterMaterial?
    public let renderLayer: GModMetalWorldRenderLayer
    public var samplerConfiguration: GModMetalWorldSamplerConfiguration? {
        bitmap.map {
            GModMetalWorldSamplerConfiguration(
                bitmap: $0,
                renderLayer: renderLayer
            )
        }
    }

    public init(
        materialName: String?,
        firstIndex: Int,
        indexCount: Int,
        bitmap: GModMetalSurfaceBitmap?,
        waterSurface: GModMetalWorldWaterSurface? = nil,
        waterMaterial: GModMetalWorldWaterMaterial? = nil,
        renderLayer: GModMetalWorldRenderLayer = .world
    ) {
        self.materialName = materialName
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.waterSurface = waterSurface
        self.waterMaterial = waterMaterial
        self.renderLayer = renderLayer
        if let bitmap {
            materialResolution = .resolved(bitmap)
        } else if waterSurface != nil || materialName == nil {
            materialResolution = .notApplicable
        } else {
            materialResolution = .sourceMissing
        }
        let skybox = renderLayer == .sky2D
            ? Self.skyboxBinding(for: materialName)
            : nil
        skyboxName = skybox?.name
        skyboxFace = skybox?.face
    }

    public init(
        materialName: String?,
        firstIndex: Int,
        indexCount: Int,
        materialResolution: GModMetalWorldMaterialResolution,
        waterSurface: GModMetalWorldWaterSurface? = nil,
        waterMaterial: GModMetalWorldWaterMaterial? = nil,
        renderLayer: GModMetalWorldRenderLayer = .world
    ) {
        self.materialName = materialName
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.materialResolution = materialResolution
        self.waterSurface = waterSurface
        self.waterMaterial = waterMaterial
        self.renderLayer = renderLayer
        let skybox = renderLayer == .sky2D
            ? Self.skyboxBinding(for: materialName)
            : nil
        skyboxName = skybox?.name
        skyboxFace = skybox?.face
    }

    private static func skyboxBinding(
        for materialName: String?
    ) -> (name: String, face: GModMetalSkyboxFace)? {
        guard var normalized = materialName?
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            normalized.hasPrefix("skybox/") else { return nil }
        normalized.removeFirst("skybox/".count)
        guard let face = GModMetalSkyboxFace.allCases.first(where: {
            normalized.hasSuffix($0.rawValue)
        }) else { return nil }
        normalized.removeLast(face.rawValue.count)
        guard !normalized.isEmpty else { return nil }
        return (normalized, face)
    }
}

public struct GModMetalWorldMaterialDiagnostics: Sendable, Equatable {
    public let worldMaterialRangeCount: Int
    public let resolvedWorldMaterialRangeCount: Int
    public let missingWorldMaterialRangeCount: Int
    public let unnamedWorldFallbackRangeCount: Int
    public let unresolvedWorldMaterialNames: [String]
    public let skyboxName: String?
    public let skyboxFaceRangeCount: Int
    public let resolvedSkyboxFaceCount: Int
    public let missingSkyboxMaterialNames: [String]
    public let waterMaterialRangeCount: Int
    public let resolvedWaterMaterialRangeCount: Int
    public let unsupportedWaterBumpTextureNames: [String]
    public let sourceMissingMaterialNames: [String]
    public let decodeFailedMaterialNames: [String]
    public let retentionCapacityExceededMaterialNames: [String]
}

/// A real, mesh-scoped renderer lifecycle. A frame is presentable only after
/// every resolvable texture required by that encoded scene is resident and the
/// GPU command buffer completes. Permanent Source misses remain Problems and
/// intentionally do not block this lifecycle.
public struct GModMetalWorldTextureUploadProgress: Sendable, Equatable {
    public let meshIdentifier: String
    public let uploadedTextureCount: Int
    public let requiredTextureCount: Int

    public init(
        meshIdentifier: String,
        uploadedTextureCount: Int,
        requiredTextureCount: Int
    ) {
        self.meshIdentifier = meshIdentifier
        self.uploadedTextureCount = uploadedTextureCount
        self.requiredTextureCount = requiredTextureCount
    }
}

public enum GModMetalWorldRendererFailureReason: Sendable, Equatable {
    case metalDeviceUnavailable
    case setupFailed(String)
    case sceneRejected(String)
    case lightmapUploadFailed(resourceIdentifier: String, detail: String)
    case textureUploadFailed(
        resourceIdentifier: String,
        byteCount: Int,
        detail: String
    )
    case commandBufferCreationFailed
    case renderEncoderCreationFailed
    case commandBufferFailed(status: String, detail: String?)

    public var diagnosticDescription: String {
        switch self {
        case .metalDeviceUnavailable:
            return "Metal device unavailable"
        case let .setupFailed(detail):
            return "Metal renderer setup failed: \(detail)"
        case let .sceneRejected(detail):
            return "Metal world scene rejected: \(detail)"
        case let .lightmapUploadFailed(resourceIdentifier, detail):
            return "Metal lightmap upload failed for \(resourceIdentifier): \(detail)"
        case let .textureUploadFailed(resourceIdentifier, byteCount, detail):
            return "Metal texture upload failed for \(resourceIdentifier) " +
                "(\(byteCount) bytes): \(detail)"
        case .commandBufferCreationFailed:
            return "Metal command buffer creation failed"
        case .renderEncoderCreationFailed:
            return "Metal render encoder creation failed"
        case let .commandBufferFailed(status, detail):
            let suffix = detail.map { ": \($0)" } ?? ""
            return "Metal command buffer failed (\(status))\(suffix)"
        }
    }
}

public struct GModMetalWorldRendererFailure: Sendable, Equatable {
    public let meshIdentifier: String
    public let reason: GModMetalWorldRendererFailureReason

    public init(
        meshIdentifier: String,
        reason: GModMetalWorldRendererFailureReason
    ) {
        self.meshIdentifier = meshIdentifier
        self.reason = reason
    }
}

public enum GModMetalWorldFrameEvent: Sendable, Equatable {
    case textureUploadProgress(GModMetalWorldTextureUploadProgress)
    case presented(meshIdentifier: String)
    case failed(GModMetalWorldRendererFailure)
}

public struct GModMetalWorldLightmapAtlas: Sendable, Equatable {
    public static let maximumWidth = 2_048
    public static let maximumHeight = 4_096
    public static let maximumByteCount = 64 * 1_024 * 1_024

    public let identifier: String
    public let width: Int
    public let height: Int
    /// Native little-endian RGBA16Float texels in Source linear-light space.
    public let linearRGBA16Float: Data

    public init(
        identifier: String,
        width: Int,
        height: Int,
        linearRGBA16Float: Data
    ) {
        self.identifier = identifier
        self.width = width
        self.height = height
        self.linearRGBA16Float = linearRGBA16Float
    }
}

public enum GModMetalWorldLightmapAtlasStatus: Sendable, Equatable {
    case unavailableNoLightmaps
    case built(width: Int, height: Int, byteCount: Int)
    case capacityExceeded(
        requiredWidth: Int,
        requiredHeight: Int,
        requiredByteCount: Int,
        maximumWidth: Int,
        maximumHeight: Int,
        maximumByteCount: Int
    )
}

public struct GModMetalWorldLightmapDiagnostics: Sendable, Equatable {
    public let atlasStatus: GModMetalWorldLightmapAtlasStatus
    public let ignoredAdditionalLightStyleFaceCount: Int
    public let ignoredBumpLightFaceCount: Int
    public let clampedChannelCount: Int

    public init(
        atlasStatus: GModMetalWorldLightmapAtlasStatus = .unavailableNoLightmaps,
        ignoredAdditionalLightStyleFaceCount: Int = 0,
        ignoredBumpLightFaceCount: Int = 0,
        clampedChannelCount: Int = 0
    ) {
        self.atlasStatus = atlasStatus
        self.ignoredAdditionalLightStyleFaceCount =
            ignoredAdditionalLightStyleFaceCount
        self.ignoredBumpLightFaceCount = ignoredBumpLightFaceCount
        self.clampedChannelCount = clampedChannelCount
    }
}

/// Test-visible decision used when the scene cannot supply a sampled atlas.
/// A capacity failure remains diagnosable and falls back to directional light;
/// it never manufactures a replacement lightmap.
enum GModMetalWorldLightmapRenderContract {
    static func fallbackReason(
        for status: GModMetalWorldLightmapAtlasStatus
    ) -> String? {
        switch status {
        case .unavailableNoLightmaps:
            return nil
        case let .built(width, height, byteCount):
            return "scene reports a built \(width)x\(height) / \(byteCount)-byte " +
                "lightmap atlas but supplied no atlas data"
        case let .capacityExceeded(
            requiredWidth,
            requiredHeight,
            requiredByteCount,
            maximumWidth,
            maximumHeight,
            maximumByteCount
        ):
            return "lightmap atlas requires \(requiredWidth)x\(requiredHeight) / " +
                "\(requiredByteCount) bytes; cap is \(maximumWidth)x" +
                "\(maximumHeight) / \(maximumByteCount) bytes"
        }
    }
}

/// Immutable renderer input for one static Source world mesh and its camera.
///
/// Source coordinates use +X forward, +Y left, and +Z up. Metal coordinates
/// use +X right, +Y up, and -Z forward. Both representations are retained so
/// the host/renderer boundary stays explicit and auditable.
///
/// The base-texture and baked-lightmap UV streams stay distinct. The optional
/// bounded RGBA16Float atlas carries Valve's unclamped linear RGB-exponent
/// samples; material-specific styles and bump-light planes remain explicit
/// diagnostics rather than being fabricated.
public struct GModMetalWorldScene: Sendable, Equatable {
    /// Stable identity for the geometry. Change this value whenever any mesh
    /// position, normal, or index changes so the renderer refreshes its cache.
    public let meshIdentifier: String

    public let sourcePositions: [SIMD3<Float>]
    public let sourceNormals: [SIMD3<Float>]
    public let sourceTextureCoordinates: [SIMD2<Float>]
    public let sourceLightmapTextureCoordinates: [SIMD2<Float>]
    public let metalPositions: [SIMD3<Float>]
    public let metalNormals: [SIMD3<Float>]
    public let indices: [UInt32]
    public let materialRanges: [GModMetalWorldMaterialRange]
    public let materialDiagnostics: GModMetalWorldMaterialDiagnostics
    public let lightmapAtlas: GModMetalWorldLightmapAtlas?
    public let lightmapDiagnostics: GModMetalWorldLightmapDiagnostics
    public let environmentLighting: GModMetalWorldEnvironmentLighting?
    public let sunSprites: [GModMetalWorldSunSprite]
    public let sky3D: GModMetalWorldSky3D?
    public let skyboxVisibility: GModMetalSkyboxVisibility
    /// Fixed Source session time. Pause freezes this value, so material
    /// proxies such as TextureScroll freeze with the singleplayer world.
    public let sourceFixedTime: Float

    /// Camera values in Source coordinates.
    public let cameraEye: SIMD3<Float>
    public let cameraForward: SIMD3<Float>
    public let cameraUp: SIMD3<Float>

    /// Camera values converted to Metal coordinates.
    public let metalCameraEye: SIMD3<Float>
    public let metalCameraForward: SIMD3<Float>
    public let metalCameraUp: SIMD3<Float>

    /// A 2D Source skybox follows camera rotation but never camera translation.
    /// The renderer uses this zero eye for its dedicated sky pass.
    public let metalSkyboxCameraEye: SIMD3<Float> =
        GModMetalSkyboxRenderContract.cameraEye

    public init(
        meshIdentifier: String,
        sourcePositions: [SIMD3<Float>],
        sourceNormals: [SIMD3<Float>],
        sourceTextureCoordinates: [SIMD2<Float>] = [],
        sourceLightmapTextureCoordinates: [SIMD2<Float>] = [],
        indices: [UInt32],
        materialRanges: [GModMetalWorldMaterialRange] = [],
        lightmapAtlas: GModMetalWorldLightmapAtlas? = nil,
        lightmapDiagnostics: GModMetalWorldLightmapDiagnostics = .init(),
        environmentLighting: GModMetalWorldEnvironmentLighting? = nil,
        sunSprites: [GModMetalWorldSunSprite] = [],
        sky3D: GModMetalWorldSky3D? = nil,
        skyboxVisibility: GModMetalSkyboxVisibility = .notVisible,
        cameraEye: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        cameraUp: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        sourceFixedTime: Float = 0
    ) {
        self.meshIdentifier = meshIdentifier
        self.sourcePositions = sourcePositions
        self.sourceNormals = sourceNormals
        self.sourceTextureCoordinates = sourceTextureCoordinates.isEmpty
            ? Array(repeating: .zero, count: sourcePositions.count)
            : sourceTextureCoordinates
        self.sourceLightmapTextureCoordinates =
            sourceLightmapTextureCoordinates.isEmpty
                ? Array(repeating: .zero, count: sourcePositions.count)
                : sourceLightmapTextureCoordinates
        self.metalPositions = sourcePositions.map(Self.convertSourceVector)
        self.metalNormals = sourceNormals.map(Self.convertSourceVector)
        self.indices = indices
        self.materialRanges = materialRanges
        self.materialDiagnostics = Self.makeMaterialDiagnostics(materialRanges)
        self.lightmapAtlas = lightmapAtlas
        self.lightmapDiagnostics = lightmapDiagnostics
        self.environmentLighting = environmentLighting
        self.sunSprites = sunSprites
        self.sky3D = sky3D
        self.skyboxVisibility = skyboxVisibility
        self.sourceFixedTime = sourceFixedTime
        self.cameraEye = cameraEye
        self.cameraForward = cameraForward
        self.cameraUp = cameraUp
        self.metalCameraEye = Self.convertSourceVector(cameraEye)
        self.metalCameraForward = Self.convertSourceVector(cameraForward)
        self.metalCameraUp = Self.convertSourceVector(cameraUp)
    }

    /// Returns a camera-updated value while sharing the immutable mesh array
    /// storage. This avoids reconverting every vertex for player motion.
    public func updatingCamera(
        eye: SIMD3<Float>,
        forward: SIMD3<Float>,
        up: SIMD3<Float>? = nil,
        skyboxVisibility: GModMetalSkyboxVisibility? = nil,
        sourceFixedTime: Float? = nil
    ) -> Self {
        Self(
            meshIdentifier: meshIdentifier,
            sourcePositions: sourcePositions,
            sourceNormals: sourceNormals,
            sourceTextureCoordinates: sourceTextureCoordinates,
            sourceLightmapTextureCoordinates: sourceLightmapTextureCoordinates,
            metalPositions: metalPositions,
            metalNormals: metalNormals,
            indices: indices,
            materialRanges: materialRanges,
            lightmapAtlas: lightmapAtlas,
            lightmapDiagnostics: lightmapDiagnostics,
            environmentLighting: environmentLighting,
            sunSprites: sunSprites,
            sky3D: sky3D,
            skyboxVisibility: skyboxVisibility ?? self.skyboxVisibility,
            cameraEye: eye,
            cameraForward: forward,
            cameraUp: up ?? cameraUp,
            sourceFixedTime: sourceFixedTime ?? self.sourceFixedTime
        )
    }

    /// Converts either a position or a direction because this coordinate
    /// change is a translation-free orthonormal basis change.
    public static func convertSourceVector(
        _ value: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(-value.y, value.z, -value.x)
    }

    private init(
        meshIdentifier: String,
        sourcePositions: [SIMD3<Float>],
        sourceNormals: [SIMD3<Float>],
        sourceTextureCoordinates: [SIMD2<Float>],
        sourceLightmapTextureCoordinates: [SIMD2<Float>],
        metalPositions: [SIMD3<Float>],
        metalNormals: [SIMD3<Float>],
        indices: [UInt32],
        materialRanges: [GModMetalWorldMaterialRange],
        lightmapAtlas: GModMetalWorldLightmapAtlas?,
        lightmapDiagnostics: GModMetalWorldLightmapDiagnostics,
        environmentLighting: GModMetalWorldEnvironmentLighting?,
        sunSprites: [GModMetalWorldSunSprite],
        sky3D: GModMetalWorldSky3D?,
        skyboxVisibility: GModMetalSkyboxVisibility,
        cameraEye: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        sourceFixedTime: Float
    ) {
        self.meshIdentifier = meshIdentifier
        self.sourcePositions = sourcePositions
        self.sourceNormals = sourceNormals
        self.sourceTextureCoordinates = sourceTextureCoordinates
        self.sourceLightmapTextureCoordinates = sourceLightmapTextureCoordinates
        self.metalPositions = metalPositions
        self.metalNormals = metalNormals
        self.indices = indices
        self.materialRanges = materialRanges
        self.materialDiagnostics = Self.makeMaterialDiagnostics(materialRanges)
        self.lightmapAtlas = lightmapAtlas
        self.lightmapDiagnostics = lightmapDiagnostics
        self.environmentLighting = environmentLighting
        self.sunSprites = sunSprites
        self.sky3D = sky3D
        self.skyboxVisibility = skyboxVisibility
        self.sourceFixedTime = sourceFixedTime
        self.cameraEye = cameraEye
        self.cameraForward = cameraForward
        self.cameraUp = cameraUp
        self.metalCameraEye = Self.convertSourceVector(cameraEye)
        self.metalCameraForward = Self.convertSourceVector(cameraForward)
        self.metalCameraUp = Self.convertSourceVector(cameraUp)
    }

    private static func makeMaterialDiagnostics(
        _ ranges: [GModMetalWorldMaterialRange]
    ) -> GModMetalWorldMaterialDiagnostics {
        let skyboxRanges = ranges.filter { $0.skyboxFace != nil }
        let worldRanges = ranges.filter { $0.skyboxFace == nil }
        let waterRanges = worldRanges.filter { $0.waterSurface != nil }
        let unresolvedWorldNames = Set(worldRanges.compactMap { range -> String? in
            guard range.bitmap == nil, range.waterMaterial == nil,
                  range.materialResolution != .notApplicable else { return nil }
            return range.materialName
        }).sorted()
        let skyboxNames = Set(skyboxRanges.compactMap(\.skyboxName))
        let missingSkyboxNames = skyboxRanges.compactMap { range -> String? in
            guard range.bitmap == nil else { return nil }
            return range.materialName
        }.sorted()
        return GModMetalWorldMaterialDiagnostics(
            worldMaterialRangeCount: worldRanges.count,
            resolvedWorldMaterialRangeCount: worldRanges.filter {
                $0.bitmap != nil || $0.waterMaterial != nil
            }.count,
            missingWorldMaterialRangeCount: worldRanges.filter {
                $0.bitmap == nil && $0.waterMaterial == nil &&
                    $0.materialResolution != .notApplicable && $0.materialName != nil
            }.count,
            unnamedWorldFallbackRangeCount: worldRanges.filter {
                $0.bitmap == nil && $0.materialName == nil
            }.count,
            unresolvedWorldMaterialNames: unresolvedWorldNames,
            skyboxName: skyboxNames.count == 1 ? skyboxNames.first : nil,
            skyboxFaceRangeCount: skyboxRanges.count,
            resolvedSkyboxFaceCount: skyboxRanges.filter {
                $0.bitmap != nil
            }.count,
            missingSkyboxMaterialNames: missingSkyboxNames,
            waterMaterialRangeCount: waterRanges.count,
            resolvedWaterMaterialRangeCount: waterRanges.filter {
                $0.waterMaterial != nil
            }.count,
            unsupportedWaterBumpTextureNames: waterRanges.compactMap {
                $0.waterMaterial?.unsupportedBumpTextureFormat == nil
                    ? nil
                    : $0.materialName
            }.sorted(),
            sourceMissingMaterialNames: ranges.compactMap { range in
                range.materialResolution == .sourceMissing
                    ? range.materialName
                    : nil
            }.sorted(),
            decodeFailedMaterialNames: ranges.compactMap { range in
                guard case .decodeFailed = range.materialResolution else {
                    return nil
                }
                return range.materialName
            }.sorted(),
            retentionCapacityExceededMaterialNames: ranges.compactMap { range in
                guard case .retentionCapacityExceeded =
                    range.materialResolution else { return nil }
                return range.materialName
            }.sorted()
        )
    }
}

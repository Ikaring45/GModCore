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

/// Renderer-facing static `sky_camera` fog. Colors remain authored
/// display-sRGB values until the Metal boundary converts them to linear.
public struct GModMetalWorldSky3DFog: Sendable, Equatable {
    public let blendsColors: Bool
    public let sourcePrimaryDirection: SIMD3<Float>
    public let primaryDisplayRGB: SIMD3<Float>
    public let secondaryDisplayRGB: SIMD3<Float>
    public let start: Float
    public let end: Float
    public let maximumDensity: Float
    public let isRadial: Bool

    public init(
        blendsColors: Bool,
        sourcePrimaryDirection: SIMD3<Float>,
        primaryDisplayRGB: SIMD3<Float>,
        secondaryDisplayRGB: SIMD3<Float>,
        start: Float,
        end: Float,
        maximumDensity: Float,
        isRadial: Bool
    ) {
        self.blendsColors = blendsColors
        self.sourcePrimaryDirection = sourcePrimaryDirection
        self.primaryDisplayRGB = primaryDisplayRGB
        self.secondaryDisplayRGB = secondaryDisplayRGB
        self.start = start
        self.end = end
        self.maximumDensity = maximumDensity
        self.isRadial = isRadial
    }
}

public struct GModMetalWorldSky3D: Sendable, Equatable {
    /// `sky_camera` origin in Source coordinates before mesh baking.
    public let sourceOrigin: SIMD3<Float>
    /// Positive Source `sky_camera` scale used by `(vertex - origin) * scale`.
    public let scale: Float
    public let fog: GModMetalWorldSky3DFog?

    public init(
        sourceOrigin: SIMD3<Float>,
        scale: Float,
        fog: GModMetalWorldSky3DFog? = nil
    ) {
        self.sourceOrigin = sourceOrigin
        self.scale = scale
        self.fog = fog
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

struct GModMetalSky3DFogUniforms: Sendable, Equatable {
    let linearRGB: SIMD3<Float>
    let start: Float
    let end: Float
    let maximumDensity: Float
    let isRadial: Bool
    let metalCameraEye: SIMD3<Float>
    let metalCameraForward: SIMD3<Float>
}

/// CPU oracle for the pinned Source 2013 sky-fog path. Source draws miniature
/// geometry and divides start/end by sky scale. Our mesh bakes geometry by the
/// reciprocal transform, so authored start/end are already the equivalent
/// baked-space distances. Range fog then squares the saturated factor in the
/// pixel shader, matching `CalcRangeFog` + `BlendPixelFog`.
enum GModMetalSky3DFogContract {
    static func uniforms(
        fog: GModMetalWorldSky3DFog,
        sourceCameraForward: SIMD3<Float>,
        metalCameraEye: SIMD3<Float>,
        metalCameraForward: SIMD3<Float>
    ) -> GModMetalSky3DFogUniforms? {
        guard finite(fog.primaryDisplayRGB),
              finite(fog.secondaryDisplayRGB),
              channelsAreDisplayRGB(fog.primaryDisplayRGB),
              channelsAreDisplayRGB(fog.secondaryDisplayRGB),
              fog.start.isFinite,
              fog.end.isFinite,
              fog.end > fog.start,
              fog.maximumDensity.isFinite,
              finite(metalCameraEye),
              let normalizedMetalForward = normalized(metalCameraForward),
              let displayRGB = resolvedDisplayRGB(
                fog: fog,
                sourceCameraForward: sourceCameraForward
              ) else { return nil }
        return GModMetalSky3DFogUniforms(
            linearRGB: GModMetalWorldColorSpaceContract.decodeDisplaySRGB(
                displayRGB
            ),
            start: fog.start,
            end: fog.end,
            maximumDensity: fog.maximumDensity,
            isRadial: fog.isRadial,
            metalCameraEye: metalCameraEye,
            metalCameraForward: normalizedMetalForward
        )
    }

    static func resolvedDisplayRGB(
        fog: GModMetalWorldSky3DFog,
        sourceCameraForward: SIMD3<Float>
    ) -> SIMD3<Float>? {
        guard finite(fog.primaryDisplayRGB),
              finite(fog.secondaryDisplayRGB),
              finite(fog.sourcePrimaryDirection),
              let forward = normalized(sourceCameraForward) else { return nil }
        guard fog.blendsColors else { return fog.primaryDisplayRGB }
        // Source's GetSkyboxFogColor dots the normalized view forward against
        // the raw FIELD_VECTOR keyfield. It does not normalize or clamp the
        // authored fog direction, so preserve that behavior here.
        let blend = 0.5 * dot(forward, fog.sourcePrimaryDirection) + 0.5
        return fog.primaryDisplayRGB * blend +
            fog.secondaryDisplayRGB * (1 - blend)
    }

    static func sourceShaderMixFactor(
        distance: Float,
        fog: GModMetalWorldSky3DFog
    ) -> Float? {
        guard distance.isFinite,
              fog.start.isFinite,
              fog.end.isFinite,
              fog.end > fog.start,
              fog.maximumDensity.isFinite else { return nil }
        let unsquared = Swift.max(
            0,
            Swift.min(
                1,
                Swift.min(
                    fog.maximumDensity,
                    (distance - fog.start) / (fog.end - fog.start)
                )
            )
        )
        return unsquared * unsquared
    }

    private static func channelsAreDisplayRGB(_ value: SIMD3<Float>) -> Bool {
        (0...1).contains(value.x) &&
            (0...1).contains(value.y) &&
            (0...1).contains(value.z)
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

    private static func normalized(
        _ value: SIMD3<Float>
    ) -> SIMD3<Float>? {
        guard finite(value) else { return nil }
        let lengthSquared = dot(value, value)
        guard lengthSquared > Float.ulpOfOne else { return nil }
        return value / lengthSquared.squareRoot()
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
    /// Metal window coordinates and normalized 2D texture coordinates both use
    /// a top-left origin. The reflected camera projects the same water point to
    /// the opposite NDC Y, so its render-target lookup must invert screen Y;
    /// the ordinary refraction view remains screen-aligned.
    static func renderTargetBases(
        screenUV: SIMD2<Float>
    ) -> GModMetalWaterDependentTextureCoordinates {
        GModMetalWaterDependentTextureCoordinates(
            reflection: SIMD2<Float>(screenUV.x, 1 - screenUV.y),
            refraction: screenUV
        )
    }

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

    func targetFlags(for material: GModMetalWorldWaterMaterial) -> UInt32 {
        let reflection: UInt32 = requiresReflection &&
            material.reflectionAmount != nil ? 1 : 0
        let refraction: UInt32 = requiresRefraction &&
            material.refractionAmount != nil ? 2 : 0
        return reflection | refraction
    }
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
        // `CUnderWaterView` creates only an out-of-water refraction view;
        // Source's reflected view belongs to `CAboveWaterView`.
        let requiresReflection = cameraZ >= first.surface.surfaceZ &&
            visible.contains { $0.material.reflectionAmount != nil }
        let requiresRefraction = visible.contains {
            $0.material.refractionAmount != nil
        }
        guard requiresReflection || requiresRefraction else { return nil }
        return GModMetalWaterRenderTargetPlan(
            sourceSurfaceZ: first.surface.surfaceZ,
            requiresReflection: requiresReflection,
            requiresRefraction: requiresRefraction
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

/// Immutable model-zero BSP traversal data used to locate the camera leaf.
/// Normals and distances remain in Source coordinates; only face bounds are
/// converted to Metal space for the renderer's view-frustum test.
public struct GModMetalWorldVisibilityPlane: Sendable, Equatable {
    public let sourceNormal: SIMD3<Float>
    public let distance: Float

    public init(sourceNormal: SIMD3<Float>, distance: Float) {
        self.sourceNormal = sourceNormal
        self.distance = distance
    }
}

public struct GModMetalWorldVisibilityNode: Sendable, Equatable {
    public let planeIndex: Int
    public let frontChild: Int32
    public let backChild: Int32

    public init(planeIndex: Int, frontChild: Int32, backChild: Int32) {
        self.planeIndex = planeIndex
        self.frontChild = frontChild
        self.backChild = backChild
    }
}

/// Source LUMP_VISIBILITY bytes retained verbatim. Runtime decoding writes one
/// row into caller-owned storage instead of allocating a Set every frame.
public struct GModMetalWorldPotentialVisibility: Sendable, Equatable {
    public let clusterCount: Int
    public let encodedBytes: [UInt8]
    public let pvsOffsets: [Int]

    public init(
        clusterCount: Int,
        encodedBytes: [UInt8],
        pvsOffsets: [Int]
    ) {
        self.clusterCount = clusterCount
        self.encodedBytes = encodedBytes
        self.pvsOffsets = pvsOffsets
    }

    func decodeRow(from cluster: Int, into row: inout [UInt8]) -> Bool {
        guard clusterCount > 0,
              pvsOffsets.count == clusterCount,
              pvsOffsets.indices.contains(cluster) else { return false }
        let rowByteCount = (clusterCount + 7) / 8
        if row.count != rowByteCount {
            row = [UInt8](repeating: 0, count: rowByteCount)
        }
        var output = 0
        var cursor = pvsOffsets[cluster]
        while output < rowByteCount {
            guard encodedBytes.indices.contains(cursor) else { return false }
            let value = encodedBytes[cursor]
            cursor += 1
            if value != 0 {
                row[output] = value
                output += 1
                continue
            }
            guard encodedBytes.indices.contains(cursor) else { return false }
            let runLength = Int(encodedBytes[cursor])
            cursor += 1
            guard runLength > 0,
                  runLength <= rowByteCount - output else { return false }
            for index in output..<(output + runLength) {
                row[index] = 0
            }
            output += runLength
        }
        return true
    }

    func contains(_ cluster: Int, inDecodedRow row: [UInt8]) -> Bool {
        cluster >= 0 && cluster < clusterCount &&
            row.count == (clusterCount + 7) / 8 &&
            row[cluster >> 3] & (1 << UInt8(cluster & 7)) != 0
    }
}

public struct GModMetalWorldVisibilitySpan: Sendable, Equatable {
    public let materialRangeIndex: Int
    public let firstIndex: Int
    public let indexCount: Int
    public let metalMinimum: SIMD3<Float>
    public let metalMaximum: SIMD3<Float>
    public let clusterStartIndex: Int
    public let clusterCount: Int

    public init(
        materialRangeIndex: Int,
        firstIndex: Int,
        indexCount: Int,
        metalMinimum: SIMD3<Float>,
        metalMaximum: SIMD3<Float>,
        clusterStartIndex: Int,
        clusterCount: Int
    ) {
        self.materialRangeIndex = materialRangeIndex
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.metalMinimum = metalMinimum
        self.metalMaximum = metalMaximum
        self.clusterStartIndex = clusterStartIndex
        self.clusterCount = clusterCount
    }
}

public struct GModMetalWorldVisibility: Sendable, Equatable {
    public let headNode: Int32
    public let planes: [GModMetalWorldVisibilityPlane]
    public let nodes: [GModMetalWorldVisibilityNode]
    public let leafClusters: [Int16]
    public let potentialVisibility: GModMetalWorldPotentialVisibility?
    public let spans: [GModMetalWorldVisibilitySpan]
    public let spanClusters: [Int16]

    public init(
        headNode: Int32,
        planes: [GModMetalWorldVisibilityPlane],
        nodes: [GModMetalWorldVisibilityNode],
        leafClusters: [Int16],
        potentialVisibility: GModMetalWorldPotentialVisibility?,
        spans: [GModMetalWorldVisibilitySpan],
        spanClusters: [Int16]
    ) {
        self.headNode = headNode
        self.planes = planes
        self.nodes = nodes
        self.leafClusters = leafClusters
        self.potentialVisibility = potentialVisibility
        self.spans = spans
        self.spanClusters = spanClusters
    }

    func cameraCluster(at sourcePoint: SIMD3<Float>) -> Int16? {
        guard Self.finite(sourcePoint) else { return nil }
        var child = headNode
        var remainingSteps = nodes.count + 1
        while child >= 0, remainingSteps > 0 {
            remainingSteps -= 1
            let nodeIndex = Int(child)
            guard nodes.indices.contains(nodeIndex) else { return nil }
            let node = nodes[nodeIndex]
            guard planes.indices.contains(node.planeIndex) else { return nil }
            let plane = planes[node.planeIndex]
            guard Self.finite(plane.sourceNormal),
                  plane.distance.isFinite else { return nil }
            let distance = Self.dot(plane.sourceNormal, sourcePoint) -
                plane.distance
            child = distance >= 0 ? node.frontChild : node.backChild
        }
        guard child < 0, remainingSteps > 0 else { return nil }
        let leafIndex64 = -1 - Int64(child)
        guard leafIndex64 >= 0,
              leafIndex64 < Int64(leafClusters.count) else { return nil }
        return leafClusters[Int(leafIndex64)]
    }

    private static func dot(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func finite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}

struct GModMetalWorldVisibleIndexSpan: Sendable, Equatable {
    let materialRangeIndex: Int
    let firstIndex: Int
    let indexCount: Int
}

public struct GModMetalWorldVisibilityMetrics: Sendable, Equatable {
    public let sourceSpanCount: Int
    public let sourceIndexCount: Int
    public let visibleSpanCount: Int
    public let visibleIndexCount: Int
    public let drawSpanCount: Int
}

/// Reusable per-view Source world-list workspace. The immutable scene owns all
/// BSP metadata; this object retains just one decoded PVS row and one bounded
/// coalesced span array across frames. Unknown or malformed visibility inputs
/// return false so the renderer draws the original complete material ranges.
final class GModMetalWorldVisibilityWorkspace {
    private struct ViewKey: Equatable {
        let meshIdentifier: String
        let sourceCameraEye: SIMD3<Float>
        let metalCameraEye: SIMD3<Float>
        let metalCameraForward: SIMD3<Float>
        let metalCameraUp: SIMD3<Float>
        let verticalFieldOfViewRadians: Float
        let aspectRatio: Float
        let nearPlane: Float
        let farPlane: Float
    }

    private(set) var visibleDrawSpans: [GModMetalWorldVisibleIndexSpan] = []
    private(set) var metrics: GModMetalWorldVisibilityMetrics?
    private(set) var rebuildCount = 0
    private var decodedPVSRow: [UInt8] = []
    private var cachedViewKey: ViewKey?
    private var cachedSelectionIsUsable = false

    func reset() {
        cachedViewKey = nil
        cachedSelectionIsUsable = false
        metrics = nil
        visibleDrawSpans.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func update(
        scene: GModMetalWorldScene,
        sourceCameraEye: SIMD3<Float>,
        metalCameraEye: SIMD3<Float>,
        metalCameraForward: SIMD3<Float>,
        metalCameraUp: SIMD3<Float>,
        verticalFieldOfViewRadians: Float,
        aspectRatio: Float,
        nearPlane: Float,
        farPlane: Float
    ) -> Bool {
        let viewKey = ViewKey(
            meshIdentifier: scene.meshIdentifier,
            sourceCameraEye: sourceCameraEye,
            metalCameraEye: metalCameraEye,
            metalCameraForward: metalCameraForward,
            metalCameraUp: metalCameraUp,
            verticalFieldOfViewRadians: verticalFieldOfViewRadians,
            aspectRatio: aspectRatio,
            nearPlane: nearPlane,
            farPlane: farPlane
        )
        if cachedViewKey == viewKey {
            return cachedSelectionIsUsable
        }

        rebuildCount &+= 1
        cachedViewKey = nil
        cachedSelectionIsUsable = false
        metrics = nil
        visibleDrawSpans.removeAll(keepingCapacity: true)

        guard let visibility = scene.worldVisibility,
              let pvs = visibility.potentialVisibility,
              let cameraCluster = visibility.cameraCluster(
                at: sourceCameraEye
              ), cameraCluster >= 0,
              pvs.decodeRow(
                from: Int(cameraCluster),
                into: &decodedPVSRow
              ),
              let basis = Self.cameraBasis(
                forward: metalCameraForward,
                up: metalCameraUp
              ),
              let frustum = Self.frustum(
                verticalFieldOfViewRadians: verticalFieldOfViewRadians,
                aspectRatio: aspectRatio,
                nearPlane: nearPlane,
                farPlane: farPlane
              ), Self.finite(metalCameraEye) else {
            return failOpen(for: viewKey)
        }

        var sourceIndexCount = 0
        var previousMaterialRangeIndex = -1
        var previousSpanEnd = 0
        for span in visibility.spans {
            guard scene.materialRanges.indices.contains(
                span.materialRangeIndex
            ) else { return failOpen(for: viewKey) }
            let materialRange = scene.materialRanges[span.materialRangeIndex]
            let (spanEnd, spanOverflow) = span.firstIndex
                .addingReportingOverflow(span.indexCount)
            let (rangeEnd, rangeOverflow) = materialRange.firstIndex
                .addingReportingOverflow(materialRange.indexCount)
            let (clusterEnd, clusterOverflow) = span.clusterStartIndex
                .addingReportingOverflow(span.clusterCount)
            guard span.indexCount > 0,
                  span.clusterCount >= 0,
                  !spanOverflow,
                  !rangeOverflow,
                  !clusterOverflow,
                  span.firstIndex >= materialRange.firstIndex,
                  spanEnd <= rangeEnd,
                  spanEnd <= scene.indices.count,
                  span.clusterStartIndex >= 0,
                  clusterEnd <= visibility.spanClusters.count,
                  materialRange.renderLayer == .world,
                  materialRange.waterSurface == nil,
                  materialRange.waterMaterial == nil,
                  Self.validBounds(
                    minimum: span.metalMinimum,
                    maximum: span.metalMaximum
                  ),
                    span.materialRangeIndex >= previousMaterialRangeIndex,
                  span.materialRangeIndex != previousMaterialRangeIndex ||
                    span.firstIndex >= previousSpanEnd else {
                return failOpen(for: viewKey)
            }
            for index in span.clusterStartIndex..<clusterEnd {
                let cluster = Int(visibility.spanClusters[index])
                guard cluster >= 0, cluster < pvs.clusterCount else {
                    return failOpen(for: viewKey)
                }
            }
            let (nextIndexCount, countOverflow) = sourceIndexCount
                .addingReportingOverflow(span.indexCount)
            guard !countOverflow else { return failOpen(for: viewKey) }
            sourceIndexCount = nextIndexCount
            previousMaterialRangeIndex = span.materialRangeIndex
            previousSpanEnd = spanEnd
        }
        guard !visibility.spans.isEmpty else {
            return failOpen(for: viewKey)
        }
        var expectedIndexCount = 0
        for range in scene.materialRanges where
            range.renderLayer == .world &&
            range.waterSurface == nil &&
            range.waterMaterial == nil {
            let (nextExpectedCount, overflow) = expectedIndexCount
                .addingReportingOverflow(range.indexCount)
            guard !overflow else { return failOpen(for: viewKey) }
            expectedIndexCount = nextExpectedCount
        }
        guard sourceIndexCount == expectedIndexCount else {
            return failOpen(for: viewKey)
        }

        visibleDrawSpans.reserveCapacity(visibility.spans.count)
        var visibleSpanCount = 0
        var visibleIndexCount = 0
        for span in visibility.spans {
            let clusterEnd = span.clusterStartIndex + span.clusterCount
            let pvsVisible: Bool
            if span.clusterCount == 0 {
                // A face not referenced by a leaf is not evidence of hiding.
                pvsVisible = true
            } else {
                pvsVisible = (span.clusterStartIndex..<clusterEnd).contains {
                    pvs.contains(
                        Int(visibility.spanClusters[$0]),
                        inDecodedRow: decodedPVSRow
                    )
                }
            }
            guard pvsVisible,
                  Self.intersectsFrustum(
                    minimum: span.metalMinimum,
                    maximum: span.metalMaximum,
                    eye: metalCameraEye,
                    forward: basis.forward,
                    right: basis.right,
                    up: basis.up,
                    verticalTangent: frustum.verticalTangent,
                    horizontalTangent: frustum.horizontalTangent,
                    nearPlane: nearPlane,
                    farPlane: farPlane
                  ) else { continue }

            visibleSpanCount += 1
            visibleIndexCount += span.indexCount
            if let last = visibleDrawSpans.last,
               last.materialRangeIndex == span.materialRangeIndex,
               last.firstIndex + last.indexCount == span.firstIndex {
                visibleDrawSpans[visibleDrawSpans.count - 1] =
                    GModMetalWorldVisibleIndexSpan(
                        materialRangeIndex: last.materialRangeIndex,
                        firstIndex: last.firstIndex,
                        indexCount: last.indexCount + span.indexCount
                    )
            } else {
                visibleDrawSpans.append(GModMetalWorldVisibleIndexSpan(
                    materialRangeIndex: span.materialRangeIndex,
                    firstIndex: span.firstIndex,
                    indexCount: span.indexCount
                ))
            }
        }
        metrics = GModMetalWorldVisibilityMetrics(
            sourceSpanCount: visibility.spans.count,
            sourceIndexCount: sourceIndexCount,
            visibleSpanCount: visibleSpanCount,
            visibleIndexCount: visibleIndexCount,
            drawSpanCount: visibleDrawSpans.count
        )
        cachedViewKey = viewKey
        cachedSelectionIsUsable = true
        return true
    }

    private func failOpen(for viewKey: ViewKey) -> Bool {
        cachedViewKey = viewKey
        cachedSelectionIsUsable = false
        metrics = nil
        visibleDrawSpans.removeAll(keepingCapacity: true)
        return false
    }

    private static func cameraBasis(
        forward: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> (forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>)? {
        guard let forward = normalized(forward) else { return nil }
        let projectedUp = up - forward * dot(up, forward)
        guard let projectedUp = normalized(projectedUp),
              let right = normalized(cross(forward, projectedUp)),
              let correctedUp = normalized(cross(right, forward)) else {
            return nil
        }
        return (forward, right, correctedUp)
    }

    private static func frustum(
        verticalFieldOfViewRadians: Float,
        aspectRatio: Float,
        nearPlane: Float,
        farPlane: Float
    ) -> (verticalTangent: Float, horizontalTangent: Float)? {
        guard verticalFieldOfViewRadians.isFinite,
              verticalFieldOfViewRadians > 0,
              verticalFieldOfViewRadians < .pi,
              aspectRatio.isFinite,
              aspectRatio > 0,
              nearPlane.isFinite,
              nearPlane > 0,
              farPlane.isFinite,
              farPlane > nearPlane else { return nil }
        let verticalTangent = tan(verticalFieldOfViewRadians * 0.5)
        let horizontalTangent = verticalTangent * aspectRatio
        guard verticalTangent.isFinite, verticalTangent > 0,
              horizontalTangent.isFinite, horizontalTangent > 0 else {
            return nil
        }
        return (verticalTangent, horizontalTangent)
    }

    private static func intersectsFrustum(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        eye: SIMD3<Float>,
        forward: SIMD3<Float>,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        verticalTangent: Float,
        horizontalTangent: Float,
        nearPlane: Float,
        farPlane: Float
    ) -> Bool {
        let center = (minimum + maximum) * 0.5
        let extents = (maximum - minimum) * 0.5
        let relativeCenter = center - eye
        let forwardCenter = dot(relativeCenter, forward)
        let forwardRadius = dot(extents, absolute(forward))
        guard forwardCenter + forwardRadius >= nearPlane,
              forwardCenter - forwardRadius <= farPlane else { return false }

        let left = forward * horizontalTangent + right
        let rightPlane = forward * horizontalTangent - right
        let bottom = forward * verticalTangent + up
        let top = forward * verticalTangent - up
        return retains(
            relativeCenter: relativeCenter,
            extents: extents,
            inwardNormal: left
        ) && retains(
            relativeCenter: relativeCenter,
            extents: extents,
            inwardNormal: rightPlane
        ) && retains(
            relativeCenter: relativeCenter,
            extents: extents,
            inwardNormal: bottom
        ) && retains(
            relativeCenter: relativeCenter,
            extents: extents,
            inwardNormal: top
        )
    }

    private static func retains(
        relativeCenter: SIMD3<Float>,
        extents: SIMD3<Float>,
        inwardNormal: SIMD3<Float>
    ) -> Bool {
        dot(relativeCenter, inwardNormal) +
            dot(extents, absolute(inwardNormal)) >= 0
    }

    private static func validBounds(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> Bool {
        finite(minimum) && finite(maximum) &&
            minimum.x <= maximum.x &&
            minimum.y <= maximum.y &&
            minimum.z <= maximum.z
    }

    private static func absolute(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(Swift.abs(value.x), Swift.abs(value.y), Swift.abs(value.z))
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

    private static func normalized(_ value: SIMD3<Float>) -> SIMD3<Float>? {
        guard finite(value) else { return nil }
        let lengthSquared = dot(value, value)
        guard lengthSquared > Float.ulpOfOne else { return nil }
        return value / lengthSquared.squareRoot()
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
    public let worldVisibility: GModMetalWorldVisibility?
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
        worldVisibility: GModMetalWorldVisibility? = nil,
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
        self.worldVisibility = worldVisibility
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
            worldVisibility: worldVisibility,
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
        worldVisibility: GModMetalWorldVisibility?,
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
        self.worldVisibility = worldVisibility
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

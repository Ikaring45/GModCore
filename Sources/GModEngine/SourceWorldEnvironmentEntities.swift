import Foundation

/// VRAD lighting mode used when compiling `light_environment` entity fields.
///
/// This selects authored SDR/HDR tuples only. Global VRAD command-line
/// `-lightscale` is deliberately outside this entity-owned contract.
public enum SourceWorldEnvironmentLightingMode: Sendable, Equatable {
    case standardDynamicRange
    case highDynamicRange
}

/// One BSP entity with its stable entity-lump index and ordered keyvalues.
/// Duplicate keys remain legal; Source lookups resolve the last authored value
/// through `SourceBSPParsedEntity.value(forKey:)`.
public struct SourceCanonicalMapEntityKeyValues: Sendable, Equatable {
    public let sourceEntityIndex: Int
    public let keyValues: [SourceBSPEntityKeyValue]

    public init(
        sourceEntityIndex: Int,
        parsedEntity: SourceBSPParsedEntity
    ) {
        self.sourceEntityIndex = sourceEntityIndex
        keyValues = parsedEntity.keyValues
    }

    public func value(forKey key: String) -> String? {
        keyValues.last {
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    public var className: String? { value(forKey: "classname") }
}

/// Renderer-neutral VRAD result derived solely from the first authored
/// `light_environment`. Colors use VRAD's linear intensity scale, not display
/// RGB and not a renderer exposure value.
public struct SourceLightEnvironmentEntityState: Sendable, Equatable {
    public let sourceEntityIndex: Int
    /// Normal written by VRAD to the compiled `emit_skylight` world light.
    public let sourceDirectionFromLight: SourceVector3
    public let directLinearRGB: SourceVector3
    public let ambientLinearRGB: SourceVector3
    public let lightingMode: SourceWorldEnvironmentLightingMode
    public let directKey: String?
    public let ambientKey: String?
    public let sunSpreadAngleDegrees: Float?
    /// `sin(SunSpreadAngle)` as stored in VRAD's global sun angular extent.
    public let sunAngularExtent: Float?
    public let ignoredAdditionalEntityCount: Int

    public init(
        sourceEntityIndex: Int,
        sourceDirectionFromLight: SourceVector3,
        directLinearRGB: SourceVector3,
        ambientLinearRGB: SourceVector3,
        lightingMode: SourceWorldEnvironmentLightingMode,
        directKey: String?,
        ambientKey: String?,
        sunSpreadAngleDegrees: Float?,
        sunAngularExtent: Float?,
        ignoredAdditionalEntityCount: Int
    ) {
        self.sourceEntityIndex = sourceEntityIndex
        self.sourceDirectionFromLight = sourceDirectionFromLight
        self.directLinearRGB = directLinearRGB
        self.ambientLinearRGB = ambientLinearRGB
        self.lightingMode = lightingMode
        self.directKey = directKey
        self.ambientKey = ambientKey
        self.sunSpreadAngleDegrees = sunSpreadAngleDegrees
        self.sunAngularExtent = sunAngularExtent
        self.ignoredAdditionalEntityCount = ignoredAdditionalEntityCount
    }
}

public struct SourceEnvironmentSunSpriteLayer: Sendable, Equatable {
    public let materialName: String
    public let displayRGB: SourceVector3
    public let size: Int

    public init(materialName: String, displayRGB: SourceVector3, size: Int) {
        self.materialName = materialName
        self.displayRGB = displayRGB
        self.size = size
    }
}

/// Activated static state of one `env_sun`. Exact-name static targets are
/// resolved from the same canonical entity set; dynamic/special target names
/// stay an explicit unsupported boundary.
public struct SourceEnvironmentSunEntityState: Sendable, Equatable {
    public let sourceEntityIndex: Int
    /// `CSun::m_vDirection`: direction from the camera toward the sun.
    public let sourceDirectionToSun: SourceVector3
    public let usesAngles: Bool
    public let resolvedTargetEntityIndex: Int?
    public let hdrColorScale: Float
    public let isInitiallyOn: Bool
    public let core: SourceEnvironmentSunSpriteLayer
    public let overlay: SourceEnvironmentSunSpriteLayer

    public init(
        sourceEntityIndex: Int,
        sourceDirectionToSun: SourceVector3,
        usesAngles: Bool,
        resolvedTargetEntityIndex: Int?,
        hdrColorScale: Float,
        isInitiallyOn: Bool,
        core: SourceEnvironmentSunSpriteLayer,
        overlay: SourceEnvironmentSunSpriteLayer
    ) {
        self.sourceEntityIndex = sourceEntityIndex
        self.sourceDirectionToSun = sourceDirectionToSun
        self.usesAngles = usesAngles
        self.resolvedTargetEntityIndex = resolvedTargetEntityIndex
        self.hdrColorScale = hdrColorScale
        self.isInitiallyOn = isInitiallyOn
        self.core = core
        self.overlay = overlay
    }
}

public struct SourceSkyCameraFogEntityState: Sendable, Equatable {
    public let isEnabled: Bool
    public let blendsColors: Bool
    public let sourcePrimaryDirection: SourceVector3
    public let primaryDisplayRGBA: SIMD4<Float>
    public let secondaryDisplayRGBA: SIMD4<Float>
    public let start: Float
    public let end: Float
    public let maximumDensity: Float
    public let isRadial: Bool

    public init(
        isEnabled: Bool,
        blendsColors: Bool,
        sourcePrimaryDirection: SourceVector3,
        primaryDisplayRGBA: SIMD4<Float>,
        secondaryDisplayRGBA: SIMD4<Float>,
        start: Float,
        end: Float,
        maximumDensity: Float,
        isRadial: Bool
    ) {
        self.isEnabled = isEnabled
        self.blendsColors = blendsColors
        self.sourcePrimaryDirection = sourcePrimaryDirection
        self.primaryDisplayRGBA = primaryDisplayRGBA
        self.secondaryDisplayRGBA = secondaryDisplayRGBA
        self.start = start
        self.end = end
        self.maximumDensity = maximumDensity
        self.isRadial = isRadial
    }
}

/// Entity-owned 3D sky placement. BSP leaf area/cluster selection is a
/// separate spatial-query concern and is intentionally not guessed here.
public struct SourceSkyCameraEntityState: Sendable, Equatable {
    public let sourceEntityIndex: Int
    public let sourceOrigin: SourceVector3
    public let scale: Int
    public let fog: SourceSkyCameraFogEntityState

    public init(
        sourceEntityIndex: Int,
        sourceOrigin: SourceVector3,
        scale: Int,
        fog: SourceSkyCameraFogEntityState
    ) {
        self.sourceEntityIndex = sourceEntityIndex
        self.sourceOrigin = sourceOrigin
        self.scale = scale
        self.fog = fog
    }
}

public struct SourceWorldEnvironmentEntityState: Sendable, Equatable {
    public let lightEnvironment: SourceLightEnvironmentEntityState?
    public let suns: [SourceEnvironmentSunEntityState]
    public let skyCameras: [SourceSkyCameraEntityState]

    public init(
        lightEnvironment: SourceLightEnvironmentEntityState?,
        suns: [SourceEnvironmentSunEntityState],
        skyCameras: [SourceSkyCameraEntityState]
    ) {
        self.lightEnvironment = lightEnvironment
        self.suns = suns
        self.skyCameras = skyCameras
    }
}

public enum SourceWorldEnvironmentEntityError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case invalidValue(entityIndex: Int, className: String, key: String, value: String?)
    case unsupportedDynamicTarget(entityIndex: Int, target: String)
    case unresolvedTarget(entityIndex: Int, target: String)
    case zeroDirection(entityIndex: Int, className: String)

    public var description: String {
        switch self {
        case let .invalidValue(index, className, key, value):
            return className + " entity " + String(index) + " has invalid " +
                key + "=" + (value ?? "<missing>")
        case let .unsupportedDynamicTarget(index, target):
            return "env_sun entity " + String(index) + " target " + target +
                " requires dynamic Source name resolution"
        case let .unresolvedTarget(index, target):
            return "env_sun entity " + String(index) +
                " cannot resolve target " + target
        case let .zeroDirection(index, className):
            return className + " entity " + String(index) +
                " activates with a zero direction"
        }
    }
}

/// Compiles immutable environment entities using the pinned Source SDK/VRAD
/// contracts. Runtime inputs, target movement, and global compiler flags do not
/// cross this boundary.
public enum SourceWorldEnvironmentEntityCompiler {
    /// Compiles only `env_sun` entities so an unrelated malformed
    /// `sky_camera` cannot suppress an otherwise valid activated sun overlay.
    public static func compileSuns(
        parsedEntities: [SourceBSPParsedEntity]
    ) throws -> [SourceEnvironmentSunEntityState] {
        let entities = parsedEntities.enumerated().map {
            SourceCanonicalMapEntityKeyValues(
                sourceEntityIndex: $0.offset,
                parsedEntity: $0.element
            )
        }
        return try entities
            .filter { isClass($0, "env_sun") }
            .map { try compileSun($0, allEntities: entities) }
    }

    public static func compile(
        parsedEntities: [SourceBSPParsedEntity],
        lightingMode: SourceWorldEnvironmentLightingMode
    ) throws -> SourceWorldEnvironmentEntityState {
        let entities = parsedEntities.enumerated().map {
            SourceCanonicalMapEntityKeyValues(
                sourceEntityIndex: $0.offset,
                parsedEntity: $0.element
            )
        }
        return try compile(entities: entities, lightingMode: lightingMode)
    }

    public static func compile(
        entities: [SourceCanonicalMapEntityKeyValues],
        lightingMode: SourceWorldEnvironmentLightingMode
    ) throws -> SourceWorldEnvironmentEntityState {
        let lightEntities = entities.filter { isClass($0, "light_environment") }
        let lightEnvironment = try lightEntities.first.map {
            try compileLightEnvironment(
                $0,
                lightingMode: lightingMode,
                ignoredAdditionalEntityCount: max(0, lightEntities.count - 1)
            )
        }
        let suns = try entities
            .filter { isClass($0, "env_sun") }
            .map { try compileSun($0, allEntities: entities) }
        let skyCameras = try entities
            .filter { isClass($0, "sky_camera") }
            .map(compileSkyCamera)
        return SourceWorldEnvironmentEntityState(
            lightEnvironment: lightEnvironment,
            suns: suns,
            skyCameras: skyCameras
        )
    }

    private static func compileLightEnvironment(
        _ entity: SourceCanonicalMapEntityKeyValues,
        lightingMode: SourceWorldEnvironmentLightingMode,
        ignoredAdditionalEntityCount: Int
    ) throws -> SourceLightEnvironmentEntityState {
        let angles = try vector(entity, key: "angles", default: .zero)
        let pitch = try float(entity, key: "pitch", default: 0)
        let angle = try float(entity, key: "angle", default: 0)
        let direction = setupLightNormal(angles: angles, angle: angle, pitch: pitch)
        guard finite(direction), direction.lengthSquared > 0 else {
            throw SourceWorldEnvironmentEntityError.zeroDirection(
                entityIndex: entity.sourceEntityIndex,
                className: "light_environment"
            )
        }

        let directSelection = selectDirectIntensity(
            entity,
            lightingMode: lightingMode
        )
        var direct = directSelection.value
        if lightingMode == .highDynamicRange {
            direct = direct * (try float(
                entity,
                key: "_lightscaleHDR",
                default: 1
            ))
        }
        let ambientSelection = selectAmbientIntensity(
            entity,
            lightingMode: lightingMode,
            direct: direct
        )
        var ambient = ambientSelection.value
        if lightingMode == .highDynamicRange {
            ambient = ambient * (try float(
                entity,
                key: "_AmbientScaleHDR",
                default: 1
            ))
        }
        guard finite(direct), finite(ambient) else {
            throw invalid(entity, key: "_light/_ambient")
        }

        let spreadDegrees: Float?
        let angularExtent: Float?
        if entity.value(forKey: "SunSpreadAngle") != nil {
            let spread = try float(entity, key: "SunSpreadAngle", default: 0)
            spreadDegrees = spread
            angularExtent = sin(spread * .pi / 180)
        } else {
            spreadDegrees = nil
            angularExtent = nil
        }
        return SourceLightEnvironmentEntityState(
            sourceEntityIndex: entity.sourceEntityIndex,
            sourceDirectionFromLight: direction,
            directLinearRGB: direct,
            ambientLinearRGB: ambient,
            lightingMode: lightingMode,
            directKey: directSelection.key,
            ambientKey: ambientSelection.key,
            sunSpreadAngleDegrees: spreadDegrees,
            sunAngularExtent: angularExtent,
            ignoredAdditionalEntityCount: ignoredAdditionalEntityCount
        )
    }

    private static func compileSun(
        _ entity: SourceCanonicalMapEntityKeyValues,
        allEntities: [SourceCanonicalMapEntityKeyValues]
    ) throws -> SourceEnvironmentSunEntityState {
        let usesAngles = try boolean(entity, key: "use_angles", default: false)
        let direction: SourceVector3
        let resolvedTargetEntityIndex: Int?
        if usesAngles {
            let angles = try vector(entity, key: "angles", default: .zero)
            let pitch = try float(entity, key: "pitch", default: 0)
            let angle = try float(entity, key: "angle", default: 0)
            direction = -setupLightNormal(
                angles: angles,
                angle: angle,
                pitch: pitch
            )
            resolvedTargetEntityIndex = nil
        } else {
            guard let target = entity.value(forKey: "target")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !target.isEmpty else {
                throw invalid(entity, key: "target")
            }
            guard !target.contains("*") && !target.contains("?") &&
                !target.hasPrefix("!") else {
                throw SourceWorldEnvironmentEntityError.unsupportedDynamicTarget(
                    entityIndex: entity.sourceEntityIndex,
                    target: target
                )
            }
            guard let targetEntity = allEntities.first(where: {
                $0.value(forKey: "targetname")?
                    .caseInsensitiveCompare(target) == .orderedSame
            }) else {
                throw SourceWorldEnvironmentEntityError.unresolvedTarget(
                    entityIndex: entity.sourceEntityIndex,
                    target: target
                )
            }
            let origin = try vector(entity, key: "origin", default: .zero)
            let targetOrigin = try vector(targetEntity, key: "origin", default: .zero)
            let delta = origin - targetOrigin
            guard finite(delta), delta.lengthSquared > 0 else {
                throw SourceWorldEnvironmentEntityError.zeroDirection(
                    entityIndex: entity.sourceEntityIndex,
                    className: "env_sun"
                )
            }
            direction = delta / delta.length
            resolvedTargetEntityIndex = targetEntity.sourceEntityIndex
        }
        guard finite(direction), direction.lengthSquared > 0 else {
            throw SourceWorldEnvironmentEntityError.zeroDirection(
                entityIndex: entity.sourceEntityIndex,
                className: "env_sun"
            )
        }

        let size = try integer(entity, key: "size", default: 16)
        guard (0...1_023).contains(size) else { throw invalid(entity, key: "size") }
        let rawOverlaySize = try integer(entity, key: "overlaysize", default: -1)
        guard rawOverlaySize == -1 || (0...1_023).contains(rawOverlaySize) else {
            throw invalid(entity, key: "overlaysize")
        }
        let overlaySize = rawOverlaySize == -1 ? size : rawOverlaySize

        let renderColor = try color32(
            entity,
            key: "rendercolor",
            default: SIMD4<UInt8>(255, 255, 255, 255)
        )
        let maximum = max(renderColor.x, max(renderColor.y, renderColor.z))
        let coreColor = maximum == 0
            ? SourceVector3(1, 1, 1)
            : SourceVector3(
                Float(renderColor.x) / Float(maximum),
                Float(renderColor.y) / Float(maximum),
                Float(renderColor.z) / Float(maximum)
            )
        let overlayColor32 = try color32(
            entity,
            key: "overlaycolor",
            default: .zero
        )
        let overlayColor = overlayColor32.x == 0 &&
            overlayColor32.y == 0 && overlayColor32.z == 0
            ? coreColor
            : SourceVector3(
                Float(overlayColor32.x) / 255,
                Float(overlayColor32.y) / 255,
                Float(overlayColor32.z) / 255
            )
        let coreMaterial = try materialName(
            entity,
            key: "material",
            default: "sprites/light_glow02_add_noz.vmt"
        )
        let overlayMaterial = try materialName(
            entity,
            key: "overlaymaterial",
            default: "sprites/light_glow02_add_noz.vmt"
        )
        let hdrScale = try float(entity, key: "HDRColorScale", default: 0)
        guard (0...100).contains(hdrScale) else {
            throw invalid(entity, key: "HDRColorScale")
        }
        return SourceEnvironmentSunEntityState(
            sourceEntityIndex: entity.sourceEntityIndex,
            sourceDirectionToSun: direction,
            usesAngles: usesAngles,
            resolvedTargetEntityIndex: resolvedTargetEntityIndex,
            hdrColorScale: hdrScale,
            isInitiallyOn: true,
            core: SourceEnvironmentSunSpriteLayer(
                materialName: coreMaterial,
                displayRGB: coreColor,
                size: size
            ),
            overlay: SourceEnvironmentSunSpriteLayer(
                materialName: overlayMaterial,
                displayRGB: overlayColor,
                size: overlaySize
            )
        )
    }

    private static func compileSkyCamera(
        _ entity: SourceCanonicalMapEntityKeyValues
    ) throws -> SourceSkyCameraEntityState {
        let origin = try vector(entity, key: "origin", default: .zero)
        let scale = try integer(entity, key: "scale", default: 0)
        guard scale > 0 else { throw invalid(entity, key: "scale") }
        let usesAngles = try boolean(entity, key: "use_angles", default: false)
        let direction: SourceVector3
        if usesAngles {
            let angles = try vector(entity, key: "angles", default: .zero)
            direction = -SourceQAngle(
                pitch: angles.x,
                yaw: angles.y,
                roll: angles.z
            ).sourceBasis.forward
        } else {
            direction = try vector(entity, key: "fogdir", default: .zero)
        }
        guard finite(direction) else { throw invalid(entity, key: "fogdir/angles") }
        let fog = SourceSkyCameraFogEntityState(
            isEnabled: try boolean(entity, key: "fogenable", default: false),
            blendsColors: try boolean(entity, key: "fogblend", default: false),
            sourcePrimaryDirection: direction,
            primaryDisplayRGBA: displayRGBA(try color32(
                entity,
                key: "fogcolor",
                default: .zero
            )),
            secondaryDisplayRGBA: displayRGBA(try color32(
                entity,
                key: "fogcolor2",
                default: .zero
            )),
            start: try float(entity, key: "fogstart", default: 0),
            end: try float(entity, key: "fogend", default: 0),
            maximumDensity: try float(entity, key: "fogmaxdensity", default: 1),
            isRadial: try boolean(entity, key: "fogradial", default: false)
        )
        return SourceSkyCameraEntityState(
            sourceEntityIndex: entity.sourceEntityIndex,
            sourceOrigin: origin,
            scale: scale,
            fog: fog
        )
    }

    private struct IntensitySelection {
        let value: SourceVector3
        let key: String?
    }

    private static func selectDirectIntensity(
        _ entity: SourceCanonicalMapEntityKeyValues,
        lightingMode: SourceWorldEnvironmentLightingMode
    ) -> IntensitySelection {
        if lightingMode == .highDynamicRange,
           let hdr = entity.value(forKey: "_lightHDR"),
           let parsed = lightIntensity(hdr, lightingMode: lightingMode) {
            return IntensitySelection(value: parsed, key: "_lightHDR")
        }
        if let authored = entity.value(forKey: "_light"),
           let parsed = lightIntensity(authored, lightingMode: lightingMode) {
            return IntensitySelection(value: parsed, key: "_light")
        }
        return IntensitySelection(value: .zero, key: nil)
    }

    private static func selectAmbientIntensity(
        _ entity: SourceCanonicalMapEntityKeyValues,
        lightingMode: SourceWorldEnvironmentLightingMode,
        direct: SourceVector3
    ) -> IntensitySelection {
        if lightingMode == .highDynamicRange,
           let hdr = entity.value(forKey: "_ambientHDR"),
           let parsed = lightIntensity(hdr, lightingMode: lightingMode) {
            return IntensitySelection(value: parsed, key: "_ambientHDR")
        }
        if let authored = entity.value(forKey: "_ambient"),
           let parsed = lightIntensity(authored, lightingMode: lightingMode) {
            return IntensitySelection(value: parsed, key: "_ambient")
        }
        return IntensitySelection(value: direct * 0.5, key: nil)
    }

    /// Mirrors VRAD `LightForString`: 1, 3, 4, or paired 8-component values;
    /// sRGB channels are raised to 2.2 and remain on VRAD's 0...255 scale.
    private static func lightIntensity(
        _ text: String,
        lightingMode: SourceWorldEnvironmentLightingMode
    ) -> SourceVector3? {
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard [1, 3, 4, 8].contains(parts.count) else { return nil }
        var values: [Double] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Double(part), value.isFinite else { return nil }
            values.append(value)
        }
        if values.count == 8 {
            values = lightingMode == .highDynamicRange
                ? Array(values[4..<8])
                : Array(values[0..<4])
        }
        let red = values[0]
        let green = values.count >= 3 ? values[1] : red
        let blue = values.count >= 3 ? values[2] : red
        let scalar = values.count == 4 ? values[3] : 255
        guard red >= 0, green >= 0, blue >= 0, scalar >= 0 else { return nil }
        let multiplier = scalar / 255
        let result = SourceVector3(
            Float(pow(red / 255, 2.2) * 255 * multiplier),
            Float(pow(green / 255, 2.2) * 255 * multiplier),
            Float(pow(blue / 255, 2.2) * 255 * multiplier)
        )
        return finite(result) ? result : nil
    }

    /// Pinned SDK `SetupLightNormalFromProps`, including ANGLE_UP/DOWN.
    private static func setupLightNormal(
        angles: SourceVector3,
        angle: Float,
        pitch: Float
    ) -> SourceVector3 {
        var output: SourceVector3
        if angle == -1 {
            output = SourceVector3(0, 0, 1)
        } else if angle == -2 {
            output = SourceVector3(0, 0, -1)
        } else {
            let yaw = angle == 0 ? angles.y : angle
            output = SourceVector3(
                cos(yaw * .pi / 180),
                sin(yaw * .pi / 180),
                0
            )
        }
        let selectedPitch = pitch == 0 ? angles.x : pitch
        output.z = sin(selectedPitch * .pi / 180)
        let cosinePitch = cos(selectedPitch * .pi / 180)
        output.x *= cosinePitch
        output.y *= cosinePitch
        return output
    }

    private static func isClass(
        _ entity: SourceCanonicalMapEntityKeyValues,
        _ className: String
    ) -> Bool {
        entity.className?.caseInsensitiveCompare(className) == .orderedSame
    }

    private static func float(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String,
        default defaultValue: Float
    ) throws -> Float {
        guard let text = entity.value(forKey: key) else { return defaultValue }
        guard let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else { throw invalid(entity, key: key) }
        return value
    }

    private static func integer(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let text = entity.value(forKey: key) else { return defaultValue }
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw invalid(entity, key: key)
        }
        return value
    }

    private static func boolean(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String,
        default defaultValue: Bool
    ) throws -> Bool {
        try integer(entity, key: key, default: defaultValue ? 1 : 0) != 0
    }

    private static func vector(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String,
        default defaultValue: SourceVector3
    ) throws -> SourceVector3 {
        guard let text = entity.value(forKey: key) else { return defaultValue }
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 3,
              let x = Float(parts[0]), let y = Float(parts[1]), let z = Float(parts[2]) else {
            throw invalid(entity, key: key)
        }
        let value = SourceVector3(x, y, z)
        guard finite(value) else { throw invalid(entity, key: key) }
        return value
    }

    private static func color32(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String,
        default defaultValue: SIMD4<UInt8>
    ) throws -> SIMD4<UInt8> {
        guard let text = entity.value(forKey: key) else { return defaultValue }
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 3 || parts.count == 4 else {
            throw invalid(entity, key: key)
        }
        var channels: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { throw invalid(entity, key: key) }
            channels.append(value)
        }
        return SIMD4<UInt8>(
            channels[0],
            channels[1],
            channels[2],
            channels.count == 4 ? channels[3] : 255
        )
    }

    private static func materialName(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String,
        default defaultValue: String
    ) throws -> String {
        let authored = entity.value(forKey: key) ?? defaultValue
        var normalized = authored
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasPrefix("materials/") {
            normalized.removeFirst("materials/".count)
        }
        if normalized.hasSuffix(".vmt") {
            normalized.removeLast(".vmt".count)
        }
        let components = normalized.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains(":"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw invalid(entity, key: key)
        }
        return normalized
    }

    private static func displayRGBA(_ color: SIMD4<UInt8>) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(color.x) / 255,
            Float(color.y) / 255,
            Float(color.z) / 255,
            Float(color.w) / 255
        )
    }

    private static func finite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func invalid(
        _ entity: SourceCanonicalMapEntityKeyValues,
        key: String
    ) -> SourceWorldEnvironmentEntityError {
        .invalidValue(
            entityIndex: entity.sourceEntityIndex,
            className: entity.className ?? "<unknown>",
            key: key,
            value: entity.value(forKey: key)
        )
    }
}

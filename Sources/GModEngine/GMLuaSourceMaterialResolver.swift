import Foundation
import GModLua

public enum GMLuaSourceMaterialError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case unsafeLogicalPath(String)
    case encodedMaterialByteCountExceeded(path: String, actual: Int, maximum: Int)
    case materialIsNotUTF8(String)
    case entityMaterialOverrideMissing(String)
    case entityMaterialOverrideRequiresVMT(String)
    case invalidPNGHeader(String)
    case textureWidthExceeded(path: String, actual: Int, maximum: Int)
    case textureHeightExceeded(path: String, actual: Int, maximum: Int)
    case decodedDimensionsMismatch(
        path: String,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )

    public var description: String {
        switch self {
        case let .unsafeLogicalPath(path):
            return "unsafe Source material path: \(path)"
        case let .encodedMaterialByteCountExceeded(path, actual, maximum):
            return "Source material \(path) contains \(actual) encoded bytes; maximum is \(maximum)"
        case let .materialIsNotUTF8(path):
            return "Source material \(path) is not UTF-8"
        case let .entityMaterialOverrideMissing(path):
            return "Source Entity material override is missing from GAME: \(path)"
        case let .entityMaterialOverrideRequiresVMT(path):
            return "Source Entity material override requires a VMT: \(path)"
        case let .invalidPNGHeader(path):
            return "imported material PNG header is invalid: \(path)"
        case let .textureWidthExceeded(path, actual, maximum):
            return "Source texture \(path) width \(actual) exceeds maximum \(maximum)"
        case let .textureHeightExceeded(path, actual, maximum):
            return "Source texture \(path) height \(actual) exceeds maximum \(maximum)"
        case let .decodedDimensionsMismatch(
            path,
            expectedWidth,
            expectedHeight,
            actualWidth,
            actualHeight
        ):
            return "decoded image \(path) is \(actualWidth)x\(actualHeight); " +
                "header declares \(expectedWidth)x\(expectedHeight)"
        }
    }
}

public enum GMLuaSourceEntityColorProxyKind: Sendable, Equatable {
    case playerColor
    case playerWeaponColor
}

/// Ordered Source material-proxy binding retained from the resolved VMT.
/// The renderer may implement only variables whose shader contract it owns;
/// retaining the exact `resultvar` prevents a similarly named proxy from
/// becoming blanket model tinting.
public struct GMLuaSourceEntityColorProxy: Sendable, Equatable {
    public let kind: GMLuaSourceEntityColorProxyKind
    public let resultVariable: String

    public init(
        kind: GMLuaSourceEntityColorProxyKind,
        resultVariable: String
    ) {
        self.kind = kind
        self.resultVariable = resultVariable
    }
}

/// Authored `$detail` shader inputs retained without resolving or decoding the
/// secondary VTF during an ordinary material lookup. World render adapters can
/// request the texture through `resolveTexture` only when the selected shader
/// path actually consumes it.
public struct GMLuaSourceDetailMaterialParameters: Sendable, Equatable {
    public let textureName: String
    public let scale: Float?
    public let blendFactor: Float?
    public let blendMode: Int?
    public let textureTransform: SourceVMTMatrix?

    public init(
        textureName: String,
        scale: Float?,
        blendFactor: Float?,
        blendMode: Int?,
        textureTransform: SourceVMTMatrix?
    ) {
        self.textureName = textureName
        self.scale = scale
        self.blendFactor = blendFactor
        self.blendMode = blendMode
        self.textureTransform = textureTransform
    }
}

/// Exact texture bindings used by Source's `WorldVertexTransition` material.
/// The BSP displacement alpha channel is kept separately on render vertices;
/// this contract deliberately does not guess shader blend math.
public struct GMLuaSourceWorldVertexTransitionParameters: Sendable, Equatable {
    public let baseTexture2Name: String
    public let baseTextureTransform2: SourceVMTMatrix?
    public let blendModulateTextureName: String?

    public init(
        baseTexture2Name: String,
        baseTextureTransform2: SourceVMTMatrix?,
        blendModulateTextureName: String?
    ) {
        self.baseTexture2Name = baseTexture2Name
        self.baseTextureTransform2 = baseTextureTransform2
        self.blendModulateTextureName = blendModulateTextureName
    }
}

/// Complete static result shared by GLua resource handles and renderer adapters.
/// `rgbaBytes == nil` is intentional for real VMTs whose base texture is an
/// engine render target or is absent from the mounted search paths.
public struct GMLuaResolvedSourceMaterial: Sendable, Equatable {
    public let metadata: GMLuaMaterialMetadata
    /// Tightly packed, top-left-origin, straight-alpha RGBA8 mip zero pixels.
    public let rgbaBytes: Data?
    public let sourceTextureFormat: SourceVTFImageFormat?
    public let sourceTextureFlags: SourceVTFTextureFlags?
    /// Every authored VTF mip, largest first. Imported PNGs have one level.
    /// These are the real file levels; the renderer must not synthesize blur.
    public let mipImages: [SourceVTFDecodedImage]
    /// Exact supported entity-colour proxy declarations from the resolved VMT.
    /// They remain ordered because duplicate Source proxy blocks are legal.
    public let entityColorProxies: [GMLuaSourceEntityColorProxy]
    public let detailParameters: GMLuaSourceDetailMaterialParameters?
    public let worldVertexTransitionParameters:
        GMLuaSourceWorldVertexTransitionParameters?

    public init(
        metadata: GMLuaMaterialMetadata,
        rgbaBytes: Data?,
        sourceTextureFormat: SourceVTFImageFormat? = nil,
        sourceTextureFlags: SourceVTFTextureFlags? = nil,
        mipImages: [SourceVTFDecodedImage] = [],
        entityColorProxies: [GMLuaSourceEntityColorProxy] = [],
        detailParameters: GMLuaSourceDetailMaterialParameters? = nil,
        worldVertexTransitionParameters:
            GMLuaSourceWorldVertexTransitionParameters? = nil
    ) {
        self.metadata = metadata
        self.rgbaBytes = rgbaBytes
        self.sourceTextureFormat = sourceTextureFormat
        self.sourceTextureFlags = sourceTextureFlags
        self.entityColorProxies = entityColorProxies
        self.detailParameters = detailParameters
        self.worldVertexTransitionParameters =
            worldVertexTransitionParameters
        if mipImages.isEmpty,
           let dimensions = metadata.dimensions,
           let rgbaBytes {
            self.mipImages = [SourceVTFDecodedImage(
                width: dimensions.width,
                height: dimensions.height,
                rgbaBytes: rgbaBytes
            )]
        } else {
            self.mipImages = mipImages
        }
    }

    public var decodedByteCount: Int {
        mipImages.reduce(0) { $0 + $1.rgbaBytes.count }
    }

    public func pixel(x: Int, y: Int) -> GMLuaRGBA8? {
        guard let dimensions = metadata.dimensions,
              let rgbaBytes,
              x >= 0,
              y >= 0,
              x < dimensions.width,
              y < dimensions.height else { return nil }
        let offset = (y * dimensions.width + x) * 4
        guard offset + 3 < rgbaBytes.count else { return nil }
        return GMLuaRGBA8(
            red: rgbaBytes[offset],
            green: rgbaBytes[offset + 1],
            blue: rgbaBytes[offset + 2],
            alpha: rgbaBytes[offset + 3]
        )
    }
}

public enum GMLuaSourceTextureDecodeStatus: Sendable, Equatable {
    case decoded
    case missing
    case unsupportedImageFormat(SourceVTFImageFormat)
}

/// Controls how much of an authored Source texture is decoded and retained.
/// Surface/VGUI only samples mip zero; the world renderer samples the real
/// authored chain. Keeping this in the core resolver (and its cache key)
/// prevents a Surface-only request from paying to decode every VTF mip.
public enum GMLuaSourceTextureMipPolicy: Sendable, Equatable, Hashable {
    case mipZeroOnly
    case authoredChain
}

public struct GMLuaResolvedSourceTexture: Sendable, Equatable {
    public let logicalPath: String
    public let width: Int?
    public let height: Int?
    public let rgbaBytes: Data?
    public let imageFormat: SourceVTFImageFormat?
    public let flags: SourceVTFTextureFlags?
    public let mipImages: [SourceVTFDecodedImage]
    public let status: GMLuaSourceTextureDecodeStatus
}

public struct GMLuaSourceTextureScroll: Sendable, Equatable {
    public let targetVariable: String
    public let rate: Float
    public let angleDegrees: Float
}

/// Shader-specific Water inputs parsed from the real resolved VMT. Optional
/// values remain absent rather than being replaced with invented defaults.
public struct GMLuaResolvedSourceWaterMaterial: Sendable, Equatable {
    public let materialPath: String
    public let isAboveWater: Bool?
    public let fogEnabled: Bool?
    /// Raw Source 0...255 VMT color components.
    public let fogColor: [Float]?
    public let fogStart: Float?
    public let fogEnd: Float?
    public let reflectionAmount: Float?
    public let refractionAmount: Float?
    public let normalTexture: GMLuaResolvedSourceTexture?
    public let bumpTexture: GMLuaResolvedSourceTexture?
    public let textureScroll: GMLuaSourceTextureScroll?
}

/// Bounded Source VMT/VTF material resolver. It resolves the explicit VMT
/// `$basetexture` binding (or an explicitly imported PNG) and retains exact
/// supported entity-colour proxy declarations. Proxy evaluation, animation
/// frames, cubemap faces, environment maps, and wrap behavior belong to their
/// renderer contracts.
public final class GMLuaSourceMaterialResolver: GMLuaMaterialMetadataResolver,
    @unchecked Sendable
{
    public typealias Loader = @Sendable (_ logicalPath: String) throws -> Data?
    /// Monotonic identity of the loader's active content/search-path mount.
    /// A request retains the value captured before its first cache lookup.
    public typealias ContentEpochProvider = @Sendable () -> UInt64

    public static let defaultMaximumEncodedMaterialByteCount = 1 * 1_024 * 1_024
    public static let defaultMaximumEncodedTextureByteCount = 16 * 1_024 * 1_024
    public static let defaultMaximumTextureWidth = 4_096
    public static let defaultMaximumTextureHeight = 4_096
    // Stock gm_construct contains 2048x2048 base textures. Keep the resolver
    // bounded, but admit that exact Source-era size for world rendering.
    public static let defaultMaximumTexturePixelCount = 4_194_304
    public static let defaultMaximumDecodedTextureByteCount = 16 * 1_024 * 1_024

    private struct Key: Hashable {
        let contentEpoch: UInt64
        let canonicalMaterialPath: String
        let encodedParameters: LuaString?
        let mipPolicy: GMLuaSourceTextureMipPolicy
    }

    private let loader: Loader
    private let contentEpochProvider: ContentEpochProvider
    private let maximumPatchDepth: Int
    private let maximumEncodedMaterialByteCount: Int
    private let maximumTextureWidth: Int
    private let maximumTextureHeight: Int
    private let maximumCachedEntryCount: Int
    private let maximumCachedByteCount: Int
    private let vtfLimits: SourceVTFAllocationLimits
    private let lock = NSLock()
    private var cache: [Key: GMLuaResolvedSourceMaterial] = [:]
    private var cacheOrder: [Key] = []
    private var cachedByteCountStorage = 0

    public init(
        maximumPatchDepth: Int = 10,
        maximumCachedEntryCount: Int = 512,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024,
        maximumEncodedMaterialByteCount: Int =
            GMLuaSourceMaterialResolver.defaultMaximumEncodedMaterialByteCount,
        maximumEncodedTextureByteCount: Int =
            GMLuaSourceMaterialResolver.defaultMaximumEncodedTextureByteCount,
        maximumTextureWidth: Int =
            GMLuaSourceMaterialResolver.defaultMaximumTextureWidth,
        maximumTextureHeight: Int =
            GMLuaSourceMaterialResolver.defaultMaximumTextureHeight,
        maximumTexturePixelCount: Int =
            GMLuaSourceMaterialResolver.defaultMaximumTexturePixelCount,
        maximumDecodedTextureByteCount: Int =
            GMLuaSourceMaterialResolver.defaultMaximumDecodedTextureByteCount,
        contentEpochProvider: @escaping ContentEpochProvider = { 0 },
        loader: @escaping Loader
    ) {
        self.maximumPatchDepth = max(0, maximumPatchDepth)
        self.maximumCachedEntryCount = max(1, maximumCachedEntryCount)
        self.maximumCachedByteCount = max(1, maximumCachedByteCount)
        self.maximumEncodedMaterialByteCount = max(1, maximumEncodedMaterialByteCount)
        self.maximumTextureWidth = max(1, maximumTextureWidth)
        self.maximumTextureHeight = max(1, maximumTextureHeight)
        vtfLimits = SourceVTFAllocationLimits(
            maximumEncodedBytes: max(1, maximumEncodedTextureByteCount),
            maximumPixelCount: max(1, maximumTexturePixelCount),
            maximumDecodedBytes: max(1, maximumDecodedTextureByteCount)
        )
        self.contentEpochProvider = contentEpochProvider
        self.loader = loader
    }

    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public var cachedImageByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedByteCountStorage
    }

    public func removeAllCachedMaterials() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        cachedByteCountStorage = 0
        lock.unlock()
    }

    public func metadata(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaMaterialMetadata {
        try resolve(
            materialPath: materialPath,
            encodedParameters: encodedParameters
        ).metadata
    }

    public func dimensions(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaImageDimensions? {
        try resolve(
            materialPath: materialPath,
            encodedParameters: encodedParameters
        ).metadata.dimensions
    }

    public func pixel(
        materialPath: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int
    ) throws -> GMLuaRGBA8? {
        try resolve(
            materialPath: materialPath,
            encodedParameters: encodedParameters
        ).pixel(x: x, y: y)
    }

    public func resolve(
        named materialName: String,
        encodedParameters: LuaString? = nil,
        mipPolicy: GMLuaSourceTextureMipPolicy = .mipZeroOnly
    ) throws -> GMLuaResolvedSourceMaterial {
        try resolve(
            materialPath: LuaString(materialName),
            encodedParameters: encodedParameters,
            mipPolicy: mipPolicy
        )
    }

    /// Resolves the public `Entity:SetMaterial` spelling to one real GAME VMT.
    /// Empty input clears the override. Missing materials and imported images
    /// are rejected before canonical state or its replication revision moves.
    public func resolveEntityMaterialOverride(
        named materialName: String
    ) throws -> SourceEntityMaterialOverride? {
        guard !materialName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return nil }
        let resolved = try resolve(named: materialName)
        let logicalPath = resolved.metadata.materialPath.utf8String
        guard resolved.metadata.status != .materialMissing else {
            throw GMLuaSourceMaterialError.entityMaterialOverrideMissing(
                logicalPath
            )
        }
        let lowercasedPath = logicalPath.lowercased()
        guard lowercasedPath.hasPrefix("materials/"),
              lowercasedPath.hasSuffix(".vmt") else {
            throw GMLuaSourceMaterialError.entityMaterialOverrideRequiresVMT(
                logicalPath
            )
        }
        let nameStart = lowercasedPath.index(
            lowercasedPath.startIndex,
            offsetBy: "materials/".count
        )
        let nameEnd = lowercasedPath.index(
            lowercasedPath.endIndex,
            offsetBy: -".vmt".count
        )
        let canonicalName = String(lowercasedPath[nameStart..<nameEnd])
        return SourceEntityMaterialOverride(
            name: canonicalName,
            logicalMaterialPath: lowercasedPath
        )
    }

    public func resolve(
        materialPath: LuaString,
        encodedParameters: LuaString? = nil,
        mipPolicy: GMLuaSourceTextureMipPolicy = .mipZeroOnly
    ) throws -> GMLuaResolvedSourceMaterial {
        let sourceName = materialPath.utf8String
        guard LuaString(sourceName) == materialPath,
              let logicalPath = try Self.normalizedMaterialPath(sourceName) else {
            throw GMLuaSourceMaterialError.unsafeLogicalPath(sourceName)
        }
        // Capture the mount identity before touching either cache or loader.
        // A concurrent content swap can let this request finish, but its old-
        // epoch result can never satisfy a lookup begun against the new mount.
        let key = Key(
            contentEpoch: contentEpochProvider(),
            canonicalMaterialPath: logicalPath.lowercased(),
            encodedParameters: encodedParameters,
            mipPolicy: mipPolicy
        )
        if let cached = cachedValue(for: key) { return cached }

        let resolved: GMLuaResolvedSourceMaterial
        if logicalPath.lowercased().hasSuffix(".png") {
            resolved = try resolveImportedPNG(
                logicalPath: logicalPath,
                encodedParameters: encodedParameters
            )
        } else {
            resolved = try resolveVMT(
                logicalPath: logicalPath,
                mipPolicy: mipPolicy
            )
        }
        store(resolved, for: key)
        return resolved
    }

    /// Resolves one explicit Source VTF through the same bounded loader used
    /// by material base textures and Water normal maps.
    public func resolveTexture(
        named textureName: String,
        mipPolicy: GMLuaSourceTextureMipPolicy = .mipZeroOnly
    ) throws -> GMLuaResolvedSourceTexture? {
        try resolveSourceTexture(named: textureName, mipPolicy: mipPolicy)
    }

    public func resolveWater(
        named materialName: String,
        mipPolicy: GMLuaSourceTextureMipPolicy = .mipZeroOnly
    ) throws -> GMLuaResolvedSourceWaterMaterial? {
        guard let logicalPath = try Self.normalizedMaterialPath(materialName),
              let document = try loadVMTDocument(logicalPath: logicalPath),
              document.shader.caseInsensitiveCompare("Water") == .orderedSame else {
            return nil
        }

        func float(_ name: String) throws -> Float? {
            guard let number = try document.number(named: name) else { return nil }
            let converted = Float(number)
            guard converted.isFinite else {
                throw SourceVMTError.invalidNumber(name, String(number))
            }
            return converted
        }
        let fogColor = try document.vector(named: "$fogcolor", componentCount: 3...3)?
            .map { Float($0) }
        let normalTexture = try document.string(named: "$normalmap")
            .flatMap { try resolveSourceTexture(named: $0, mipPolicy: mipPolicy) }
        let bumpTexture = try document.string(named: "$bumpmap")
            .flatMap { try resolveSourceTexture(named: $0, mipPolicy: mipPolicy) }

        let textureScroll = document.proxies.first(where: {
            $0.name.caseInsensitiveCompare("TextureScroll") == .orderedSame
        }).flatMap { proxy -> GMLuaSourceTextureScroll? in
            func value(_ name: String) -> String? {
                for entry in proxy.parameters where
                    entry.key.caseInsensitiveCompare(name) == .orderedSame {
                    guard case let .string(value) = entry.value else { return nil }
                    return value
                }
                return nil
            }
            guard let target = value("texturescrollvar"),
                  let rawRate = value("texturescrollrate"),
                  let rawAngle = value("texturescrollangle"),
                  let rate = Float(rawRate), rate.isFinite,
                  let angle = Float(rawAngle), angle.isFinite else { return nil }
            return GMLuaSourceTextureScroll(
                targetVariable: target,
                rate: rate,
                angleDegrees: angle
            )
        }
        return GMLuaResolvedSourceWaterMaterial(
            materialPath: logicalPath,
            isAboveWater: try document.boolean(named: "$abovewater"),
            fogEnabled: try document.boolean(named: "$fogenable"),
            fogColor: fogColor,
            fogStart: try float("$fogstart"),
            fogEnd: try float("$fogend"),
            reflectionAmount: try float("$reflectamount"),
            refractionAmount: try float("$refractamount"),
            normalTexture: normalTexture,
            bumpTexture: bumpTexture,
            textureScroll: textureScroll
        )
    }

    private func resolveVMT(
        logicalPath: String,
        mipPolicy: GMLuaSourceTextureMipPolicy
    ) throws -> GMLuaResolvedSourceMaterial {
        guard let document = try loadVMTDocument(logicalPath: logicalPath) else {
            return missingMaterial(logicalPath)
        }
        let shader = LuaString(document.shader)
        let entityColorProxies = Self.entityColorProxies(in: document)
        let detailParameters = try Self.detailParameters(in: document)
        let worldVertexTransitionParameters = try Self
            .worldVertexTransitionParameters(in: document)
        guard let baseTextureValue = try document.string(named: "$basetexture"),
              !baseTextureValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GMLuaResolvedSourceMaterial(
                metadata: GMLuaMaterialMetadata(
                    materialPath: LuaString(logicalPath),
                    shaderName: shader,
                    baseTextureName: nil,
                    dimensions: nil,
                    isError: false,
                    status: .materialWithoutBaseTexture
                ),
                rgbaBytes: nil,
                entityColorProxies: entityColorProxies,
                detailParameters: detailParameters,
                worldVertexTransitionParameters:
                    worldVertexTransitionParameters
            )
        }
        guard let baseTexturePath = try Self.normalizedVTFPath(baseTextureValue) else {
            throw GMLuaSourceMaterialError.unsafeLogicalPath(baseTextureValue)
        }
        guard let encodedVTF = try load(baseTexturePath) else {
            return GMLuaResolvedSourceMaterial(
                metadata: GMLuaMaterialMetadata(
                    materialPath: LuaString(logicalPath),
                    shaderName: shader,
                    baseTextureName: LuaString(baseTexturePath),
                    dimensions: nil,
                    isError: false,
                    status: .baseTextureMissing
                ),
                rgbaBytes: nil,
                entityColorProxies: entityColorProxies,
                detailParameters: detailParameters,
                worldVertexTransitionParameters:
                    worldVertexTransitionParameters
            )
        }

        let vtf = try SourceVTFFile(data: encodedVTF, allocationLimits: vtfLimits)
        try validateDimensions(
            width: vtf.width,
            height: vtf.height,
            logicalPath: baseTexturePath
        )
        let mipImages = try Self.decodeMipImages(from: vtf, policy: mipPolicy)
        guard let image = mipImages.first else {
            throw SourceVTFError.invalidMipCount(0, maximum: vtf.mipCount)
        }
        return GMLuaResolvedSourceMaterial(
            metadata: GMLuaMaterialMetadata(
                materialPath: LuaString(logicalPath),
                shaderName: shader,
                baseTextureName: LuaString(baseTexturePath),
                dimensions: GMLuaImageDimensions(width: image.width, height: image.height),
                isError: false,
                status: .resolved
            ),
            rgbaBytes: image.rgbaBytes,
            sourceTextureFormat: vtf.imageFormat,
            sourceTextureFlags: vtf.flags,
            mipImages: mipImages,
            entityColorProxies: entityColorProxies,
            detailParameters: detailParameters,
            worldVertexTransitionParameters: worldVertexTransitionParameters
        )
    }

    private static func detailParameters(
        in document: SourceVMTDocument
    ) throws -> GMLuaSourceDetailMaterialParameters? {
        guard let rawTexture = try document.string(named: "$detail"),
              !rawTexture.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else { return nil }
        guard let textureName = try normalizedVTFPath(rawTexture) else {
            throw GMLuaSourceMaterialError.unsafeLogicalPath(rawTexture)
        }

        func float(_ name: String) throws -> Float? {
            guard let number = try document.number(named: name) else {
                return nil
            }
            let value = Float(number)
            guard value.isFinite else {
                throw SourceVMTError.invalidNumber(name, String(number))
            }
            return value
        }

        let blendMode: Int?
        if let number = try document.number(named: "$detailblendmode") {
            guard let value = Int(exactly: number) else {
                throw SourceVMTError.invalidNumber(
                    "$detailblendmode",
                    String(number)
                )
            }
            blendMode = value
        } else {
            blendMode = nil
        }

        return GMLuaSourceDetailMaterialParameters(
            textureName: textureName,
            scale: try float("$detailscale"),
            blendFactor: try float("$detailblendfactor"),
            blendMode: blendMode,
            textureTransform: try document.matrix(
                named: "$detailtexturetransform"
            )
        )
    }

    private static func worldVertexTransitionParameters(
        in document: SourceVMTDocument
    ) throws -> GMLuaSourceWorldVertexTransitionParameters? {
        guard document.shader.caseInsensitiveCompare(
            "WorldVertexTransition"
        ) == .orderedSame,
        let rawBaseTexture2 = try document.string(named: "$basetexture2"),
        !rawBaseTexture2.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return nil }
        guard let baseTexture2Name = try normalizedVTFPath(rawBaseTexture2) else {
            throw GMLuaSourceMaterialError.unsafeLogicalPath(rawBaseTexture2)
        }

        let blendModulateTextureName: String?
        if let rawBlend = try document.string(named: "$blendmodulatetexture"),
           !rawBlend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = try normalizedVTFPath(rawBlend) else {
                throw GMLuaSourceMaterialError.unsafeLogicalPath(rawBlend)
            }
            blendModulateTextureName = normalized
        } else {
            blendModulateTextureName = nil
        }

        return GMLuaSourceWorldVertexTransitionParameters(
            baseTexture2Name: baseTexture2Name,
            baseTextureTransform2: try document.matrix(
                named: "$basetexturetransform2"
            ),
            blendModulateTextureName: blendModulateTextureName
        )
    }

    private static func entityColorProxies(
        in document: SourceVMTDocument
    ) -> [GMLuaSourceEntityColorProxy] {
        document.proxies.compactMap { proxy in
            let kind: GMLuaSourceEntityColorProxyKind
            if proxy.name.caseInsensitiveCompare("PlayerColor") == .orderedSame {
                kind = .playerColor
            } else if proxy.name.caseInsensitiveCompare("PlayerWeaponColor") ==
                        .orderedSame {
                kind = .playerWeaponColor
            } else {
                return nil
            }
            guard let result = proxy.parameters.first(where: {
                $0.key.caseInsensitiveCompare("resultvar") == .orderedSame
            }), case let .string(resultVariable) = result.value,
               !resultVariable.trimmingCharacters(
                in: .whitespacesAndNewlines
               ).isEmpty else {
                return nil
            }
            return GMLuaSourceEntityColorProxy(
                kind: kind,
                resultVariable: resultVariable
            )
        }
    }

    private func loadVMTDocument(
        logicalPath: String
    ) throws -> SourceVMTDocument? {
        guard let encodedVMT = try load(logicalPath) else { return nil }
        let source = try vmtSource(encodedVMT, logicalPath: logicalPath)
        let includeResolver = SourceVMTIncludeResolver { [self] includeName in
            guard let includePath = try Self.normalizedVMTPath(includeName) else {
                throw GMLuaSourceMaterialError.unsafeLogicalPath(includeName)
            }
            guard let includeData = try load(includePath) else { return nil }
            return try vmtSource(includeData, logicalPath: includePath)
        }
        return try SourceVMTDocument.parse(
            source: source,
            sourceName: logicalPath,
            resolver: includeResolver,
            maximumPatchDepth: maximumPatchDepth
        )
    }

    private func resolveSourceTexture(
        named textureName: String,
        mipPolicy: GMLuaSourceTextureMipPolicy
    ) throws -> GMLuaResolvedSourceTexture? {
        guard let logicalPath = try Self.normalizedVTFPath(textureName) else {
            throw GMLuaSourceMaterialError.unsafeLogicalPath(textureName)
        }
        guard let encoded = try load(logicalPath) else {
            return GMLuaResolvedSourceTexture(
                logicalPath: logicalPath,
                width: nil,
                height: nil,
                rgbaBytes: nil,
                imageFormat: nil,
                flags: nil,
                mipImages: [],
                status: .missing
            )
        }
        let vtf = try SourceVTFFile(data: encoded, allocationLimits: vtfLimits)
        try validateDimensions(
            width: vtf.width,
            height: vtf.height,
            logicalPath: logicalPath
        )
        do {
            let mipImages = try Self.decodeMipImages(from: vtf, policy: mipPolicy)
            guard let image = mipImages.first else {
                throw SourceVTFError.invalidMipCount(0, maximum: vtf.mipCount)
            }
            return GMLuaResolvedSourceTexture(
                logicalPath: logicalPath,
                width: image.width,
                height: image.height,
                rgbaBytes: image.rgbaBytes,
                imageFormat: vtf.imageFormat,
                flags: vtf.flags,
                mipImages: mipImages,
                status: .decoded
            )
        } catch let SourceVTFError.unsupportedImageFormat(format) {
            return GMLuaResolvedSourceTexture(
                logicalPath: logicalPath,
                width: vtf.width,
                height: vtf.height,
                rgbaBytes: nil,
                imageFormat: vtf.imageFormat,
                flags: vtf.flags,
                mipImages: [],
                status: .unsupportedImageFormat(format)
            )
        }
    }

    private func resolveImportedPNG(
        logicalPath: String,
        encodedParameters: LuaString?
    ) throws -> GMLuaResolvedSourceMaterial {
        guard let encoded = try load(logicalPath) else {
            return missingMaterial(logicalPath)
        }
        guard encoded.count <= vtfLimits.maximumEncodedBytes else {
            throw GMLuaSourceMaterialError.encodedMaterialByteCountExceeded(
                path: logicalPath,
                actual: encoded.count,
                maximum: vtfLimits.maximumEncodedBytes
            )
        }
        let header = try pngDimensions(encoded, logicalPath: logicalPath)
        try validateDimensions(
            width: header.width,
            height: header.height,
            logicalPath: logicalPath
        )
        let pixels = header.width.multipliedReportingOverflow(by: header.height)
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !pixels.overflow,
              pixels.partialValue <= vtfLimits.maximumPixelCount,
              !bytes.overflow,
              bytes.partialValue <= vtfLimits.maximumDecodedBytes else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "imported PNG decoded RGBA8 bytes",
                limit: vtfLimits.maximumDecodedBytes,
                actual: bytes.partialValue
            )
        }
        let decoded = try GMLuaPlatformImageDecoder.decode(encoded)
        guard decoded.width == header.width, decoded.height == header.height else {
            throw GMLuaSourceMaterialError.decodedDimensionsMismatch(
                path: logicalPath,
                expectedWidth: header.width,
                expectedHeight: header.height,
                actualWidth: decoded.width,
                actualHeight: decoded.height
            )
        }
        var rgbaBytes = Data(count: bytes.partialValue)
        var complete = true
        rgbaBytes.withUnsafeMutableBytes { rawBytes in
            let output = rawBytes.bindMemory(to: UInt8.self)
            for y in 0..<decoded.height {
                for x in 0..<decoded.width {
                    guard let pixel = decoded.pixel(x: x, y: y) else {
                        complete = false
                        continue
                    }
                    let offset = (y * decoded.width + x) * 4
                    output[offset] = pixel.red
                    output[offset + 1] = pixel.green
                    output[offset + 2] = pixel.blue
                    output[offset + 3] = pixel.alpha
                }
            }
        }
        guard complete else { throw GMLuaImageDecodeError.platformFailure }

        let parameters = encodedParameters?.utf8String.lowercased() ?? ""
        let tokens = parameters.split(whereSeparator: { $0.isWhitespace })
        let shader = tokens.contains("vertexlitgeneric")
            ? LuaString("VertexLitGeneric")
            : LuaString("UnlitGeneric")
        return GMLuaResolvedSourceMaterial(
            metadata: GMLuaMaterialMetadata(
                materialPath: LuaString(logicalPath),
                shaderName: shader,
                baseTextureName: LuaString(logicalPath),
                dimensions: GMLuaImageDimensions(width: decoded.width, height: decoded.height),
                isError: false,
                status: .resolved
            ),
            rgbaBytes: rgbaBytes
        )
    }

    private func missingMaterial(_ logicalPath: String) -> GMLuaResolvedSourceMaterial {
        GMLuaResolvedSourceMaterial(
            metadata: GMLuaMaterialMetadata(
                materialPath: LuaString(logicalPath),
                shaderName: "shader_error",
                baseTextureName: nil,
                dimensions: nil,
                isError: true,
                status: .materialMissing
            ),
            rgbaBytes: nil
        )
    }

    private func load(_ logicalPath: String) throws -> Data? {
        if let data = try loader(logicalPath) { return data }
        let folded = logicalPath.lowercased()
        guard folded != logicalPath else { return nil }
        return try loader(folded)
    }

    private func vmtSource(
        _ data: Data,
        logicalPath: String
    ) throws -> String {
        guard data.count <= maximumEncodedMaterialByteCount else {
            throw GMLuaSourceMaterialError.encodedMaterialByteCountExceeded(
                path: logicalPath,
                actual: data.count,
                maximum: maximumEncodedMaterialByteCount
            )
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let source = String(data: body, encoding: .utf8) else {
            throw GMLuaSourceMaterialError.materialIsNotUTF8(logicalPath)
        }
        return source
    }

    private func validateDimensions(
        width: Int,
        height: Int,
        logicalPath: String
    ) throws {
        guard width <= maximumTextureWidth else {
            throw GMLuaSourceMaterialError.textureWidthExceeded(
                path: logicalPath,
                actual: width,
                maximum: maximumTextureWidth
            )
        }
        guard height <= maximumTextureHeight else {
            throw GMLuaSourceMaterialError.textureHeightExceeded(
                path: logicalPath,
                actual: height,
                maximum: maximumTextureHeight
            )
        }
    }

    private static func decodeMipImages(
        from vtf: SourceVTFFile,
        policy: GMLuaSourceTextureMipPolicy
    ) throws -> [SourceVTFDecodedImage] {
        var images: [SourceVTFDecodedImage] = []
        let decodedMipCount = policy == .authoredChain ? vtf.mipCount : 1
        images.reserveCapacity(decodedMipCount)
        for mipLevel in 0..<decodedMipCount {
            images.append(try vtf.decodeRGBA8(
                mipLevel: mipLevel,
                frame: 0,
                face: 0,
                slice: 0
            ))
        }
        return images
    }

    private func pngDimensions(
        _ data: Data,
        logicalPath: String
    ) throws -> (width: Int, height: Int) {
        guard data.count >= 24,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(data[8..<12]) == [0, 0, 0, 13],
              Array(data[12..<16]) == [73, 72, 68, 82] else {
            throw GMLuaSourceMaterialError.invalidPNGHeader(logicalPath)
        }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) << 24 |
                UInt32(data[offset + 1]) << 16 |
                UInt32(data[offset + 2]) << 8 |
                UInt32(data[offset + 3])
        }
        let width = uint32(16)
        let height = uint32(20)
        guard width > 0,
              height > 0,
              let safeWidth = Int(exactly: width),
              let safeHeight = Int(exactly: height) else {
            throw GMLuaSourceMaterialError.invalidPNGHeader(logicalPath)
        }
        return (safeWidth, safeHeight)
    }

    private func cachedValue(for key: Key) -> GMLuaResolvedSourceMaterial? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return value
    }

    private func store(_ value: GMLuaResolvedSourceMaterial, for key: Key) {
        let byteCount = value.decodedByteCount
        guard byteCount <= maximumCachedByteCount else { return }
        lock.lock()
        defer { lock.unlock() }
        if let previous = cache.removeValue(forKey: key) {
            cachedByteCountStorage -= previous.decodedByteCount
            cacheOrder.removeAll { $0 == key }
        }
        while !cacheOrder.isEmpty && (
            cache.count >= maximumCachedEntryCount ||
                cachedByteCountStorage > maximumCachedByteCount - byteCount
        ) {
            let oldest = cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedByteCountStorage -= evicted.decodedByteCount
            }
        }
        cache[key] = value
        cacheOrder.append(key)
        cachedByteCountStorage += byteCount
    }

    private static func normalizedMaterialPath(_ name: String) throws -> String? {
        guard var path = try normalizedAssetStem(name) else { return nil }
        let lower = path.lowercased()
        if lower.hasSuffix(".png") || lower.hasSuffix(".vmt") {
            return "materials/" + path
        }
        path += ".vmt"
        return "materials/" + path
    }

    private static func normalizedVMTPath(_ name: String) throws -> String? {
        guard var path = try normalizedAssetStem(name) else { return nil }
        if !path.lowercased().hasSuffix(".vmt") { path += ".vmt" }
        return "materials/" + path
    }

    private static func normalizedVTFPath(_ name: String) throws -> String? {
        guard var path = try normalizedAssetStem(name) else { return nil }
        if !path.lowercased().hasSuffix(".vtf") { path += ".vtf" }
        return "materials/" + path
    }

    private static func normalizedAssetStem(_ name: String) throws -> String? {
        var path = name
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.hasPrefix("/") else { return nil }
        if path.lowercased().hasPrefix("materials/") {
            path.removeFirst("materials/".count)
        }
        guard !path.isEmpty,
              !path.contains(":"),
              !path.contains("\0") else { return nil }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.map(String.init).joined(separator: "/")
    }
}

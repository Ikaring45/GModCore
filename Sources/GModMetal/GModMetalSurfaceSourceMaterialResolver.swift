import Foundation
import GModEngine

/// Lossless outcome for one Studio VMT candidate. Callers may continue to the
/// next ordered candidate only for `materialMissing`; an existing VMT with an
/// unusable base texture remains the authoritative stopping point.
public enum GModMetalStudioMaterialCandidateResolution: Sendable, Equatable {
    case materialMissing
    case materialWithoutBaseTexture
    case baseTextureMissing
    case resolved(GModMetalSurfaceBitmap)
}

public enum GModMetalStudioMaterialCandidateError:
    Error,
    Sendable,
    Equatable
{
    case resolvedMaterialHasNoBitmap(String)
}

public enum GModMetalWorldTerrainMaterialError:
    Error,
    Sendable,
    Equatable
{
    case invalidTextureTransform(String)
}

/// Metal-facing adapter over the same VMT/VTF core used by IMaterial and
/// ITexture. It performs only the alpha-premultiplication required by the
/// Surface shader and retains a separately bounded bitmap cache so a frame
/// never repeats that conversion.
public final class GModMetalSurfaceSourceMaterialResolver:
    GModMetalSurfaceTextureResolving,
    @unchecked Sendable
{
    private struct CacheKey: Hashable {
        let contentEpoch: UInt64
        let logicalKey: String
    }

    private enum CachedResult {
        case missing
        case bitmap(GModMetalSurfaceBitmap)
    }

    public let sourceMaterialResolver: GMLuaSourceMaterialResolver

    private let maximumCachedEntryCount: Int
    private let maximumCachedByteCount: Int
    private let contentEpochProvider:
        GMLuaSourceMaterialResolver.ContentEpochProvider
    private let lock = NSLock()
    private var cache: [CacheKey: CachedResult] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cachedByteCountStorage = 0

    public convenience init(
        maximumCachedEntryCount: Int = 512,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024,
        contentEpochProvider: @escaping
            GMLuaSourceMaterialResolver.ContentEpochProvider = { 0 },
        loader: @escaping GMLuaSourceMaterialResolver.Loader
    ) {
        self.init(
            sourceMaterialResolver: GMLuaSourceMaterialResolver(
                contentEpochProvider: contentEpochProvider,
                loader: loader
            ),
            maximumCachedEntryCount: maximumCachedEntryCount,
            maximumCachedByteCount: maximumCachedByteCount,
            contentEpochProvider: contentEpochProvider
        )
    }

    public init(
        sourceMaterialResolver: GMLuaSourceMaterialResolver,
        maximumCachedEntryCount: Int = 512,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024,
        contentEpochProvider: @escaping
            GMLuaSourceMaterialResolver.ContentEpochProvider = { 0 }
    ) {
        self.sourceMaterialResolver = sourceMaterialResolver
        self.maximumCachedEntryCount = max(1, maximumCachedEntryCount)
        self.maximumCachedByteCount = max(1, maximumCachedByteCount)
        self.contentEpochProvider = contentEpochProvider
    }

    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public var cachedTextureByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedByteCountStorage
    }

    public func removeAllCachedTextures() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        cachedByteCountStorage = 0
        lock.unlock()
        sourceMaterialResolver.removeAllCachedMaterials()
    }

    public func resolveSurfaceTexture(
        named logicalName: String
    ) throws -> GModMetalSurfaceBitmap? {
        try resolveTexture(named: logicalName, retainingAuthoredMipChain: false)
    }

    /// World materials retain the VTF-authored mip chain for Source minification.
    /// VGUI Surface deliberately uses mip zero only because its sampler is
    /// non-mipmapped and retaining the other levels would consume CPU/GPU cache
    /// and upload budget without ever sampling them.
    public func resolveWorldTexture(
        named logicalName: String
    ) throws -> GModMetalSurfaceBitmap? {
        try resolveTexture(named: logicalName, retainingAuthoredMipChain: true)
    }

    /// Resolves secondary terrain bindings only when the real VMT declares
    /// them. Defaults are the values authored by Valve's Source shaders:
    /// detail scale 4, blend factor 1, and combine mode 0.
    public func resolveWorldTerrainMaterial(
        named logicalName: String
    ) throws -> GModMetalWorldTerrainMaterial? {
        let resolved = try sourceMaterialResolver.resolve(
            named: logicalName,
            mipPolicy: .authoredChain
        )

        func textureResolution(
            _ textureName: String
        ) -> GModMetalWorldMaterialResolution {
            do {
                return try resolveWorldSourceTexture(named: textureName).map {
                    .resolved($0)
                } ?? .sourceMissing
            } catch {
                return .decodeFailed(String(describing: error))
            }
        }

        let detail: GModMetalWorldDetailMaterial?
        if let parameters = resolved.detailParameters {
            let scale = parameters.scale ?? 4
            let blendFactor = parameters.blendFactor ?? 1
            let blendMode = parameters.blendMode ?? 0
            guard scale.isFinite, blendFactor.isFinite,
                  let transform = Self.makeUVTransform(
                    parameters.textureTransform,
                    scale: scale
                  ) else {
                throw GModMetalWorldTerrainMaterialError
                    .invalidTextureTransform(parameters.textureName)
            }
            detail = GModMetalWorldDetailMaterial(
                textureName: parameters.textureName,
                textureResolution: textureResolution(parameters.textureName),
                textureTransform: transform,
                blendFactor: blendFactor,
                blendMode: blendMode
            )
        } else {
            detail = nil
        }

        let vertexTransition: GModMetalWorldVertexTransitionMaterial?
        if let parameters = resolved.worldVertexTransitionParameters {
            guard let blendMaskTransform = Self.makeUVTransform(
                parameters.blendMaskTransform,
                scale: 1
            ) else {
                throw GModMetalWorldTerrainMaterialError
                    .invalidTextureTransform(
                        parameters.blendModulateTextureName ??
                            parameters.baseTexture2Name
                    )
            }
            vertexTransition = GModMetalWorldVertexTransitionMaterial(
                baseTexture2Name: parameters.baseTexture2Name,
                baseTexture2Resolution: textureResolution(
                    parameters.baseTexture2Name
                ),
                blendModulateTextureName:
                    parameters.blendModulateTextureName,
                blendModulateResolution:
                    parameters.blendModulateTextureName.map(textureResolution),
                blendMaskTransform: blendMaskTransform
            )
        } else {
            vertexTransition = nil
        }

        guard detail != nil || vertexTransition != nil else { return nil }
        return GModMetalWorldTerrainMaterial(
            detail: detail,
            vertexTransition: vertexTransition
        )
    }

    /// Resolves one ordered Studio VMT candidate without collapsing distinct
    /// Source absence/failure boundaries into an optional bitmap.
    public func resolveStudioMaterialCandidate(
        named logicalName: String
    ) throws -> GModMetalStudioMaterialCandidateResolution {
        let resolved = try sourceMaterialResolver.resolve(
            named: logicalName,
            mipPolicy: .authoredChain
        )
        switch resolved.metadata.status {
        case .materialMissing:
            return .materialMissing
        case .materialWithoutBaseTexture:
            return .materialWithoutBaseTexture
        case .baseTextureMissing:
            return .baseTextureMissing
        case .resolved:
            guard let bitmap = try resolveWorldTexture(named: logicalName) else {
                throw GModMetalStudioMaterialCandidateError
                    .resolvedMaterialHasNoBitmap(logicalName)
            }
            return .resolved(bitmap)
        }
    }

    /// Returns the ordered entity-colour proxy declarations from the same
    /// resolved Studio VMT. Bitmap caching remains independent because two
    /// VMTs may share one VTF while binding different material variables.
    public func resolveStudioEntityColorProxies(
        named logicalName: String
    ) throws -> [GMLuaSourceEntityColorProxy] {
        try sourceMaterialResolver.resolve(
            named: logicalName,
            mipPolicy: .authoredChain
        ).entityColorProxies
    }

    private func resolveTexture(
        named logicalName: String,
        retainingAuthoredMipChain: Bool
    ) throws -> GModMetalSurfaceBitmap? {
        let logicalKey = logicalName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !logicalKey.isEmpty else { return nil }
        let key = CacheKey(
            contentEpoch: contentEpochProvider(),
            logicalKey: (retainingAuthoredMipChain ? "world:" : "surface:") +
                logicalKey
        )
        if let cached = cachedValue(for: key) {
            switch cached {
            case .missing: return nil
            case let .bitmap(bitmap): return bitmap
            }
        }

        let resolved = try sourceMaterialResolver.resolve(
            named: logicalName,
            mipPolicy: retainingAuthoredMipChain
                ? .authoredChain
                : .mipZeroOnly
        )
        guard let dimensions = resolved.metadata.dimensions,
              let rgbaBytes = resolved.rgbaBytes,
              let baseTextureName = resolved.metadata.baseTextureName else {
            store(.missing, for: key)
            return nil
        }
        // Source paths are case-insensitive. Use the normalized VTF path, not
        // the referring VMT path, as the immutable payload identity.
        let canonicalTexturePath = baseTextureName.utf8String.lowercased()
        let bitmap = try makeBitmap(
            resourceIdentifier: canonicalTexturePath,
            width: dimensions.width,
            height: dimensions.height,
            rgbaBytes: rgbaBytes,
            mipImages: resolved.mipImages,
            flags: resolved.sourceTextureFlags,
            alphaRepresentation: retainingAuthoredMipChain
                ? .straight
                : .premultiplied
        )
        store(.bitmap(bitmap), for: key)
        return bitmap
    }

    private func resolveWorldSourceTexture(
        named textureName: String
    ) throws -> GModMetalSurfaceBitmap? {
        let logicalKey = textureName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !logicalKey.isEmpty else { return nil }
        let key = CacheKey(
            contentEpoch: contentEpochProvider(),
            logicalKey: "world-vtf:" + logicalKey
        )
        if let cached = cachedValue(for: key) {
            switch cached {
            case .missing: return nil
            case let .bitmap(bitmap): return bitmap
            }
        }
        guard let texture = try sourceMaterialResolver.resolveTexture(
            named: textureName,
            mipPolicy: .authoredChain
        ), texture.status == .decoded,
        let width = texture.width,
        let height = texture.height,
        let rgbaBytes = texture.rgbaBytes else {
            store(.missing, for: key)
            return nil
        }
        let bitmap = try makeBitmap(
            resourceIdentifier: texture.logicalPath.lowercased(),
            width: width,
            height: height,
            rgbaBytes: rgbaBytes,
            mipImages: texture.mipImages,
            flags: texture.flags,
            alphaRepresentation: .straight
        )
        store(.bitmap(bitmap), for: key)
        return bitmap
    }

    private static func makeUVTransform(
        _ source: SourceVMTMatrix?,
        scale: Float
    ) -> GModMetalWorldUVTransform? {
        guard scale.isFinite else { return nil }
        var row0: SIMD3<Float>
        var row1: SIMD3<Float>
        switch source {
        case nil:
            row0 = SIMD3<Float>(1, 0, 0)
            row1 = SIMD3<Float>(0, 1, 0)
        case let .matrix4x4(values):
            guard values.count == 16 else { return nil }
            row0 = SIMD3<Float>(
                Float(values[0]), Float(values[1]), Float(values[3])
            )
            row1 = SIMD3<Float>(
                Float(values[4]), Float(values[5]), Float(values[7])
            )
        case let .textureTransform(
            center,
            authoredScale,
            rotationDegrees,
            translation
        ):
            let radians = rotationDegrees * .pi / 180
            let cosine = cos(radians)
            let sine = sin(radians)
            let m00 = cosine * authoredScale.x
            let m01 = -sine * authoredScale.y
            let m10 = sine * authoredScale.x
            let m11 = cosine * authoredScale.y
            row0 = SIMD3<Float>(
                Float(m00),
                Float(m01),
                Float(center.x + translation.x - m00 * center.x -
                    m01 * center.y)
            )
            row1 = SIMD3<Float>(
                Float(m10),
                Float(m11),
                Float(center.y + translation.y - m10 * center.x -
                    m11 * center.y)
            )
        }
        // Source scales both the two basis coefficients and translation after
        // resolving the material matrix (`SetVertexShaderTextureScaledTransform`).
        row0 *= scale
        row1 *= scale
        guard row0.x.isFinite, row0.y.isFinite, row0.z.isFinite,
              row1.x.isFinite, row1.y.isFinite, row1.z.isFinite else {
            return nil
        }
        return GModMetalWorldUVTransform(row0: row0, row1: row1)
    }

    /// Resolves only values present in a real Source `Water` VMT. Missing
    /// shader inputs remain unresolved; in particular, this adapter does not
    /// replace an unsupported DuDv texture with a fabricated normal map.
    public func resolveWaterMaterial(
        named logicalName: String
    ) throws -> GModMetalWorldWaterMaterial? {
        guard let material = try sourceMaterialResolver.resolveWater(
            named: logicalName,
            mipPolicy: .authoredChain
        ), let isAboveWater = material.isAboveWater,
           let rawFogColor = material.fogColor,
           rawFogColor.count == 3,
           rawFogColor.allSatisfy(\.isFinite),
           material.reflectionAmount?.isFinite ?? true,
           material.refractionAmount?.isFinite ?? true,
           material.reflectionAmount != nil ||
            material.refractionAmount != nil else {
            return nil
        }

        let normalBitmap: GModMetalSurfaceBitmap?
        if let normalTexture = material.normalTexture,
           normalTexture.status == .decoded,
           let width = normalTexture.width,
           let height = normalTexture.height,
           let rgbaBytes = normalTexture.rgbaBytes {
            normalBitmap = try makeBitmap(
                resourceIdentifier: normalTexture.logicalPath,
                width: width,
                height: height,
                rgbaBytes: rgbaBytes,
                mipImages: normalTexture.mipImages,
                flags: normalTexture.flags,
                alphaRepresentation: .straight
            )
        } else {
            normalBitmap = nil
        }

        let unsupportedBumpTextureFormat: String?
        if case let .unsupportedImageFormat(format)? = material.bumpTexture?.status {
            unsupportedBumpTextureFormat = String(describing: format)
        } else {
            unsupportedBumpTextureFormat = nil
        }

        let textureScroll = material.textureScroll.flatMap { scroll in
            scroll.targetVariable
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("$bumptransform") == .orderedSame
                ? scroll
                : nil
        }
        return GModMetalWorldWaterMaterial(
            resourceIdentifier: material.materialPath,
            isAboveWater: isAboveWater,
            fogColor: SIMD3<Float>(
                rawFogColor[0] / 255,
                rawFogColor[1] / 255,
                rawFogColor[2] / 255
            ),
            fogEnabled: material.fogEnabled,
            fogStart: material.fogStart,
            fogEnd: material.fogEnd,
            reflectionAmount: material.reflectionAmount,
            refractionAmount: material.refractionAmount,
            normalBitmap: normalBitmap,
            textureScrollRate: textureScroll?.rate,
            textureScrollAngleDegrees: textureScroll?.angleDegrees,
            unsupportedBumpTextureFormat: unsupportedBumpTextureFormat
        )
    }

    private func makeBitmap(
        resourceIdentifier: String,
        width: Int,
        height: Int,
        rgbaBytes: Data,
        mipImages: [SourceVTFDecodedImage],
        flags: SourceVTFTextureFlags?,
        alphaRepresentation: GModMetalBitmapAlphaRepresentation
    ) throws -> GModMetalSurfaceBitmap {
        func premultiply(_ straightRGBA8: Data) -> Data {
            var premultiplied = straightRGBA8
            premultiplied.withUnsafeMutableBytes { rawBytes in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                var offset = 0
                while offset + 3 < bytes.count {
                    let alpha = UInt16(bytes[offset + 3])
                    bytes[offset] = UInt8(
                        (UInt16(bytes[offset]) * alpha + 127) / 255
                    )
                    bytes[offset + 1] = UInt8(
                        (UInt16(bytes[offset + 1]) * alpha + 127) / 255
                    )
                    bytes[offset + 2] = UInt8(
                        (UInt16(bytes[offset + 2]) * alpha + 127) / 255
                    )
                    offset += 4
                }
            }
            return premultiplied
        }
        let retainedMipLevels: [GModMetalSurfaceMipLevel]
        if mipImages.isEmpty {
            retainedMipLevels = [GModMetalSurfaceMipLevel(
                width: width,
                height: height,
                premultipliedRGBA8: alphaRepresentation == .premultiplied
                    ? premultiply(rgbaBytes)
                    : rgbaBytes
            )]
        } else {
            let retainedSourceMips = flags?.contains(.noMip) == true
                ? mipImages.prefix(1)
                : mipImages[...]
            retainedMipLevels = retainedSourceMips.map {
                GModMetalSurfaceMipLevel(
                    width: $0.width,
                    height: $0.height,
                    premultipliedRGBA8: alphaRepresentation == .premultiplied
                        ? premultiply($0.rgbaBytes)
                        : $0.rgbaBytes
                )
            }
        }
        guard let baseMip = retainedMipLevels.first else {
            preconditionFailure("resolved Source texture must retain mip zero")
        }
        return try GModMetalSurfaceBitmap(
            resourceIdentifier: resourceIdentifier,
            width: width,
            height: height,
            premultipliedRGBA8: baseMip.premultipliedRGBA8,
            mipLevels: retainedMipLevels,
            sourceTextureFlags: flags,
            alphaRepresentation: alphaRepresentation
        )
    }

    private func cachedValue(for key: CacheKey) -> CachedResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return value
    }

    private func store(_ value: CachedResult, for key: CacheKey) {
        let byteCount: Int
        switch value {
        case .missing: byteCount = 0
        case let .bitmap(bitmap): byteCount = bitmap.totalByteCount
        }
        guard byteCount <= maximumCachedByteCount else { return }
        lock.lock()
        defer { lock.unlock() }
        if let previous = cache.removeValue(forKey: key) {
            cachedByteCountStorage -= Self.byteCount(of: previous)
            cacheOrder.removeAll { $0 == key }
        }
        while !cacheOrder.isEmpty && (
            cache.count >= maximumCachedEntryCount ||
                cachedByteCountStorage > maximumCachedByteCount - byteCount
        ) {
            let oldest = cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedByteCountStorage -= Self.byteCount(of: evicted)
            }
        }
        cache[key] = value
        cacheOrder.append(key)
        cachedByteCountStorage += byteCount
    }

    private static func byteCount(of value: CachedResult) -> Int {
        switch value {
        case .missing: return 0
        case let .bitmap(bitmap): return bitmap.totalByteCount
        }
    }
}

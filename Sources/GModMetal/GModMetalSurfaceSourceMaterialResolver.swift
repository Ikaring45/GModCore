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

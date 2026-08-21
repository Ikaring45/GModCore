import Foundation
import GModEngine

/// Metal-facing adapter over the same VMT/VTF core used by IMaterial and
/// ITexture. It performs only the alpha-premultiplication required by the
/// Surface shader and retains a separately bounded bitmap cache so a frame
/// never repeats that conversion.
public final class GModMetalSurfaceSourceMaterialResolver:
    GModMetalSurfaceTextureResolving,
    @unchecked Sendable
{
    private enum CachedResult {
        case missing
        case bitmap(GModMetalSurfaceBitmap)
    }

    public let sourceMaterialResolver: GMLuaSourceMaterialResolver

    private let maximumCachedEntryCount: Int
    private let maximumCachedByteCount: Int
    private let lock = NSLock()
    private var cache: [String: CachedResult] = [:]
    private var cacheOrder: [String] = []
    private var cachedByteCountStorage = 0

    public convenience init(
        maximumCachedEntryCount: Int = 512,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024,
        loader: @escaping GMLuaSourceMaterialResolver.Loader
    ) {
        self.init(
            sourceMaterialResolver: GMLuaSourceMaterialResolver(loader: loader),
            maximumCachedEntryCount: maximumCachedEntryCount,
            maximumCachedByteCount: maximumCachedByteCount
        )
    }

    public init(
        sourceMaterialResolver: GMLuaSourceMaterialResolver,
        maximumCachedEntryCount: Int = 512,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024
    ) {
        self.sourceMaterialResolver = sourceMaterialResolver
        self.maximumCachedEntryCount = max(1, maximumCachedEntryCount)
        self.maximumCachedByteCount = max(1, maximumCachedByteCount)
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

    private func resolveTexture(
        named logicalName: String,
        retainingAuthoredMipChain: Bool
    ) throws -> GModMetalSurfaceBitmap? {
        let logicalKey = logicalName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !logicalKey.isEmpty else { return nil }
        let key = (retainingAuthoredMipChain ? "world:" : "surface:") + logicalKey
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
              let rgbaBytes = resolved.rgbaBytes else {
            store(.missing, for: key)
            return nil
        }
        let bitmap = try makeBitmap(
            resourceIdentifier: resolved.metadata.materialPath.utf8String,
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
            retainedMipLevels = mipImages.map {
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

    private func cachedValue(for key: String) -> CachedResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return value
    }

    private func store(_ value: CachedResult, for key: String) {
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

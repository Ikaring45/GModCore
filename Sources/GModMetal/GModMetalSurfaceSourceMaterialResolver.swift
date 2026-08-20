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
        let key = logicalName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = cachedValue(for: key) {
            switch cached {
            case .missing: return nil
            case let .bitmap(bitmap): return bitmap
            }
        }

        let resolved = try sourceMaterialResolver.resolve(named: logicalName)
        guard let dimensions = resolved.metadata.dimensions,
              let rgbaBytes = resolved.rgbaBytes else {
            store(.missing, for: key)
            return nil
        }
        var premultiplied = rgbaBytes
        premultiplied.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 3 < bytes.count {
                let alpha = UInt16(bytes[offset + 3])
                bytes[offset] = UInt8((UInt16(bytes[offset]) * alpha + 127) / 255)
                bytes[offset + 1] = UInt8(
                    (UInt16(bytes[offset + 1]) * alpha + 127) / 255
                )
                bytes[offset + 2] = UInt8(
                    (UInt16(bytes[offset + 2]) * alpha + 127) / 255
                )
                offset += 4
            }
        }
        let bitmap = try GModMetalSurfaceBitmap(
            resourceIdentifier: resolved.metadata.materialPath.utf8String,
            width: dimensions.width,
            height: dimensions.height,
            premultipliedRGBA8: premultiplied
        )
        store(.bitmap(bitmap), for: key)
        return bitmap
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
        case let .bitmap(bitmap): byteCount = bitmap.premultipliedRGBA8.count
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
        case let .bitmap(bitmap): return bitmap.premultipliedRGBA8.count
        }
    }
}

import Foundation
import GModEngine

public enum GModMetalSurfacePNGResolverError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case encodedByteCountExceeded(actual: Int, maximum: Int)
    case invalidPNGSignature
    case invalidIHDR
    case invalidIHDRDimensions(width: UInt32, height: UInt32)
    case widthExceeded(actual: UInt32, maximum: Int)
    case heightExceeded(actual: UInt32, maximum: Int)
    case pixelCountExceeded(actual: UInt64, maximum: Int)
    case decodedByteCountOverflow
    case decodedByteCountExceeded(actual: UInt64, maximum: Int)
    case decodedDimensionsMismatch(
        headerWidth: Int,
        headerHeight: Int,
        decodedWidth: Int,
        decodedHeight: Int
    )

    public var description: String {
        switch self {
        case let .encodedByteCountExceeded(actual, maximum):
            return "PNG contains \(actual) encoded bytes; maximum is \(maximum)"
        case .invalidPNGSignature:
            return "PNG signature is invalid"
        case .invalidIHDR:
            return "PNG does not begin with a complete 13-byte IHDR chunk"
        case let .invalidIHDRDimensions(width, height):
            return "PNG IHDR dimensions are invalid (\(width)x\(height))"
        case let .widthExceeded(actual, maximum):
            return "PNG IHDR width \(actual) exceeds maximum \(maximum)"
        case let .heightExceeded(actual, maximum):
            return "PNG IHDR height \(actual) exceeds maximum \(maximum)"
        case let .pixelCountExceeded(actual, maximum):
            return "PNG IHDR pixel count \(actual) exceeds maximum \(maximum)"
        case .decodedByteCountOverflow:
            return "PNG IHDR decoded RGBA byte count overflows UInt64"
        case let .decodedByteCountExceeded(actual, maximum):
            return "PNG IHDR decoded RGBA byte count \(actual) exceeds maximum \(maximum)"
        case let .decodedDimensionsMismatch(
            headerWidth,
            headerHeight,
            decodedWidth,
            decodedHeight
        ):
            return "PNG decoder returned \(decodedWidth)x\(decodedHeight); " +
                "IHDR declares \(headerWidth)x\(headerHeight)"
        }
    }
}

/// Resolves real bundled PNG bytes through a host-supplied logical-path loader.
/// GModMetal intentionally does not depend on GModGameAssets, so the Apple host
/// can connect `GModGameAssets.clientContentData(for:)` without introducing an
/// asset or Lua dependency into the render callback.
public final class GModMetalSurfacePNGResolver:
    GModMetalSurfaceTextureResolving,
    @unchecked Sendable
{
    public typealias Loader = @Sendable (_ logicalPath: String) throws -> Data?

    /// Generous relative to the authorized bundle (currently at most 325,497
    /// encoded bytes and 1,048,576 decoded RGBA bytes), while still rejecting
    /// hostile compressed or metadata-heavy inputs before platform decoding.
    public static let defaultMaximumEncodedPNGByteCount = 16 * 1_024 * 1_024
    public static let defaultMaximumPNGWidth = 4_096
    public static let defaultMaximumPNGHeight = 4_096
    public static let defaultMaximumPNGPixelCount = 2_097_152
    public static let defaultMaximumDecodedPNGByteCount = 8 * 1_024 * 1_024

    private enum CachedResult {
        case missing
        case bitmap(GModMetalSurfaceBitmap)
    }

    private let loader: Loader
    private let maximumCachedEntryCount: Int
    private let maximumCachedByteCount: Int
    private let maximumEncodedPNGByteCount: Int
    private let maximumPNGWidth: Int
    private let maximumPNGHeight: Int
    private let maximumPNGPixelCount: Int
    private let maximumDecodedPNGByteCount: Int
    private let lock = NSLock()
    private var cache: [String: CachedResult] = [:]
    private var cacheOrder: [String] = []
    private var cachedByteCount = 0

    public init(
        maximumCachedEntryCount: Int = 4_096,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024,
        maximumEncodedPNGByteCount: Int =
            GModMetalSurfacePNGResolver.defaultMaximumEncodedPNGByteCount,
        maximumPNGWidth: Int =
            GModMetalSurfacePNGResolver.defaultMaximumPNGWidth,
        maximumPNGHeight: Int =
            GModMetalSurfacePNGResolver.defaultMaximumPNGHeight,
        maximumPNGPixelCount: Int =
            GModMetalSurfacePNGResolver.defaultMaximumPNGPixelCount,
        maximumDecodedPNGByteCount: Int =
            GModMetalSurfacePNGResolver.defaultMaximumDecodedPNGByteCount,
        loader: @escaping Loader
    ) {
        self.maximumCachedEntryCount = max(1, maximumCachedEntryCount)
        self.maximumCachedByteCount = max(1, maximumCachedByteCount)
        self.maximumEncodedPNGByteCount = max(1, maximumEncodedPNGByteCount)
        self.maximumPNGWidth = max(1, maximumPNGWidth)
        self.maximumPNGHeight = max(1, maximumPNGHeight)
        self.maximumPNGPixelCount = max(1, maximumPNGPixelCount)
        self.maximumDecodedPNGByteCount = max(
            1,
            maximumDecodedPNGByteCount
        )
        self.loader = loader
    }

    public var cachedTextureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.values.reduce(into: 0) { count, value in
            if case .bitmap = value { count += 1 }
        }
    }

    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public var cachedTextureByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedByteCount
    }

    public func removeAllCachedTextures() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        cachedByteCount = 0
        lock.unlock()
    }

    public func resolveSurfaceTexture(
        named logicalName: String
    ) throws -> GModMetalSurfaceBitmap? {
        let candidates = Self.logicalPNGCandidates(for: logicalName)
        guard let canonicalCandidate = candidates.last else { return nil }
        let key = canonicalCandidate.lowercased()
        if let cached = cachedResult(for: key) {
            switch cached {
            case .missing:
                return nil
            case let .bitmap(bitmap):
                return bitmap
            }
        }

        for candidate in candidates {
            guard let encoded = try loader(candidate) else { continue }
            let bitmap = try decodePNG(
                encoded,
                resourceIdentifier: candidate
            )
            storeCachedResult(.bitmap(bitmap), for: key)
            return bitmap
        }

        storeCachedResult(.missing, for: key)
        return nil
    }

    private func cachedResult(for key: String) -> CachedResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let result = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return result
    }

    private func storeCachedResult(_ result: CachedResult, for key: String) {
        let byteCount: Int
        switch result {
        case .missing:
            byteCount = 0
        case let .bitmap(bitmap):
            byteCount = bitmap.premultipliedRGBA8.count
        }
        guard byteCount <= maximumCachedByteCount else { return }

        lock.lock()
        defer { lock.unlock() }
        if let previous = cache.removeValue(forKey: key) {
            cachedByteCount -= Self.byteCount(of: previous)
            cacheOrder.removeAll { $0 == key }
        }
        while !cacheOrder.isEmpty && (
            cache.count >= maximumCachedEntryCount ||
                cachedByteCount > maximumCachedByteCount - byteCount
        ) {
            let oldest = cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedByteCount -= Self.byteCount(of: evicted)
            }
        }
        cache[key] = result
        cacheOrder.append(key)
        cachedByteCount += byteCount
    }

    private static func byteCount(of result: CachedResult) -> Int {
        switch result {
        case .missing:
            return 0
        case let .bitmap(bitmap):
            return bitmap.premultipliedRGBA8.count
        }
    }

    /// Candidate paths stay inside `materials/` and preserve an explicit PNG
    /// request. Extensionless/VMT/VTF names remain unresolved because assuming
    /// a same-basename PNG would invent material binding semantics.
    public static func logicalPNGCandidates(
        for logicalName: String
    ) -> [String] {
        var path = logicalName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty,
              !path.contains(":"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return [] }

        if path.lowercased().hasPrefix("materials/") {
            path.removeFirst("materials/".count)
        }
        guard !path.isEmpty else { return [] }

        guard path.lowercased().hasSuffix(".png") else { return [] }

        let candidates = [
            "materials/" + path,
            "materials/" + path.lowercased()
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private struct ValidatedHeader {
        let width: Int
        let height: Int
        let decodedByteCount: Int
    }

    private func validatedHeader(for encoded: Data) throws -> ValidatedHeader {
        guard encoded.count <= maximumEncodedPNGByteCount else {
            throw GModMetalSurfacePNGResolverError.encodedByteCountExceeded(
                actual: encoded.count,
                maximum: maximumEncodedPNGByteCount
            )
        }

        // A PNG signature, IHDR length/type/data, and IHDR CRC occupy 33 bytes.
        // Copying only this fixed prefix keeps all integer reads bounds-safe.
        guard encoded.count >= 33 else {
            throw GModMetalSurfacePNGResolverError.invalidIHDR
        }
        let header = Array(encoded.prefix(33))
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard Array(header[0..<8]) == signature else {
            throw GModMetalSurfacePNGResolverError.invalidPNGSignature
        }
        guard Self.readBigEndianUInt32(header, at: 8) == 13,
              Array(header[12..<16]) == [73, 72, 68, 82]
        else {
            throw GModMetalSurfacePNGResolverError.invalidIHDR
        }

        let rawWidth = Self.readBigEndianUInt32(header, at: 16)
        let rawHeight = Self.readBigEndianUInt32(header, at: 20)
        guard rawWidth > 0, rawHeight > 0 else {
            throw GModMetalSurfacePNGResolverError.invalidIHDRDimensions(
                width: rawWidth,
                height: rawHeight
            )
        }
        guard UInt64(rawWidth) <= UInt64(maximumPNGWidth) else {
            throw GModMetalSurfacePNGResolverError.widthExceeded(
                actual: rawWidth,
                maximum: maximumPNGWidth
            )
        }
        guard UInt64(rawHeight) <= UInt64(maximumPNGHeight) else {
            throw GModMetalSurfacePNGResolverError.heightExceeded(
                actual: rawHeight,
                maximum: maximumPNGHeight
            )
        }

        let pixels = UInt64(rawWidth) * UInt64(rawHeight)
        guard pixels <= UInt64(maximumPNGPixelCount) else {
            throw GModMetalSurfacePNGResolverError.pixelCountExceeded(
                actual: pixels,
                maximum: maximumPNGPixelCount
            )
        }
        let decodedBytes = pixels.multipliedReportingOverflow(by: 4)
        guard !decodedBytes.overflow else {
            throw GModMetalSurfacePNGResolverError.decodedByteCountOverflow
        }
        guard decodedBytes.partialValue <= UInt64(maximumDecodedPNGByteCount)
        else {
            throw GModMetalSurfacePNGResolverError.decodedByteCountExceeded(
                actual: decodedBytes.partialValue,
                maximum: maximumDecodedPNGByteCount
            )
        }
        guard let width = Int(exactly: rawWidth),
              let height = Int(exactly: rawHeight),
              let decodedByteCount = Int(exactly: decodedBytes.partialValue)
        else {
            throw GModMetalSurfacePNGResolverError.decodedByteCountOverflow
        }
        return ValidatedHeader(
            width: width,
            height: height,
            decodedByteCount: decodedByteCount
        )
    }

    private static func readBigEndianUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }

    private func decodePNG(
        _ encoded: Data,
        resourceIdentifier: String
    ) throws -> GModMetalSurfaceBitmap {
        let header = try validatedHeader(for: encoded)
        let decoded = try GMLuaPlatformImageDecoder.decode(encoded)
        guard decoded.width == header.width, decoded.height == header.height else {
            throw GModMetalSurfacePNGResolverError.decodedDimensionsMismatch(
                headerWidth: header.width,
                headerHeight: header.height,
                decodedWidth: decoded.width,
                decodedHeight: decoded.height
            )
        }

        var premultiplied = Data(count: header.decodedByteCount)
        var decodedEveryPixel = true
        premultiplied.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            for y in 0..<decoded.height {
                for x in 0..<decoded.width {
                    guard let pixel = decoded.pixel(x: x, y: y) else {
                        decodedEveryPixel = false
                        continue
                    }
                    let offset = (y * decoded.width + x) * 4
                    let alpha = UInt16(pixel.alpha)
                    bytes[offset] = UInt8(
                        (UInt16(pixel.red) * alpha + 127) / 255
                    )
                    bytes[offset + 1] = UInt8(
                        (UInt16(pixel.green) * alpha + 127) / 255
                    )
                    bytes[offset + 2] = UInt8(
                        (UInt16(pixel.blue) * alpha + 127) / 255
                    )
                    bytes[offset + 3] = pixel.alpha
                }
            }
        }
        guard decodedEveryPixel else {
            throw GMLuaImageDecodeError.platformFailure
        }

        return try GModMetalSurfaceBitmap(
            resourceIdentifier: resourceIdentifier,
            width: decoded.width,
            height: decoded.height,
            premultipliedRGBA8: premultiplied
        )
    }
}

import Foundation
import GModImageDecode
import GModLua

public enum GMLuaImageDecodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidArgument
    case unsupportedPlatform
    case malformedImage
    case allocationFailed
    case platformFailure

    public var description: String {
        switch self {
        case .invalidArgument:
            return "invalid encoded image"
        case .unsupportedPlatform:
            return "image decoding is unavailable on this platform"
        case .malformedImage:
            return "encoded image is malformed or unsupported"
        case .allocationFailed:
            return "image decoding allocation failed"
        case .platformFailure:
            return "platform image decoder failed"
        }
    }
}

/// Immutable, top-left-origin, straight-alpha RGBA8 image data.
public struct GMLuaDecodedRGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    private let rgbaBytes: Data

    fileprivate init(width: Int, height: Int, bytesPerRow: Int, rgbaBytes: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.rgbaBytes = rgbaBytes
    }

    public var dimensions: GMLuaImageDimensions {
        GMLuaImageDimensions(width: width, height: height)
    }

    public func pixel(x: Int, y: Int) -> GMLuaRGBA8? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = y * bytesPerRow + x * 4
        guard offset >= 0, offset + 3 < rgbaBytes.count else { return nil }
        return GMLuaRGBA8(
            red: rgbaBytes[offset],
            green: rgbaBytes[offset + 1],
            blue: rgbaBytes[offset + 2],
            alpha: rgbaBytes[offset + 3]
        )
    }
}

public enum GMLuaPlatformImageDecoder {
    /// Decodes a PNG or another platform-supported image into straight RGBA8.
    public static func decode(_ encodedImage: Data) throws -> GMLuaDecodedRGBAImage {
        guard !encodedImage.isEmpty else { throw GMLuaImageDecodeError.invalidArgument }

        var decoded = GModDecodedRGBAImage(
            pixels: nil,
            width: 0,
            height: 0,
            bytes_per_row: 0
        )
        let result = encodedImage.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 1
            }
            return gmod_decode_image_rgba(baseAddress, bytes.count, &decoded)
        }
        guard result == 0 else {
            switch result {
            case 1: throw GMLuaImageDecodeError.invalidArgument
            case 2: throw GMLuaImageDecodeError.unsupportedPlatform
            case 3: throw GMLuaImageDecodeError.malformedImage
            case 4: throw GMLuaImageDecodeError.allocationFailed
            default: throw GMLuaImageDecodeError.platformFailure
            }
        }
        defer { gmod_free_decoded_image(&decoded) }

        let width = Int(decoded.width)
        let height = Int(decoded.height)
        let bytesPerRow = Int(decoded.bytes_per_row)
        guard width > 0,
              height > 0,
              bytesPerRow >= width * 4,
              height <= Int.max / bytesPerRow,
              let pixels = decoded.pixels else {
            throw GMLuaImageDecodeError.platformFailure
        }
        let byteCount = height * bytesPerRow
        let rgbaBytes = Data(bytes: pixels, count: byteCount)
        return GMLuaDecodedRGBAImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            rgbaBytes: rgbaBytes
        )
    }
}

/// Cached bridge from encoded material bytes to IMaterial/ITexture pixels.
///
/// The loader is responsible for mount precedence and path resolution. A nil
/// result remains unresolved; no fallback color or placeholder raster is used.
public final class GMLuaEncodedMaterialPixelResolver: GMLuaMaterialPixelResolver,
    @unchecked Sendable
{
    public typealias Loader = @Sendable (
        _ materialPath: LuaString,
        _ encodedParameters: LuaString?
    ) throws -> Data?

    private struct Key: Hashable {
        let materialPath: LuaString
        let encodedParameters: LuaString?
    }

    private enum CachedImage {
        case missing
        case decoded(GMLuaDecodedRGBAImage)
    }

    private let lock = NSLock()
    private let loader: Loader
    private var cache: [Key: CachedImage] = [:]

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func removeAllCachedImages() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func dimensions(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaImageDimensions? {
        try image(materialPath: materialPath, encodedParameters: encodedParameters)?.dimensions
    }

    public func pixel(
        materialPath: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int
    ) throws -> GMLuaRGBA8? {
        try image(materialPath: materialPath, encodedParameters: encodedParameters)?.pixel(x: x, y: y)
    }

    private func image(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaDecodedRGBAImage? {
        let key = Key(materialPath: materialPath, encodedParameters: encodedParameters)
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] {
            switch cached {
            case .missing: return nil
            case let .decoded(image): return image
            }
        }

        guard let encodedImage = try loader(materialPath, encodedParameters) else {
            cache[key] = .missing
            return nil
        }
        let decodedImage = try GMLuaPlatformImageDecoder.decode(encodedImage)
        cache[key] = .decoded(decodedImage)
        return decodedImage
    }
}

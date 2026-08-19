import Foundation

public struct SourceVTFVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: SourceVTFVersion, rhs: SourceVTFVersion) -> Bool {
        lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
    }

    public var description: String { "\(major).\(minor)" }
}

/// Values from Source SDK 2013's public `bitmap/imageformat.h`.
public enum SourceVTFImageFormat: Int32, Sendable, CaseIterable {
    case unknown = -1
    case rgba8888 = 0
    case abgr8888 = 1
    case rgb888 = 2
    case bgr888 = 3
    case rgb565 = 4
    case i8 = 5
    case ia88 = 6
    case p8 = 7
    case a8 = 8
    case rgb888BlueScreen = 9
    case bgr888BlueScreen = 10
    case argb8888 = 11
    case bgra8888 = 12
    case dxt1 = 13
    case dxt3 = 14
    case dxt5 = 15
    case bgrx8888 = 16
    case bgr565 = 17
    case bgrx5551 = 18
    case bgra4444 = 19
    case dxt1OneBitAlpha = 20
    case bgra5551 = 21
    case uv88 = 22
    case uvwq8888 = 23
    case rgba16161616F = 24
    case rgba16161616 = 25
    case uvlx8888 = 26
    case r32F = 27
    case rgb323232F = 28
    case rgba32323232F = 29
    case nvDST16 = 30
    case nvDST24 = 31
    case nvINTZ = 32
    case nvRAWZ = 33
    case atiDST16 = 34
    case atiDST24 = 35
    case nvNull = 36
    case ati2N = 37
    case ati1N = 38
    case dxt1Runtime = 39
    case dxt5Runtime = 40
}

public struct SourceVTFTextureFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let pointSample = SourceVTFTextureFlags(rawValue: 0x0000_0001)
    public static let trilinear = SourceVTFTextureFlags(rawValue: 0x0000_0002)
    public static let clampS = SourceVTFTextureFlags(rawValue: 0x0000_0004)
    public static let clampT = SourceVTFTextureFlags(rawValue: 0x0000_0008)
    public static let anisotropic = SourceVTFTextureFlags(rawValue: 0x0000_0010)
    public static let sRGB = SourceVTFTextureFlags(rawValue: 0x0000_0040)
    public static let normal = SourceVTFTextureFlags(rawValue: 0x0000_0080)
    public static let noMip = SourceVTFTextureFlags(rawValue: 0x0000_0100)
    public static let noLOD = SourceVTFTextureFlags(rawValue: 0x0000_0200)
    public static let oneBitAlpha = SourceVTFTextureFlags(rawValue: 0x0000_1000)
    public static let eightBitAlpha = SourceVTFTextureFlags(rawValue: 0x0000_2000)
    public static let environmentMap = SourceVTFTextureFlags(rawValue: 0x0000_4000)
    public static let renderTarget = SourceVTFTextureFlags(rawValue: 0x0000_8000)
    public static let clampU = SourceVTFTextureFlags(rawValue: 0x0200_0000)
}

public enum SourceVTFError: Error, Sendable, Equatable, CustomStringConvertible {
    case truncated(context: String, expectedEnd: Int, actualCount: Int)
    case invalidSignature([UInt8])
    case unsupportedVersion(SourceVTFVersion)
    case invalidHeaderSize(Int, minimum: Int)
    case invalidDimensions(width: Int, height: Int, depth: Int)
    case invalidFrameCount(Int)
    case invalidMipCount(Int, maximum: Int)
    case unknownImageFormat(Int32)
    case unsupportedImageFormat(SourceVTFImageFormat)
    case invalidLowResolutionImage(width: Int, height: Int, format: Int32)
    case excessiveResourceCount(Int)
    case duplicateResource(UInt32)
    case missingImageResource
    case invalidResourceOffset(type: UInt32, offset: Int)
    case arithmeticOverflow(String)
    case allocationLimitExceeded(context: String, limit: Int, actual: Int)
    case subresourceOutOfRange(mip: Int, frame: Int, face: Int, slice: Int)

    public var description: String {
        switch self {
        case let .truncated(context, expectedEnd, actualCount):
            return "truncated VTF \(context): needs byte \(expectedEnd), has \(actualCount)"
        case let .invalidSignature(bytes):
            return "invalid VTF signature: \(bytes)"
        case let .unsupportedVersion(version):
            return "unsupported VTF version \(version)"
        case let .invalidHeaderSize(size, minimum):
            return "invalid VTF header size \(size); minimum is \(minimum)"
        case let .invalidDimensions(width, height, depth):
            return "invalid VTF dimensions \(width)x\(height)x\(depth)"
        case let .invalidFrameCount(count):
            return "invalid VTF frame count \(count)"
        case let .invalidMipCount(count, maximum):
            return "invalid VTF mip count \(count); maximum is \(maximum)"
        case let .unknownImageFormat(rawValue):
            return "unknown VTF image format \(rawValue)"
        case let .unsupportedImageFormat(format):
            return "unsupported VTF image format \(format)"
        case let .invalidLowResolutionImage(width, height, format):
            return "invalid VTF low-resolution image \(width)x\(height), format \(format)"
        case let .excessiveResourceCount(count):
            return "VTF resource dictionary contains \(count) entries; maximum is 32"
        case let .duplicateResource(type):
            return "duplicate VTF resource type 0x\(String(type, radix: 16))"
        case .missingImageResource:
            return "VTF 7.3+ resource dictionary has no high-resolution image"
        case let .invalidResourceOffset(type, offset):
            return "invalid VTF resource 0x\(String(type, radix: 16)) offset \(offset)"
        case let .arithmeticOverflow(context):
            return "VTF integer overflow while calculating \(context)"
        case let .allocationLimitExceeded(context, limit, actual):
            return "VTF \(context) requires \(actual) bytes/items; limit is \(limit)"
        case let .subresourceOutOfRange(mip, frame, face, slice):
            return "VTF subresource is out of range (mip \(mip), frame \(frame), face \(face), slice \(slice))"
        }
    }
}

/// Per-file limits for allocations driven by untrusted VTF metadata.
///
/// The encoded limit bounds the retained input and any individual encoded
/// subresource copy. Pixel and decoded-byte limits independently bound RGBA8
/// expansion work so a compact block-compressed texture cannot request an
/// unexpectedly large allocation.
public struct SourceVTFAllocationLimits: Sendable, Equatable {
    public static let `default` = SourceVTFAllocationLimits()

    public let maximumEncodedBytes: Int
    public let maximumPixelCount: Int
    public let maximumDecodedBytes: Int

    public init(
        maximumEncodedBytes: Int = 256 * 1024 * 1024,
        maximumPixelCount: Int = 64 * 1024 * 1024,
        maximumDecodedBytes: Int = 256 * 1024 * 1024
    ) {
        precondition(maximumEncodedBytes >= 0, "VTF encoded-byte limit cannot be negative")
        precondition(maximumPixelCount >= 0, "VTF pixel limit cannot be negative")
        precondition(maximumDecodedBytes >= 0, "VTF decoded-byte limit cannot be negative")
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumPixelCount = maximumPixelCount
        self.maximumDecodedBytes = maximumDecodedBytes
    }
}

public struct SourceVTFResourceEntry: Sendable, Equatable {
    /// The low 24-bit resource identifier.
    public let type: UInt32
    /// Flags stored in the high byte of the on-disk type field.
    public let flags: UInt8
    /// Inline data or a file offset, depending on `hasNoDataChunk`.
    public let dataOrOffset: UInt32

    public init(type: UInt32, flags: UInt8, dataOrOffset: UInt32) {
        self.type = type & 0x00FF_FFFF
        self.flags = flags
        self.dataOrOffset = dataOrOffset
    }

    public var hasNoDataChunk: Bool { flags & 0x02 != 0 }
}

public struct SourceVTFFloat3: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct SourceVTFSubresource: Sendable, Equatable {
    public let mipLevel: Int
    public let frame: Int
    public let face: Int
    public let slice: Int
    public let width: Int
    public let height: Int
    public let mipDepth: Int
    public let format: SourceVTFImageFormat
    public let fileRange: Range<Int>
    public let data: Data
}

public struct SourceVTFColorRGBA8: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct SourceVTFDecodedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Tightly packed, top-left-origin RGBA8 pixels.
    public let rgbaBytes: Data

    public func pixel(x: Int, y: Int) -> SourceVTFColorRGBA8? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        guard offset + 3 < rgbaBytes.count else { return nil }
        return SourceVTFColorRGBA8(
            red: rgbaBytes[offset],
            green: rgbaBytes[offset + 1],
            blue: rgbaBytes[offset + 2],
            alpha: rgbaBytes[offset + 3]
        )
    }
}

/// Bounds-checked reader for Source 1 VTF 7.1 through the GMod-observed 7.5.
public struct SourceVTFFile: Sendable, Equatable {
    private static let signature: [UInt8] = [0x56, 0x54, 0x46, 0x00] // VTF\0
    private static let lowResolutionResource: UInt32 = 0x000001
    private static let imageResource: UInt32 = 0x000030
    private static let maximumResources = 32

    public let version: SourceVTFVersion
    public let headerSize: Int
    public let width: Int
    public let height: Int
    public let depth: Int
    public let flags: SourceVTFTextureFlags
    public let frameCount: Int
    public let firstFrame: UInt16
    /// Source exposes this vector in B, G, R semantic order.
    public let reflectivity: SourceVTFFloat3
    public let bumpScale: Float
    public let imageFormat: SourceVTFImageFormat
    public let mipCount: Int
    public let lowResolutionFormat: SourceVTFImageFormat
    public let lowResolutionWidth: Int
    public let lowResolutionHeight: Int
    public let resources: [SourceVTFResourceEntry]
    public let faceCount: Int
    public let imageDataRange: Range<Int>
    public let lowResolutionDataRange: Range<Int>?
    public let allocationLimits: SourceVTFAllocationLimits

    private let fileData: Data
    private let genericResourceRanges: [UInt32: Range<Int>]

    public init(
        data: Data,
        allocationLimits: SourceVTFAllocationLimits = .default
    ) throws {
        guard data.count <= allocationLimits.maximumEncodedBytes else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "encoded file bytes",
                limit: allocationLimits.maximumEncodedBytes,
                actual: data.count
            )
        }
        let reader = SourceVTFByteReader(data: data)
        try reader.require(end: 16, context: "base header")
        let signature = Array(data.prefix(4))
        guard signature == Self.signature else {
            throw SourceVTFError.invalidSignature(signature)
        }

        let major = Int(try reader.int32(at: 4, context: "major version"))
        let minor = Int(try reader.int32(at: 8, context: "minor version"))
        let parsedVersion = SourceVTFVersion(major: major, minor: minor)
        guard major == 7, (1...5).contains(minor) else {
            throw SourceVTFError.unsupportedVersion(parsedVersion)
        }

        let rawHeaderSize = try reader.uint32(at: 12, context: "header size")
        guard let parsedHeaderSize = Int(exactly: rawHeaderSize) else {
            throw SourceVTFError.arithmeticOverflow("header size")
        }
        // The official VTFFileHeaderV7_1_t ends at a 64-byte aligned boundary.
        // V7_2 adds the depth field but occupies 80 bytes on disk because
        // VectorAligned contributes trailing padding to the final derived
        // header even under pack(1). vtf.h calls this a compatibility-critical
        // historical quirk.
        let fixedMinimum = minor == 1 ? 64 : 80
        guard parsedHeaderSize >= fixedMinimum else {
            throw SourceVTFError.invalidHeaderSize(parsedHeaderSize, minimum: fixedMinimum)
        }
        try reader.require(end: parsedHeaderSize, context: "header")

        let parsedWidth = Int(try reader.uint16(at: 16, context: "width"))
        let parsedHeight = Int(try reader.uint16(at: 18, context: "height"))
        let parsedFlags = SourceVTFTextureFlags(
            rawValue: try reader.uint32(at: 20, context: "flags")
        )
        let parsedFrameCount = Int(try reader.uint16(at: 24, context: "frame count"))
        let parsedFirstFrame = try reader.uint16(at: 26, context: "first frame")
        let parsedReflectivity = SourceVTFFloat3(
            x: try reader.float32(at: 32, context: "reflectivity x"),
            y: try reader.float32(at: 36, context: "reflectivity y"),
            z: try reader.float32(at: 40, context: "reflectivity z")
        )
        let parsedBumpScale = try reader.float32(at: 48, context: "bump scale")
        let rawImageFormat = try reader.int32(at: 52, context: "image format")
        guard let parsedImageFormat = SourceVTFImageFormat(rawValue: rawImageFormat) else {
            throw SourceVTFError.unknownImageFormat(rawImageFormat)
        }
        guard parsedImageFormat != .unknown else {
            throw SourceVTFError.unsupportedImageFormat(parsedImageFormat)
        }
        let parsedMipCount = Int(try reader.uint8(at: 56, context: "mip count"))
        let rawLowFormat = try reader.int32(at: 57, context: "low-resolution format")
        guard let parsedLowFormat = SourceVTFImageFormat(rawValue: rawLowFormat) else {
            throw SourceVTFError.unknownImageFormat(rawLowFormat)
        }
        let parsedLowWidth = Int(try reader.uint8(at: 61, context: "low-resolution width"))
        let parsedLowHeight = Int(try reader.uint8(at: 62, context: "low-resolution height"))
        // Depth was introduced by VTFFileHeaderV7_2_t. V7_1 textures are
        // two-dimensional and have no bytes for this field.
        let parsedDepth = minor >= 2
            ? Int(try reader.uint16(at: 63, context: "depth"))
            : 1

        guard parsedWidth > 0, parsedHeight > 0, parsedDepth > 0 else {
            throw SourceVTFError.invalidDimensions(
                width: parsedWidth,
                height: parsedHeight,
                depth: parsedDepth
            )
        }
        guard parsedFrameCount > 0 else {
            throw SourceVTFError.invalidFrameCount(parsedFrameCount)
        }
        let maximumMipCount = Self.maximumMipCount(
            width: parsedWidth,
            height: parsedHeight,
            depth: parsedDepth
        )
        guard parsedMipCount > 0, parsedMipCount <= maximumMipCount else {
            throw SourceVTFError.invalidMipCount(parsedMipCount, maximum: maximumMipCount)
        }

        let parsedFaceCount: Int
        if parsedFlags.contains(.environmentMap) {
            // Before 7.5, a non-0xFFFF first frame denotes the legacy seventh
            // spheremap face described by the public SDK CubeMapFaceIndex_t.
            parsedFaceCount = minor < 5 && parsedFirstFrame != UInt16.max ? 7 : 6
        } else {
            parsedFaceCount = 1
        }

        let parsedResources: [SourceVTFResourceEntry]
        if minor >= 3 {
            let resourceCount = Int(try reader.uint32(at: 68, context: "resource count"))
            guard resourceCount <= Self.maximumResources else {
                throw SourceVTFError.excessiveResourceCount(resourceCount)
            }
            let dictionaryBytes = try Self.checkedMultiply(
                resourceCount,
                8,
                context: "resource dictionary size"
            )
            let dictionaryEnd = try Self.checkedAdd(
                80,
                dictionaryBytes,
                context: "resource dictionary end"
            )
            guard parsedHeaderSize >= dictionaryEnd else {
                throw SourceVTFError.invalidHeaderSize(parsedHeaderSize, minimum: dictionaryEnd)
            }

            var entries: [SourceVTFResourceEntry] = []
            var seen: Set<UInt32> = []
            for index in 0..<resourceCount {
                let offset = 80 + index * 8
                let rawType = try reader.uint32(at: offset, context: "resource type")
                let identifier = rawType & 0x00FF_FFFF
                guard seen.insert(identifier).inserted else {
                    throw SourceVTFError.duplicateResource(identifier)
                }
                entries.append(
                    SourceVTFResourceEntry(
                        type: identifier,
                        flags: UInt8(truncatingIfNeeded: rawType >> 24),
                        dataOrOffset: try reader.uint32(
                            at: offset + 4,
                            context: "resource data"
                        )
                    )
                )
            }
            parsedResources = entries
        } else {
            parsedResources = []
        }

        let lowResolutionSize: Int
        if parsedLowWidth == 0 && parsedLowHeight == 0 {
            lowResolutionSize = 0
        } else {
            guard parsedLowWidth > 0,
                  parsedLowHeight > 0,
                  parsedLowFormat != .unknown else {
                throw SourceVTFError.invalidLowResolutionImage(
                    width: parsedLowWidth,
                    height: parsedLowHeight,
                    format: rawLowFormat
                )
            }
            lowResolutionSize = try Self.encodedSliceByteCount(
                format: parsedLowFormat,
                width: parsedLowWidth,
                height: parsedLowHeight
            )
        }

        let parsedImageOffset: Int
        let parsedLowRange: Range<Int>?
        if minor >= 3 {
            guard let imageResource = parsedResources.first(where: {
                $0.type == Self.imageResource
            }) else {
                throw SourceVTFError.missingImageResource
            }
            guard !imageResource.hasNoDataChunk,
                  let offset = Int(exactly: imageResource.dataOrOffset),
                  offset >= parsedHeaderSize else {
                throw SourceVTFError.invalidResourceOffset(
                    type: imageResource.type,
                    offset: Int(imageResource.dataOrOffset)
                )
            }
            parsedImageOffset = offset

            if lowResolutionSize > 0 {
                guard let lowResource = parsedResources.first(where: {
                    $0.type == Self.lowResolutionResource
                }),
                    !lowResource.hasNoDataChunk,
                    let lowOffset = Int(exactly: lowResource.dataOrOffset),
                    lowOffset >= parsedHeaderSize else {
                    throw SourceVTFError.invalidResourceOffset(
                        type: Self.lowResolutionResource,
                        offset: -1
                    )
                }
                let lowEnd = try Self.checkedAdd(
                    lowOffset,
                    lowResolutionSize,
                    context: "low-resolution image end"
                )
                try reader.require(end: lowEnd, context: "low-resolution image")
                parsedLowRange = lowOffset..<lowEnd
            } else {
                parsedLowRange = nil
            }
        } else {
            if lowResolutionSize > 0 {
                let lowEnd = try Self.checkedAdd(
                    parsedHeaderSize,
                    lowResolutionSize,
                    context: "low-resolution image end"
                )
                try reader.require(end: lowEnd, context: "low-resolution image")
                parsedLowRange = parsedHeaderSize..<lowEnd
                parsedImageOffset = lowEnd
            } else {
                parsedLowRange = nil
                parsedImageOffset = parsedHeaderSize
            }
        }

        let imageSize = try Self.totalImageByteCount(
            format: parsedImageFormat,
            width: parsedWidth,
            height: parsedHeight,
            depth: parsedDepth,
            mipCount: parsedMipCount,
            frameCount: parsedFrameCount,
            faceCount: parsedFaceCount
        )
        let imageEnd = try Self.checkedAdd(
            parsedImageOffset,
            imageSize,
            context: "image data end"
        )
        try reader.require(end: imageEnd, context: "image data")

        var resourceRanges: [UInt32: Range<Int>] = [:]
        if minor >= 3 {
            for resource in parsedResources where
                resource.type != Self.lowResolutionResource
                    && resource.type != Self.imageResource
                    && !resource.hasNoDataChunk
            {
                guard let offset = Int(exactly: resource.dataOrOffset),
                      offset >= parsedHeaderSize else {
                    throw SourceVTFError.invalidResourceOffset(
                        type: resource.type,
                        offset: Int(resource.dataOrOffset)
                    )
                }
                let lengthEnd = try Self.checkedAdd(offset, 4, context: "resource length")
                try reader.require(end: lengthEnd, context: "resource length")
                let length = try reader.uint32(at: offset, context: "resource length")
                guard let payloadLength = Int(exactly: length) else {
                    throw SourceVTFError.arithmeticOverflow("resource payload length")
                }
                let payloadEnd = try Self.checkedAdd(
                    lengthEnd,
                    payloadLength,
                    context: "resource payload end"
                )
                try reader.require(end: payloadEnd, context: "resource payload")
                resourceRanges[resource.type] = lengthEnd..<payloadEnd
            }
        }

        version = parsedVersion
        headerSize = parsedHeaderSize
        width = parsedWidth
        height = parsedHeight
        depth = parsedDepth
        flags = parsedFlags
        frameCount = parsedFrameCount
        firstFrame = parsedFirstFrame
        reflectivity = parsedReflectivity
        bumpScale = parsedBumpScale
        imageFormat = parsedImageFormat
        mipCount = parsedMipCount
        lowResolutionFormat = parsedLowFormat
        lowResolutionWidth = parsedLowWidth
        lowResolutionHeight = parsedLowHeight
        resources = parsedResources
        faceCount = parsedFaceCount
        imageDataRange = parsedImageOffset..<imageEnd
        lowResolutionDataRange = parsedLowRange
        self.allocationLimits = allocationLimits
        fileData = data
        genericResourceRanges = resourceRanges
    }

    public func lowResolutionData() -> Data? {
        guard let range = lowResolutionDataRange else { return nil }
        return fileData.subdata(in: range)
    }

    /// Returns an extended resource payload. Inline (`RSRCF_HAS_NO_DATA_CHUNK`)
    /// values remain available through `resources[].dataOrOffset` and return nil.
    public func resourceData(for type: UInt32) -> Data? {
        guard let range = genericResourceRanges[type & 0x00FF_FFFF] else { return nil }
        return fileData.subdata(in: range)
    }

    /// Extracts one frame/face/depth slice. Public mip zero is the largest mip,
    /// while the VTF disk stream is traversed from the coarsest mip upward.
    public func subresource(
        mipLevel: Int,
        frame: Int = 0,
        face: Int = 0,
        slice: Int = 0
    ) throws -> SourceVTFSubresource {
        let mipDepth = Self.mipDimension(depth, level: mipLevel)
        guard mipLevel >= 0, mipLevel < mipCount,
              frame >= 0, frame < frameCount,
              face >= 0, face < faceCount,
              slice >= 0, slice < mipDepth else {
            throw SourceVTFError.subresourceOutOfRange(
                mip: mipLevel,
                frame: frame,
                face: face,
                slice: slice
            )
        }

        var offset = imageDataRange.lowerBound
        if mipLevel + 1 < mipCount {
            for precedingMip in (mipLevel + 1..<mipCount).reversed() {
                offset = try Self.checkedAdd(
                    offset,
                    Self.totalByteCountForMip(
                        precedingMip,
                        format: imageFormat,
                        width: width,
                        height: height,
                        depth: depth,
                        frameCount: frameCount,
                        faceCount: faceCount
                    ),
                    context: "preceding mip offset"
                )
            }
        }

        let mipWidth = Self.mipDimension(width, level: mipLevel)
        let mipHeight = Self.mipDimension(height, level: mipLevel)
        let sliceSize = try Self.encodedSliceByteCount(
            format: imageFormat,
            width: mipWidth,
            height: mipHeight
        )
        let frameFace = try Self.checkedAdd(
            try Self.checkedMultiply(frame, faceCount, context: "frame/face index"),
            face,
            context: "frame/face index"
        )
        let sliceOrdinal = try Self.checkedAdd(
            try Self.checkedMultiply(frameFace, mipDepth, context: "slice index"),
            slice,
            context: "slice index"
        )
        offset = try Self.checkedAdd(
            offset,
            try Self.checkedMultiply(sliceOrdinal, sliceSize, context: "slice offset"),
            context: "subresource offset"
        )
        let end = try Self.checkedAdd(offset, sliceSize, context: "subresource end")
        guard offset >= imageDataRange.lowerBound, end <= imageDataRange.upperBound else {
            throw SourceVTFError.truncated(
                context: "subresource",
                expectedEnd: end,
                actualCount: imageDataRange.upperBound
            )
        }
        let range = offset..<end
        return SourceVTFSubresource(
            mipLevel: mipLevel,
            frame: frame,
            face: face,
            slice: slice,
            width: mipWidth,
            height: mipHeight,
            mipDepth: mipDepth,
            format: imageFormat,
            fileRange: range,
            data: fileData.subdata(in: range)
        )
    }

    public func decodeRGBA8(
        mipLevel: Int = 0,
        frame: Int = 0,
        face: Int = 0,
        slice: Int = 0
    ) throws -> SourceVTFDecodedImage {
        let decodedWidth = Self.mipDimension(width, level: mipLevel)
        let decodedHeight = Self.mipDimension(height, level: mipLevel)
        let pixelCount = try Self.checkedMultiply(
            decodedWidth,
            decodedHeight,
            context: "decoded pixel count"
        )
        guard pixelCount <= allocationLimits.maximumPixelCount else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "decoded pixel count",
                limit: allocationLimits.maximumPixelCount,
                actual: pixelCount
            )
        }
        let rgbaByteCount = try Self.checkedMultiply(
            pixelCount,
            4,
            context: "decoded RGBA8 byte count"
        )
        guard rgbaByteCount <= allocationLimits.maximumDecodedBytes else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "decoded RGBA8 bytes",
                limit: allocationLimits.maximumDecodedBytes,
                actual: rgbaByteCount
            )
        }
        let resource = try subresource(
            mipLevel: mipLevel,
            frame: frame,
            face: face,
            slice: slice
        )
        let pixels: [UInt8]
        switch imageFormat {
        case .rgba8888:
            pixels = try Self.decodeLinear(resource, order: .rgba)
        case .bgra8888:
            pixels = try Self.decodeLinear(resource, order: .bgra)
        case .abgr8888:
            pixels = try Self.decodeLinear(resource, order: .abgr)
        case .argb8888:
            pixels = try Self.decodeLinear(resource, order: .argb)
        case .bgrx8888:
            pixels = try Self.decodeLinear(resource, order: .bgrx)
        case .rgb888:
            pixels = try Self.decodeLinear(resource, order: .rgb)
        case .bgr888:
            pixels = try Self.decodeLinear(resource, order: .bgr)
        case .rgb565:
            pixels = try Self.decodePacked16(resource, order: .rgb565)
        case .bgr565:
            pixels = try Self.decodePacked16(resource, order: .bgr565)
        case .bgrx5551:
            pixels = try Self.decodePacked16(resource, order: .bgrx5551)
        case .bgra4444:
            pixels = try Self.decodePacked16(resource, order: .bgra4444)
        case .bgra5551:
            pixels = try Self.decodePacked16(resource, order: .bgra5551)
        case .i8:
            pixels = try Self.decodeIntensity(resource, hasAlpha: false)
        case .ia88:
            pixels = try Self.decodeIntensity(resource, hasAlpha: true)
        case .a8:
            pixels = try Self.decodeAlpha(resource)
        case .dxt1, .dxt1OneBitAlpha, .dxt1Runtime:
            pixels = try Self.decodeDXT1(resource)
        case .dxt3:
            pixels = try Self.decodeDXT3(resource)
        case .dxt5, .dxt5Runtime:
            pixels = try Self.decodeDXT5(resource)
        case .ati1N:
            pixels = try Self.decodeBC4(resource)
        case .ati2N:
            pixels = try Self.decodeBC5(resource)
        default:
            throw SourceVTFError.unsupportedImageFormat(imageFormat)
        }
        return SourceVTFDecodedImage(
            width: resource.width,
            height: resource.height,
            rgbaBytes: Data(pixels)
        )
    }

    private enum LinearOrder {
        case rgba
        case bgra
        case abgr
        case argb
        case bgrx
        case rgb
        case bgr

        var bytesPerPixel: Int {
            switch self {
            case .rgb, .bgr: return 3
            default: return 4
            }
        }
    }

    private static func decodeLinear(
        _ resource: SourceVTFSubresource,
        order: LinearOrder
    ) throws -> [UInt8] {
        let pixelCount = try checkedMultiply(
            resource.width,
            resource.height,
            context: "decoded pixel count"
        )
        let expected = try checkedMultiply(
            pixelCount,
            order.bytesPerPixel,
            context: "encoded linear image size"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "linear image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }
        var output = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixelIndex in 0..<pixelCount {
            let input = pixelIndex * order.bytesPerPixel
            let outputOffset = pixelIndex * 4
            switch order {
            case .rgba:
                output[outputOffset] = resource.data[input]
                output[outputOffset + 1] = resource.data[input + 1]
                output[outputOffset + 2] = resource.data[input + 2]
                output[outputOffset + 3] = resource.data[input + 3]
            case .bgra:
                output[outputOffset] = resource.data[input + 2]
                output[outputOffset + 1] = resource.data[input + 1]
                output[outputOffset + 2] = resource.data[input]
                output[outputOffset + 3] = resource.data[input + 3]
            case .abgr:
                output[outputOffset] = resource.data[input + 3]
                output[outputOffset + 1] = resource.data[input + 2]
                output[outputOffset + 2] = resource.data[input + 1]
                output[outputOffset + 3] = resource.data[input]
            case .argb:
                output[outputOffset] = resource.data[input + 1]
                output[outputOffset + 1] = resource.data[input + 2]
                output[outputOffset + 2] = resource.data[input + 3]
                output[outputOffset + 3] = resource.data[input]
            case .bgrx:
                output[outputOffset] = resource.data[input + 2]
                output[outputOffset + 1] = resource.data[input + 1]
                output[outputOffset + 2] = resource.data[input]
                // Direct3D's undefined X component reads as one. It is not
                // texture alpha, even if the stored padding bit pattern is 0.
                output[outputOffset + 3] = 255
            case .rgb:
                output[outputOffset] = resource.data[input]
                output[outputOffset + 1] = resource.data[input + 1]
                output[outputOffset + 2] = resource.data[input + 2]
                output[outputOffset + 3] = 255
            case .bgr:
                output[outputOffset] = resource.data[input + 2]
                output[outputOffset + 1] = resource.data[input + 1]
                output[outputOffset + 2] = resource.data[input]
                output[outputOffset + 3] = 255
            }
        }
        return output
    }

    private enum Packed16Order {
        case rgb565
        case bgr565
        case bgrx5551
        case bgra4444
        case bgra5551
    }

    private static func decodePacked16(
        _ resource: SourceVTFSubresource,
        order: Packed16Order
    ) throws -> [UInt8] {
        let pixelCount = try checkedMultiply(
            resource.width,
            resource.height,
            context: "decoded pixel count"
        )
        let expected = try checkedMultiply(
            pixelCount,
            2,
            context: "encoded packed-16 image size"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "packed-16 image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }

        var output = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixelIndex in 0..<pixelCount {
            let value = uint16(resource.data, at: pixelIndex * 2)
            let color: RGBA
            switch order {
            case .rgb565:
                // Source's format names list the least-significant component
                // first: R occupies bits 0...4 and B occupies bits 11...15.
                color = RGBA(
                    red: expandUNorm(value & 0x1F, maximum: 0x1F),
                    green: expandUNorm((value >> 5) & 0x3F, maximum: 0x3F),
                    blue: expandUNorm((value >> 11) & 0x1F, maximum: 0x1F),
                    alpha: 255
                )
            case .bgr565:
                color = RGBA(
                    red: expandUNorm((value >> 11) & 0x1F, maximum: 0x1F),
                    green: expandUNorm((value >> 5) & 0x3F, maximum: 0x3F),
                    blue: expandUNorm(value & 0x1F, maximum: 0x1F),
                    alpha: 255
                )
            case .bgrx5551:
                color = RGBA(
                    red: expandUNorm((value >> 10) & 0x1F, maximum: 0x1F),
                    green: expandUNorm((value >> 5) & 0x1F, maximum: 0x1F),
                    blue: expandUNorm(value & 0x1F, maximum: 0x1F),
                    alpha: 255
                )
            case .bgra4444:
                color = RGBA(
                    red: expandUNorm((value >> 8) & 0x0F, maximum: 0x0F),
                    green: expandUNorm((value >> 4) & 0x0F, maximum: 0x0F),
                    blue: expandUNorm(value & 0x0F, maximum: 0x0F),
                    alpha: expandUNorm((value >> 12) & 0x0F, maximum: 0x0F)
                )
            case .bgra5551:
                color = RGBA(
                    red: expandUNorm((value >> 10) & 0x1F, maximum: 0x1F),
                    green: expandUNorm((value >> 5) & 0x1F, maximum: 0x1F),
                    blue: expandUNorm(value & 0x1F, maximum: 0x1F),
                    alpha: value & 0x8000 == 0 ? 0 : 255
                )
            }
            write(color, at: pixelIndex, output: &output)
        }
        return output
    }

    private static func decodeIntensity(
        _ resource: SourceVTFSubresource,
        hasAlpha: Bool
    ) throws -> [UInt8] {
        let pixelCount = try checkedMultiply(
            resource.width,
            resource.height,
            context: "decoded pixel count"
        )
        let bytesPerPixel = hasAlpha ? 2 : 1
        let expected = try checkedMultiply(
            pixelCount,
            bytesPerPixel,
            context: "encoded intensity image size"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "intensity image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }

        var output = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixelIndex in 0..<pixelCount {
            let input = pixelIndex * bytesPerPixel
            let intensity = resource.data[input]
            write(
                RGBA(
                    red: intensity,
                    green: intensity,
                    blue: intensity,
                    alpha: hasAlpha ? resource.data[input + 1] : 255
                ),
                at: pixelIndex,
                output: &output
            )
        }
        return output
    }

    private static func decodeAlpha(_ resource: SourceVTFSubresource) throws -> [UInt8] {
        let pixelCount = try checkedMultiply(
            resource.width,
            resource.height,
            context: "decoded pixel count"
        )
        guard resource.data.count == pixelCount else {
            throw SourceVTFError.truncated(
                context: "alpha image",
                expectedEnd: pixelCount,
                actualCount: resource.data.count
            )
        }

        var output = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixelIndex in 0..<pixelCount {
            // D3DFMT_A8 is the documented exception to the usual value-one
            // rule for missing channels: its three color channels read as 0.
            write(
                RGBA(red: 0, green: 0, blue: 0, alpha: resource.data[pixelIndex]),
                at: pixelIndex,
                output: &output
            )
        }
        return output
    }

    private static func decodeDXT1(_ resource: SourceVTFSubresource) throws -> [UInt8] {
        let blockColumns = max(1, (resource.width + 3) / 4)
        let blockRows = max(1, (resource.height + 3) / 4)
        let expected = try checkedMultiply(
            try checkedMultiply(blockColumns, blockRows, context: "DXT1 block count"),
            8,
            context: "DXT1 byte count"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "DXT1 image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }
        var output = [UInt8](repeating: 0, count: resource.width * resource.height * 4)
        for blockY in 0..<blockRows {
            for blockX in 0..<blockColumns {
                let offset = (blockY * blockColumns + blockX) * 8
                let color0 = uint16(resource.data, at: offset)
                let color1 = uint16(resource.data, at: offset + 2)
                let palette = colorPalette(color0: color0, color1: color1, allowsTransparency: true)
                let indices = uint32(resource.data, at: offset + 4)
                writeColorBlock(
                    palette: palette,
                    indices: indices,
                    blockX: blockX,
                    blockY: blockY,
                    width: resource.width,
                    height: resource.height,
                    output: &output
                )
            }
        }
        return output
    }

    private static func decodeDXT3(_ resource: SourceVTFSubresource) throws -> [UInt8] {
        let blockColumns = max(1, (resource.width + 3) / 4)
        let blockRows = max(1, (resource.height + 3) / 4)
        let expected = try checkedMultiply(
            try checkedMultiply(blockColumns, blockRows, context: "DXT3 block count"),
            16,
            context: "DXT3 byte count"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "DXT3 image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }

        var output = [UInt8](repeating: 0, count: resource.width * resource.height * 4)
        for blockY in 0..<blockRows {
            for blockX in 0..<blockColumns {
                let offset = (blockY * blockColumns + blockX) * 16
                var explicitAlpha: UInt64 = 0
                for byteIndex in 0..<8 {
                    explicitAlpha |= UInt64(resource.data[offset + byteIndex])
                        << UInt64(byteIndex * 8)
                }

                let color0 = uint16(resource.data, at: offset + 8)
                let color1 = uint16(resource.data, at: offset + 10)
                // BC2/DXT3 always uses the opaque four-color BC1 palette;
                // the unsigned endpoint comparison must not select BC1's
                // transparent entry.
                let palette = colorPalette(
                    color0: color0,
                    color1: color1,
                    allowsTransparency: false
                )
                let colorIndices = uint32(resource.data, at: offset + 12)

                for localY in 0..<4 {
                    for localX in 0..<4 {
                        let x = blockX * 4 + localX
                        let y = blockY * 4 + localY
                        guard x < resource.width, y < resource.height else { continue }
                        let localIndex = localY * 4 + localX
                        let colorIndex = Int(
                            (colorIndices >> UInt32(localIndex * 2)) & 0x03
                        )
                        let alpha4 = UInt8(
                            (explicitAlpha >> UInt64(localIndex * 4)) & 0x0F
                        )
                        var color = palette[colorIndex]
                        // Replication is the exact 4-bit UNORM-to-8-bit map.
                        color.alpha = (alpha4 << 4) | alpha4
                        write(color, x: x, y: y, width: resource.width, output: &output)
                    }
                }
            }
        }
        return output
    }

    private static func decodeDXT5(_ resource: SourceVTFSubresource) throws -> [UInt8] {
        let blockColumns = max(1, (resource.width + 3) / 4)
        let blockRows = max(1, (resource.height + 3) / 4)
        let expected = try checkedMultiply(
            try checkedMultiply(blockColumns, blockRows, context: "DXT5 block count"),
            16,
            context: "DXT5 byte count"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "DXT5 image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }
        var output = [UInt8](repeating: 0, count: resource.width * resource.height * 4)
        for blockY in 0..<blockRows {
            for blockX in 0..<blockColumns {
                let offset = (blockY * blockColumns + blockX) * 16
                let alpha0 = resource.data[offset]
                let alpha1 = resource.data[offset + 1]
                let alphaPalette = dxt5AlphaPalette(alpha0: alpha0, alpha1: alpha1)
                var alphaIndices: UInt64 = 0
                for byteIndex in 0..<6 {
                    alphaIndices |= UInt64(resource.data[offset + 2 + byteIndex]) << UInt64(byteIndex * 8)
                }

                let color0 = uint16(resource.data, at: offset + 8)
                let color1 = uint16(resource.data, at: offset + 10)
                let palette = colorPalette(
                    color0: color0,
                    color1: color1,
                    allowsTransparency: false
                )
                let colorIndices = uint32(resource.data, at: offset + 12)

                for localY in 0..<4 {
                    for localX in 0..<4 {
                        let x = blockX * 4 + localX
                        let y = blockY * 4 + localY
                        guard x < resource.width, y < resource.height else { continue }
                        let localIndex = localY * 4 + localX
                        let colorIndex = Int((colorIndices >> UInt32(localIndex * 2)) & 0x03)
                        let alphaIndex = Int((alphaIndices >> UInt64(localIndex * 3)) & 0x07)
                        var color = palette[colorIndex]
                        color.alpha = alphaPalette[alphaIndex]
                        write(color, x: x, y: y, width: resource.width, output: &output)
                    }
                }
            }
        }
        return output
    }

    private struct BCScalarBlock {
        let palette: [UInt8]
        let indices: UInt64

        func value(at localIndex: Int) -> UInt8 {
            let paletteIndex = Int((indices >> UInt64(localIndex * 3)) & 0x07)
            return palette[paletteIndex]
        }
    }

    private static func scalarBlock(_ data: Data, at offset: Int) -> BCScalarBlock {
        let endpoint0 = data[offset]
        let endpoint1 = data[offset + 1]
        var indices: UInt64 = 0
        for byteIndex in 0..<6 {
            indices |= UInt64(data[offset + 2 + byteIndex]) << UInt64(byteIndex * 8)
        }
        return BCScalarBlock(
            palette: dxt5AlphaPalette(alpha0: endpoint0, alpha1: endpoint1),
            indices: indices
        )
    }

    private static func decodeBC4(_ resource: SourceVTFSubresource) throws -> [UInt8] {
        try decodeBCScalar(resource, componentCount: 1)
    }

    private static func decodeBC5(_ resource: SourceVTFSubresource) throws -> [UInt8] {
        try decodeBCScalar(resource, componentCount: 2)
    }

    private static func decodeBCScalar(
        _ resource: SourceVTFSubresource,
        componentCount: Int
    ) throws -> [UInt8] {
        let bytesPerBlock = componentCount * 8
        let formatName = componentCount == 1 ? "ATI1N/BC4" : "ATI2N/BC5"
        let blockColumns = max(1, (resource.width + 3) / 4)
        let blockRows = max(1, (resource.height + 3) / 4)
        let expected = try checkedMultiply(
            try checkedMultiply(
                blockColumns,
                blockRows,
                context: "\(formatName) block count"
            ),
            bytesPerBlock,
            context: "\(formatName) byte count"
        )
        guard resource.data.count == expected else {
            throw SourceVTFError.truncated(
                context: "\(formatName) image",
                expectedEnd: expected,
                actualCount: resource.data.count
            )
        }

        var output = [UInt8](repeating: 0, count: resource.width * resource.height * 4)
        for blockY in 0..<blockRows {
            for blockX in 0..<blockColumns {
                let offset = (blockY * blockColumns + blockX) * bytesPerBlock
                let red = scalarBlock(resource.data, at: offset)
                let green = componentCount == 2
                    ? scalarBlock(resource.data, at: offset + 8)
                    : nil

                for localY in 0..<4 {
                    for localX in 0..<4 {
                        let x = blockX * 4 + localX
                        let y = blockY * 4 + localY
                        guard x < resource.width, y < resource.height else { continue }
                        let localIndex = localY * 4 + localX
                        write(
                            RGBA(
                                red: red.value(at: localIndex),
                                green: green?.value(at: localIndex) ?? 0,
                                blue: 0,
                                alpha: 255
                            ),
                            x: x,
                            y: y,
                            width: resource.width,
                            output: &output
                        )
                    }
                }
            }
        }
        return output
    }

    private struct RGBA {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    private static func colorPalette(
        color0: UInt16,
        color1: UInt16,
        allowsTransparency: Bool
    ) -> [RGBA] {
        let first = decodeRGB565(color0)
        let second = decodeRGB565(color1)
        if allowsTransparency && color0 <= color1 {
            return [
                first,
                second,
                interpolate(first, second, firstWeight: 1, secondWeight: 1, divisor: 2),
                RGBA(red: 0, green: 0, blue: 0, alpha: 0)
            ]
        }
        return [
            first,
            second,
            interpolate(first, second, firstWeight: 2, secondWeight: 1, divisor: 3),
            interpolate(first, second, firstWeight: 1, secondWeight: 2, divisor: 3)
        ]
    }

    private static func decodeRGB565(_ value: UInt16) -> RGBA {
        // BC1/2/3 promotion is not generic UNORM requantization. The Direct3D
        // functional specification requires MSB extension (bit replication)
        // from each 5:6:5 endpoint to UNORM8 before palette interpolation.
        let red5 = UInt8((value >> 11) & 0x1F)
        let green6 = UInt8((value >> 5) & 0x3F)
        let blue5 = UInt8(value & 0x1F)
        let red = (red5 << 3) | (red5 >> 2)
        let green = (green6 << 2) | (green6 >> 4)
        let blue = (blue5 << 3) | (blue5 >> 2)
        return RGBA(red: red, green: green, blue: blue, alpha: 255)
    }

    private static func expandUNorm(_ value: UInt16, maximum: UInt16) -> UInt8 {
        let numerator = UInt32(value) * 255 + UInt32(maximum) / 2
        return UInt8(numerator / UInt32(maximum))
    }

    private static func interpolate(
        _ first: RGBA,
        _ second: RGBA,
        firstWeight: UInt32,
        secondWeight: UInt32,
        divisor: UInt32
    ) -> RGBA {
        func channel(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
            let weighted = UInt32(lhs) * firstWeight + UInt32(rhs) * secondWeight
            // DirectX defines the intermediate values as linear UNORM blends.
            // Integer RGBA8 output therefore rounds to the nearest code point.
            return UInt8((weighted + divisor / 2) / divisor)
        }
        return RGBA(
            red: channel(first.red, second.red),
            green: channel(first.green, second.green),
            blue: channel(first.blue, second.blue),
            alpha: channel(first.alpha, second.alpha)
        )
    }

    private static func dxt5AlphaPalette(alpha0: UInt8, alpha1: UInt8) -> [UInt8] {
        func blend(_ firstWeight: UInt16, _ secondWeight: UInt16, divisor: UInt16) -> UInt8 {
            let weighted = firstWeight * UInt16(alpha0) + secondWeight * UInt16(alpha1)
            return UInt8((weighted + divisor / 2) / divisor)
        }

        if alpha0 > alpha1 {
            return [
                alpha0,
                alpha1,
                blend(6, 1, divisor: 7),
                blend(5, 2, divisor: 7),
                blend(4, 3, divisor: 7),
                blend(3, 4, divisor: 7),
                blend(2, 5, divisor: 7),
                blend(1, 6, divisor: 7)
            ]
        }
        return [
            alpha0,
            alpha1,
            blend(4, 1, divisor: 5),
            blend(3, 2, divisor: 5),
            blend(2, 3, divisor: 5),
            blend(1, 4, divisor: 5),
            0,
            255
        ]
    }

    private static func writeColorBlock(
        palette: [RGBA],
        indices: UInt32,
        blockX: Int,
        blockY: Int,
        width: Int,
        height: Int,
        output: inout [UInt8]
    ) {
        for localY in 0..<4 {
            for localX in 0..<4 {
                let x = blockX * 4 + localX
                let y = blockY * 4 + localY
                guard x < width, y < height else { continue }
                let localIndex = localY * 4 + localX
                let paletteIndex = Int((indices >> UInt32(localIndex * 2)) & 0x03)
                write(palette[paletteIndex], x: x, y: y, width: width, output: &output)
            }
        }
    }

    private static func write(
        _ color: RGBA,
        x: Int,
        y: Int,
        width: Int,
        output: inout [UInt8]
    ) {
        let offset = (y * width + x) * 4
        output[offset] = color.red
        output[offset + 1] = color.green
        output[offset + 2] = color.blue
        output[offset + 3] = color.alpha
    }

    private static func write(_ color: RGBA, at pixelIndex: Int, output: inout [UInt8]) {
        let offset = pixelIndex * 4
        output[offset] = color.red
        output[offset + 1] = color.green
        output[offset + 2] = color.blue
        output[offset + 3] = color.alpha
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func maximumMipCount(width: Int, height: Int, depth: Int) -> Int {
        var largest = max(width, max(height, depth))
        var count = 1
        while largest > 1 {
            largest >>= 1
            count += 1
        }
        return count
    }

    private static func mipDimension(_ base: Int, level: Int) -> Int {
        guard level > 0 else { return base }
        return max(1, base >> level)
    }

    private static func totalImageByteCount(
        format: SourceVTFImageFormat,
        width: Int,
        height: Int,
        depth: Int,
        mipCount: Int,
        frameCount: Int,
        faceCount: Int
    ) throws -> Int {
        var total = 0
        for mip in 0..<mipCount {
            total = try checkedAdd(
                total,
                totalByteCountForMip(
                    mip,
                    format: format,
                    width: width,
                    height: height,
                    depth: depth,
                    frameCount: frameCount,
                    faceCount: faceCount
                ),
                context: "total image size"
            )
        }
        return total
    }

    private static func totalByteCountForMip(
        _ mip: Int,
        format: SourceVTFImageFormat,
        width: Int,
        height: Int,
        depth: Int,
        frameCount: Int,
        faceCount: Int
    ) throws -> Int {
        let slice = try encodedSliceByteCount(
            format: format,
            width: mipDimension(width, level: mip),
            height: mipDimension(height, level: mip)
        )
        let allSlices = try checkedMultiply(
            slice,
            mipDimension(depth, level: mip),
            context: "mip depth size"
        )
        let allFrames = try checkedMultiply(
            allSlices,
            frameCount,
            context: "mip frame size"
        )
        return try checkedMultiply(allFrames, faceCount, context: "mip face size")
    }

    private static func encodedSliceByteCount(
        format: SourceVTFImageFormat,
        width: Int,
        height: Int
    ) throws -> Int {
        let pixelCount = try checkedMultiply(width, height, context: "image pixel count")
        switch format {
        case .rgba8888, .abgr8888, .argb8888, .bgra8888, .bgrx8888,
             .uvwq8888, .uvlx8888, .r32F, .nvDST24, .nvINTZ, .nvRAWZ, .atiDST24:
            return try checkedMultiply(pixelCount, 4, context: "four-byte image size")
        case .rgb888, .bgr888, .rgb888BlueScreen, .bgr888BlueScreen:
            return try checkedMultiply(pixelCount, 3, context: "three-byte image size")
        case .rgb565, .ia88, .bgr565, .bgrx5551, .bgra4444, .bgra5551,
             .uv88, .nvDST16, .atiDST16:
            return try checkedMultiply(pixelCount, 2, context: "two-byte image size")
        case .i8, .p8, .a8:
            return pixelCount
        case .rgba16161616F, .rgba16161616:
            return try checkedMultiply(pixelCount, 8, context: "eight-byte image size")
        case .rgb323232F:
            return try checkedMultiply(pixelCount, 12, context: "twelve-byte image size")
        case .rgba32323232F:
            return try checkedMultiply(pixelCount, 16, context: "sixteen-byte image size")
        case .dxt1, .dxt1OneBitAlpha, .ati1N, .dxt1Runtime:
            return try blockCompressedByteCount(width: width, height: height, bytesPerBlock: 8)
        case .dxt3, .dxt5, .ati2N, .dxt5Runtime:
            return try blockCompressedByteCount(width: width, height: height, bytesPerBlock: 16)
        case .unknown, .nvNull:
            throw SourceVTFError.unsupportedImageFormat(format)
        }
    }

    private static func blockCompressedByteCount(
        width: Int,
        height: Int,
        bytesPerBlock: Int
    ) throws -> Int {
        let columns = max(1, (width + 3) / 4)
        let rows = max(1, (height + 3) / 4)
        return try checkedMultiply(
            try checkedMultiply(columns, rows, context: "compressed block count"),
            bytesPerBlock,
            context: "compressed image size"
        )
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int, context: String) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw SourceVTFError.arithmeticOverflow(context) }
        return value
    }

    private static func checkedMultiply(
        _ lhs: Int,
        _ rhs: Int,
        context: String
    ) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw SourceVTFError.arithmeticOverflow(context) }
        return value
    }
}

private struct SourceVTFByteReader {
    let data: Data

    func require(end: Int, context: String) throws {
        guard end >= 0, end <= data.count else {
            throw SourceVTFError.truncated(
                context: context,
                expectedEnd: end,
                actualCount: data.count
            )
        }
    }

    func uint8(at offset: Int, context: String) throws -> UInt8 {
        try require(end: offset + 1, context: context)
        return data[offset]
    }

    func uint16(at offset: Int, context: String) throws -> UInt16 {
        try require(end: offset + 2, context: context)
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    func uint32(at offset: Int, context: String) throws -> UInt32 {
        try require(end: offset + 4, context: context)
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    func int32(at offset: Int, context: String) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset, context: context))
    }

    func float32(at offset: Int, context: String) throws -> Float {
        Float(bitPattern: try uint32(at: offset, context: context))
    }
}

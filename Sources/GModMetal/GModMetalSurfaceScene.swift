import Foundation
import GModEngine

/// A normalized top-left-origin rectangle in GLua viewport pixels.
public struct GModMetalSurfaceRect: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Straight-alpha color normalized to 0...1. The Metal shader converts it to
/// premultiplied alpha immediately before blending.
public struct GModMetalSurfaceColor: Sendable, Equatable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum GModMetalSurfaceBitmapError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case emptyIdentifier
    case invalidDimensions(width: Int, height: Int)
    case byteCountOverflow
    case invalidByteCount(expected: Int, actual: Int)
    case invalidMipDimensions(
        level: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidMipByteCount(level: Int, expected: Int, actual: Int)
    case mipZeroDoesNotMatchBase
    case excessiveMipCount(maximum: Int, actual: Int)

    public var description: String {
        switch self {
        case .emptyIdentifier:
            return "surface bitmap identifier is empty"
        case let .invalidDimensions(width, height):
            return "surface bitmap dimensions are invalid (\(width)x\(height))"
        case .byteCountOverflow:
            return "surface bitmap byte count overflows Int"
        case let .invalidByteCount(expected, actual):
            return "surface bitmap contains \(actual) bytes; expected \(expected)"
        case let .invalidMipDimensions(
            level, expectedWidth, expectedHeight, actualWidth, actualHeight
        ):
            return "surface bitmap mip \(level) is \(actualWidth)x\(actualHeight); " +
                "expected \(expectedWidth)x\(expectedHeight)"
        case let .invalidMipByteCount(level, expected, actual):
            return "surface bitmap mip \(level) contains \(actual) bytes; " +
                "expected \(expected)"
        case .mipZeroDoesNotMatchBase:
            return "surface bitmap mip 0 pixels do not match the base image"
        case let .excessiveMipCount(maximum, actual):
            return "surface bitmap has \(actual) mips; maximum is \(maximum)"
        }
    }
}

public struct GModMetalSurfaceMipLevel: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let premultipliedRGBA8: Data

    public init(width: Int, height: Int, premultipliedRGBA8: Data) {
        self.width = width
        self.height = height
        self.premultipliedRGBA8 = premultipliedRGBA8
    }
}

/// Describes how the RGB channels are encoded relative to alpha. Surface and
/// CoreText blending require premultiplied pixels; Source world, sky, and
/// water textures remain straight-alpha until the shader samples them.
public enum GModMetalBitmapAlphaRepresentation: UInt8, Sendable, Equatable,
    Hashable
{
    case straight
    case premultiplied
}

enum GModMetalSurfaceTextureUploadContract {
    static let mipmapLevelCount = 1
}

/// Immutable, top-left-origin RGBA8 pixels. `alphaRepresentation` is part of
/// cache identity because the same Source mip bytes have different blending
/// semantics in Surface and world render passes. Bitmap conversion and glyph
/// rasterization happen while a scene is built, never in MTKView.draw.
public struct GModMetalSurfaceBitmap: Sendable, Equatable {
    public let resourceIdentifier: String
    public let cacheIdentifier: String
    public let width: Int
    public let height: Int
    public let premultipliedRGBA8: Data
    public let mipLevels: [GModMetalSurfaceMipLevel]
    public let sourceTextureFlags: SourceVTFTextureFlags?
    public let alphaRepresentation: GModMetalBitmapAlphaRepresentation

    public init(
        resourceIdentifier: String,
        width: Int,
        height: Int,
        premultipliedRGBA8: Data,
        mipLevels: [GModMetalSurfaceMipLevel] = [],
        sourceTextureFlags: SourceVTFTextureFlags? = nil,
        alphaRepresentation: GModMetalBitmapAlphaRepresentation = .premultiplied
    ) throws {
        guard !resourceIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw GModMetalSurfaceBitmapError.emptyIdentifier
        }
        guard width > 0, height > 0 else {
            throw GModMetalSurfaceBitmapError.invalidDimensions(
                width: width,
                height: height
            )
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else {
            throw GModMetalSurfaceBitmapError.byteCountOverflow
        }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow else {
            throw GModMetalSurfaceBitmapError.byteCountOverflow
        }
        guard premultipliedRGBA8.count == bytes.partialValue else {
            throw GModMetalSurfaceBitmapError.invalidByteCount(
                expected: bytes.partialValue,
                actual: premultipliedRGBA8.count
            )
        }

        let retainedMipLevels = mipLevels.isEmpty
            ? [GModMetalSurfaceMipLevel(
                width: width,
                height: height,
                premultipliedRGBA8: premultipliedRGBA8
            )]
            : mipLevels
        var maximumMipCount = 1
        var maximumDimension = Swift.max(width, height)
        while maximumDimension > 1 {
            maximumDimension >>= 1
            maximumMipCount += 1
        }
        guard retainedMipLevels.count <= maximumMipCount else {
            throw GModMetalSurfaceBitmapError.excessiveMipCount(
                maximum: maximumMipCount,
                actual: retainedMipLevels.count
            )
        }
        for (level, mip) in retainedMipLevels.enumerated() {
            let expectedWidth = Swift.max(1, width >> level)
            let expectedHeight = Swift.max(1, height >> level)
            guard mip.width == expectedWidth,
                  mip.height == expectedHeight else {
                throw GModMetalSurfaceBitmapError.invalidMipDimensions(
                    level: level,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    actualWidth: mip.width,
                    actualHeight: mip.height
                )
            }
            let mipPixels = expectedWidth.multipliedReportingOverflow(
                by: expectedHeight
            )
            guard !mipPixels.overflow else {
                throw GModMetalSurfaceBitmapError.byteCountOverflow
            }
            let mipBytes = mipPixels.partialValue.multipliedReportingOverflow(by: 4)
            guard !mipBytes.overflow else {
                throw GModMetalSurfaceBitmapError.byteCountOverflow
            }
            guard mip.premultipliedRGBA8.count == mipBytes.partialValue else {
                throw GModMetalSurfaceBitmapError.invalidMipByteCount(
                    level: level,
                    expected: mipBytes.partialValue,
                    actual: mip.premultipliedRGBA8.count
                )
            }
        }
        guard retainedMipLevels.first?.premultipliedRGBA8 == premultipliedRGBA8
        else {
            throw GModMetalSurfaceBitmapError.mipZeroDoesNotMatchBase
        }

        self.resourceIdentifier = resourceIdentifier
        self.width = width
        self.height = height
        self.premultipliedRGBA8 = premultipliedRGBA8
        self.mipLevels = retainedMipLevels
        self.sourceTextureFlags = sourceTextureFlags
        self.alphaRepresentation = alphaRepresentation
        self.cacheIdentifier = resourceIdentifier + ":" + Self.contentDigest(
            width: width,
            height: height,
            mipLevels: retainedMipLevels,
            flags: sourceTextureFlags,
            alphaRepresentation: alphaRepresentation
        )
    }

    public var totalByteCount: Int {
        mipLevels.reduce(0) { $0 + $1.premultipliedRGBA8.count }
    }

    /// FNV-1a is used only as a fast cache hint. The renderer also compares the
    /// complete bitmap value before reusing a texture, so a hash collision
    /// cannot substitute pixels from another resource.
    private static func contentDigest(
        width: Int,
        height: Int,
        mipLevels: [GModMetalSurfaceMipLevel],
        flags: SourceVTFTextureFlags?,
        alphaRepresentation: GModMetalBitmapAlphaRepresentation
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for value in UInt64(width).littleEndianBytes { append(value) }
        for value in UInt64(height).littleEndianBytes { append(value) }
        for value in UInt64(flags?.rawValue ?? 0).littleEndianBytes { append(value) }
        append(alphaRepresentation.rawValue)
        for mip in mipLevels {
            for value in UInt64(mip.width).littleEndianBytes { append(value) }
            for value in UInt64(mip.height).littleEndianBytes { append(value) }
            for value in mip.premultipliedRGBA8 { append(value) }
        }
        return String(hash, radix: 16)
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

public protocol GModMetalSurfaceTextureResolving: Sendable {
    /// Returns actual decoded pixels or nil. A nil result stays explicitly
    /// unresolved; the scene builder never creates a placeholder texture.
    func resolveSurfaceTexture(named logicalName: String) throws
        -> GModMetalSurfaceBitmap?
}

public protocol GModMetalSurfaceTextRasterizing: Sendable {
    /// Rasterizes one snapshot command before it reaches the render thread.
    /// Returning nil means the command produces no pixels.
    func rasterizeSurfaceText(
        _ text: String,
        font: GMLuaFontDescriptor
    ) throws -> GModMetalSurfaceBitmap?
}

public struct GModMetalSurfaceSolidRectangle: Sendable, Equatable {
    public let frame: GModMetalSurfaceRect
    public let color: GModMetalSurfaceColor
}

public struct GModMetalSurfaceTexturedRectangle: Sendable, Equatable {
    public let frame: GModMetalSurfaceRect
    public let uv: GModMetalSurfaceRect
    public let textureName: String
    public let color: GModMetalSurfaceColor
    public let bitmap: GModMetalSurfaceBitmap
    public let minificationFilter: GMLuaTextureFilter?
    public let magnificationFilter: GMLuaTextureFilter?

    public init(
        frame: GModMetalSurfaceRect,
        uv: GModMetalSurfaceRect,
        textureName: String,
        color: GModMetalSurfaceColor,
        bitmap: GModMetalSurfaceBitmap,
        minificationFilter: GMLuaTextureFilter? = nil,
        magnificationFilter: GMLuaTextureFilter? = nil
    ) {
        self.frame = frame
        self.uv = uv
        self.textureName = textureName
        self.color = color
        self.bitmap = bitmap
        self.minificationFilter = minificationFilter
        self.magnificationFilter = magnificationFilter
    }
}

public enum GModMetalSurfaceSamplerAxisFilter: Sendable, Equatable, Hashable {
    case point
    case linear
}

/// Finite Metal sampler key derived from GMod's independent min/mag override
/// stacks. TEXFILTER.NONE disables the override and therefore resolves to the
/// same linear default as an empty stack. Hardware anisotropy applies only to
/// minification; an anisotropic magnification request remains linear.
enum GModMetalSamplerContract {
    /// GMod exposes anisotropic filtering as its highest-quality texture
    /// filter. Metal defines 16 as the highest legal sampler anisotropy.
    static let maximumAnisotropy = 16
}

public struct GModMetalSurfaceSamplerConfiguration: Sendable, Equatable, Hashable {
    public static let defaultMaximumAnisotropy =
        GModMetalSamplerContract.maximumAnisotropy

    public let minification: GModMetalSurfaceSamplerAxisFilter
    public let magnification: GModMetalSurfaceSamplerAxisFilter
    public let maximumAnisotropy: Int

    public init(
        minification: GModMetalSurfaceSamplerAxisFilter,
        magnification: GModMetalSurfaceSamplerAxisFilter,
        maximumAnisotropy: Int
    ) {
        self.minification = minification
        self.magnification = magnification
        self.maximumAnisotropy = maximumAnisotropy
    }

    public static func source(
        minification: GMLuaTextureFilter?,
        magnification: GMLuaTextureFilter?
    ) -> Self {
        Self(
            minification: axisFilter(minification),
            magnification: axisFilter(magnification),
            maximumAnisotropy: minification == .anisotropic
                ? defaultMaximumAnisotropy
                : 1
        )
    }

    static let allSourceConfigurations: [Self] = {
        let values: [GMLuaTextureFilter?] = [
            nil,
            .some(.none),
            .some(.point),
            .some(.linear),
            .some(.anisotropic),
        ]
        return Array(Set(values.flatMap { minification in
            values.map { magnification in
                source(
                    minification: minification,
                    magnification: magnification
                )
            }
        })).sorted {
            let lhs = ($0.minification.sortOrder, $0.magnification.sortOrder,
                $0.maximumAnisotropy)
            let rhs = ($1.minification.sortOrder, $1.magnification.sortOrder,
                $1.maximumAnisotropy)
            return lhs < rhs
        }
    }()

    private static func axisFilter(
        _ filter: GMLuaTextureFilter?
    ) -> GModMetalSurfaceSamplerAxisFilter {
        switch filter {
        case .some(.point):
            return .point
        case nil, .some(.none), .some(.linear), .some(.anisotropic):
            return .linear
        }
    }
}

private extension GModMetalSurfaceSamplerAxisFilter {
    var sortOrder: Int {
        switch self {
        case .point: return 0
        case .linear: return 1
        }
    }
}

public struct GModMetalSurfaceText: Sendable, Equatable {
    public let frame: GModMetalSurfaceRect
    public let uv: GModMetalSurfaceRect
    public let value: String
    public let font: GMLuaFontDescriptor
    public let color: GModMetalSurfaceColor
    public let glyphBitmap: GModMetalSurfaceBitmap
}

/// Ordered renderer-ready commands. The cases deliberately remain separate so
/// later texture atlasing does not erase the original surface semantics.
public enum GModMetalSurfaceCommand: Sendable, Equatable {
    case solidRectangle(GModMetalSurfaceSolidRectangle)
    case texturedRectangle(GModMetalSurfaceTexturedRectangle)
    case text(GModMetalSurfaceText)
}

public enum GModMetalSurfaceCommandKind: String, Sendable, Equatable {
    case solidRectangle
    case texturedRectangle
    case text
}

public struct GModMetalSurfaceUnresolvedCommand: Sendable, Equatable {
    public let commandIndex: Int
    public let kind: GModMetalSurfaceCommandKind
    public let reason: String
}

public struct GModMetalSurfaceDiagnostics: Sendable, Equatable {
    public let snapshotCommandCount: Int
    public let captureDiagnostics: GMLuaSurfaceCommandCaptureDiagnostics
    public let processedSnapshotCommandCount: Int
    public let droppedSnapshotCommandCount: Int
    public let maximumSnapshotCommandCount: Int
    public let solidRectangleCount: Int
    public let texturedRectangleCount: Int
    public let textCount: Int
    public let clippedCommandCount: Int
    public let discardedEmptyCommandCount: Int
    public let retainedBitmapCount: Int
    public let retainedBitmapByteCount: Int
    public let unresolvedCommands: [GModMetalSurfaceUnresolvedCommand]

    public var resolvedCommandCount: Int {
        solidRectangleCount + texturedRectangleCount + textCount
    }

    public var overflowed: Bool {
        captureDiagnostics.overflowed || droppedSnapshotCommandCount > 0
    }
}

/// Final render-thread guard. Capture and scene construction are independently
/// bounded, but the renderer still treats every incoming immutable scene as
/// untrusted so a future producer cannot multiply draw calls without limit.
struct GModMetalSurfaceDrawCommandBudget: Sendable, Equatable {
    static let defaultMaximumCommandCount = 16_384

    let maximumCommandCount: Int

    init(maximumCommandCount: Int = Self.defaultMaximumCommandCount) {
        self.maximumCommandCount = max(0, maximumCommandCount)
    }

    func admission(for commandCount: Int) -> (
        admittedCommandCount: Int,
        droppedCommandCount: Int
    ) {
        let count = max(0, commandCount)
        let admitted = min(count, maximumCommandCount)
        return (admitted, count - admitted)
    }
}

public enum GModMetalSurfaceSceneError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidViewport(width: Int, height: Int)

    public var description: String {
        switch self {
        case let .invalidViewport(width, height):
            return "surface viewport is invalid (\(width)x\(height))"
        }
    }
}

/// Immutable renderer boundary for one `GMLuaSurfaceFrameSnapshot`.
///
/// Construct this on the game/session actor (or another non-render worker).
/// Texture loading, PNG decoding, and CoreText rasterization can occur here;
/// the Metal callback receives only validated values and premultiplied pixels.
public struct GModMetalSurfaceScene: Sendable, Equatable {
    public static let defaultMaximumCommandCount = 16_384
    public static let defaultMaximumRetainedBitmapCount = 2_048
    public static let defaultMaximumRetainedBitmapByteCount =
        32 * 1_024 * 1_024

    public let viewportWidth: Int
    public let viewportHeight: Int
    public let commands: [GModMetalSurfaceCommand]
    public let diagnostics: GModMetalSurfaceDiagnostics

    public init(
        snapshot: GMLuaSurfaceFrameSnapshot,
        textureResolver: (any GModMetalSurfaceTextureResolving)? = nil,
        textRasterizer: (any GModMetalSurfaceTextRasterizing)? = nil,
        maximumCommandCount: Int =
            GModMetalSurfaceScene.defaultMaximumCommandCount,
        maximumRetainedBitmapCount: Int =
            GModMetalSurfaceScene.defaultMaximumRetainedBitmapCount,
        maximumRetainedBitmapByteCount: Int =
            GModMetalSurfaceScene.defaultMaximumRetainedBitmapByteCount
    ) throws {
        guard snapshot.viewportWidth > 0, snapshot.viewportHeight > 0 else {
            throw GModMetalSurfaceSceneError.invalidViewport(
                width: snapshot.viewportWidth,
                height: snapshot.viewportHeight
            )
        }

        let commandLimit = max(0, maximumCommandCount)
        let processedCommandCount = min(snapshot.commands.count, commandLimit)
        let droppedCommandCount = snapshot.commands.count - processedCommandCount
        var resolved: [GModMetalSurfaceCommand] = []
        resolved.reserveCapacity(processedCommandCount)
        var unresolved: [GModMetalSurfaceUnresolvedCommand] = []
        var solidCount = 0
        var textureCount = 0
        var textCount = 0
        var clippedCount = 0
        var discardedCount = 0
        var bitmapRetention = BitmapRetentionBudget(
            maximumCount: max(0, maximumRetainedBitmapCount),
            maximumByteCount: max(0, maximumRetainedBitmapByteCount)
        )
        let textureFiltersByCommandIndex = snapshot.textureFilters.reduce(
            into: [Int: GMLuaSurfaceTextureFilterSnapshot]()
        ) { result, filter in
            // Capture emits at most one value per retained textured command.
            // Keep the first value if a synthetic/malformed snapshot contains
            // duplicates so scene construction remains deterministic.
            if result[filter.commandIndex] == nil {
                result[filter.commandIndex] = filter
            }
        }

        for (index, command) in snapshot.commands
            .prefix(processedCommandCount)
            .enumerated() {
            switch command {
            case let .rectangle(frame, color, clip):
                guard let normalizedColor = Self.color(color) else {
                    unresolved.append(Self.unresolved(
                        index,
                        .solidRectangle,
                        "color contains a non-finite component"
                    ))
                    continue
                }
                switch Self.clip(
                    frame: frame,
                    uv: nil,
                    clip: clip,
                    viewportWidth: snapshot.viewportWidth,
                    viewportHeight: snapshot.viewportHeight
                ) {
                case .invalid:
                    unresolved.append(Self.unresolved(
                        index,
                        .solidRectangle,
                        "rectangle or clip geometry is invalid"
                    ))
                case .empty:
                    discardedCount += 1
                case let .visible(geometry):
                    if geometry.wasClipped { clippedCount += 1 }
                    resolved.append(.solidRectangle(
                        GModMetalSurfaceSolidRectangle(
                            frame: geometry.frame,
                            color: normalizedColor
                        )
                    ))
                    solidCount += 1
                }

            case let .texturedRectangle(frame, uv, textureName, color, clip):
                guard let normalizedColor = Self.color(color) else {
                    unresolved.append(Self.unresolved(
                        index,
                        .texturedRectangle,
                        "color contains a non-finite component"
                    ))
                    continue
                }
                let geometryResult = Self.clip(
                    frame: frame,
                    uv: uv,
                    clip: clip,
                    viewportWidth: snapshot.viewportWidth,
                    viewportHeight: snapshot.viewportHeight
                )
                guard case let .visible(geometry) = geometryResult else {
                    if case .invalid = geometryResult {
                        unresolved.append(Self.unresolved(
                            index,
                            .texturedRectangle,
                            "rectangle, UV, or clip geometry is invalid"
                        ))
                    } else {
                        discardedCount += 1
                    }
                    continue
                }
                guard Self.hasUnitTextureCoordinates(geometry.uv) else {
                    unresolved.append(Self.unresolved(
                        index,
                        .texturedRectangle,
                        "UV addressing outside 0...1 requires unresolved material wrap metadata"
                    ))
                    continue
                }
                guard let decodedName = String(
                    bytes: textureName.bytes,
                    encoding: .utf8
                ) else {
                    unresolved.append(Self.unresolved(
                        index,
                        .texturedRectangle,
                        "texture name is not valid UTF-8"
                    ))
                    continue
                }
                guard let textureResolver else {
                    unresolved.append(Self.unresolved(
                        index,
                        .texturedRectangle,
                        "texture resolver is unavailable for '\(decodedName)'"
                    ))
                    continue
                }
                do {
                    guard let bitmap = try textureResolver
                        .resolveSurfaceTexture(named: decodedName)
                    else {
                        unresolved.append(Self.unresolved(
                            index,
                            .texturedRectangle,
                            "texture '\(decodedName)' was not resolved"
                        ))
                        continue
                    }
                    let retainedBitmap: GModMetalSurfaceBitmap
                    switch bitmapRetention.admit(bitmap) {
                    case let .accepted(canonicalBitmap):
                        retainedBitmap = canonicalBitmap
                    case let .rejected(reason):
                        unresolved.append(Self.unresolved(
                            index,
                            .texturedRectangle,
                            "texture '\(decodedName)' was not retained: \(reason)"
                        ))
                        continue
                    }
                    if geometry.wasClipped { clippedCount += 1 }
                    resolved.append(.texturedRectangle(
                        GModMetalSurfaceTexturedRectangle(
                            frame: geometry.frame,
                            uv: geometry.uv,
                            textureName: decodedName,
                            color: normalizedColor,
                            bitmap: retainedBitmap,
                            minificationFilter:
                                textureFiltersByCommandIndex[index]?.minification,
                            magnificationFilter:
                                textureFiltersByCommandIndex[index]?.magnification
                        )
                    ))
                    textureCount += 1
                } catch {
                    unresolved.append(Self.unresolved(
                        index,
                        .texturedRectangle,
                        "texture '\(decodedName)' failed: \(error)"
                    ))
                }

            case let .text(value, position, font, color, clip):
                guard let normalizedColor = Self.color(color) else {
                    unresolved.append(Self.unresolved(
                        index,
                        .text,
                        "color contains a non-finite component"
                    ))
                    continue
                }
                guard position.x.isFinite, position.y.isFinite else {
                    unresolved.append(Self.unresolved(
                        index,
                        .text,
                        "text position is non-finite"
                    ))
                    continue
                }
                guard let decodedText = String(bytes: value.bytes, encoding: .utf8) else {
                    unresolved.append(Self.unresolved(
                        index,
                        .text,
                        "text is not valid UTF-8"
                    ))
                    continue
                }
                guard !decodedText.isEmpty else {
                    discardedCount += 1
                    continue
                }
                guard let textRasterizer else {
                    unresolved.append(Self.unresolved(
                        index,
                        .text,
                        "text rasterizer is unavailable"
                    ))
                    continue
                }
                do {
                    guard let bitmap = try textRasterizer.rasterizeSurfaceText(
                        decodedText,
                        font: font
                    ) else {
                        discardedCount += 1
                        continue
                    }
                    let textFrame = GMLuaPanelRect(
                        x: position.x,
                        y: position.y,
                        width: Double(bitmap.width),
                        height: Double(bitmap.height)
                    )
                    let geometryResult = Self.clip(
                        frame: textFrame,
                        uv: GMLuaPanelRect(x: 0, y: 0, width: 1, height: 1),
                        clip: clip,
                        viewportWidth: snapshot.viewportWidth,
                        viewportHeight: snapshot.viewportHeight
                    )
                    guard case let .visible(geometry) = geometryResult else {
                        if case .invalid = geometryResult {
                            unresolved.append(Self.unresolved(
                                index,
                                .text,
                                "text clip geometry is invalid"
                            ))
                        } else {
                            discardedCount += 1
                        }
                        continue
                    }
                    let retainedBitmap: GModMetalSurfaceBitmap
                    switch bitmapRetention.admit(bitmap) {
                    case let .accepted(canonicalBitmap):
                        retainedBitmap = canonicalBitmap
                    case let .rejected(reason):
                        unresolved.append(Self.unresolved(
                            index,
                            .text,
                            "text glyph bitmap was not retained: \(reason)"
                        ))
                        continue
                    }
                    if geometry.wasClipped { clippedCount += 1 }
                    resolved.append(.text(
                        GModMetalSurfaceText(
                            frame: geometry.frame,
                            uv: geometry.uv,
                            value: decodedText,
                            font: font,
                            color: normalizedColor,
                            glyphBitmap: retainedBitmap
                        )
                    ))
                    textCount += 1
                } catch {
                    unresolved.append(Self.unresolved(
                        index,
                        .text,
                        "text rasterization failed: \(error)"
                    ))
                }
            }
        }

        viewportWidth = snapshot.viewportWidth
        viewportHeight = snapshot.viewportHeight
        commands = resolved
        diagnostics = GModMetalSurfaceDiagnostics(
            snapshotCommandCount: snapshot.commands.count,
            captureDiagnostics: snapshot.captureDiagnostics,
            processedSnapshotCommandCount: processedCommandCount,
            droppedSnapshotCommandCount: droppedCommandCount,
            maximumSnapshotCommandCount: commandLimit,
            solidRectangleCount: solidCount,
            texturedRectangleCount: textureCount,
            textCount: textCount,
            clippedCommandCount: clippedCount,
            discardedEmptyCommandCount: discardedCount,
            retainedBitmapCount: bitmapRetention.retainedCount,
            retainedBitmapByteCount: bitmapRetention.retainedByteCount,
            unresolvedCommands: unresolved
        )
    }

    private enum BitmapAdmission {
        case accepted(GModMetalSurfaceBitmap)
        case rejected(String)
    }

    /// Returns the previously retained value for an equal bitmap. This makes
    /// repeated commands share the same Data storage even if a resolver creates
    /// a fresh-but-equal buffer for every lookup.
    private struct BitmapRetentionBudget {
        let maximumCount: Int
        let maximumByteCount: Int
        private(set) var retainedCount = 0
        private(set) var retainedByteCount = 0
        private var bitmapsByCacheIdentifier:
            [String: [GModMetalSurfaceBitmap]] = [:]

        init(maximumCount: Int, maximumByteCount: Int) {
            self.maximumCount = maximumCount
            self.maximumByteCount = maximumByteCount
        }

        mutating func admit(
            _ candidate: GModMetalSurfaceBitmap
        ) -> BitmapAdmission {
            if let canonical = bitmapsByCacheIdentifier[
                candidate.cacheIdentifier
            ]?.first(where: { $0 == candidate }) {
                return .accepted(canonical)
            }

            let candidateByteCount = candidate.premultipliedRGBA8.count
            let fitsBytes = candidateByteCount <= maximumByteCount &&
                retainedByteCount <= maximumByteCount - candidateByteCount
            guard retainedCount < maximumCount, fitsBytes else {
                return .rejected(
                    "scene bitmap retention limit is \(maximumCount) unique " +
                        "bitmaps / \(maximumByteCount) bytes; currently " +
                        "\(retainedCount) / \(retainedByteCount), candidate " +
                        "adds 1 / \(candidateByteCount)"
                )
            }

            bitmapsByCacheIdentifier[
                candidate.cacheIdentifier,
                default: []
            ].append(candidate)
            retainedCount += 1
            retainedByteCount += candidateByteCount
            return .accepted(candidate)
        }
    }

    private struct ClippedGeometry {
        let frame: GModMetalSurfaceRect
        let uv: GModMetalSurfaceRect
        let wasClipped: Bool
    }

    private enum ClipResult {
        case invalid
        case empty
        case visible(ClippedGeometry)
    }

    private static func clip(
        frame: GMLuaPanelRect,
        uv: GMLuaPanelRect?,
        clip: GMLuaPanelRect,
        viewportWidth: Int,
        viewportHeight: Int
    ) -> ClipResult {
        let values = [
            frame.x, frame.y, frame.width, frame.height,
            clip.x, clip.y, clip.width, clip.height
        ] + (uv.map { [$0.x, $0.y, $0.width, $0.height] } ?? [])
        guard values.allSatisfy(\.isFinite) else { return .invalid }
        guard frame.width > 0, frame.height > 0 else { return .empty }
        guard clip.width > 0, clip.height > 0 else { return .empty }

        let frameMaximumX = frame.x + frame.width
        let frameMaximumY = frame.y + frame.height
        let clipMaximumX = clip.x + clip.width
        let clipMaximumY = clip.y + clip.height
        guard frameMaximumX.isFinite, frameMaximumY.isFinite,
              clipMaximumX.isFinite, clipMaximumY.isFinite
        else { return .invalid }

        let minimumX = max(0, max(frame.x, clip.x))
        let minimumY = max(0, max(frame.y, clip.y))
        let maximumX = min(
            Double(viewportWidth),
            min(frameMaximumX, clipMaximumX)
        )
        let maximumY = min(
            Double(viewportHeight),
            min(frameMaximumY, clipMaximumY)
        )
        guard maximumX > minimumX, maximumY > minimumY else { return .empty }

        let clippedWidth = maximumX - minimumX
        let clippedHeight = maximumY - minimumY
        let outputValues = [minimumX, minimumY, clippedWidth, clippedHeight]
        guard outputValues.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) })
        else { return .invalid }

        let adjustedUV: GMLuaPanelRect
        if let uv {
            let leftFraction = (minimumX - frame.x) / frame.width
            let topFraction = (minimumY - frame.y) / frame.height
            let rightFraction = (maximumX - frame.x) / frame.width
            let bottomFraction = (maximumY - frame.y) / frame.height
            adjustedUV = GMLuaPanelRect(
                x: uv.x + uv.width * leftFraction,
                y: uv.y + uv.height * topFraction,
                width: uv.width * (rightFraction - leftFraction),
                height: uv.height * (bottomFraction - topFraction)
            )
        } else {
            adjustedUV = GMLuaPanelRect(x: 0, y: 0, width: 1, height: 1)
        }
        let uvValues = [
            adjustedUV.x, adjustedUV.y, adjustedUV.width, adjustedUV.height
        ]
        guard uvValues.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) })
        else { return .invalid }

        return .visible(ClippedGeometry(
            frame: GModMetalSurfaceRect(
                x: Float(minimumX),
                y: Float(minimumY),
                width: Float(clippedWidth),
                height: Float(clippedHeight)
            ),
            uv: GModMetalSurfaceRect(
                x: Float(adjustedUV.x),
                y: Float(adjustedUV.y),
                width: Float(adjustedUV.width),
                height: Float(adjustedUV.height)
            ),
            wasClipped: minimumX != frame.x || minimumY != frame.y ||
                maximumX != frameMaximumX || maximumY != frameMaximumY
        ))
    }

    private static func color(
        _ source: GMLuaSurfaceColor
    ) -> GModMetalSurfaceColor? {
        let values = [source.red, source.green, source.blue, source.alpha]
        guard values.allSatisfy(\.isFinite) else { return nil }
        func normalized(_ value: Double) -> Float {
            Float(min(255, max(0, value)) / 255)
        }
        return GModMetalSurfaceColor(
            red: normalized(source.red),
            green: normalized(source.green),
            blue: normalized(source.blue),
            alpha: normalized(source.alpha)
        )
    }

    private static func hasUnitTextureCoordinates(
        _ uv: GModMetalSurfaceRect
    ) -> Bool {
        let maximumX = uv.x + uv.width
        let maximumY = uv.y + uv.height
        return min(uv.x, maximumX) >= 0 && max(uv.x, maximumX) <= 1 &&
            min(uv.y, maximumY) >= 0 && max(uv.y, maximumY) <= 1
    }

    private static func unresolved(
        _ index: Int,
        _ kind: GModMetalSurfaceCommandKind,
        _ reason: String
    ) -> GModMetalSurfaceUnresolvedCommand {
        GModMetalSurfaceUnresolvedCommand(
            commandIndex: index,
            kind: kind,
            reason: reason
        )
    }
}

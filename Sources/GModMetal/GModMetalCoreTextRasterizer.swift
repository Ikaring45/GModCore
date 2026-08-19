import Foundation
import CoreGraphics
import CoreText
import GModEngine

public enum GModMetalCoreTextRasterizerError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case unsupportedFontEffects([String])
    case unresolvedFont(String)
    case unavailableFontTraits(String)
    case invalidMetrics
    case bitmapTooLarge(width: Int, height: Int)
    case contextCreationFailed

    public var description: String {
        switch self {
        case let .unsupportedFontEffects(effects):
            return "unsupported CoreText font effects: \(effects.joined(separator: ", "))"
        case let .unresolvedFont(name):
            return "CoreText did not resolve requested font '\(name)'"
        case let .unavailableFontTraits(name):
            return "CoreText could not apply requested traits to '\(name)'"
        case .invalidMetrics:
            return "CoreText produced invalid glyph metrics"
        case let .bitmapTooLarge(width, height):
            return "CoreText bitmap is too large (\(width)x\(height))"
        case .contextCreationFailed:
            return "CoreText bitmap context creation failed"
        }
    }
}

/// Rasterizes supported GLua text to immutable glyph pixels before Metal draw.
///
/// The optional resolver lets GModApp map copied GMod family aliases to their
/// registered PostScript faces. Effects without a faithful CoreText mapping
/// are rejected and remain visible in scene diagnostics instead of silently
/// rendering a different style.
public final class GModMetalCoreTextRasterizer:
    GModMetalSurfaceTextRasterizing,
    @unchecked Sendable
{
    public typealias FontNameResolver = @Sendable (
        _ requestedName: String,
        _ weight: Int,
        _ italic: Bool
    ) -> String?

    private let fontNameResolver: FontNameResolver?
    private let maximumPixelCount: Int
    private let maximumCachedGlyphCount: Int
    private let maximumCachedByteCount: Int
    private let lock = NSLock()
    private var cache: [CacheKey: GModMetalSurfaceBitmap] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cachedByteCount = 0

    private struct CacheKey: Hashable {
        let text: String
        let requestedFontName: String
        let resolvedFontName: String?
        let size: Int
        let weight: Int
        let italic: Bool
        let antialias: Bool
    }

    public init(
        maximumPixelCount: Int = 2_097_152,
        maximumCachedGlyphCount: Int = 512,
        maximumCachedByteCount: Int = 32 * 1_024 * 1_024,
        fontNameResolver: FontNameResolver? = nil
    ) {
        self.maximumPixelCount = max(1, maximumPixelCount)
        self.maximumCachedGlyphCount = max(1, maximumCachedGlyphCount)
        self.maximumCachedByteCount = max(1, maximumCachedByteCount)
        self.fontNameResolver = fontNameResolver
    }

    public var cachedGlyphCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public var cachedGlyphByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedByteCount
    }

    public func removeAllCachedGlyphs() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        cachedByteCount = 0
        lock.unlock()
    }

    public func rasterizeSurfaceText(
        _ text: String,
        font descriptor: GMLuaFontDescriptor
    ) throws -> GModMetalSurfaceBitmap? {
        guard !text.isEmpty else { return nil }

        let unsupportedEffects = Self.unsupportedEffects(descriptor)
        guard unsupportedEffects.isEmpty else {
            throw GModMetalCoreTextRasterizerError.unsupportedFontEffects(
                unsupportedEffects
            )
        }

        let requestedName = String(decoding: descriptor.font.bytes, as: UTF8.self)
        let resolvedByHost = fontNameResolver?(
            requestedName,
            descriptor.weight,
            descriptor.italic
        )
        let cacheKey = CacheKey(
            text: text,
            requestedFontName: requestedName,
            resolvedFontName: resolvedByHost,
            size: descriptor.size,
            weight: descriptor.weight,
            italic: descriptor.italic,
            antialias: descriptor.antialias
        )
        if let cached = cachedBitmap(for: cacheKey) { return cached }

        let initialPointSize = CGFloat(max(1, descriptor.size))
        let baseName = resolvedByHost ?? requestedName
        let base = CTFontCreateWithName(
            baseName as CFString,
            initialPointSize,
            nil
        )
        guard Self.font(base, matches: baseName) else {
            throw GModMetalCoreTextRasterizerError.unresolvedFont(baseName)
        }

        let styled: CTFont
        if resolvedByHost != nil {
            styled = base
        } else {
            var traits: CTFontSymbolicTraits = []
            if descriptor.weight >= 700 { traits.insert(.traitBold) }
            if descriptor.italic { traits.insert(.traitItalic) }
            if traits.isEmpty {
                styled = base
            } else {
                guard let copied = CTFontCreateCopyWithSymbolicTraits(
                    base,
                    initialPointSize,
                    nil,
                    traits,
                    traits
                ) else {
                    throw GModMetalCoreTextRasterizerError
                        .unavailableFontTraits(requestedName)
                }
                styled = copied
            }
        }

        let unscaledLineHeight = Double(
            CTFontGetAscent(styled)
                + CTFontGetDescent(styled)
                + CTFontGetLeading(styled)
        )
        let pointSize = GMLuaSourceFontTallMetrics.scaledPointSize(
            unscaledPointSize: Double(initialPointSize),
            unscaledLineHeight: unscaledLineHeight,
            requestedTall: descriptor.size
        )
        guard pointSize.isFinite, pointSize > 0 else {
            throw GModMetalCoreTextRasterizerError.invalidMetrics
        }
        let postScriptName = CTFontCopyPostScriptName(styled) as String
        let font = CTFontCreateWithName(
            postScriptName as CFString,
            CGFloat(pointSize),
            nil
        )

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(
                kCTForegroundColorFromContextAttributeName as String
            ): true
        ]
        let coreTextLines = lines.map { line in
            CTLineCreateWithAttributedString(NSAttributedString(
                string: String(line),
                attributes: attributes
            ))
        }
        let widths = coreTextLines.map {
            CTLineGetTypographicBounds($0, nil, nil, nil)
        }
        guard widths.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw GModMetalCoreTextRasterizerError.invalidMetrics
        }
        let maximumWidth = widths.max() ?? 0
        guard maximumWidth > 0 else { return nil }
        let roundedWidth = ceil(maximumWidth)
        guard roundedWidth.isFinite, roundedWidth <= Double(Int.max) else {
            throw GModMetalCoreTextRasterizerError.invalidMetrics
        }
        let width = max(1, Int(roundedWidth))
        let height = GMLuaSourceFontTallMetrics.exactTextHeight(
            lineCount: lines.count,
            requestedTall: descriptor.size
        )
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow,
              pixels.partialValue > 0,
              pixels.partialValue <= maximumPixelCount
        else {
            throw GModMetalCoreTextRasterizerError.bitmapTooLarge(
                width: width,
                height: height
            )
        }
        let byteCount = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !byteCount.overflow else {
            throw GModMetalCoreTextRasterizerError.bitmapTooLarge(
                width: width,
                height: height
            )
        }

        var bytes = Data(count: byteCount.partialValue)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var drew = false
        bytes.withUnsafeMutableBytes { rawBytes in
            guard let context = CGContext(
                data: rawBytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.setAllowsAntialiasing(descriptor.antialias)
            context.setShouldAntialias(descriptor.antialias)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.textMatrix = .identity
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)

            let ascent = CTFontGetAscent(font)
            for (index, line) in coreTextLines.enumerated() {
                context.textPosition = CGPoint(
                    x: 0,
                    y: CGFloat(index * max(1, descriptor.size)) + ascent
                )
                CTLineDraw(line, context)
            }
            drew = true
        }
        guard drew else {
            throw GModMetalCoreTextRasterizerError.contextCreationFailed
        }

        let bitmap = try GModMetalSurfaceBitmap(
            resourceIdentifier: "coretext:\(postScriptName):\(descriptor.size)",
            width: width,
            height: height,
            premultipliedRGBA8: bytes
        )
        storeCachedBitmap(bitmap, for: cacheKey)
        return bitmap
    }

    private func cachedBitmap(
        for key: CacheKey
    ) -> GModMetalSurfaceBitmap? {
        lock.lock()
        defer { lock.unlock() }
        guard let bitmap = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return bitmap
    }

    private func storeCachedBitmap(
        _ bitmap: GModMetalSurfaceBitmap,
        for key: CacheKey
    ) {
        let byteCount = bitmap.premultipliedRGBA8.count
        guard byteCount <= maximumCachedByteCount else { return }

        lock.lock()
        defer { lock.unlock() }
        if let previous = cache.removeValue(forKey: key) {
            cachedByteCount -= previous.premultipliedRGBA8.count
            cacheOrder.removeAll { $0 == key }
        }
        while !cacheOrder.isEmpty && (
            cache.count >= maximumCachedGlyphCount ||
                cachedByteCount > maximumCachedByteCount - byteCount
        ) {
            let oldest = cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedByteCount -= evicted.premultipliedRGBA8.count
            }
        }
        cache[key] = bitmap
        cacheOrder.append(key)
        cachedByteCount += byteCount
    }

    private static func unsupportedEffects(
        _ descriptor: GMLuaFontDescriptor
    ) -> [String] {
        var effects: [String] = []
        if descriptor.blurSize != 0 { effects.append("blur") }
        if descriptor.scanlines != 0 { effects.append("scanlines") }
        if descriptor.underline { effects.append("underline") }
        if descriptor.strikeout { effects.append("strikeout") }
        if descriptor.symbol { effects.append("symbol") }
        if descriptor.rotary { effects.append("rotary") }
        if descriptor.shadow { effects.append("shadow") }
        if descriptor.additive { effects.append("additive") }
        if descriptor.outline { effects.append("outline") }
        return effects
    }

    private static func font(_ font: CTFont, matches requestedName: String) -> Bool {
        let requested = canonicalFontName(requestedName)
        guard !requested.isEmpty else { return false }
        let resolvedNames = [
            CTFontCopyPostScriptName(font) as String,
            CTFontCopyFullName(font) as String,
            CTFontCopyFamilyName(font) as String
        ]
        return resolvedNames.contains {
            canonicalFontName($0) == requested
        }
    }

    private static func canonicalFontName(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

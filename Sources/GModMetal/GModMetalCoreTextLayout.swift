import CoreGraphics
import CoreText
import Foundation

/// Shared shaping for GLua measurement and pixels. Fallback glyph runs can
/// exceed the Latin face's ascent/descent; fit the complete shaped line into
/// Source's requested font tall before either layout or rasterization uses it.
public struct GModMetalCoreTextLayout {
    public let lines: [CTLine]
    public let ascents: [CGFloat]
    public let widths: [Double]

    public init(text: String, font: CTFont, requestedTall: Int, fitsFallbackGlyphs: Bool = true) {
        let strings = text.split(separator: "\n", omittingEmptySubsequences: false)
        let usesJapaneseKana = text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value)
        }
        func shape(_ face: CTFont) -> [CTLine] {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): face,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]
            if usesJapaneseKana {
                attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = "ja"
            }
            return strings.map {
                CTLineCreateWithAttributedString(NSAttributedString(
                    string: String($0), attributes: attributes
                ))
            }
        }
        func metrics(_ line: CTLine) -> (width: Double, ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return (width, ascent, descent, leading)
        }
        let tall = CGFloat(max(1, requestedTall))
        // Normalize per font, never per input string: measuring "ABC" as a
        // caret prefix must use the same size as "ABC日本語" in the full line.
        let faceHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        // A symbol image must not shrink to accommodate unrelated CJK probe
        // fallback glyphs. Its supported characters come from the exact face.
        var maximumHeight = faceHeight
        if fitsFallbackGlyphs {
            let probe = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Ag日本語かなカナ",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTLanguageAttributeName as String): "ja"
                ]
            ))
            let m = metrics(probe)
            maximumHeight = max(faceHeight, m.ascent + m.descent + max(0, m.leading))
        }
        var fitted = font
        if maximumHeight.isFinite, maximumHeight > tall + 0.01 {
            fitted = CTFontCreateCopyWithAttributes(
                font, CTFontGetSize(font) * tall / maximumHeight, nil, nil
            )
        }
        let shaped = shape(fitted)
        let measured = shaped.map(metrics)
        lines = shaped
        widths = measured.map(\.width)
        ascents = measured.map { min(tall, max(0, $0.ascent)) }
    }
}

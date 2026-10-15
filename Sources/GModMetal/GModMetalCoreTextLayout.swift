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

    public init(text: String, font: CTFont, requestedTall: Int) {
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
        var shaped = shape(font)
        let tall = CGFloat(max(1, requestedTall))
        let maximumHeight = shaped.map { line -> CGFloat in
            let m = metrics(line)
            return m.ascent + m.descent + max(0, m.leading)
        }.max() ?? 0
        if maximumHeight.isFinite, maximumHeight > tall + 0.01 {
            let fitted = CTFontCreateCopyWithAttributes(
                font, CTFontGetSize(font) * tall / maximumHeight, nil, nil
            )
            shaped = shape(fitted)
        }
        let measured = shaped.map(metrics)
        lines = shaped
        widths = measured.map(\.width)
        ascents = measured.map { min(tall, max(0, $0.ascent)) }
    }
}

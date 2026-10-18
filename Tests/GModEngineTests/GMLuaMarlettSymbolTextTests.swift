import XCTest
import GModEngine

final class GMLuaMarlettSymbolTextTests: XCTestCase {
    func testOnlyTheBundledSymbolCmapRangesAreMapped() {
        XCTAssertTrue(GMLuaMarlettSymbolText.supports(face: "Marlett"))
        XCTAssertFalse(GMLuaMarlettSymbolText.supports(face: "Wingdings"))
        XCTAssertEqual(GMLuaMarlettSymbolText.mapped("gefb"), "\u{F067}\u{F065}\u{F066}\u{F062}")
        XCTAssertEqual(GMLuaMarlettSymbolText.mapped("09\nay"), "\u{F030}\u{F039}\n\u{F061}\u{F079}")
        XCTAssertEqual(GMLuaMarlettSymbolText.mapped("\u{F067}"), "\u{F067}")
        for text in ["z", "A", " ", "日本語", "\u{F07A}", "\r"] {
            XCTAssertNil(GMLuaMarlettSymbolText.mapped(text), text)
        }
    }
}

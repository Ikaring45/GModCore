#if canImport(UIKit)
import UIKit
import XCTest
@testable import GModApp

final class GModJapaneseTextInputTests: XCTestCase {
    @MainActor
    func testMarkedJapaneseIsCommittedOnceAndNeverLeaksAcrossFocus() {
        let view = GModDermaMenuKeyInputView(frame: .zero, textContainer: nil)
        var commits: [String] = []
        var deletions = 0
        view.onText = { commits.append($0) }
        view.onDeleteBackward = { deletions += 1 }
        view.updateFocus(wantsFocus: true, identifier: 10)

        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(commits, [])
        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(commits, [])
        view.unmarkText()
        XCTAssertEqual(commits, ["日本語"])
        XCTAssertEqual(view.text, "")
        view.textViewDidChange(view)
        XCTAssertEqual(commits, ["日本語"])

        view.deleteBackward()
        XCTAssertEqual(deletions, 1)
        view.insertText("テスト😀")
        XCTAssertEqual(commits, ["日本語", "テスト😀"])

        view.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0))
        view.updateFocus(wantsFocus: true, identifier: 11)
        view.unmarkText()
        XCTAssertEqual(commits, ["日本語", "テスト😀"])
        view.updateFocus(wantsFocus: false, identifier: nil)
        view.insertText("遅延入力")
        XCTAssertEqual(commits, ["日本語", "テスト😀"])
        XCTAssertFalse(view.wantsKeyboardFocus)
    }
}
#endif

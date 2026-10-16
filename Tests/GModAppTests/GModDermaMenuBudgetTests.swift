import XCTest
@testable import GModApp

final class GModDermaMenuBudgetTests: XCTestCase {
    func testProblemsRespectCombinedRealmBudgetWithoutSplittingJapanese() {
        let input = Array(repeating: String(repeating: "日本語", count: 200), count: 256)
        let result = GModDermaMenuModel.boundedProblemLines(input)
        XCTAssertLessThanOrEqual(result.joined(separator: "\n").utf8.count, 64 * 1_024)
        XCTAssertTrue(result.allSatisfy { $0.utf8.count <= 1_024 && !$0.contains("�") })
    }

    func testConsoleKeepsNewestLinesInsideCombinedRealmBudget() {
        var input = Array(repeating: String(repeating: "ログ", count: 500), count: 512)
        input.append("newest 日本語")
        let result = GModDermaMenuModel.boundedConsoleLines(input)
        XCTAssertEqual(result.last, "newest 日本語")
        XCTAssertLessThanOrEqual(result.joined(separator: "\n").utf8.count, 128 * 1_024)
        XCTAssertTrue(result.allSatisfy { $0.utf8.count <= 2 * 1_024 && !$0.contains("�") })
    }
}

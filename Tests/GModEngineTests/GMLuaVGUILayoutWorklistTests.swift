import XCTest
@testable import GModEngine

final class GMLuaVGUILayoutWorklistTests: XCTestCase {
    func testMatchesSetMinimumAcrossRemovalReinsertionAndScopedSelection() {
        var work = GMLuaVGUILayoutWorklist()
        var reference: Set<Int> = []
        for value in (0..<2_048).reversed() {
            work.insert(value)
            work.insert(value)
            reference.insert(value)
        }
        for step in 0..<6_144 {
            let expected: Int?
            let actual: Int?
            if step.isMultiple(of: 3) {
                expected = reference.filter { $0.isMultiple(of: 2) }.min()
                actual = work.filter { $0.isMultiple(of: 2) }.min()
            } else {
                expected = reference.min()
                actual = work.minimum()
            }
            XCTAssertEqual(actual, expected)
            if let actual {
                work.remove(actual)
                reference.remove(actual)
            }
            if step.isMultiple(of: 7) {
                let value = (step * 37) % 2_048
                work.insert(value)
                reference.insert(value)
            }
        }
        XCTAssertEqual(work.isEmpty, reference.isEmpty)
        XCTAssertEqual(work.minimum(), reference.min())
    }
}

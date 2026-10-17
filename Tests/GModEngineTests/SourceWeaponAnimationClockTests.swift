import XCTest
import GModEngine

final class SourceWeaponAnimationClockTests: XCTestCase {
    private func state(loops: Bool = false) -> SourceCanonicalWeaponRuntimeState {
        .init(animationSequence: 2, animationSequenceDuration: 2,
              animationCycleRate: 0.5, animationFrameCount: 61,
              animationSequenceLoops: loops, animationLastAdvanceTime: 1)
    }

    func testFixedTimeCyclePauseAndNonLoopingEnd() throws {
        let start = state()
        let half = try start.advancingAnimation(to: 2)
        XCTAssertEqual(half.animationCycle, 0.1, accuracy: 0.00001)
        XCTAssertEqual(start.animationCycle, 0)
        XCTAssertEqual(try half.advancingAnimation(to: 2), half)
        var almostFinished = half
        almostFinished.animationCycle = 0.95
        let end = try almostFinished.advancingAnimation(to: 5)
        XCTAssertEqual(end.animationCycle, 1)
        XCTAssertEqual(try end.advancingAnimation(to: 10), end)
        var paused = half
        paused.animationPlaybackRate = 0
        XCTAssertEqual(try paused.advancingAnimation(to: 3).animationCycle, half.animationCycle)
        XCTAssertEqual(try start.advancingAnimation(to: 1.0005), start)
    }

    func testLoopWrapAndPlaybackRate() throws {
        var looping = state(loops: true)
        looping.animationPlaybackRate = 10
        XCTAssertEqual(try looping.advancingAnimation(to: 2).animationCycle, 0)
        XCTAssertEqual(try looping.advancingAnimation(to: 1.05).animationCycle, 0.25, accuracy: 0.00001)
    }

    func testInvalidTimeAndStateFailTransactionally() throws {
        let start = state()
        XCTAssertThrowsError(try start.advancingAnimation(to: .nan))
        XCTAssertThrowsError(try start.advancingAnimation(to: 0.5))
        var invalid = start
        invalid.animationCycle = .infinity
        XCTAssertThrowsError(try invalid.advancingAnimation(to: 2))
        XCTAssertEqual(start.animationCycle, 0)
        XCTAssertEqual(try SourceCanonicalWeaponRuntimeState().advancingAnimation(to: 2), .init())
    }
}

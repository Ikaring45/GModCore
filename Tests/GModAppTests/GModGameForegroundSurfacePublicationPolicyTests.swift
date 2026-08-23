import XCTest
@testable import GModApp

final class GModGameForegroundSurfacePublicationPolicyTests: XCTestCase {
    func testFirstQAndContextScenesRequireResolvedPublication() {
        for menu in [GModGameClientMenu.spawn, .context] {
            XCTAssertTrue(
                GModGameForegroundSurfacePublicationPolicy
                    .requiresResolvedPublicationBeforeReturning(
                        activeMenu: menu,
                        hasPublishedScene: false
                    )
            )
        }
    }

    func testPublishedForegroundSceneUsesCoalescedReplacementWorker() {
        XCTAssertFalse(
            GModGameForegroundSurfacePublicationPolicy
                .requiresResolvedPublicationBeforeReturning(
                    activeMenu: .spawn,
                    hasPublishedScene: true
                )
        )
    }

    func testIncidentalSolidStripsDoNotSatisfyFirstVisibleQFrame() {
        XCTAssertFalse(
            GModGameForegroundSurfacePublicationPolicy
                .hasResolvedForegroundContent(
                    texturedRectangleCount: 0,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0.5
                )
        )
        XCTAssertFalse(
            GModGameForegroundSurfacePublicationPolicy
                .hasResolvedForegroundContent(
                    texturedRectangleCount: 1,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0.001
                ),
            "resolver-free Q strips must not satisfy first publication"
        )
        XCTAssertTrue(
            GModGameForegroundSurfacePublicationPolicy
                .hasResolvedForegroundContent(
                    texturedRectangleCount: 1,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0.25
                )
        )
        XCTAssertTrue(
            GModGameForegroundSurfacePublicationPolicy
                .hasResolvedForegroundContent(
                    texturedRectangleCount: 0,
                    textCount: 1,
                    maximumAlphaWeightedViewportCoverage: 0.25
                )
        )
    }

    func testOverlayNeverBlocksOnForegroundPublicationPolicy() {
        XCTAssertFalse(
            GModGameForegroundSurfacePublicationPolicy
                .requiresResolvedPublicationBeforeReturning(
                    activeMenu: nil,
                    hasPublishedScene: false
                )
        )
    }

    func testFailedForegroundGetsOneBoundedAutomaticRetry() {
        var budget = GModGameForegroundSurfaceRetryBudget()
        XCTAssertFalse(budget.consume())
        budget.arm()
        XCTAssertTrue(budget.consume())
        XCTAssertFalse(budget.consume())
        budget.arm()
        budget.cancel()
        XCTAssertFalse(budget.consume())
    }
}

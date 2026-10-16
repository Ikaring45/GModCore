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
        XCTAssertTrue(
            GModGameForegroundSurfacePublicationPolicy
                .hasResolvedForegroundContent(
                    texturedRectangleCount: 1,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0.001
                ),
            "a resolved small Gwen slice is still renderer-visible"
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

    func testEveryForegroundReplacementMustRemainRendererVisible() {
        XCTAssertFalse(
            GModGameForegroundSurfacePublicationPolicy
                .admitsResolvedForegroundScene(
                    activeMenu: .spawn,
                    texturedRectangleCount: 0,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0.75
                ),
            "a later transparent/solid-only capture must not erase visible Q"
        )
        XCTAssertTrue(
            GModGameForegroundSurfacePublicationPolicy
                .admitsResolvedForegroundScene(
                    activeMenu: .spawn,
                    texturedRectangleCount: 1,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0.001
                )
        )
        XCTAssertTrue(
            GModGameForegroundSurfacePublicationPolicy
                .admitsResolvedForegroundScene(
                    activeMenu: .spawn,
                    texturedRectangleCount: 1,
                    textCount: 1,
                    maximumAlphaWeightedViewportCoverage: 0.25
                )
        )
    }

    func testOverlayReplacementIsNotSubjectToForegroundCoverageGate() {
        XCTAssertTrue(
            GModGameForegroundSurfacePublicationPolicy
                .admitsResolvedForegroundScene(
                    activeMenu: nil,
                    texturedRectangleCount: 0,
                    textCount: 0,
                    maximumAlphaWeightedViewportCoverage: 0
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

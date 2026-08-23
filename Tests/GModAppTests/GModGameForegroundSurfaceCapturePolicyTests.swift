import XCTest
import GModEngine
@testable import GModApp

final class GModGameForegroundSurfaceCapturePolicyTests: XCTestCase {
    func testStructuralSceneOnlyBridgesFirstForegroundPublication() {
        XCTAssertTrue(
            GModGameForegroundSurfaceCapturePolicy
                .shouldPublishStructuralScene(
                    activeMenu: .spawn,
                    hasPublishedScene: false
                )
        )
        XCTAssertFalse(
            GModGameForegroundSurfaceCapturePolicy
                .shouldPublishStructuralScene(
                    activeMenu: .spawn,
                    hasPublishedScene: true
                )
        )
        XCTAssertFalse(
            GModGameForegroundSurfaceCapturePolicy
                .shouldPublishStructuralScene(
                    activeMenu: nil,
                    hasPublishedScene: false
                )
        )
    }

    func testPassiveHostFramesCannotChainBehindForegroundWork() {
        XCTAssertFalse(GModGameForegroundSurfaceCapturePolicy.shouldAdmit(
            scope: .all,
            cause: .hostFrame,
            now: 20,
            lastCompletionTime: 19,
            captureOrBuildInFlight: true
        ))
        XCTAssertFalse(GModGameForegroundSurfaceCapturePolicy.shouldAdmit(
            scope: .all,
            cause: .hostFrame,
            now: 20.10,
            lastCompletionTime: 20,
            captureOrBuildInFlight: false
        ))
        XCTAssertTrue(GModGameForegroundSurfaceCapturePolicy.shouldAdmit(
            scope: .all,
            cause: .hostFrame,
            now: 20.25,
            lastCompletionTime: 20,
            captureOrBuildInFlight: false
        ))
    }

    func testLifecycleAndPointerFramesSupersedeInFlightForegroundBuild() {
        for cause in [
            GModGameForegroundSurfaceCaptureCause.menuTransition,
            .pointerMutation,
        ] {
            XCTAssertTrue(GModGameForegroundSurfaceCapturePolicy.shouldAdmit(
                scope: .all,
                cause: cause,
                now: 20,
                lastCompletionTime: 20,
                captureOrBuildInFlight: true
            ))
        }
    }

    func testOverlayRemainsOwnedByDedicatedHintPacer() {
        XCTAssertTrue(GModGameForegroundSurfaceCapturePolicy.shouldAdmit(
            scope: .overlay,
            cause: .hostFrame,
            now: 20,
            lastCompletionTime: 20,
            captureOrBuildInFlight: true
        ))
    }

    func testStaleOverlayRequestCannotOwnOpenedMenuSurface() {
        XCTAssertTrue(
            GModGameForegroundSurfaceCapturePolicy.requestOwnsCurrentSurface(
                scope: .overlay,
                activeMenu: nil
            )
        )
        XCTAssertFalse(
            GModGameForegroundSurfaceCapturePolicy.requestOwnsCurrentSurface(
                scope: .overlay,
                activeMenu: .spawn
            )
        )
        XCTAssertTrue(
            GModGameForegroundSurfaceCapturePolicy.requestOwnsCurrentSurface(
                scope: .all,
                activeMenu: .context
            )
        )
        XCTAssertFalse(
            GModGameForegroundSurfaceCapturePolicy.requestOwnsCurrentSurface(
                scope: .all,
                activeMenu: nil
            )
        )
    }

    func testReplacedHostClockDoesNotSuppressFirstPassiveFrame() {
        XCTAssertTrue(GModGameForegroundSurfaceCapturePolicy.shouldAdmit(
            scope: .all,
            cause: .hostFrame,
            now: 2,
            lastCompletionTime: 10,
            captureOrBuildInFlight: false
        ))
    }
}

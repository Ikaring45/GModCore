import Foundation
import XCTest
import GModEngine

final class GMLuaScreenMetricsTests: XCTestCase {
    func testClientRuntimeInstallsOfficialScreenFunctionsAndScaling() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            initialViewport: GMLuaViewportSize(width: 1600, height: 900)
        )
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaScreenMetricsRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaScreenMetricsRegression",
                withExtension: "lua"
            )
        )
        try runtime.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaScreenMetricsRegression.lua"
        )
        let sentinel = try runtime.executeReturningValues(
            "return GLUA_SCREEN_METRICS_REGRESSION_OK"
        ).first
        guard let sentinel, case .boolean(true) = sentinel else {
            return XCTFail("screen-metrics fixture did not reach its success sentinel")
        }
    }

    func testHostViewportUpdatesAreLiveAndRejectTransientZeroSizes() throws {
        let runtime = GMLuaRuntime(
            realm: .menu,
            logger: { _ in },
            initialViewport: GMLuaViewportSize(width: 1024, height: 768)
        )
        let metrics = try XCTUnwrap(runtime.screenMetrics)
        XCTAssertEqual(metrics.viewport, GMLuaViewportSize(width: 1024, height: 768))

        XCTAssertTrue(runtime.updateViewport(width: 2732, height: 2048))
        try runtime.execute(
            "assert(ScrW() == 2732 and ScrH() == 2048); " +
                "assert(ScreenScale(640) == 2732 and ScreenScaleH(480) == 2048)",
            sourceName: "@GMLuaScreenMetricsLiveUpdate.lua"
        )
        XCTAssertFalse(runtime.updateViewport(width: 0, height: 2048))
        XCTAssertFalse(runtime.updateViewport(width: 2732, height: 0))
        XCTAssertEqual(metrics.viewport, GMLuaViewportSize(width: 2732, height: 2048))
        XCTAssertFalse(runtime.updateViewport(width: 2732, height: 2048))
    }

    func testLogicalDefaultIsExplicitAndScreenSurfaceIsClientOnly() throws {
        XCTAssertEqual(
            GMLuaViewportSize.logicalDesktopDefault,
            GMLuaViewportSize(width: 1280, height: 720)
        )

        let client = GMLuaRuntime(realm: .client, logger: { _ in })
        try client.execute(
            "assert(ScrW() == 1280 and ScrH() == 720)",
            sourceName: "@GMLuaScreenMetricsDefault.lua"
        )

        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        try server.execute(
            "assert(ScrW == nil and ScrH == nil and ScreenScale == nil and ScreenScaleH == nil and SScale == nil)",
            sourceName: "@GMLuaScreenMetricsServerAbsence.lua"
        )
        XCTAssertNil(server.screenMetrics)
        XCTAssertFalse(server.updateViewport(width: 1920, height: 1080))
    }

    func testViewportDeliveryTargetsClientCapableRealmRatherThanServerConsole() throws {
        let client = GMLuaRuntime(realm: .client, logger: { _ in })
        let serverConsole = GMLuaRuntime(realm: .server, logger: { _ in })

        XCTAssertTrue(client.updateViewport(width: 2388, height: 1668))
        XCTAssertFalse(serverConsole.updateViewport(width: 2388, height: 1668))
        try client.execute(
            "assert(ScrW() == 2388 and ScrH() == 1668)",
            sourceName: "@GMLuaClientViewportDelivery.lua"
        )
        try serverConsole.execute(
            "assert(ScrW == nil and ScrH == nil)",
            sourceName: "@GMLuaServerConsoleViewportIsolation.lua"
        )
    }
}

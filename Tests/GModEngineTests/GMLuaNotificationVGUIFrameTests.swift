import Foundation
import XCTest
import GModEngine
import GModGameAssets

final class GMLuaNotificationVGUIFrameTests: XCTestCase {
    func testVisiblePanelAnimationAndThinkAdvanceOnLiveVGUIFrames() throws {
        let clock = NotificationSystemTimeSource(100)
        let runtime = try makeRuntime(clock: clock)
        defer { _ = runtime.close() }
        try runtime.loadFile("lua/includes/init.lua")

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        try runtime.execute(
            """
            PANEL_THINKS = 0
            PANEL = assert(vgui.Create("Panel", GetOverlayPanel()))
            PANEL:SetPos(8, 8)
            PANEL:SetSize(64, 24)
            PANEL:SetAlpha(255)
            function PANEL:Think() PANEL_THINKS = PANEL_THINKS + 1 end
            PANEL:AlphaTo(0, 1, 0)
            PANEL:SetTerm(2)

            HIDDEN_THINKS = 0
            HIDDEN = assert(vgui.Create("Panel", GetOverlayPanel()))
            HIDDEN:SetVisible(false)
            HIDDEN:SetTerm(0.5)
            function HIDDEN:Think() HIDDEN_THINKS = HIDDEN_THINKS + 1 end
            """,
            sourceName: "=(live VGUI animation callbacks)"
        )

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )
        try runtime.execute(
            "assert(PANEL_THINKS == 1 and PANEL:GetAlpha() == 255); " +
                "assert(HIDDEN_THINKS == 0 and IsValid(HIDDEN))"
        )

        clock.set(100.5)
        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )
        try runtime.execute(
            "assert(PANEL_THINKS == 2); " +
                "assert(PANEL:GetAlpha() >= 127 and PANEL:GetAlpha() <= 128); " +
                "assert(HIDDEN_THINKS == 0 and IsValid(HIDDEN))"
        )

        clock.set(101)
        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )
        try runtime.execute(
            "assert(PANEL_THINKS == 3 and PANEL:GetAlpha() == 0); " +
                "assert(HIDDEN_THINKS == 0 and IsValid(HIDDEN))"
        )

        clock.set(102)
        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )
        try runtime.execute(
            "assert(not IsValid(PANEL) and PANEL_THINKS == 3); " +
                "assert(IsValid(HIDDEN) and HIDDEN_THINKS == 0); " +
                "HIDDEN:SetVisible(true)"
        )

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )
        try runtime.execute(
            "assert(not IsValid(HIDDEN) and HIDDEN_THINKS == 0)",
            sourceName: "=(hidden VGUI animation resumes when visible)"
        )
    }

    func testStockNotificationUsesOverlayLayoutAndExpiresFromThink() throws {
        let clock = NotificationSystemTimeSource(200)
        let runtime = try makeRuntime(clock: clock)
        defer { _ = runtime.close() }
        try runtime.loadFile("lua/includes/init.lua")
        try runtime.loadFile("lua/derma/init.lua")
        try runtime.loadFile("lua/vgui/dpanel.lua")
        try runtime.loadFile("lua/vgui/dlabel.lua")
        try runtime.loadFile("lua/vgui/dimage.lua")
        try runtime.loadFile("lua/includes/modules/notification.lua")

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        try runtime.execute(
            """
            notification.AddLegacy("stock hint", NOTIFY_HINT, 1)
            local count = 0
            for _, panel in ipairs(vgui.GetAll()) do
                if panel:GetClassName() == "NoticePanel" then
                    STOCK_NOTICE = panel
                    count = count + 1
                end
            end
            assert(count == 1 and IsValid(STOCK_NOTICE))
            assert(STOCK_NOTICE:GetParent() == GetOverlayPanel())
            local l, t, r, b = STOCK_NOTICE:GetDockPadding()
            assert(l == 3 and t == 3 and r == 3 and b == 3)
            assert(STOCK_NOTICE:GetWide() > 0 and STOCK_NOTICE:GetTall() > 0)
            """,
            sourceName: "=(stock notification initial overlay state)"
        )
        XCTAssertTrue(registry.hasVisibleOverlayPanels)

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )

        clock.set(200.5)
        try runtime.execute(
            "hook.Run('Think'); assert(IsValid(STOCK_NOTICE))",
            sourceName: "=(stock notification live Think)"
        )

        clock.set(201.1)
        try runtime.execute(
            "hook.Run('Think'); assert(not IsValid(STOCK_NOTICE))",
            sourceName: "=(stock notification expiry Think)"
        )
        XCTAssertFalse(registry.hasVisibleOverlayPanels)

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180,
            scope: .overlay
        )
        try runtime.execute(
            """
            for _, panel in ipairs(vgui.GetAll()) do
                assert(panel:GetClassName() != "NoticePanel")
            end
            """,
            sourceName: "=(stock notification deferred removal completed)"
        )
    }

    private func makeRuntime(
        clock: NotificationSystemTimeSource
    ) throws -> GMLuaRuntime {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        return GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            initialViewport: GMLuaViewportSize(width: 320, height: 180),
            systemTimeSource: clock
        )
    }
}

private final class NotificationSystemTimeSource: GMLuaSystemTimeSource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: Double

    init(_ value: Double) {
        self.value = value
    }

    func set(_ replacement: Double) {
        lock.lock()
        value = replacement
        lock.unlock()
    }

    func currentSystemTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

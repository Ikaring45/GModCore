import XCTest
import GModEngine
import GModGameAssets

private final class MenuTestClock: GMLuaSystemTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    func currentSystemTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return time
    }
    func advance() {
        lock.lock()
        time += 0.25
        lock.unlock()
    }
}

final class GMLuaMenuSessionTests: XCTestCase {
    func testOriginalProblemTabsRouteLuaErrorsPermissionsAndSettings() throws {
        var messages: [String] = []
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(), writable: false
        )
        let clock = MenuTestClock()
        let session = GMLuaMenuSession(fileSystem: files, systemTimeSource: clock, logger: { messages.append($0) })
        defer { _ = session.close() }
        _ = try session.start()
        try session.updateProblems(["Runtime diagnostic 日本語"])
        try session.updateLuaErrors([
            GMLuaMenuLuaError(realm: "client", message: "Original Lua error 日本語")
        ])
        try session.updatePermissions(GMLuaPermissionSnapshot(
            temporary: ["local://garrys-pad": ["connect"]], permanent: [:]
        ))
        try session.present(.problems)
        var frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        for tab in ["problems.problems", "problems.lua_errors", "permissions.title"] {
            let point = try XCTUnwrap(frame.commands.compactMap { command -> GMLuaCursorPosition? in
                guard case let .text(value, position, _, _, _) = command,
                      value.utf8String == tab || value.utf8String == "#" + tab else { return nil }
                return position
            }.first, "missing original tab \(tab): \(texts(in: frame)); logs: \(messages)")
            try tap(x: point.x + 8, y: point.y + 5, in: session)
            clock.advance()
            _ = try session.advance(by: 0.2)
            frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
            if tab == "problems.lua_errors" {
                XCTAssertTrue(texts(in: frame).contains { $0.contains("Original Lua error") })
            } else if tab == "permissions.title" {
                XCTAssertTrue(texts(in: frame).contains { $0.contains("local://garrys-pad") })
            }
        }
        let revoke = try XCTUnwrap(frame.commands.compactMap { command -> GMLuaPanelRect? in
            guard case let .texturedRectangle(rect, _, name, _, _) = command,
                  name.utf8String.contains("icon16/cross") else { return nil }
            return rect
        }.first, "missing revoke texture: \(frame.commands)")
        try tap(x: revoke.x + revoke.width / 2, y: revoke.y + revoke.height / 2, in: session)
        XCTAssertTrue(session.drainActions().contains(.revokePermission("connect", "local://garrys-pad")))
        try session.updatePermissions(GMLuaPermissionSnapshot(temporary: [:], permanent: [:]))
        try session.present(.settings)
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(texts(in: frame).contains("Settings"))
        XCTAssertFalse(messages.contains { $0.contains("failed:") }, messages.joined(separator: "\n"))
    }

    func testDermaUtilitiesRenderHostStateAndRouteSettingsProblemsAndConsole()
        throws
    {
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        var messages: [String] = []
        let session = GMLuaMenuSession(
            fileSystem: files,
            initialViewport: GMLuaViewportSize(width: 1_024, height: 768),
            logger: { messages.append($0) }
        )
        defer { _ = session.close() }

        let report = try session.start()
        XCTAssertEqual(report.loadedPaths.first, "lua/includes/init.lua")
        XCTAssertEqual(report.loadedPaths.last, "lua/skins/default.lua")
        XCTAssertGreaterThanOrEqual(report.rootPanelCount, 2)
        XCTAssertTrue(report.loadedPaths.contains("lua/menu/problems/problems_pnl.lua"))

        var frame = try session.renderFrame(
            viewportWidth: 1_024,
            viewportHeight: 768
        )
        XCTAssertFalse(texts(in: frame).contains("Garry's PAD"))

        try session.updateSettings(GMLuaMenuSettingsSnapshot(
            audioEnabled: true,
            menuBackgroundsEnabled: false,
            preferredFramesPerSecond: 60,
            invertTouchLookY: true,
            touchLookSensitivity: 0.34
        ))
        try session.present(.settings)
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(texts(in: frame).contains("Settings"))
        XCTAssertTrue(texts(in: frame).contains("Menu backgrounds: Off"))
        XCTAssertTrue(texts(in: frame).contains("Invert touch look Y: On"))
        try tap(x: 250, y: 270, in: session)
        XCTAssertEqual(session.drainActions(), [.setAudioEnabled(false)])

        try session.updateProblems([
            "Lua: 現在のtimer failureはありません",
            "Renderer: physical iPad validation pending",
        ])
        try session.present(.problems)
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let renderedText = texts(in: frame)
        XCTAssertTrue(renderedText.contains(where: {
            $0.contains("physical iPad validation pending")
        }))
        XCTAssertTrue(renderedText.contains(where: {
            $0.contains("現在のtimer failureはありません")
        }))

        try session.updateConsoleLines([
            "GModLua Console initialized",
            "[CLIENT][VGUI] Surface route ready 日本語",
        ])
        try session.present(.console)
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(texts(in: frame).contains(where: {
            $0.contains("Surface route ready 日本語")
        }))
        XCTAssertNotNil(try session.insertText("status日本"))
        XCTAssertNotNil(try session.deleteTextBackward())
        XCTAssertNotNil(try session.deleteTextBackward())
        XCTAssertNotNil(try session.submitFocusedTextEntry())
        XCTAssertEqual(
            session.drainActions(),
            [.executeConsoleLine("status")]
        )

        // Focus may remain on the DTextEntry object after Console is hidden,
        // but native input must follow visible ancestry rather than target the
        // hidden utility.
        try session.present(.problems)
        XCTAssertNil(try session.insertText(""))
        XCTAssertNil(try session.submitFocusedTextEntry())
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertFalse(frame.commands.isEmpty)
        XCTAssertFalse(messages.contains { $0.contains("failed:") }, messages.joined(separator: "\n"))
    }

    func testMenuSessionIsSingleUseAndBoundsHostRetainedTextAndActions() throws {
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }

        XCTAssertThrowsError(
            try session.renderFrame(viewportWidth: 100, viewportHeight: 100)
        ) { error in
            XCTAssertEqual(error as? GMLuaMenuSessionError, .notStarted)
        }
        _ = try session.start()
        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertEqual(error as? GMLuaMenuSessionError, .alreadyStarted)
        }

        XCTAssertNoThrow(try session.updateProblems([
            String(repeating: "a", count: 1_024),
        ]))
        XCTAssertThrowsError(try session.updateProblems([
            String(repeating: "a", count: 1_025),
        ]))
        XCTAssertNoThrow(try session.updateConsoleLines([
            String(repeating: "c", count: 2 * 1_024),
        ]))
        XCTAssertThrowsError(try session.updateConsoleLines([
            String(repeating: "c", count: 2 * 1_024 + 1),
        ]))

        XCTAssertTrue(session.close())
        XCTAssertFalse(session.close())
        XCTAssertThrowsError(try session.updateProblems([])) { error in
            XCTAssertEqual(error as? GMLuaMenuSessionError, .closed)
        }
    }

    private func tap(
        x: Double,
        y: Double,
        in session: GMLuaMenuSession
    ) throws {
        _ = try session.dispatchPointerEvent(
            x: x,
            y: y,
            phase: .began,
            timestamp: 1,
            viewportWidth: 1_024,
            viewportHeight: 768
        )
        _ = try session.dispatchPointerEvent(
            x: x,
            y: y,
            phase: .ended,
            timestamp: 1.01,
            viewportWidth: 1_024,
            viewportHeight: 768
        )
    }

    private func texts(in frame: GMLuaSurfaceFrameSnapshot) -> [String] {
        frame.commands.compactMap { command in
            guard case let .text(value, _, _, _, _) = command else { return nil }
            return value.utf8String
        }
    }
}

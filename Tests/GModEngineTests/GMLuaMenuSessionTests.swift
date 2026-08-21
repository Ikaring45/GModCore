import XCTest
import GModEngine
import GModGameAssets

final class GMLuaMenuSessionTests: XCTestCase {
    func testShippedMenuDermaRendersAndRoutesHomeOptionsProblemsAndConsole()
        throws
    {
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let session = GMLuaMenuSession(
            fileSystem: files,
            initialViewport: GMLuaViewportSize(width: 1_024, height: 768),
            logger: { _ in }
        )
        defer { _ = session.close() }

        let report = try session.start()
        XCTAssertEqual(report.loadedPaths.first, "lua/includes/init.lua")
        XCTAssertEqual(report.loadedPaths.last, "lua/skins/default.lua")
        XCTAssertGreaterThanOrEqual(report.rootPanelCount, 4)

        var frame = try session.renderFrame(
            viewportWidth: 1_024,
            viewportHeight: 768
        )
        XCTAssertTrue(texts(in: frame).contains("Garry's PAD"))
        XCTAssertTrue(texts(in: frame).contains("gm_construct"))
        XCTAssertTrue(texts(in: frame).contains("Options"))
        XCTAssertTrue(texts(in: frame).contains("Problems"))
        XCTAssertTrue(texts(in: frame).contains("Console"))

        try tap(x: 275, y: 227, in: session)
        XCTAssertEqual(session.drainActions(), [.startMap("gm_construct")])

        try tap(x: 523, y: 227, in: session)
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(texts(in: frame).contains("Toggle Audio"))
        try tap(x: 401, y: 351, in: session)
        XCTAssertEqual(session.drainActions(), [.setAudioEnabled(false)])

        try session.updateProblems([
            "Lua: no current timer failures",
            "Renderer: physical iPad validation pending",
        ])
        try tap(x: 523, y: 279, in: session)
        frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let renderedText = texts(in: frame)
        XCTAssertTrue(renderedText.contains(where: {
            $0.contains("physical iPad validation pending")
        }))

        // Raising Console after the other frames exercises real Derma popup
        // ordering instead of bypassing VGUI with a direct native call.
        try tap(x: 523, y: 331, in: session)
        _ = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertNotNil(try session.insertText("status"))
        try tap(x: 277, y: 423, in: session)
        XCTAssertEqual(
            session.drainActions(),
            [.executeConsoleLine("status")]
        )
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

import Foundation
import GModLua

/// Host requests emitted by the trusted Garry's PAD MENU realm.
///
/// The visible controls remain ordinary shipped Derma panels. These values
/// are the narrow boundary where a menu button asks the application host to
/// perform work that Garry's Mod normally delegates to GameUI.
public enum GMLuaMenuAction: Sendable, Equatable {
    case startMap(String)
    case resumeGame
    case setAudioEnabled(Bool)
    case executeConsoleLine(String)
    case disconnect
    case quit
}

public enum GMLuaMenuSessionError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case alreadyStarted
    case notStarted
    case closed
    case missingRuntimeSurface(String)
    case actionQueueFull(maximum: Int)
    case invalidAction(String)
    case invalidProblemText(String)

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "MENU Derma session has already started"
        case .notStarted:
            return "MENU Derma session has not started"
        case .closed:
            return "MENU Derma session is closed"
        case let .missingRuntimeSurface(surface):
            return "MENU Derma session is missing \(surface)"
        case let .actionQueueFull(maximum):
            return "MENU action queue reached its \(maximum)-action limit"
        case let .invalidAction(message):
            return "invalid MENU action: \(message)"
        case let .invalidProblemText(message):
            return "invalid MENU Problems text: \(message)"
        }
    }
}

public struct GMLuaMenuBootstrapReport: Sendable, Equatable {
    public let loadedPaths: [String]
    public let rootPanelCount: Int

    public init(loadedPaths: [String], rootPanelCount: Int) {
        self.loadedPaths = loadedPaths
        self.rootPanelCount = rootPanelCount
    }
}

private final class GMLuaMenuHostState: @unchecked Sendable {
    static let maximumActionCount = 256
    static let maximumProblemLineCount = 256
    static let maximumProblemLineBytes = 1_024
    static let maximumProblemTextBytes = 64 * 1_024
    static let maximumConsoleLineBytes = 8 * 1_024

    private let lock = NSLock()
    private var actions: [GMLuaMenuAction] = []
    private var problemText = "No current problems."

    func append(_ action: GMLuaMenuAction) throws {
        lock.lock()
        defer { lock.unlock() }
        guard actions.count < Self.maximumActionCount else {
            throw GMLuaMenuSessionError.actionQueueFull(
                maximum: Self.maximumActionCount
            )
        }
        actions.append(action)
    }

    func drainActions() -> [GMLuaMenuAction] {
        lock.lock()
        defer { lock.unlock() }
        let result = actions
        actions.removeAll(keepingCapacity: true)
        return result
    }

    func replaceProblems(_ lines: [String]) throws {
        guard lines.count <= Self.maximumProblemLineCount else {
            throw GMLuaMenuSessionError.invalidProblemText(
                "more than \(Self.maximumProblemLineCount) lines"
            )
        }
        var encodedLines: [String] = []
        encodedLines.reserveCapacity(lines.count)
        var totalBytes = 0
        for line in lines {
            let bytes = Array(line.utf8)
            guard bytes.count <= Self.maximumProblemLineBytes else {
                throw GMLuaMenuSessionError.invalidProblemText(
                    "one line exceeds \(Self.maximumProblemLineBytes) UTF-8 bytes"
                )
            }
            let separatorBytes = encodedLines.isEmpty ? 0 : 1
            let addition = totalBytes.addingReportingOverflow(
                bytes.count + separatorBytes
            )
            guard !addition.overflow,
                  addition.partialValue <= Self.maximumProblemTextBytes else {
                throw GMLuaMenuSessionError.invalidProblemText(
                    "text exceeds \(Self.maximumProblemTextBytes) UTF-8 bytes"
                )
            }
            totalBytes = addition.partialValue
            encodedLines.append(line)
        }
        lock.lock()
        problemText = encodedLines.isEmpty
            ? "No current problems."
            : encodedLines.joined(separator: "\n")
        lock.unlock()
    }

    func currentProblemText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return problemText
    }
}

/// One trusted Garry's Mod MENU realm backed by the same native VGUI, Derma,
/// pointer, text-input, and renderer-neutral Surface implementation as the
/// gameplay Spawnmenu.
///
/// This replaces Swift lookalike windows with original shipped DFrame,
/// DButton, DLabel, and DTextEntry controls. The application remains
/// responsible for executing typed ``GMLuaMenuAction`` values; MENU Lua never
/// receives direct UIKit, filesystem, or process access.
public final class GMLuaMenuSession: @unchecked Sendable {
    private static let bootstrapPaths = [
        "lua/includes/init.lua",
        "lua/derma/init.lua",
        "lua/vgui/dpanel.lua",
        "lua/vgui/dlabel.lua",
        "lua/vgui/dbutton.lua",
        "lua/vgui/dtextentry.lua",
        "lua/vgui/dframe.lua",
        "lua/skins/default.lua",
    ]

    private let lifecycleLock = NSLock()
    private let hostState = GMLuaMenuHostState()
    private let runtime: GMLuaRuntime
    private let permissionsHost: GMLuaPermissionsHost?
    private var started = false
    private var closed = false

    public init(
        fileSystem: any LuaVirtualFileSystem & Sendable,
        initialViewport: GMLuaViewportSize = .logicalDesktopDefault,
        textMeasurer: (any GMLuaTextMeasurer)? = nil,
        languageConfiguration: GMLuaLanguageConfiguration = .empty,
        permissionsHost: GMLuaPermissionsHost? = nil,
        logger: @escaping (String) -> Void
    ) {
        self.permissionsHost = permissionsHost
        runtime = GMLuaRuntime(
            realm: .menu,
            logger: logger,
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            initialViewport: initialViewport,
            textMeasurer: textMeasurer,
            languageConfiguration: languageConfiguration
        )
        runtime.resourceRegistry?.setMaterialPixelResolver(
            GMLuaVPKMaterialPixelResolver(
                looseFileSystem: fileSystem,
                archivesInPriorityOrder: []
            )
        )
    }

    deinit {
        _ = runtime.close()
    }

    @discardableResult
    public func start() throws -> GMLuaMenuBootstrapReport {
        lifecycleLock.lock()
        if closed {
            lifecycleLock.unlock()
            throw GMLuaMenuSessionError.closed
        }
        if started {
            lifecycleLock.unlock()
            throw GMLuaMenuSessionError.alreadyStarted
        }
        // Reserve the single-use boundary before entering Lua. A partially
        // executed shipped bootstrap is not safe to replay in the same state.
        started = true
        lifecycleLock.unlock()

        try installHostBoundary()
        for path in Self.bootstrapPaths {
            try runtime.loadFile(path)
        }
        try runtime.execute(Self.menuSource, sourceName: "@garryspad/menu.lua")

        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        let rootCount = registry
            .renderTree(viewportWidth: 1_024, viewportHeight: 768)
            .filter { $0.parentIdentifier == nil }
            .count
        return GMLuaMenuBootstrapReport(
            loadedPaths: Self.bootstrapPaths,
            rootPanelCount: rootCount
        )
    }

    public func updateProblems(_ lines: [String]) throws {
        try requireActive()
        try hostState.replaceProblems(lines)
    }

    public func drainActions() -> [GMLuaMenuAction] {
        hostState.drainActions()
    }

    @discardableResult
    public func advance(by delta: Double) throws -> [GMLuaTimerFailure] {
        try requireActive()
        guard let scheduler = runtime.timerScheduler else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("timer scheduler")
        }
        return try scheduler.advance(by: delta)
    }

    public func renderFrame(
        viewportWidth: Int,
        viewportHeight: Int
    ) throws -> GMLuaSurfaceFrameSnapshot {
        try requireActive()
        _ = runtime.updateViewport(width: viewportWidth, height: viewportHeight)
        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        guard let surface = runtime.surfaceCommandState else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("Surface command state")
        }
        return try registry.renderFrame(
            surface: surface,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
    }

    public func dispatchPointerEvent(
        x: Double,
        y: Double,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval,
        viewportWidth: Int,
        viewportHeight: Int
    ) throws -> GMLuaPointerDispatchResult {
        try requireActive()
        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        return try registry.dispatchPointerEvent(
            x: x,
            y: y,
            phase: phase,
            timestamp: timestamp,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
    }

    @discardableResult
    public func insertText(_ text: String) throws -> Int? {
        try requireActive()
        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        return try registry.insertText(text)
    }

    @discardableResult
    public func close() -> Bool {
        lifecycleLock.lock()
        if closed {
            lifecycleLock.unlock()
            return false
        }
        closed = true
        lifecycleLock.unlock()
        _ = runtime.close()
        return true
    }

    private func requireActive() throws {
        lifecycleLock.lock()
        let isClosed = closed
        let isStarted = started
        lifecycleLock.unlock()
        if isClosed { throw GMLuaMenuSessionError.closed }
        if !isStarted { throw GMLuaMenuSessionError.notStarted }
    }

    private func installHostBoundary() throws {
        let state = runtime.state
        let hostState = self.hostState
        if let permissionsHost {
            let runtime = self.runtime
            try GMLuaPermissions.install(
                into: state,
                realm: .menu,
                host: permissionsHost,
                onPermissionsChanged: { [weak runtime] in
                    _ = runtime?.dispatchContainedHostHook(
                        named: "OnPermissionsChanged"
                    )
                },
                onLocalSessionConnect: {
                    try hostState.append(.resumeGame)
                }
            )
        }
        state.register("__garryspad_menu_action") { arguments in
            guard case let .string(rawName)? = arguments.first else {
                throw LuaError.runtime(
                    "bad argument #1 to '__garryspad_menu_action' (string expected)"
                )
            }
            let name = rawName.utf8String
            switch name {
            case "start_map":
                let map = try Self.requiredString(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                guard map == "gm_construct" || map == "gm_flatgrass" else {
                    throw GMLuaMenuSessionError.invalidAction(
                        "unsupported bundled map \(map)"
                    )
                }
                try hostState.append(.startMap(map))
            case "resume":
                try hostState.append(.resumeGame)
            case "audio":
                guard arguments.indices.contains(1),
                      case let .boolean(enabled) = arguments[1] else {
                    throw LuaError.runtime(
                        "bad argument #2 to '__garryspad_menu_action' " +
                            "(boolean expected)"
                    )
                }
                try hostState.append(.setAudioEnabled(enabled))
            case "console":
                let line = try Self.requiredString(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                guard !line.isEmpty else { return [] }
                guard line.utf8.count <= GMLuaMenuHostState.maximumConsoleLineBytes else {
                    throw GMLuaMenuSessionError.invalidAction(
                        "console line exceeds " +
                            "\(GMLuaMenuHostState.maximumConsoleLineBytes) UTF-8 bytes"
                    )
                }
                try hostState.append(.executeConsoleLine(line))
            case "disconnect":
                try hostState.append(.disconnect)
            case "quit":
                try hostState.append(.quit)
            default:
                throw GMLuaMenuSessionError.invalidAction(name)
            }
            return []
        }
        state.register("__garryspad_menu_problem_text") { _ in
            [.string(LuaString(hostState.currentProblemText()))]
        }
    }

    private static func requiredString(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> String {
        guard arguments.indices.contains(index),
              case let .string(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                    "(string expected, got \(actual))"
            )
        }
        return value.utf8String
    }

    private static let menuSource = #"""
        local function menuButton(parent, text, x, y, width, callback)
            local button = assert(vgui.Create("DButton", parent))
            button:SetText(text)
            button:SetPos(x, y)
            button:SetSize(width, 42)
            button.DoClick = callback
            return button
        end

        local home = assert(vgui.Create("DFrame"))
        GARRYSPAD_HOME = home
        home:SetTitle("Garry's PAD")
        home:SetSize(math.min(ScrW() - 48, 760), math.min(ScrH() - 48, 640))
        home:Center()
        home:SetSizable(true)
        home:SetDeleteOnClose(false)
        home:MakePopup()

        local title = assert(vgui.Create("DLabel", home))
        title:SetText("Sandbox")
        title:SetFont("DermaLarge")
        title:SetPos(28, 52)
        title:SetSize(360, 48)

        local status = assert(vgui.Create("DLabel", home))
        status:SetText("Original Lua / Derma menu realm")
        status:SetPos(30, 96)
        status:SetSize(420, 24)

        local options = assert(vgui.Create("DFrame"))
        GARRYSPAD_OPTIONS = options
        options:SetTitle("Options")
        options:SetSize(460, 300)
        options:Center()
        options:SetSizable(true)
        options:SetDeleteOnClose(false)
        options:SetVisible(false)
        local audioEnabled = true
        local audioStatus = assert(vgui.Create("DLabel", options))
        audioStatus:SetPos(24, 54)
        audioStatus:SetSize(390, 28)
        local function refreshAudio()
            audioStatus:SetText(audioEnabled and "Audio: Enabled" or "Audio: Muted")
        end
        refreshAudio()
        menuButton(options, "Toggle Audio", 24, 96, 190, function()
            audioEnabled = not audioEnabled
            refreshAudio()
            __garryspad_menu_action("audio", audioEnabled)
        end)

        local problems = assert(vgui.Create("DFrame"))
        GARRYSPAD_PROBLEMS = problems
        problems:SetTitle("Problems")
        problems:SetSize(620, 420)
        problems:Center()
        problems:SetSizable(true)
        problems:SetDeleteOnClose(false)
        problems:SetVisible(false)
        local problemText = assert(vgui.Create("DLabel", problems))
        problemText:SetPos(20, 48)
        problemText:SetSize(570, 340)
        problemText:SetWrap(true)
        problemText:SetAutoStretchVertical(false)
        problemText.Think = function(self)
            local text = __garryspad_menu_problem_text()
            if self:GetText() ~= text then self:SetText(text) end
        end

        local console = assert(vgui.Create("DFrame"))
        GARRYSPAD_CONSOLE = console
        console:SetTitle("Console")
        console:SetSize(660, 260)
        console:Center()
        console:SetSizable(true)
        console:SetDeleteOnClose(false)
        console:SetVisible(false)
        local consoleHint = assert(vgui.Create("DLabel", console))
        consoleHint:SetText("Enter a console command and submit it to the active host.")
        consoleHint:SetPos(20, 50)
        consoleHint:SetSize(610, 24)
        local consoleEntry = assert(vgui.Create("DTextEntry", console))
        GARRYSPAD_CONSOLE_ENTRY = consoleEntry
        consoleEntry:SetPos(20, 90)
        consoleEntry:SetSize(610, 38)
        local function submitConsole()
            local value = consoleEntry:GetValue()
            if value == nil or value == "" then return end
            __garryspad_menu_action("console", value)
            consoleEntry:SetText("")
        end
        consoleEntry.OnEnter = submitConsole
        menuButton(console, "Run", 20, 148, 150, submitConsole)

        menuButton(home, "gm_construct", 28, 142, 230, function()
            __garryspad_menu_action("start_map", "gm_construct")
        end)
        menuButton(home, "gm_flatgrass", 28, 194, 230, function()
            __garryspad_menu_action("start_map", "gm_flatgrass")
        end)
        menuButton(home, "Resume Game", 28, 258, 230, function()
            __garryspad_menu_action("resume")
        end)
        menuButton(home, "Options", 286, 142, 210, function()
            options:SetVisible(true)
            options:MakePopup()
        end)
        menuButton(home, "Problems", 286, 194, 210, function()
            problems:SetVisible(true)
            problems:MakePopup()
        end)
        menuButton(home, "Console", 286, 246, 210, function()
            console:SetVisible(true)
            console:MakePopup()
            consoleEntry:RequestFocus()
        end)
        menuButton(home, "Disconnect", 28, 334, 230, function()
            __garryspad_menu_action("disconnect")
        end)
        menuButton(home, "Quit", 286, 334, 210, function()
            __garryspad_menu_action("quit")
        end)
    """#
}

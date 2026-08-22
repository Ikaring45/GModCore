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
    case setMenuBackgroundsEnabled(Bool)
    case setPreferredFramesPerSecond(Int)
    case setInvertTouchLookY(Bool)
    case setTouchLookSensitivity(Double)
    case executeConsoleLine(String)
    case closeUtility
    case disconnect
    case quit
}

/// Host utility selected by the original HTML Home menu (or by the stock
/// `gui.ShowConsole` command). Home itself remains the shipped DHTML surface;
/// these cases only identify the Derma window layered above it.
public enum GMLuaMenuUtility: String, Sendable, Equatable {
    case settings
    case problems
    case console
}

/// Immutable values read by MENU Lua from the app stores that actually own
/// audio, content presentation, touch input, and display cadence.
public struct GMLuaMenuSettingsSnapshot: Sendable, Equatable {
    public var audioEnabled: Bool
    public var menuBackgroundsEnabled: Bool
    public var preferredFramesPerSecond: Int
    public var invertTouchLookY: Bool
    public var touchLookSensitivity: Double

    public init(
        audioEnabled: Bool = true,
        menuBackgroundsEnabled: Bool = true,
        preferredFramesPerSecond: Int = 60,
        invertTouchLookY: Bool = false,
        touchLookSensitivity: Double = 0.34
    ) {
        self.audioEnabled = audioEnabled
        self.menuBackgroundsEnabled = menuBackgroundsEnabled
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.invertTouchLookY = invertTouchLookY
        self.touchLookSensitivity = touchLookSensitivity
    }
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
    case invalidConsoleText(String)

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
        case let .invalidConsoleText(message):
            return "invalid MENU Console text: \(message)"
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
    static let maximumConsoleHistoryLineCount = 512
    static let maximumConsoleHistoryLineBytes = 2 * 1_024
    static let maximumConsoleHistoryTextBytes = 128 * 1_024

    private let lock = NSLock()
    private var actions: [GMLuaMenuAction] = []
    private var problemText = "No current problems."
    private var consoleText = "Console ready."
    private var settings = GMLuaMenuSettingsSnapshot()

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

    func replaceConsoleLines(_ lines: [String]) throws {
        guard lines.count <= Self.maximumConsoleHistoryLineCount else {
            throw GMLuaMenuSessionError.invalidConsoleText(
                "more than \(Self.maximumConsoleHistoryLineCount) lines"
            )
        }
        var encodedLines: [String] = []
        encodedLines.reserveCapacity(lines.count)
        var totalBytes = 0
        for line in lines {
            let bytes = Array(line.utf8)
            guard bytes.count <= Self.maximumConsoleHistoryLineBytes else {
                throw GMLuaMenuSessionError.invalidConsoleText(
                    "one line exceeds \(Self.maximumConsoleHistoryLineBytes) UTF-8 bytes"
                )
            }
            let separatorBytes = encodedLines.isEmpty ? 0 : 1
            let addition = totalBytes.addingReportingOverflow(
                bytes.count + separatorBytes
            )
            guard !addition.overflow,
                  addition.partialValue <= Self.maximumConsoleHistoryTextBytes else {
                throw GMLuaMenuSessionError.invalidConsoleText(
                    "text exceeds \(Self.maximumConsoleHistoryTextBytes) UTF-8 bytes"
                )
            }
            totalBytes = addition.partialValue
            encodedLines.append(line)
        }
        lock.lock()
        consoleText = encodedLines.isEmpty
            ? "Console ready."
            : encodedLines.joined(separator: "\n")
        lock.unlock()
    }

    func currentConsoleText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return consoleText
    }

    func replaceSettings(_ replacement: GMLuaMenuSettingsSnapshot) {
        lock.lock()
        settings = replacement
        lock.unlock()
    }

    func currentSettings() -> GMLuaMenuSettingsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }
}

/// One trusted Garry's Mod MENU realm backed by the same native VGUI, Derma,
/// pointer, text-input, and renderer-neutral Surface implementation as the
/// gameplay Spawnmenu.
///
/// The application remains responsible for executing typed
/// ``GMLuaMenuAction`` values; MENU Lua never receives direct UIKit,
/// filesystem, or process access. The original Home DHTML is hosted by the app
/// and this realm owns only the Derma Settings, Problems, and Console windows.
public final class GMLuaMenuSession: @unchecked Sendable {
    private static let bootstrapPaths = [
        "lua/includes/init.lua",
        "lua/derma/init.lua",
        "lua/vgui/dpanel.lua",
        "lua/vgui/dlabel.lua",
        "lua/vgui/dbutton.lua",
        "lua/vgui/dscrollbargrip.lua",
        "lua/vgui/dvscrollbar.lua",
        "lua/vgui/dscrollpanel.lua",
        "lua/vgui/dtextentry.lua",
        "lua/vgui/dframe.lua",
        "lua/skins/default.lua",
    ]

    private let lifecycleLock = NSLock()
    private let hostState = GMLuaMenuHostState()
    private let runtime: GMLuaRuntime
    private let permissionsHost: GMLuaPermissionsHost?
    private let permissionSessionTransport: GMLuaPermissionSessionTransport?
    private var started = false
    private var closed = false

    public init(
        fileSystem: any LuaVirtualFileSystem & Sendable,
        initialViewport: GMLuaViewportSize = .logicalDesktopDefault,
        textMeasurer: (any GMLuaTextMeasurer)? = nil,
        languageConfiguration: GMLuaLanguageConfiguration = .empty,
        permissionsHost: GMLuaPermissionsHost? = nil,
        permissionSessionTransport: GMLuaPermissionSessionTransport? = nil,
        logger: @escaping (String) -> Void
    ) {
        self.permissionsHost = permissionsHost
        self.permissionSessionTransport = permissionSessionTransport
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
        try runtime.execute(
            Self.menuSource,
            sourceName: "@garryspad/menu_utilities.lua"
        )

        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        let rootCount = registry.rootPanelCount
        return GMLuaMenuBootstrapReport(
            loadedPaths: Self.bootstrapPaths,
            rootPanelCount: rootCount
        )
    }

    public func updateProblems(_ lines: [String]) throws {
        try requireActive()
        try hostState.replaceProblems(lines)
        try runtime.execute(
            "if GARRYSPAD_REFRESH_PROBLEMS then GARRYSPAD_REFRESH_PROBLEMS() end",
            sourceName: "=(Garry's PAD Problems refresh)"
        )
    }

    public func updateConsoleLines(_ lines: [String]) throws {
        try requireActive()
        try hostState.replaceConsoleLines(lines)
        try runtime.execute(
            "if GARRYSPAD_REFRESH_CONSOLE then GARRYSPAD_REFRESH_CONSOLE() end",
            sourceName: "=(Garry's PAD Console refresh)"
        )
    }

    public func updateSettings(_ settings: GMLuaMenuSettingsSnapshot) throws {
        try requireActive()
        hostState.replaceSettings(settings)
        try runtime.execute(
            "if GARRYSPAD_REFRESH_SETTINGS then GARRYSPAD_REFRESH_SETTINGS() end",
            sourceName: "=(Garry's PAD Settings refresh)"
        )
    }

    public func present(_ utility: GMLuaMenuUtility) throws {
        try requireActive()
        let source: String
        switch utility {
        case .settings:
            source = "GARRYSPAD_OPEN_UTILITY('settings')"
        case .problems:
            source = "GARRYSPAD_OPEN_UTILITY('problems')"
        case .console:
            source = "GARRYSPAD_OPEN_UTILITY('console')"
        }
        try runtime.execute(source, sourceName: "=(Garry's PAD utility open)")
    }

    public func dismissUtility() throws {
        try requireActive()
        try runtime.execute(
            "GARRYSPAD_OPEN_UTILITY(nil)",
            sourceName: "=(Garry's PAD utility close)"
        )
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
        _ = runtime.updateViewport(width: viewportWidth, height: viewportHeight)
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
    public func deleteTextBackward() throws -> Int? {
        try requireActive()
        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        return try registry.deleteTextBackward()
    }

    @discardableResult
    public func submitFocusedTextEntry() throws -> Int? {
        try requireActive()
        guard let registry = runtime.vguiRegistry else {
            throw GMLuaMenuSessionError.missingRuntimeSurface("VGUI registry")
        }
        return try registry.submitFocusedTextEntry()
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
                sessionTransport: permissionSessionTransport,
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
                let enabled = try Self.requiredBoolean(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                try hostState.append(.setAudioEnabled(enabled))
                var settings = hostState.currentSettings()
                settings.audioEnabled = enabled
                hostState.replaceSettings(settings)
            case "backgrounds":
                let enabled = try Self.requiredBoolean(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                try hostState.append(.setMenuBackgroundsEnabled(enabled))
                var settings = hostState.currentSettings()
                settings.menuBackgroundsEnabled = enabled
                hostState.replaceSettings(settings)
            case "frame_rate":
                let rawValue = try Self.requiredNumber(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                guard rawValue == 60 || rawValue == 120 else {
                    throw GMLuaMenuSessionError.invalidAction(
                        "unsupported frame rate \(rawValue)"
                    )
                }
                let frameRate = Int(rawValue)
                try hostState.append(.setPreferredFramesPerSecond(frameRate))
                var settings = hostState.currentSettings()
                settings.preferredFramesPerSecond = frameRate
                hostState.replaceSettings(settings)
            case "invert_touch_y":
                let enabled = try Self.requiredBoolean(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                try hostState.append(.setInvertTouchLookY(enabled))
                var settings = hostState.currentSettings()
                settings.invertTouchLookY = enabled
                hostState.replaceSettings(settings)
            case "touch_sensitivity":
                let value = try Self.requiredNumber(
                    arguments,
                    index: 1,
                    function: "__garryspad_menu_action"
                )
                guard value.isFinite, value >= 0.05, value <= 1.50 else {
                    throw GMLuaMenuSessionError.invalidAction(
                        "touch sensitivity outside 0.05...1.50"
                    )
                }
                try hostState.append(.setTouchLookSensitivity(value))
                var settings = hostState.currentSettings()
                settings.touchLookSensitivity = value
                hostState.replaceSettings(settings)
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
            case "close_utility":
                try hostState.append(.closeUtility)
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
        state.register("__garryspad_menu_console_text") { _ in
            [.string(LuaString(hostState.currentConsoleText()))]
        }
        state.register("__garryspad_menu_setting") { arguments in
            let key = try Self.requiredString(
                arguments,
                index: 0,
                function: "__garryspad_menu_setting"
            )
            let settings = hostState.currentSettings()
            switch key {
            case "audio":
                return [.boolean(settings.audioEnabled)]
            case "backgrounds":
                return [.boolean(settings.menuBackgroundsEnabled)]
            case "frame_rate":
                return [.number(Double(settings.preferredFramesPerSecond))]
            case "invert_touch_y":
                return [.boolean(settings.invertTouchLookY)]
            case "touch_sensitivity":
                return [.number(settings.touchLookSensitivity)]
            default:
                throw GMLuaMenuSessionError.invalidAction(
                    "unknown settings key \(key)"
                )
            }
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

    private static func requiredBoolean(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Bool {
        guard arguments.indices.contains(index),
              case let .boolean(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                    "(boolean expected, got \(actual))"
            )
        }
        return value
    }

    private static func requiredNumber(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index),
              case let .number(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                    "(number expected, got \(actual))"
            )
        }
        return value
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

        local options = assert(vgui.Create("DFrame"))
        GARRYSPAD_OPTIONS = options
        options:SetTitle("Settings")
        options:SetSize(620, 440)
        options:Center()
        options:SetSizable(true)
        options:SetDeleteOnClose(false)
        options:SetVisible(false)

        local settingsDescription = assert(vgui.Create("DLabel", options))
        settingsDescription:SetText("These controls update the active Garry's PAD stores.")
        settingsDescription:SetPos(24, 48)
        settingsDescription:SetSize(560, 28)

        local audioButton
        local backgroundsButton
        local frameRateButton
        local invertTouchButton
        local sensitivityDown
        local sensitivityUp
        local function refreshSettings()
            local audio = __garryspad_menu_setting("audio")
            local backgrounds = __garryspad_menu_setting("backgrounds")
            local frameRate = __garryspad_menu_setting("frame_rate")
            local invertTouch = __garryspad_menu_setting("invert_touch_y")
            local sensitivity = __garryspad_menu_setting("touch_sensitivity")
            audioButton:SetText(audio and "Menu audio: On" or "Menu audio: Muted")
            backgroundsButton:SetText(
                backgrounds and "Menu backgrounds: On" or "Menu backgrounds: Off"
            )
            frameRateButton:SetText("Display cadence: " .. frameRate .. " FPS")
            invertTouchButton:SetText(
                invertTouch and "Invert touch look Y: On" or "Invert touch look Y: Off"
            )
            local sensitivityText = string.format("Touch look: %.2f", sensitivity)
            sensitivityDown:SetText(sensitivityText .. "  -")
            sensitivityUp:SetText(sensitivityText .. "  +")
        end

        audioButton = menuButton(options, "", 24, 88, 272, function()
            __garryspad_menu_action(
                "audio", not __garryspad_menu_setting("audio")
            )
            refreshSettings()
        end)
        backgroundsButton = menuButton(options, "", 320, 88, 272, function()
            __garryspad_menu_action(
                "backgrounds", not __garryspad_menu_setting("backgrounds")
            )
            refreshSettings()
        end)
        frameRateButton = menuButton(options, "", 24, 142, 272, function()
            local current = __garryspad_menu_setting("frame_rate")
            __garryspad_menu_action("frame_rate", current == 60 and 120 or 60)
            refreshSettings()
        end)
        invertTouchButton = menuButton(options, "", 320, 142, 272, function()
            __garryspad_menu_action(
                "invert_touch_y", not __garryspad_menu_setting("invert_touch_y")
            )
            refreshSettings()
        end)
        sensitivityDown = menuButton(options, "", 24, 196, 272, function()
            local current = __garryspad_menu_setting("touch_sensitivity")
            local replacement = math.max(0.05, current - 0.05)
            __garryspad_menu_action("touch_sensitivity", replacement)
            refreshSettings()
        end)
        sensitivityUp = menuButton(options, "", 320, 196, 272, function()
            local current = __garryspad_menu_setting("touch_sensitivity")
            local replacement = math.min(1.50, current + 0.05)
            __garryspad_menu_action("touch_sensitivity", replacement)
            refreshSettings()
        end)
        local optionsBack = menuButton(options, "Back", 420, 366, 172, function()
            options:Close()
        end)
        GARRYSPAD_REFRESH_SETTINGS = refreshSettings
        refreshSettings()
        local optionsFrameLayout = options.PerformLayout
        options.PerformLayout = function(self, w, h)
            optionsFrameLayout(self, w, h)
            settingsDescription:SetWide(math.max(160, w - 48))
            optionsBack:SetPos(math.max(24, w - 200), math.max(260, h - 74))
        end
        options.OnClose = function()
            __garryspad_menu_action("close_utility")
        end

        local problems = assert(vgui.Create("DFrame"))
        GARRYSPAD_PROBLEMS = problems
        problems:SetTitle("Problems")
        problems:SetSize(620, 420)
        problems:Center()
        problems:SetSizable(true)
        problems:SetDeleteOnClose(false)
        problems:SetVisible(false)
        local problemScroll = assert(vgui.Create("DScrollPanel", problems))
        local problemText = assert(vgui.Create("DLabel"))
        problemScroll:AddItem(problemText)
        problemText:SetWrap(true)
        problemText:SetAutoStretchVertical(false)
        local function refreshProblems()
            local text = __garryspad_menu_problem_text()
            if problemText:GetText() ~= text then problemText:SetText(text) end
            problems:InvalidateLayout()
        end
        GARRYSPAD_REFRESH_PROBLEMS = refreshProblems
        refreshProblems()
        local problemBack = menuButton(problems, "Back", 430, 358, 150, function()
            problems:Close()
        end)
        local problemFrameLayout = problems.PerformLayout
        problems.PerformLayout = function(self, w, h)
            problemFrameLayout(self, w, h)
            local contentWide = math.max(120, w - 40)
            local contentTall = math.max(70, h - 116)
            problemScroll:SetPos(20, 48)
            problemScroll:SetSize(contentWide, contentTall)
            problemText:SetWide(math.max(80, contentWide - 18))
            problemText:SizeToContentsY()
            problemScroll:InvalidateLayout()
            problemBack:SetPos(math.max(20, w - 170), math.max(48, h - 58))
        end
        problems:InvalidateLayout()
        problems.OnClose = function()
            __garryspad_menu_action("close_utility")
        end

        local console = assert(vgui.Create("DFrame"))
        GARRYSPAD_CONSOLE = console
        console:SetTitle("Console")
        console:SetSize(700, 440)
        console:Center()
        console:SetSizable(true)
        console:SetDeleteOnClose(false)
        console:SetVisible(false)
        local consoleScroll = assert(vgui.Create("DScrollPanel", console))
        local consoleOutput = assert(vgui.Create("DLabel"))
        consoleScroll:AddItem(consoleOutput)
        consoleOutput:SetFont("DermaDefault")
        consoleOutput:SetWrap(true)
        consoleOutput:SetAutoStretchVertical(false)
        local function refreshConsole()
            local text = __garryspad_menu_console_text()
            if consoleOutput:GetText() ~= text then consoleOutput:SetText(text) end
            console:InvalidateLayout()
        end
        GARRYSPAD_REFRESH_CONSOLE = refreshConsole
        refreshConsole()
        local consoleEntry = assert(vgui.Create("DTextEntry", console))
        GARRYSPAD_CONSOLE_ENTRY = consoleEntry
        local function submitConsole()
            local value = consoleEntry:GetValue()
            if value == nil or value == "" then return end
            __garryspad_menu_action("console", value)
            consoleEntry:SetText("")
        end
        consoleEntry.OnEnter = submitConsole
        local consoleRun = menuButton(console, "Run", 20, 148, 150, submitConsole)
        local consoleBack = menuButton(console, "Back", 180, 148, 150, function()
            console:Close()
        end)
        local consoleFrameLayout = console.PerformLayout
        console.PerformLayout = function(self, w, h)
            consoleFrameLayout(self, w, h)
            local contentWide = math.max(160, w - 40)
            local outputTall = math.max(80, h - 156)
            consoleScroll:SetPos(20, 44)
            consoleScroll:SetSize(contentWide, outputTall)
            consoleOutput:SetWide(math.max(100, contentWide - 18))
            consoleOutput:SizeToContentsY()
            consoleScroll:InvalidateLayout()
            local entryY = math.max(128, h - 100)
            consoleEntry:SetPos(20, entryY)
            consoleEntry:SetSize(contentWide, 32)
            consoleRun:SetPos(20, math.max(166, h - 58))
            consoleBack:SetPos(180, math.max(166, h - 58))
        end
        console:InvalidateLayout()
        console.OnClose = function()
            __garryspad_menu_action("close_utility")
        end

        function GARRYSPAD_OPEN_UTILITY(name)
            options:SetVisible(false)
            problems:SetVisible(false)
            console:SetVisible(false)

            if name == "settings" then
                refreshSettings()
                options:Center()
                options:SetVisible(true)
                options:MakePopup()
            elseif name == "problems" then
                refreshProblems()
                problems:Center()
                problems:SetVisible(true)
                problems:MakePopup()
            elseif name == "console" then
                refreshConsole()
                console:Center()
                console:SetVisible(true)
                console:MakePopup()
                consoleEntry:RequestFocus()
            elseif name ~= nil then
                error("unknown Garry's PAD utility " .. tostring(name), 2)
            end
        end
    """#
}

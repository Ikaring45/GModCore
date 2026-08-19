import Foundation
import GModLua

/// Screen-space cursor coordinates observed by the logical GLua input bridge.
///
/// The values deliberately remain `Double`s at this boundary. The embedding
/// host may quantize them when it maps a Lua cursor-warp request to a concrete
/// windowing system.
public struct GMLuaCursorPosition: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let origin = GMLuaCursorPosition(x: 0, y: 0)
}

/// Initial, host-supplied description of the local input device state.
///
/// Garry's Mod bindings are user configuration, so this type intentionally
/// has no made-up WASD/default binds. `LookupBinding` returns no value until
/// the host supplies both a command binding and a name for its button code.
public struct GMLuaInputConfiguration: Sendable, Equatable {
    /// BUTTON_CODE -> console command, for example `15: "+use"`.
    public var bindingsByButton: [Int: String]

    /// BUTTON_CODE -> engine-facing button name, for example `15: "e"`.
    /// These are the untranslated names returned by `input.GetKeyName`.
    public var buttonNames: [Int: String]

    public var cursorPosition: GMLuaCursorPosition

    public init(
        bindingsByButton: [Int: String] = [:],
        buttonNames: [Int: String] = [:],
        cursorPosition: GMLuaCursorPosition = .origin
    ) {
        self.bindingsByButton = bindingsByButton
        self.buttonNames = buttonNames
        self.cursorPosition = cursorPosition
    }
}

/// A request from Lua to move the platform cursor.
///
/// Connecting this sink is optional. The logical cursor position is updated
/// even without one, while an iPad/desktop embedding host can forward the
/// request to its own UI input adapter later.
public typealias GMLuaCursorWarpSink = @Sendable (GMLuaCursorPosition) -> Void

/// Host-owned logical substrate for the client/menu `input` library.
///
/// The bridge starts with no pressed controls and never polls Foundation,
/// UIKit, AppKit, or Win32. The embedding host feeds real transitions through
/// the update methods. That keeps headless conformance deterministic and
/// avoids claiming a platform event integration that does not exist yet.
public final class GMLuaInput: @unchecked Sendable {
    /// Values from Garry's Mod's public KEY enum used by the modifier helpers.
    public static let leftShiftKey = 79
    public static let rightShiftKey = 80
    public static let leftControlKey = 83
    public static let rightControlKey = 84

    public let realm: GMLuaRealm

    private let lock = NSLock()
    private var bindingsByButtonStorage: [Int: String]
    private var buttonNamesStorage: [Int: String]
    private var cursorPositionStorage: GMLuaCursorPosition
    private var pressedKeysStorage: Set<Int> = []
    private var pressedMouseButtonsStorage: Set<Int> = []
    private var pressedOtherButtonsStorage: Set<Int> = []
    private var keyTrappingStorage = false
    private var trappedButtonStorage: Int?
    private var cursorWarpSinkStorage: GMLuaCursorWarpSink?

    private init(
        realm: GMLuaRealm,
        configuration: GMLuaInputConfiguration,
        cursorWarpSink: GMLuaCursorWarpSink?
    ) {
        self.realm = realm
        bindingsByButtonStorage = configuration.bindingsByButton
        buttonNamesStorage = configuration.buttonNames
        cursorPositionStorage = configuration.cursorPosition
        cursorWarpSinkStorage = cursorWarpSink
    }

    public var cursorPosition: GMLuaCursorPosition {
        lock.lock()
        defer { lock.unlock() }
        return cursorPositionStorage
    }

    public var isKeyTrapping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keyTrappingStorage
    }

    public func binding(forButton button: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByButtonStorage[button]
    }

    public func keyName(forButton button: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return buttonNamesStorage[button]
    }

    /// Replaces the user's complete bind table without changing pressed state.
    public func replaceBindings(_ bindings: [Int: String]) {
        lock.lock()
        bindingsByButtonStorage = bindings
        lock.unlock()
    }

    /// Sets or removes one user binding.
    public func setBinding(_ command: String?, forButton button: Int) {
        lock.lock()
        bindingsByButtonStorage[button] = command
        lock.unlock()
    }

    public func replaceButtonNames(_ names: [Int: String]) {
        lock.lock()
        buttonNamesStorage = names
        lock.unlock()
    }

    public func setButtonName(_ name: String?, forButton button: Int) {
        lock.lock()
        buttonNamesStorage[button] = name
        lock.unlock()
    }

    public func connectCursorWarpSink(_ sink: @escaping GMLuaCursorWarpSink) {
        lock.lock()
        cursorWarpSinkStorage = sink
        lock.unlock()
    }

    public func disconnectCursorWarpSink() {
        lock.lock()
        cursorWarpSinkStorage = nil
        lock.unlock()
    }

    /// Delivers a real cursor position observed by the embedding host.
    public func updateCursorPosition(x: Double, y: Double) {
        lock.lock()
        cursorPositionStorage = GMLuaCursorPosition(x: x, y: y)
        lock.unlock()
    }

    /// Delivers a keyboard transition observed by the embedding host.
    public func updateKey(_ key: Int, isDown: Bool) {
        updateButton(key, isDown: isDown, category: .key)
    }

    /// Delivers a mouse-button transition observed by the embedding host.
    public func updateMouseButton(_ button: Int, isDown: Bool) {
        updateButton(button, isDown: isDown, category: .mouse)
    }

    /// Delivers a joystick/other BUTTON_CODE transition.
    public func updateButton(_ button: Int, isDown: Bool) {
        updateButton(button, isDown: isDown, category: .other)
    }

    /// Replaces a host keyboard snapshot. A newly-pressed key can satisfy an
    /// active key trap; already-held keys never do.
    public func replacePressedKeys(_ keys: Set<Int>) {
        replacePressedButtons(keys, category: .key)
    }

    public func replacePressedMouseButtons(_ buttons: Set<Int>) {
        replacePressedButtons(buttons, category: .mouse)
    }

    public func replacePressedOtherButtons(_ buttons: Set<Int>) {
        replacePressedButtons(buttons, category: .other)
    }

    public func isKeyDown(_ key: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressedKeysStorage.contains(key)
    }

    public func isMouseButtonDown(_ button: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressedMouseButtonsStorage.contains(button)
    }

    public func isButtonDown(_ button: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressedKeysStorage.contains(button)
            || pressedMouseButtonsStorage.contains(button)
            || pressedOtherButtonsStorage.contains(button)
    }

    public func startKeyTrapping() {
        lock.lock()
        keyTrappingStorage = true
        trappedButtonStorage = nil
        lock.unlock()
    }

    public func cancelKeyTrapping() {
        lock.lock()
        keyTrappingStorage = false
        trappedButtonStorage = nil
        lock.unlock()
    }

    /// Installs the logical input library into CLIENT or MENU. A nil SERVER
    /// result is intentional and leaves any existing global untouched.
    ///
    /// This is also the handoff API for `GMLuaRuntime`: runtime construction
    /// can pass a host configuration, retain the returned bridge, and expose
    /// its update methods to the platform view/input adapter.
    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        configuration: GMLuaInputConfiguration = GMLuaInputConfiguration(),
        cursorWarpSink: GMLuaCursorWarpSink? = nil
    ) throws -> GMLuaInput? {
        guard realm == .client || realm == .menu else { return nil }

        let bridge = GMLuaInput(
            realm: realm,
            configuration: configuration,
            cursorWarpSink: cursorWarpSink
        )
        let inputTable: LuaTable
        if case let .table(existing) = state.getGlobal("input") {
            inputTable = existing
        } else {
            inputTable = LuaTable()
        }

        try installFunction("LookupBinding", into: inputTable, state: state) { arguments in
            let requested = try stringArgument(
                arguments,
                at: 0,
                function: "input.LookupBinding"
            )
            let exact = arguments.count > 1 && arguments[1].isTruthy
            guard let name = bridge.lookupBinding(requested, exact: exact) else {
                return []
            }
            return [.string(LuaString(name))]
        }
        try installFunction("LookupKeyBinding", into: inputTable, state: state) { arguments in
            let button = try buttonArgument(
                arguments,
                function: "input.LookupKeyBinding"
            )
            guard let command = bridge.binding(forButton: button) else { return [] }
            return [.string(LuaString(command))]
        }
        try installFunction("GetKeyName", into: inputTable, state: state) { arguments in
            let button = try buttonArgument(arguments, function: "input.GetKeyName")
            guard let name = bridge.keyName(forButton: button) else { return [] }
            return [.string(LuaString(name))]
        }
        try installFunction("GetKeyCode", into: inputTable, state: state) { arguments in
            let name = try stringArgument(arguments, at: 0, function: "input.GetKeyCode")
            return [.number(Double(bridge.keyCode(forName: name) ?? -1))]
        }
        try installFunction("GetCursorPos", into: inputTable, state: state) { _ in
            let cursor = bridge.cursorPosition
            return [.number(cursor.x), .number(cursor.y)]
        }
        try installFunction("SetCursorPos", into: inputTable, state: state) { arguments in
            let x = try numericArgument(arguments, at: 0, function: "input.SetCursorPos")
            let y = try numericArgument(arguments, at: 1, function: "input.SetCursorPos")
            bridge.requestCursorPosition(x: x, y: y)
            return []
        }
        try installFunction("IsKeyDown", into: inputTable, state: state) { arguments in
            let key = try buttonArgument(arguments, function: "input.IsKeyDown")
            return [.boolean(bridge.isKeyDown(key))]
        }
        try installFunction("IsMouseDown", into: inputTable, state: state) { arguments in
            let button = try buttonArgument(arguments, function: "input.IsMouseDown")
            return [.boolean(bridge.isMouseButtonDown(button))]
        }
        try installFunction("IsButtonDown", into: inputTable, state: state) { arguments in
            let button = try buttonArgument(arguments, function: "input.IsButtonDown")
            return [.boolean(bridge.isButtonDown(button))]
        }
        try installFunction("IsShiftDown", into: inputTable, state: state) { _ in
            [.boolean(
                bridge.isKeyDown(leftShiftKey) || bridge.isKeyDown(rightShiftKey)
            )]
        }
        try installFunction("IsControlDown", into: inputTable, state: state) { _ in
            [.boolean(
                bridge.isKeyDown(leftControlKey) || bridge.isKeyDown(rightControlKey)
            )]
        }
        try installFunction("StartKeyTrapping", into: inputTable, state: state) { _ in
            bridge.startKeyTrapping()
            return []
        }
        try installFunction("IsKeyTrapping", into: inputTable, state: state) { _ in
            [.boolean(bridge.isKeyTrapping)]
        }
        try installFunction("CheckKeyTrapping", into: inputTable, state: state) { _ in
            guard let button = bridge.consumeTrappedButton() else { return [] }
            return [.number(Double(button))]
        }

        state.setGlobal("input", value: .table(inputTable))
        return bridge
    }

    private enum ButtonCategory {
        case key
        case mouse
        case other
    }

    private func updateButton(
        _ button: Int,
        isDown: Bool,
        category: ButtonCategory
    ) {
        lock.lock()
        let wasDown: Bool
        switch category {
        case .key:
            wasDown = pressedKeysStorage.contains(button)
            if isDown { pressedKeysStorage.insert(button) }
            else { pressedKeysStorage.remove(button) }
        case .mouse:
            wasDown = pressedMouseButtonsStorage.contains(button)
            if isDown { pressedMouseButtonsStorage.insert(button) }
            else { pressedMouseButtonsStorage.remove(button) }
        case .other:
            wasDown = pressedOtherButtonsStorage.contains(button)
            if isDown { pressedOtherButtonsStorage.insert(button) }
            else { pressedOtherButtonsStorage.remove(button) }
        }
        if isDown && !wasDown && keyTrappingStorage && trappedButtonStorage == nil {
            trappedButtonStorage = button
        }
        lock.unlock()
    }

    private func replacePressedButtons(
        _ buttons: Set<Int>,
        category: ButtonCategory
    ) {
        lock.lock()
        let oldButtons: Set<Int>
        switch category {
        case .key:
            oldButtons = pressedKeysStorage
            pressedKeysStorage = buttons
        case .mouse:
            oldButtons = pressedMouseButtonsStorage
            pressedMouseButtonsStorage = buttons
        case .other:
            oldButtons = pressedOtherButtonsStorage
            pressedOtherButtonsStorage = buttons
        }
        if keyTrappingStorage && trappedButtonStorage == nil {
            trappedButtonStorage = buttons.subtracting(oldButtons).min()
        }
        lock.unlock()
    }

    private func lookupBinding(_ requested: String, exact: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let requestedComparable = exact ? requested : strippingOneLeadingPlus(requested)
        let matchingButton = bindingsByButtonStorage
            .compactMap { button, command -> Int? in
                let commandComparable = exact ? command : strippingOneLeadingPlus(command)
                return commandComparable == requestedComparable ? button : nil
            }
            .min()
        guard let matchingButton else { return nil }
        return buttonNamesStorage[matchingButton]
    }

    private func keyCode(forName name: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return buttonNamesStorage
            .compactMap { button, candidate in candidate == name ? button : nil }
            .min()
    }

    private func requestCursorPosition(x: Double, y: Double) {
        let position = GMLuaCursorPosition(x: x, y: y)
        let sink: GMLuaCursorWarpSink?
        lock.lock()
        cursorPositionStorage = position
        sink = cursorWarpSinkStorage
        lock.unlock()
        sink?(position)
    }

    private func consumeTrappedButton() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard keyTrappingStorage, let button = trappedButtonStorage else {
            return nil
        }
        keyTrappingStorage = false
        trappedButtonStorage = nil
        return button
    }

    private func strippingOneLeadingPlus(_ value: String) -> String {
        value.hasPrefix("+") ? String(value.dropFirst()) : value
    }

    private static func installFunction(
        _ name: String,
        into table: LuaTable,
        state: LuaState,
        body: @escaping LuaNativeFunction
    ) throws {
        try state.setRawTableValue(
            .nativeFunction(
                LuaNativeFunctionBox(body, debugName: "input.\(name)")
            ),
            for: .string(LuaString(name)),
            in: table
        )
    }

    private static func stringArgument(
        _ arguments: [LuaValue],
        at index: Int,
        function: String
    ) throws -> String {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (string expected, got no value)"
            )
        }
        guard case let .string(value) = arguments[index] else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (string expected, got \(arguments[index].typeName))"
            )
        }
        return value.utf8String
    }

    private static func numericArgument(
        _ arguments: [LuaValue],
        at index: Int,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (number expected, got no value)"
            )
        }

        let number: Double?
        switch arguments[index] {
        case let .number(value): number = value
        case let .string(value): number = Double(value.utf8String)
        default: number = nil
        }
        guard let number, number.isFinite else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (number expected, got \(arguments[index].typeName))"
            )
        }
        return number
    }

    private static func buttonArgument(
        _ arguments: [LuaValue],
        function: String
    ) throws -> Int {
        let number = try numericArgument(arguments, at: 0, function: function)
        let truncated = number.rounded(.towardZero)
        // `Double(Int.max)` rounds up to 2^(wordSize-1), so an inclusive
        // comparison would admit a value that traps Swift's Int conversion.
        let lowerBoundInclusive = Double(Int.min)
        let upperBoundExclusive = -lowerBoundInclusive
        guard truncated >= lowerBoundInclusive,
              truncated < upperBoundExclusive else {
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (BUTTON_CODE out of range)"
            )
        }
        return Int(truncated)
    }
}

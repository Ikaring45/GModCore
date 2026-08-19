import Foundation
import GModLua

/// A scalar SoundData field or the two-value random range accepted by GLua.
public enum GMLuaSoundScalarOrRange: Sendable, Equatable {
    case scalar(Double)
    case range(Double, Double)
}

/// The concrete file name (or random-choice list) stored by a sound script.
public enum GMLuaSoundSource: Sendable, Equatable {
    case single(LuaString)
    case choices([LuaString])
}

/// Transport-safe snapshot of one `sound.Add` registration.
///
/// This is a logical registry record. It deliberately does not claim that a
/// Source asset has been found, decoded, or connected to an audio device.
public struct GMLuaSoundScript: Sendable, Equatable {
    public let name: LuaString
    public let channel: Int
    public let level: Double
    public let volume: GMLuaSoundScalarOrRange
    public let pitch: GMLuaSoundScalarOrRange
    public let pitchStart: Double
    public let pitchEnd: Double
    public let sound: GMLuaSoundSource
    public let hasAudioBacking: Bool

    public init(
        name: LuaString,
        channel: Int,
        level: Double,
        volume: GMLuaSoundScalarOrRange,
        pitch: GMLuaSoundScalarOrRange,
        pitchStart: Double,
        pitchEnd: Double,
        sound: GMLuaSoundSource,
        hasAudioBacking: Bool = false
    ) {
        self.name = name
        self.channel = channel
        self.level = level
        self.volume = volume
        self.pitch = pitch
        self.pitchStart = pitchStart
        self.pitchEnd = pitchEnd
        self.sound = sound
        self.hasAudioBacking = hasAudioBacking
    }
}

/// Logical request emitted by `sound.Play` for a platform audio adapter.
public struct GMLuaSoundPlayEvent: Sendable, Equatable {
    public let realm: GMLuaRealm
    public let sound: LuaString
    public let x: Double
    public let y: Double
    public let z: Double
    public let level: Double
    public let pitch: Double
    public let volume: Double
    public let dsp: Double
    public let hasAudioBacking: Bool

    public init(
        realm: GMLuaRealm,
        sound: LuaString,
        x: Double,
        y: Double,
        z: Double,
        level: Double,
        pitch: Double,
        volume: Double,
        dsp: Double,
        hasAudioBacking: Bool = false
    ) {
        self.realm = realm
        self.sound = sound
        self.x = x
        self.y = y
        self.z = z
        self.level = level
        self.pitch = pitch
        self.volume = volume
        self.dsp = dsp
        self.hasAudioBacking = hasAudioBacking
    }
}

public typealias GMLuaSoundPlaySink = @Sendable (GMLuaSoundPlayEvent) -> Void

/// Host-owned logical implementation of GLua's shared `sound` registry.
///
/// Registration and play requests are deterministic and headless. The bridge
/// never imports an audio framework and never fabricates an asset/device
/// connection; a future host can connect a sink and resolve Source assets.
public final class GMLuaSound: @unchecked Sendable {
    /// Exact public values from Garry's Mod's CHAN enum.
    public static let channelConstants: [String: Int] = [
        "CHAN_REPLACE": -1,
        "CHAN_AUTO": 0,
        "CHAN_WEAPON": 1,
        "CHAN_VOICE": 2,
        "CHAN_ITEM": 3,
        "CHAN_BODY": 4,
        "CHAN_STREAM": 5,
        "CHAN_STATIC": 6,
        "CHAN_VOICE2": 7,
        "CHAN_VOICE_BASE": 8,
        "CHAN_USER_BASE": 136
    ]

    public let realm: GMLuaRealm
    public let hasAudioBacking = false

    private let lock = NSLock()
    private var scripts: [LuaString: GMLuaSoundScript] = [:]
    private var registrationOrder: [LuaString] = []
    private var playEvents: [GMLuaSoundPlayEvent] = []
    private var playSink: GMLuaSoundPlaySink?

    private init(realm: GMLuaRealm, playSink: GMLuaSoundPlaySink?) {
        self.realm = realm
        self.playSink = playSink
    }

    public var registeredSoundNames: [LuaString] {
        lock.lock()
        defer { lock.unlock() }
        return registrationOrder
    }

    public var capturedPlayEvents: [GMLuaSoundPlayEvent] {
        lock.lock()
        defer { lock.unlock() }
        return playEvents
    }

    public func script(named name: LuaString) -> GMLuaSoundScript? {
        lock.lock()
        defer { lock.unlock() }
        return scripts[name]
    }

    public func drainCapturedPlayEvents() -> [GMLuaSoundPlayEvent] {
        lock.lock()
        let result = playEvents
        playEvents.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }

    public func connectPlaySink(_ sink: @escaping GMLuaSoundPlaySink) {
        lock.lock()
        playSink = sink
        lock.unlock()
    }

    public func disconnectPlaySink() {
        lock.lock()
        playSink = nil
        lock.unlock()
    }

    /// Installs the shared GLua sound surface. The returned object is the
    /// runtime/host handoff point for registry inspection and logical play
    /// events; no AVAudioEngine or Source decoder is implied.
    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        playSink: GMLuaSoundPlaySink? = nil
    ) throws -> GMLuaSound {
        let bridge = GMLuaSound(realm: realm, playSink: playSink)
        let soundTable: LuaTable
        if case let .table(existing) = state.getGlobal("sound") {
            soundTable = existing
        } else {
            soundTable = LuaTable()
        }

        for (name, value) in channelConstants {
            state.setGlobal(name, value: .number(Double(value)))
        }

        try installFunction("Add", into: soundTable, state: state) { arguments in
            let table = try tableArgument(arguments, at: 0, function: "sound.Add")
            let script = try parseScript(from: table, state: state)
            bridge.register(script)
            return []
        }
        try installFunction("GetProperties", into: soundTable, state: state) { arguments in
            let name = try stringArgument(arguments, at: 0, function: "sound.GetProperties")
            guard let script = bridge.script(named: name) else { return [] }
            return [.table(try makePropertiesTable(for: script, state: state))]
        }
        try installFunction("GetTable", into: soundTable, state: state) { _ in
            let result = LuaTable()
            for (offset, name) in bridge.registeredSoundNames.enumerated() {
                try state.setRawTableValue(
                    .string(name),
                    for: .number(Double(offset + 1)),
                    in: result
                )
            }
            return [.table(result)]
        }
        try installFunction("Play", into: soundTable, state: state) { arguments in
            let name = try stringArgument(arguments, at: 0, function: "sound.Play")
            guard arguments.indices.contains(1) else {
                throw badArgument(2, function: "sound.Play", expected: "Vector", actual: "no value")
            }
            let (x, y, z) = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[1],
                function: "sound.Play"
            )
            let event = GMLuaSoundPlayEvent(
                realm: realm,
                sound: name,
                x: x,
                y: y,
                z: z,
                level: try optionalNumber(arguments, at: 2, default: 75, function: "sound.Play"),
                pitch: try optionalNumber(arguments, at: 3, default: 100, function: "sound.Play"),
                volume: try optionalNumber(arguments, at: 4, default: 1, function: "sound.Play"),
                dsp: try optionalNumber(arguments, at: 5, default: 0, function: "sound.Play")
            )
            bridge.emit(event)
            return []
        }

        // The stock Lua helper is an identity function. It intentionally does
        // not turn a name into a decoded sound object.
        state.setGlobal(
            "Sound",
            value: .nativeFunction(
                LuaNativeFunctionBox({ arguments in
                    [.string(try stringArgument(arguments, at: 0, function: "Sound"))]
                }, debugName: "Sound")
            )
        )
        state.setGlobal("sound", value: .table(soundTable))
        return bridge
    }

    private func register(_ script: GMLuaSoundScript) {
        lock.lock()
        if scripts[script.name] == nil {
            registrationOrder.append(script.name)
        }
        scripts[script.name] = script
        lock.unlock()
    }

    private func emit(_ event: GMLuaSoundPlayEvent) {
        let sink: GMLuaSoundPlaySink?
        lock.lock()
        playEvents.append(event)
        sink = playSink
        lock.unlock()
        sink?(event)
    }

    private static func parseScript(
        from table: LuaTable,
        state: LuaState
    ) throws -> GMLuaSoundScript {
        let name = try requiredStringField("name", in: table, state: state, function: "sound.Add")
        let sourceValue = try state.rawTableValue(for: .string("sound"), in: table)
        let source = try soundSource(from: sourceValue, state: state)
        let channelNumber = try optionalNumberField("channel", in: table, state: state, default: 0)
        let channel = try exactInt(channelNumber, field: "channel", function: "sound.Add")
        return GMLuaSoundScript(
            name: name,
            channel: channel,
            level: try optionalNumberField("level", in: table, state: state, default: 75),
            volume: try scalarOrRangeField("volume", in: table, state: state, default: 1),
            pitch: try scalarOrRangeField("pitch", in: table, state: state, default: 100),
            pitchStart: try optionalNumberField("pitchstart", in: table, state: state, default: 100),
            pitchEnd: try optionalNumberField("pitchend", in: table, state: state, default: 100),
            sound: source
        )
    }

    private static func soundSource(
        from value: LuaValue,
        state: LuaState
    ) throws -> GMLuaSoundSource {
        if case let .string(source) = value {
            return .single(source)
        }
        guard case let .table(table) = value else {
            throw LuaError.runtime("bad field 'sound' to 'sound.Add' (string or table expected, got \(value.typeName))")
        }
        var choices: [LuaString] = []
        var index = 1
        while true {
            let item = try state.rawTableValue(for: .number(Double(index)), in: table)
            if case .nilValue = item { break }
            guard case let .string(choice) = item else {
                throw LuaError.runtime("bad field 'sound' to 'sound.Add' (sequential string table expected)")
            }
            choices.append(choice)
            index += 1
        }
        guard !choices.isEmpty else {
            throw LuaError.runtime("bad field 'sound' to 'sound.Add' (non-empty string table expected)")
        }
        return .choices(choices)
    }

    private static func makePropertiesTable(
        for script: GMLuaSoundScript,
        state: LuaState
    ) throws -> LuaTable {
        let table = LuaTable()
        try set(.string(script.name), key: "name", in: table, state: state)
        try set(.number(Double(script.channel)), key: "channel", in: table, state: state)
        try set(.number(script.level), key: "level", in: table, state: state)
        try set(try luaValue(for: script.volume, state: state), key: "volume", in: table, state: state)
        try set(try luaValue(for: script.pitch, state: state), key: "pitch", in: table, state: state)
        try set(.number(script.pitchStart), key: "pitchstart", in: table, state: state)
        try set(.number(script.pitchEnd), key: "pitchend", in: table, state: state)
        switch script.sound {
        case let .single(source):
            try set(.string(source), key: "sound", in: table, state: state)
        case let .choices(choices):
            let values = LuaTable()
            for (offset, choice) in choices.enumerated() {
                try state.setRawTableValue(
                    .string(choice),
                    for: .number(Double(offset + 1)),
                    in: values
                )
            }
            try set(.table(values), key: "sound", in: table, state: state)
        }
        return table
    }

    private static func luaValue(
        for value: GMLuaSoundScalarOrRange,
        state: LuaState
    ) throws -> LuaValue {
        switch value {
        case let .scalar(number):
            return .number(number)
        case let .range(lower, upper):
            let table = LuaTable()
            try state.setRawTableValue(.number(lower), for: .number(1), in: table)
            try state.setRawTableValue(.number(upper), for: .number(2), in: table)
            return .table(table)
        }
    }

    private static func scalarOrRangeField(
        _ name: String,
        in table: LuaTable,
        state: LuaState,
        default defaultValue: Double
    ) throws -> GMLuaSoundScalarOrRange {
        let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
        if case .nilValue = value { return .scalar(defaultValue) }
        if case let .table(range) = value {
            let lower = try requiredNumber(
                try state.rawTableValue(for: .number(1), in: range),
                description: "field '\(name)'[1]",
                function: "sound.Add"
            )
            let upper = try requiredNumber(
                try state.rawTableValue(for: .number(2), in: range),
                description: "field '\(name)'[2]",
                function: "sound.Add"
            )
            return .range(lower, upper)
        }
        return .scalar(try requiredNumber(value, description: "field '\(name)'", function: "sound.Add"))
    }

    private static func requiredStringField(
        _ name: String,
        in table: LuaTable,
        state: LuaState,
        function: String
    ) throws -> LuaString {
        let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
        guard case let .string(string) = value else {
            throw LuaError.runtime("bad field '\(name)' to '\(function)' (string expected, got \(value.typeName))")
        }
        return string
    }

    private static func optionalNumberField(
        _ name: String,
        in table: LuaTable,
        state: LuaState,
        default defaultValue: Double
    ) throws -> Double {
        let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
        if case .nilValue = value { return defaultValue }
        return try requiredNumber(value, description: "field '\(name)'", function: "sound.Add")
    }

    private static func requiredNumber(
        _ value: LuaValue,
        description: String,
        function: String
    ) throws -> Double {
        let number: Double?
        switch value {
        case let .number(candidate): number = candidate
        case let .string(candidate): number = Double(candidate.utf8String)
        default: number = nil
        }
        guard let number, number.isFinite else {
            throw LuaError.runtime("bad \(description) to '\(function)' (number expected, got \(value.typeName))")
        }
        return number
    }

    private static func exactInt(_ number: Double, field: String, function: String) throws -> Int {
        let truncated = number.rounded(.towardZero)
        let lowerBoundInclusive = Double(Int.min)
        let upperBoundExclusive = -lowerBoundInclusive
        guard truncated == number,
              truncated >= lowerBoundInclusive,
              truncated < upperBoundExclusive else {
            throw LuaError.runtime("bad field '\(field)' to '\(function)' (integer out of range)")
        }
        return Int(truncated)
    }

    private static func installFunction(
        _ name: String,
        into table: LuaTable,
        state: LuaState,
        body: @escaping LuaNativeFunction
    ) throws {
        try state.setRawTableValue(
            .nativeFunction(LuaNativeFunctionBox(body, debugName: "sound.\(name)")),
            for: .string(LuaString(name)),
            in: table
        )
    }

    private static func set(
        _ value: LuaValue,
        key: String,
        in table: LuaTable,
        state: LuaState
    ) throws {
        try state.setRawTableValue(value, for: .string(LuaString(key)), in: table)
    }

    private static func tableArgument(
        _ arguments: [LuaValue],
        at index: Int,
        function: String
    ) throws -> LuaTable {
        guard arguments.indices.contains(index) else {
            throw badArgument(index + 1, function: function, expected: "table", actual: "no value")
        }
        guard case let .table(value) = arguments[index] else {
            throw badArgument(index + 1, function: function, expected: "table", actual: arguments[index].typeName)
        }
        return value
    }

    private static func stringArgument(
        _ arguments: [LuaValue],
        at index: Int,
        function: String
    ) throws -> LuaString {
        guard arguments.indices.contains(index) else {
            throw badArgument(index + 1, function: function, expected: "string", actual: "no value")
        }
        guard case let .string(value) = arguments[index] else {
            throw badArgument(index + 1, function: function, expected: "string", actual: arguments[index].typeName)
        }
        return value
    }

    private static func optionalNumber(
        _ arguments: [LuaValue],
        at index: Int,
        default defaultValue: Double,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index) else { return defaultValue }
        if case .nilValue = arguments[index] { return defaultValue }
        return try requiredNumber(
            arguments[index],
            description: "argument #\(index + 1)",
            function: function
        )
    }

    private static func badArgument(
        _ position: Int,
        function: String,
        expected: String,
        actual: String
    ) -> LuaError {
        .runtime("bad argument #\(position) to '\(function)' (\(expected) expected, got \(actual))")
    }
}

import Foundation
import GModLua

/// Value-only copy of a GLua Color table at the instant `chat.AddText` is
/// called. Optional channels preserve malformed/mutated Color tables without
/// retaining the originating Lua table or inventing renderer defaults.
public struct GMLuaChatColorSnapshot: Sendable, Equatable {
    public let r: Double?
    public let g: Double?
    public let b: Double?
    public let a: Double?

    public init(r: Double?, g: Double?, b: Double?, a: Double?) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// Portable identity for a Player argument. The host can resolve the
/// index to a current player name/team color when it eventually renders the
/// event; the Lua userdata itself never crosses or outlives its state.
public struct GMLuaChatPlayerSnapshot: Sendable, Equatable {
    public let index: Int?
    public let metaName: String
    public let wasValid: Bool

    public init(index: Int?, metaName: String, wasValid: Bool) {
        self.index = index
        self.metaName = metaName
        self.wasValid = wasValid
    }
}

/// One argument supplied to `chat.AddText`, kept in original order.
///
/// Color, text and Player values stay logical so an embedding host can
/// apply GMod's presentation rules. Other values use the Lua state's actual
/// `tostring` result, as documented by Facepunch, while recording their source
/// type for diagnostics. No case retains a Lua table, function or userdata.
public enum GMLuaChatArgumentSnapshot: Sendable, Equatable {
    case color(GMLuaChatColorSnapshot)
    case text(LuaString)
    case player(GMLuaChatPlayerSnapshot)
    case convertedText(sourceType: String, text: LuaString)
}

/// A single local chat-box request emitted by Lua.
public struct GMLuaChatEvent: Sendable, Equatable {
    public let realm: GMLuaRealm
    public let arguments: [GMLuaChatArgumentSnapshot]

    public init(realm: GMLuaRealm, arguments: [GMLuaChatArgumentSnapshot]) {
        self.realm = realm
        self.arguments = arguments
    }
}

public typealias GMLuaChatEventSink = @Sendable (GMLuaChatEvent) -> Void

/// Native logical substrate for `chat.AddText`.
///
/// This deliberately does not render a chat HUD. It records immutable events
/// and optionally forwards them to a host-owned sink. The desktop API is
/// CLIENT-only; SERVER and MENU receive no synthetic `chat` installation.
public final class GMLuaChat: @unchecked Sendable {
    public let realm: GMLuaRealm

    private let lock = NSLock()
    private var eventStorage: [GMLuaChatEvent] = []
    private var sinkStorage: GMLuaChatEventSink?

    private init(realm: GMLuaRealm, sink: GMLuaChatEventSink?) {
        self.realm = realm
        sinkStorage = sink
    }

    public var capturedEvents: [GMLuaChatEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    public func drainCapturedEvents() -> [GMLuaChatEvent] {
        lock.lock()
        defer { lock.unlock() }
        let drained = eventStorage
        eventStorage.removeAll(keepingCapacity: true)
        return drained
    }

    public func connectSink(_ sink: @escaping GMLuaChatEventSink) {
        lock.lock()
        sinkStorage = sink
        lock.unlock()
    }

    public func disconnectSink() {
        lock.lock()
        sinkStorage = nil
        lock.unlock()
    }

    /// Installs `chat.AddText` into CLIENT. Returning nil for SERVER or MENU
    /// is intentional and preserves the public realm boundary.
    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        entityRegistry: GMLuaEntityRegistry? = nil,
        sink: GMLuaChatEventSink? = nil
    ) throws -> GMLuaChat? {
        guard realm == .client else { return nil }

        let bridge = GMLuaChat(realm: realm, sink: sink)
        let chatTable: LuaTable
        if case let .table(existing) = state.getGlobal("chat") {
            chatTable = existing
        } else {
            chatTable = LuaTable()
        }

        let addText = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [unowned state, weak entityRegistry, bridge] arguments in
                    try bridge.capture(
                        arguments,
                        state: state,
                        entityRegistry: entityRegistry
                    )
                    return []
                },
                debugName: "chat.AddText"
            )
        )
        try state.setRawTableValue(
            addText,
            for: .string("AddText"),
            in: chatTable
        )
        state.setGlobal("chat", value: .table(chatTable))
        return bridge
    }

    private func capture(
        _ arguments: [LuaValue],
        state: LuaState,
        entityRegistry: GMLuaEntityRegistry?
    ) throws {
        let snapshots = try arguments.map {
            try snapshot($0, state: state, entityRegistry: entityRegistry)
        }
        let event = GMLuaChatEvent(realm: realm, arguments: snapshots)

        let sink: GMLuaChatEventSink?
        lock.lock()
        eventStorage.append(event)
        sink = sinkStorage
        lock.unlock()

        // A host is allowed to call back into its own UI/event machinery. Never
        // hold the bridge lock while invoking it.
        sink?(event)
    }

    private func snapshot(
        _ value: LuaValue,
        state: LuaState,
        entityRegistry: GMLuaEntityRegistry?
    ) throws -> GMLuaChatArgumentSnapshot {
        if case let .string(text) = value {
            return .text(text)
        }

        if case let .table(table) = value,
           try isRegisteredColor(table, state: state) {
            return .color(
                GMLuaChatColorSnapshot(
                    r: try numericColorField("r", in: table, state: state),
                    g: try numericColorField("g", in: table, state: state),
                    b: try numericColorField("b", in: table, state: state),
                    a: try numericColorField("a", in: table, state: state)
                )
            )
        }

        if let object = GMLuaTypeSystem.typedObject(from: value),
           object.typeID == GMLuaTypeID.entity,
           object.metaName == "Player" {
            let index = entityRegistry.flatMap {
                try? $0.networkIndex(from: value, function: "chat.AddText")
            }
            return .player(
                GMLuaChatPlayerSnapshot(
                    index: index,
                    metaName: object.metaName,
                    wasValid: object.isValid
                )
            )
        }

        let tostring = state.getGlobal("tostring")
        guard tostring.typeName == "function" else {
            throw LuaError.runtime(
                "chat.AddText cannot convert \(value.typeName): tostring is unavailable"
            )
        }
        let converted = try state.call(tostring, arguments: [value]).first ?? .nilValue
        guard case let .string(text) = converted else {
            throw LuaError.runtime("chat.AddText tostring result must be a string")
        }
        return .convertedText(sourceType: value.typeName, text: text)
    }

    private func isRegisteredColor(
        _ table: LuaTable,
        state: LuaState
    ) throws -> Bool {
        guard let metatable = table.metatable else { return false }
        let metaName = try state.rawTableValue(
            for: .string("MetaName"),
            in: metatable
        )
        guard case let .string(name) = metaName else { return false }
        return name == LuaString("Color")
    }

    private func numericColorField(
        _ name: String,
        in table: LuaTable,
        state: LuaState
    ) throws -> Double? {
        let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
        switch value {
        case let .number(number):
            return number
        case let .string(string):
            return Double(string.utf8String)
        default:
            return nil
        }
    }
}

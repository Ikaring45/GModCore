import Foundation
import GModLua

public enum GMLuaHostSessionKind: String, Sendable, Equatable {
    case singlePlayer
    case listenServer
    case dedicatedServer
}

public enum GMLuaGameEnvironmentConfigurationError: Error, CustomStringConvertible, Equatable {
    case invalidMaxPlayers(Int)
    case invalidMapName(String)
    case invalidHostName(String)

    public var description: String {
        switch self {
        case let .invalidMaxPlayers(value):
            return "maxPlayers must be a positive integer exactly representable by Lua: \(value)"
        case let .invalidMapName(value):
            return "mapName must be a non-empty logical map name without a path or .bsp suffix: \(value)"
        case let .invalidHostName(value):
            return "hostName must be a non-empty host-supplied string without NUL bytes: \(value)"
        }
    }
}

/// Host-owned facts about the currently running Source session.
///
/// These values cannot be inferred from Lua source or an installed GMod tree.
/// A real app host must supply them when a session is created. The headless
/// conformance executable supplies its own clearly-labelled deterministic
/// fixture instead of pretending to have queried a live Source engine.
public struct GMLuaGameEnvironmentConfiguration: Sendable, Equatable {
    public let maxPlayers: Int
    public let mapName: String
    public let sessionKind: GMLuaHostSessionKind
    public let hostName: String

    public init(
        maxPlayers: Int,
        mapName: String,
        sessionKind: GMLuaHostSessionKind,
        hostName: String
    ) throws {
        // Lua 5.1 numbers are IEEE-754 doubles. Reject values that would be
        // rounded at the native boundary even though real server limits are
        // many orders of magnitude smaller.
        guard maxPlayers > 0, maxPlayers <= 9_007_199_254_740_991 else {
            throw GMLuaGameEnvironmentConfigurationError.invalidMaxPlayers(maxPlayers)
        }
        let trimmedMapName = mapName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMapName.isEmpty,
              trimmedMapName == mapName,
              !mapName.contains("/"),
              !mapName.contains("\\"),
              !mapName.contains("\0"),
              !mapName.lowercased().hasSuffix(".bsp") else {
            throw GMLuaGameEnvironmentConfigurationError.invalidMapName(mapName)
        }
        let trimmedHostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHostName.isEmpty,
              !hostName.contains("\0") else {
            throw GMLuaGameEnvironmentConfigurationError.invalidHostName(hostName)
        }
        self.maxPlayers = maxPlayers
        self.mapName = mapName
        self.sessionKind = sessionKind
        self.hostName = hostName
    }

    public var isSinglePlayer: Bool { sessionKind == .singlePlayer }
    public var isDedicatedServer: Bool { sessionKind == .dedicatedServer }
}

/// Live host connection behind GLua's pure session-query functions.
///
/// The environment begins disconnected unless a configuration was supplied
/// to `GMLuaRuntime`. That is the intentional iPad boundary: calls fail with a
/// precise error until the app's future game-session host connects real data.
/// Connection changes are visible to already-created Lua closures.
public final class GMLuaGameEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var configurationStorage: GMLuaGameEnvironmentConfiguration?

    fileprivate init(initialConfiguration: GMLuaGameEnvironmentConfiguration?) {
        configurationStorage = initialConfiguration
    }

    public var configuration: GMLuaGameEnvironmentConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configurationStorage
    }

    public func connect(_ configuration: GMLuaGameEnvironmentConfiguration) {
        lock.lock()
        configurationStorage = configuration
        lock.unlock()
    }

    public func disconnect() {
        lock.lock()
        configurationStorage = nil
        lock.unlock()
    }

    fileprivate func requiredConfiguration(
        for functionName: String
    ) throws -> GMLuaGameEnvironmentConfiguration {
        guard let configuration else {
            throw LuaError.runtime(
                "\(functionName) is unavailable because no host game environment is connected"
            )
        }
        return configuration
    }

    @discardableResult
    static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        initialConfiguration: GMLuaGameEnvironmentConfiguration?
    ) throws -> GMLuaGameEnvironment {
        let environment = GMLuaGameEnvironment(
            initialConfiguration: initialConfiguration
        )
        let gameTable: LuaTable
        if case let .table(existing) = state.getGlobal("game") {
            gameTable = existing
        } else {
            gameTable = LuaTable()
        }

        func set(_ name: String, _ body: @escaping LuaNativeFunction) throws {
            try state.setRawTableValue(
                .nativeFunction(LuaNativeFunctionBox(
                    body,
                    debugName: "game.\(name)"
                )),
                for: .string(LuaString(name)),
                in: gameTable
            )
        }

        try set("MaxPlayers") { [environment] _ in
            let configuration = try environment.requiredConfiguration(
                for: "game.MaxPlayers"
            )
            return [.number(Double(configuration.maxPlayers))]
        }
        try set("GetMap") { [environment] _ in
            // Desktop GMod documents this realm-specific result even when no
            // gameplay session is attached to the menu state.
            if realm == .menu { return [.string("menu")] }
            let configuration = try environment.requiredConfiguration(
                for: "game.GetMap"
            )
            return [.string(LuaString(configuration.mapName))]
        }
        try set("SinglePlayer") { [environment] _ in
            let configuration = try environment.requiredConfiguration(
                for: "game.SinglePlayer"
            )
            return [.boolean(configuration.isSinglePlayer)]
        }
        try set("IsDedicated") { [environment] _ in
            let configuration = try environment.requiredConfiguration(
                for: "game.IsDedicated"
            )
            return [.boolean(configuration.isDedicatedServer)]
        }

        state.register("GetHostName") { [environment] _ in
            let configuration = try environment.requiredConfiguration(
                for: "GetHostName"
            )
            return [.string(LuaString(configuration.hostName))]
        }

        state.setGlobal("game", value: .table(gameTable))
        return environment
    }
}

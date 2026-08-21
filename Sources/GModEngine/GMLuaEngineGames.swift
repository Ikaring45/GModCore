import Foundation
import GModLua

public enum GMLuaMountedGameError: Error, CustomStringConvertible, Equatable {
    case invalidDepot(Int)
    case invalidTitle(String)
    case invalidFolder(String)

    public var description: String {
        switch self {
        case let .invalidDepot(value):
            return "depot must be a positive integer exactly representable by Lua: \(value)"
        case let .invalidTitle(value):
            return "title must contain a non-empty, NUL-free display name: \(value)"
        case let .invalidFolder(value):
            return "folder must be a non-empty logical mounted-game folder name: \(value)"
        }
    }
}

/// One host-reported entry returned by GLua's `engine.GetGames()`.
///
/// These are Steam/install/mount facts. They cannot be derived from the Lua
/// source tree, and the booleans deliberately have no inferred relationship:
/// the host is responsible for reporting the state observed from its content
/// mounting layer.
public struct GMLuaMountedGame: Sendable, Equatable {
    public let depot: Int
    public let title: String
    public let folder: String
    public let owned: Bool
    public let installed: Bool
    public let mounted: Bool

    public init(
        depot: Int,
        title: String,
        folder: String,
        owned: Bool,
        installed: Bool,
        mounted: Bool
    ) throws {
        guard depot > 0, depot <= 9_007_199_254_740_991 else {
            throw GMLuaMountedGameError.invalidDepot(depot)
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.contains("\0") else {
            throw GMLuaMountedGameError.invalidTitle(title)
        }
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolder.isEmpty,
              trimmedFolder == folder,
              !folder.contains("/"),
              !folder.contains("\\"),
              !folder.contains("\0") else {
            throw GMLuaMountedGameError.invalidFolder(folder)
        }

        self.depot = depot
        self.title = title
        self.folder = folder
        self.owned = owned
        self.installed = installed
        self.mounted = mounted
    }
}

/// One host-reported Workshop/GMA entry returned by `engine.GetAddons()`.
/// The eight fields mirror the public engine ABI; an empty host snapshot is a
/// truthful no-addons result, while a disconnected registry still fails.
public struct GMLuaMountedAddon: Sendable, Equatable {
    public let downloaded: Bool
    public let models: Int
    public let title: String
    public let file: String
    public let mounted: Bool
    public let workshopID: String
    public let size: Int
    public let updated: Int

    public init(
        downloaded: Bool,
        models: Int,
        title: String,
        file: String,
        mounted: Bool,
        workshopID: String,
        size: Int,
        updated: Int
    ) {
        self.downloaded = downloaded
        self.models = models
        self.title = title
        self.file = file
        self.mounted = mounted
        self.workshopID = workshopID
        self.size = size
        self.updated = updated
    }
}

/// Host-owned snapshot used by native, read-only `engine` queries.
///
/// Passing an empty snapshot is meaningful and reports that the connected
/// host found no mountable games. Passing no configuration at all leaves the
/// registry disconnected, which is intentionally distinguishable on iPad.
/// Demo state lives in this same snapshot because ownership/mount state and
/// demo state are both facts of the live native engine connection; neither can
/// be inferred faithfully from the installed Lua filesystem.
public struct GMLuaEngineConfiguration: Sendable, Equatable {
    public let games: [GMLuaMountedGame]
    public let addons: [GMLuaMountedAddon]
    public let isPlayingDemo: Bool
    public let isRecordingDemo: Bool

    public init(
        games: [GMLuaMountedGame],
        addons: [GMLuaMountedAddon] = [],
        isPlayingDemo: Bool,
        isRecordingDemo: Bool
    ) {
        self.games = games
        self.addons = addons
        self.isPlayingDemo = isPlayingDemo
        self.isRecordingDemo = isRecordingDemo
    }
}

/// Live host boundary behind GLua's read-only engine queries.
///
/// A returned Lua array is rebuilt on every call. Lua code can therefore edit
/// its result without mutating the host snapshot or a later call's result.
/// `GetGames` is installed in every gameplay realm. Demo playback and capture
/// are client-driven, so their query functions are installed only on the
/// CLIENT/MENU surface and are deliberately absent from SERVER.
public final class GMLuaEngineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var configurationStorage: GMLuaEngineConfiguration?

    fileprivate init(initialConfiguration: GMLuaEngineConfiguration?) {
        configurationStorage = initialConfiguration
    }

    public var configuration: GMLuaEngineConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configurationStorage
    }

    public func connect(_ configuration: GMLuaEngineConfiguration) {
        lock.lock()
        configurationStorage = configuration
        lock.unlock()
    }

    public func disconnect() {
        lock.lock()
        configurationStorage = nil
        lock.unlock()
    }

    private func requiredConfiguration(
        for functionName: String
    ) throws -> GMLuaEngineConfiguration {
        lock.lock()
        let configuration = configurationStorage
        lock.unlock()
        guard let configuration else {
            throw LuaError.runtime(
                "\(functionName) is unavailable because no host engine registry is connected"
            )
        }
        return configuration
    }

    @discardableResult
    static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        initialConfiguration: GMLuaEngineConfiguration?
    ) throws -> GMLuaEngineRegistry {
        let registry = GMLuaEngineRegistry(
            initialConfiguration: initialConfiguration
        )
        let engineTable: LuaTable
        if case let .table(existing) = state.getGlobal("engine") {
            engineTable = existing
        } else {
            engineTable = LuaTable()
        }

        let getGames = LuaNativeFunctionBox(
            { [unowned state, registry] _ in
                let games = try registry.requiredConfiguration(
                    for: "engine.GetGames"
                ).games
                let result = LuaTable()
                for (offset, game) in games.enumerated() {
                    let entry = LuaTable()
                    try state.setRawTableValue(
                        .number(Double(game.depot)),
                        for: .string("depot"),
                        in: entry
                    )
                    try state.setRawTableValue(
                        .string(LuaString(game.title)),
                        for: .string("title"),
                        in: entry
                    )
                    try state.setRawTableValue(
                        .string(LuaString(game.folder)),
                        for: .string("folder"),
                        in: entry
                    )
                    try state.setRawTableValue(
                        .boolean(game.owned),
                        for: .string("owned"),
                        in: entry
                    )
                    try state.setRawTableValue(
                        .boolean(game.installed),
                        for: .string("installed"),
                        in: entry
                    )
                    try state.setRawTableValue(
                        .boolean(game.mounted),
                        for: .string("mounted"),
                        in: entry
                    )
                    try state.setRawTableValue(
                        .table(entry),
                        for: .number(Double(offset + 1)),
                        in: result
                    )
                }
                return [.table(result)]
            },
            debugName: "engine.GetGames"
        )
        try state.setRawTableValue(
            .nativeFunction(getGames),
            for: .string("GetGames"),
            in: engineTable
        )

        let getAddons = LuaNativeFunctionBox(
            { [unowned state, registry] _ in
                let addons = try registry.requiredConfiguration(
                    for: "engine.GetAddons"
                ).addons
                let result = LuaTable()
                for (offset, addon) in addons.enumerated() {
                    let entry = LuaTable()
                    for (name, value) in [
                        ("downloaded", LuaValue.boolean(addon.downloaded)),
                        ("models", .number(Double(addon.models))),
                        ("title", .string(LuaString(addon.title))),
                        ("file", .string(LuaString(addon.file))),
                        ("mounted", .boolean(addon.mounted)),
                        ("wsid", .string(LuaString(addon.workshopID))),
                        ("size", .number(Double(addon.size))),
                        ("updated", .number(Double(addon.updated)))
                    ] {
                        try state.setRawTableValue(
                            value,
                            for: .string(LuaString(name)),
                            in: entry
                        )
                    }
                    try state.setRawTableValue(
                        .table(entry),
                        for: .number(Double(offset + 1)),
                        in: result
                    )
                }
                return [.table(result)]
            },
            debugName: "engine.GetAddons"
        )
        try state.setRawTableValue(
            .nativeFunction(getAddons),
            for: .string("GetAddons"),
            in: engineTable
        )

        if realm != .server {
            let isPlayingDemo = LuaNativeFunctionBox(
                { [registry] _ in
                    let configuration = try registry.requiredConfiguration(
                        for: "engine.IsPlayingDemo"
                    )
                    return [.boolean(configuration.isPlayingDemo)]
                },
                debugName: "engine.IsPlayingDemo"
            )
            try state.setRawTableValue(
                .nativeFunction(isPlayingDemo),
                for: .string("IsPlayingDemo"),
                in: engineTable
            )

            let isRecordingDemo = LuaNativeFunctionBox(
                { [registry] _ in
                    let configuration = try registry.requiredConfiguration(
                        for: "engine.IsRecordingDemo"
                    )
                    return [.boolean(configuration.isRecordingDemo)]
                },
                debugName: "engine.IsRecordingDemo"
            )
            try state.setRawTableValue(
                .nativeFunction(isRecordingDemo),
                for: .string("IsRecordingDemo"),
                in: engineTable
            )
        }
        state.setGlobal("engine", value: .table(engineTable))
        return registry
    }
}

import Foundation
import GModLua

public enum GMLuaRealm: String {
    case server = "SERVER"
    case client = "CLIENT"
    case menu = "MENU"
}

public enum GMLuaBootstrapMode: String {
    /// Production/default mode. Missing engine APIs fail at their first use.
    case strict
    /// Diagnostic-only shims used to discover later bootstrap dependencies.
    case discovery
}

public final class GMLuaRuntime {
    typealias TypeSystemInstaller = (LuaState) throws -> GMLuaTypeSystem

    public let realm: GMLuaRealm
    public let bootstrapMode: GMLuaBootstrapMode
    let state: LuaState
    private(set) var typeSystem: GMLuaTypeSystem?
    private let logger: (String) -> Void
    private let fileLoader: ((String) throws -> String)?
    private let virtualFileSystem: LuaVirtualFileSystem?
    private var includedFileStorage: [String] = []
    private var clientLuaFileStorage: [String] = []
    private var consoleCommandStorage: [String] = []
    private var networkStringStorage: [String] = []
    private var compatibilityGapStorage: [String] = []
    private var bootstrapInstallationError: Error?

    public var includedFiles: [String] { includedFileStorage }
    public var clientLuaFiles: [String] { clientLuaFileStorage }
    public var consoleCommands: [String] { consoleCommandStorage }
    public var networkStrings: [String] { networkStringStorage }
    public var compatibilityGaps: [String] { compatibilityGapStorage }

    public convenience init(
        realm: GMLuaRealm,
        logger: @escaping (String) -> Void,
        fileLoader: ((String) throws -> String)? = nil,
        virtualFileSystem: LuaVirtualFileSystem? = nil,
        bootstrapMode: GMLuaBootstrapMode = .strict
    ) {
        self.init(
            realm: realm,
            logger: logger,
            fileLoader: fileLoader,
            virtualFileSystem: virtualFileSystem,
            bootstrapMode: bootstrapMode,
            typeSystemInstaller: { state in
                try GMLuaTypeSystem.install(
                    into: state,
                    utilityLayer: .nativeABIOnly
                )
            }
        )
    }

    init(
        realm: GMLuaRealm,
        logger: @escaping (String) -> Void,
        fileLoader: ((String) throws -> String)? = nil,
        virtualFileSystem: LuaVirtualFileSystem? = nil,
        bootstrapMode: GMLuaBootstrapMode = .strict,
        typeSystemInstaller: @escaping TypeSystemInstaller
    ) {
        self.realm = realm
        self.bootstrapMode = bootstrapMode
        self.logger = logger
        self.fileLoader = fileLoader
        self.virtualFileSystem = virtualFileSystem
        self.state = LuaState(
            output: { message in logger("[\(realm.rawValue)][Lua] \(message)") },
            fileLoader: fileLoader,
            virtualFileSystem: virtualFileSystem
        )
        installGLuaBootstrapSurface(typeSystemInstaller: typeSystemInstaller)
    }

    public func execute(_ source: String, sourceName: String = "=(gmod)") throws {
        try ensureBootstrapInstalled()
        try state.execute(source, sourceName: sourceName)
    }

    @discardableResult
    public func executeReturningValues(
        _ source: String,
        sourceName: String = "=(gmod)"
    ) throws -> [LuaValue] {
        try ensureBootstrapInstalled()
        return try state.executeReturningValues(source, sourceName: sourceName)
    }

    /// Loads a logical path from the mounted GMod filesystem. The source name
    /// remains virtual, so diagnostics never depend on a Windows or iPad path.
    @discardableResult
    public func loadFile(_ path: String) throws -> [LuaValue] {
        try ensureBootstrapInstalled()
        let logicalPath = try normalizeLogicalPath(path)
        let source = try readSource(at: logicalPath)
        return try state.executeReturningValues(source, sourceName: "@\(logicalPath)")
    }

    public static func describe(_ error: Error) -> String {
        if let raised = error as? LuaRaisedError { return raised.value.printable }
        return String(describing: error)
    }

    public static func decodeSource(_ data: Data) -> String? {
        LuaSourceDecoder.decode(data)
    }

    private func installGLuaBootstrapSurface(
        typeSystemInstaller: TypeSystemInstaller
    ) {
        state.setGlobal("SERVER", value: .boolean(realm == .server))
        // Garry's Mod menu Lua has the client-side API surface as well as its
        // menu marker; treating it as a third mutually-exclusive CLIENT=false
        // state incorrectly executes server-only module bodies.
        state.setGlobal("CLIENT", value: .boolean(realm != .server))
        state.setGlobal("MENU", value: .boolean(realm == .menu))
        state.setGlobal("MENU_DLL", value: .boolean(realm == .menu))
        state.setGlobal("__gmod_discovery", value: .boolean(bootstrapMode == .discovery))

        do {
            // Install only GMod's native type/metatable ABI here. The real
            // includes/util.lua must capture Lua 5.1's original `type` before
            // it installs the public GLua type/TypeID/predicate wrappers.
            typeSystem = try typeSystemInstaller(state)
        } catch {
            // Initialization stays source-compatible with existing callers;
            // every execution boundary surfaces the original installer error.
            bootstrapInstallationError = error
            return
        }

        state.register("include") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(requested) = first else {
                throw LuaError.runtime("bad argument #1 to 'include' (string expected)")
            }
            let callerSource = self.state.luaCallerSourceName(level: 2)
            let logicalPath = try self.resolveInclude(
                requested.utf8String,
                callerSourceName: callerSource
            )
            let source = try self.readSource(at: logicalPath)
            self.includedFileStorage.append(logicalPath)
            return try self.state.executeReturningValues(
                source,
                sourceName: "@\(logicalPath)",
                inheritCallerEnvironmentAtLevel: 2
            )
        }

        state.register("AddCSLuaFile") { [unowned self] arguments in
            guard self.realm == .server else { return [] }
            let requested: String
            if let first = arguments.first, case let .string(path) = first {
                requested = path.utf8String
            } else if arguments.isEmpty,
                      let current = self.state.luaCallerSourceName(level: 2) {
                requested = self.stripSourceMarker(current)
            } else {
                throw LuaError.runtime("bad argument #1 to 'AddCSLuaFile' (string expected)")
            }
            let resolved = try self.resolveInclude(
                requested,
                callerSourceName: self.state.luaCallerSourceName(level: 2),
                requireExistingFile: false
            )
            if !self.clientLuaFileStorage.contains(resolved) {
                self.clientLuaFileStorage.append(resolved)
            }
            return []
        }

        state.register("isfunction") { [.boolean($0.first?.typeName == "function")] }
        state.register("isstring") { [.boolean($0.first?.typeName == "string")] }
        state.register("isnumber") { [.boolean($0.first?.typeName == "number")] }
        state.register("istable") { [.boolean($0.first?.typeName == "table")] }
        state.register("isbool") { [.boolean($0.first?.typeName == "boolean")] }
        if bootstrapMode == .discovery {
            state.register("__gmod_MarkCompatibilityGap") { [unowned self] arguments in
                if let first = arguments.first, case let .string(gap) = first {
                    self.markCompatibilityGap(gap.utf8String)
                }
                return []
            }
            state.register("isentity") { [unowned self] _ in
                self.markCompatibilityGap("Entity type checks use discovery objects")
                return [.boolean(false)]
            }
            state.register("IsEntity") { [unowned self] _ in
                self.markCompatibilityGap("Entity type checks use discovery objects")
                return [.boolean(false)]
            }
            state.register("IsValid") { [unowned self] arguments in
                self.markCompatibilityGap("IsValid has no engine lifetime registry")
                guard let first = arguments.first else { return [.boolean(false)] }
                if case .userdata = first { return [.boolean(true)] }
                return [.boolean(false)]
            }
        }

        state.register("Msg") { [unowned self] arguments in
            self.logger("[\(self.realm.rawValue)][Lua] " + arguments.map(\.printable).joined())
            return []
        }
        state.register("MsgN") { [unowned self] arguments in
            self.logger("[\(self.realm.rawValue)][Lua] " + arguments.map(\.printable).joined(separator: "\t"))
            return []
        }
        state.register("ErrorNoHalt") { [unowned self] arguments in
            self.logger("[\(self.realm.rawValue)][Lua][ERROR] " + arguments.map(\.printable).joined())
            return []
        }
        state.register("ErrorNoHaltWithStack") { [unowned self] arguments in
            self.logger("[\(self.realm.rawValue)][Lua][ERROR] " + arguments.map(\.printable).joined())
            return []
        }
        state.register("AddConsoleCommand") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(name) = first else { return [] }
            let command = name.utf8String
            if !self.consoleCommandStorage.contains(command) {
                self.consoleCommandStorage.append(command)
            }
            return []
        }
        if bootstrapMode == .discovery {
            state.register("Material") { [unowned self] arguments in
                self.markCompatibilityGap("Material is placeholder userdata without a Metal resource")
                return [.userdata(LuaUserdata(payload: arguments.first?.printable ?? ""))]
            }
        }
        state.register("__gmod_AddNetworkString") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(name) = first else {
                throw LuaError.runtime("bad argument #1 to 'util.AddNetworkString' (string expected)")
            }
            let value = name.utf8String
            if let existing = self.networkStringStorage.firstIndex(of: value) {
                return [.number(Double(existing + 1))]
            }
            self.networkStringStorage.append(value)
            return [.number(Double(self.networkStringStorage.count))]
        }
        state.register("__gmod_NetworkStringToID") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(name) = first,
                  let index = self.networkStringStorage.firstIndex(of: name.utf8String) else {
                return [.number(0)]
            }
            return [.number(Double(index + 1))]
        }
        state.register("__gmod_NetworkIDToString") { [unowned self] arguments in
            guard let first = arguments.first, case let .number(rawIndex) = first else {
                return [.nilValue]
            }
            let index = Int(rawIndex) - 1
            guard self.networkStringStorage.indices.contains(index) else { return [.nilValue] }
            return [.string(LuaString(self.networkStringStorage[index]))]
        }
        state.register("__gmod_KeyValuesToTable") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(source) = first else {
                throw LuaError.runtime("bad argument #1 to 'util.KeyValuesToTable' (string expected)")
            }
            let usesEscapeSequences = arguments.count > 1 && arguments[1].isTruthy
            let preserveKeyCase = arguments.count > 2 && arguments[2].isTruthy
            var parser = SourceKeyValuesParser(
                source: source.utf8String,
                options: .init(
                    usesEscapeSequences: usesEscapeSequences,
                    preserveKeyCase: preserveKeyCase,
                    preserveConditionals: false
                )
            )
            let entries = try parser.parse()
            return [.table(try self.makeKeyValuesTable(from: self.unwrappedKeyValuesRoot(entries)))]
        }
        state.register("__gmod_KeyValuesToTablePreserveOrder") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(source) = first else {
                throw LuaError.runtime("bad argument #1 to 'util.KeyValuesToTablePreserveOrder' (string expected)")
            }
            let usesEscapeSequences = arguments.count > 1 && arguments[1].isTruthy
            let preserveKeyCase = arguments.count > 2 && arguments[2].isTruthy
            var parser = SourceKeyValuesParser(
                source: source.utf8String,
                options: .init(
                    usesEscapeSequences: usesEscapeSequences,
                    preserveKeyCase: preserveKeyCase,
                    preserveConditionals: true
                )
            )
            let entries = try parser.parse()
            return [.table(try self.makeOrderedKeyValuesTable(from: self.unwrappedKeyValuesRoot(entries)))]
        }
        #if os(Windows)
        let platformIsWindows = true
        let platformIsLinux = false
        #elseif os(Linux)
        let platformIsWindows = false
        let platformIsLinux = true
        #else
        let platformIsWindows = false
        let platformIsLinux = false
        #endif
        #if arch(x86_64)
        let platformArchitecture = "x86_64"
        #elseif arch(i386)
        let platformArchitecture = "x86"
        #elseif arch(arm64)
        let platformArchitecture = "arm64"
        #else
        let platformArchitecture = "unknown"
        #endif
        state.register("__gmod_SystemIsWindows") { _ in [.boolean(platformIsWindows)] }
        state.register("__gmod_SystemIsLinux") { _ in [.boolean(platformIsLinux)] }
        state.setGlobal("__gmod_platform_arch", value: .string(LuaString(platformArchitecture)))

        state.setGlobal("TEAM_CONNECTING", value: .number(0))
        state.setGlobal("TEAM_UNASSIGNED", value: .number(1_001))
        state.setGlobal("TEAM_SPECTATOR", value: .number(1_002))

        // Native package loaders remain first; this adds the canonical GMod
        // Lua-module search location without replacing Lua 5.1 require state.
        do {
            try GMLuaBitLibrary.install(into: state)
            try state.execute(
                #"""
            package.path = "lua/includes/modules/?.lua;lua/?.lua;lua/?/init.lua;" .. package.path

            gmod = gmod or {}
            function gmod.GetGamemode() return GAMEMODE end

            util = util or {}
            util.AddNetworkString = __gmod_AddNetworkString
            util.NetworkStringToID = __gmod_NetworkStringToID
            util.NetworkIDToString = __gmod_NetworkIDToString
            util.KeyValuesToTable = __gmod_KeyValuesToTable
            util.KeyValuesToTablePreserveOrder = __gmod_KeyValuesToTablePreserveOrder
            net = net or {}
            game = game or {}
            file = file or {}
            system = system or {}
            system.IsWindows = __gmod_SystemIsWindows
            system.IsLinux = __gmod_SystemIsLinux
            function system.IsOSX() return not system.IsWindows() and not system.IsLinux() end
            jit = jit or {}
            jit.arch = __gmod_platform_arch
            SENSORBONE = SENSORBONE or {
                HIP = 0, SPINE = 1, SHOULDER = 2, HEAD = 3,
                SHOULDER_LEFT = 4, ELBOW_LEFT = 5, WRIST_LEFT = 6, HAND_LEFT = 7,
                SHOULDER_RIGHT = 8, ELBOW_RIGHT = 9, WRIST_RIGHT = 10, HAND_RIGHT = 11,
                HAND_WRIGHT = 11,
                HIP_LEFT = 12, KNEE_LEFT = 13, ANKLE_LEFT = 14, FOOT_LEFT = 15,
                HIP_RIGHT = 16, KNEE_RIGHT = 17, ANKLE_RIGHT = 18, FOOT_RIGHT = 19
            }
            function tobool(value)
                if value == nil or value == false or value == 0 or value == "0" or value == "false" then return false end
                return true
            end

            if __gmod_discovery then
            ents = ents or {}
            player = player or {}
            surface = surface or {}
            function surface.GetTextureID()
                __gmod_MarkCompatibilityGap("surface.GetTextureID returns a discovery sentinel")
                return 0
            end
            sql = sql or {}
            function sql.Query()
                __gmod_MarkCompatibilityGap("sql.Query is a non-persistent discovery shim")
                return false
            end
            function sql.LastError() return "" end

            local entity_meta = FindMetaTable("Entity")
            local player_meta = FindMetaTable("Player")
            local weapon_meta = FindMetaTable("Weapon")
            local vehicle_meta = FindMetaTable("Vehicle")
            local panel_meta = FindMetaTable("Panel")
            local __gmod_placeholder_meta = {
                Entity = true, Player = true, Weapon = true, Vehicle = true, Panel = true
            }
            local __gmod_FindMetaTable = FindMetaTable
            function FindMetaTable(name)
                local value = __gmod_FindMetaTable(name)
                if value and __gmod_placeholder_meta[name] then
                    __gmod_MarkCompatibilityGap("Entity and Panel metatables use discovery objects")
                end
                return value
            end

            local __gmod_entities = {}
            function Entity(index)
                __gmod_MarkCompatibilityGap("Entity values use discovery objects")
                index = tonumber(index) or 0
                if not __gmod_entities[index] then
                    __gmod_entities[index] = setmetatable({ __entity_index = index }, entity_meta)
                end
                return __gmod_entities[index]
            end
            local vector_meta = FindMetaTable("Vector")
            function Vector(x, y, z)
                __gmod_MarkCompatibilityGap("Vector values use discovery objects")
                return setmetatable({ x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }, vector_meta)
            end

            local angle_meta = FindMetaTable("Angle")
            function Angle(p, y, r)
                __gmod_MarkCompatibilityGap("Angle values use discovery objects")
                return setmetatable({ p = tonumber(p) or 0, y = tonumber(y) or 0, r = tonumber(r) or 0 }, angle_meta)
            end

            local __gmod_convars = {}
            local convar_meta = FindMetaTable("ConVar")
            function convar_meta:GetName() return self.name end
            function convar_meta:GetDefault() return self.default end
            function convar_meta:GetString() return self.value end
            function convar_meta:GetInt() return math.floor(tonumber(self.value) or 0) end
            function convar_meta:GetFloat() return tonumber(self.value) or 0 end
            function convar_meta:GetBool() return tobool(self.value) end
            function convar_meta:SetString(value) self.value = tostring(value) end
            function convar_meta:SetInt(value) self.value = tostring(math.floor(tonumber(value) or 0)) end
            function convar_meta:SetFloat(value) self.value = tostring(tonumber(value) or 0) end
            function convar_meta:SetBool(value) self.value = value and "1" or "0" end
            function CreateConVar(name, default)
                __gmod_MarkCompatibilityGap("ConVar values use discovery objects")
                if __gmod_convars[name] then return __gmod_convars[name] end
                local value = setmetatable({ name = name, default = tostring(default or ""), value = tostring(default or "") }, convar_meta)
                __gmod_convars[name] = value
                return value
            end
            function CreateClientConVar(name, default) return CreateConVar(name, default) end
            function GetConVar(name) return __gmod_convars[name] end
            function ConVarExists(name) return __gmod_convars[name] ~= nil end
            end

            local gmod_file_meta = {}
            gmod_file_meta.__index = gmod_file_meta
            local function gmod_file_path(name, pathID)
                pathID = pathID or "DATA"
                if pathID == "DATA" then return "data/" .. name end
                if pathID == "LUA" then return "lua/" .. name end
                return name
            end
            function file.Open(name, mode, pathID)
                local handle = io.open(gmod_file_path(name, pathID), mode or "rb")
                if not handle then return nil end
                return setmetatable({ handle = handle }, gmod_file_meta)
            end
            function gmod_file_meta:Read(count) return self.handle:read(count) end
            function gmod_file_meta:ReadLine() return self.handle:read("*l") end
            function gmod_file_meta:Write(value) return self.handle:write(value) end
            function gmod_file_meta:Flush() return self.handle:flush() end
            function gmod_file_meta:Close() return self.handle:close() end
            function gmod_file_meta:Tell() return self.handle:seek() end
            function gmod_file_meta:Seek(position) return self.handle:seek("set", position) end
            function gmod_file_meta:Skip(offset) return self.handle:seek("cur", offset) end
            function gmod_file_meta:Size()
                local position = self.handle:seek()
                local size = self.handle:seek("end")
                self.handle:seek("set", position)
                return size
            end
            function gmod_file_meta:EndOfFile() return self:Tell() >= self:Size() end
            function file.Exists(name, pathID)
                local handle = file.Open(name, "rb", pathID)
                if not handle then return false end
                handle:Close()
                return true
            end
            function file.Size(name, pathID)
                local handle = file.Open(name, "rb", pathID)
                if not handle then return -1 end
                local size = handle:Size()
                handle:Close()
                return size
            end
            """#,
                sourceName: "=(GLua bootstrap)"
            )
        } catch {
            // Keep init non-throwing for existing callers, but never continue
            // with a half-installed API surface. The first execution reports
            // the original bootstrap failure instead of a misleading missing
            // global later in the loaded GMod source.
            bootstrapInstallationError = error
        }
    }

    private func ensureBootstrapInstalled() throws {
        if let bootstrapInstallationError { throw bootstrapInstallationError }
    }

    private func readSource(at path: String) throws -> String {
        if let virtualFileSystem, virtualFileSystem.fileExists(at: path) {
            let data = try virtualFileSystem.readFile(at: path)
            guard let source = LuaSourceDecoder.decode(data) else {
                throw LuaError.runtime("cannot decode Lua source: \(path)")
            }
            return source
        }
        if let fileLoader { return try fileLoader(path) }
        throw LuaError.runtime("file not found: \(path)")
    }

    private func resolveInclude(
        _ requestedPath: String,
        callerSourceName: String?,
        requireExistingFile: Bool = true
    ) throws -> String {
        let requested = try normalizeLogicalPath(requestedPath)
        var candidates: [String] = []

        if requested.hasPrefix("lua/") || requested.hasPrefix("gamemodes/") {
            candidates.append(requested)
        } else {
            if let callerSourceName {
                let caller = stripSourceMarker(callerSourceName)
                if let slash = caller.lastIndex(of: "/") {
                    let directory = String(caller[..<slash])
                    if let relative = try? normalizeLogicalPath(directory + "/" + requested) {
                        candidates.append(relative)
                    }
                }
            }
            candidates.append("lua/" + requested)
            candidates.append(requested)
        }

        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) { unique.append(candidate) }
        if !requireExistingFile { return unique.first ?? requested }
        for candidate in unique where virtualFileSystem?.fileExists(at: candidate) == true {
            return candidate
        }
        if virtualFileSystem == nil, let fileLoader {
            for candidate in unique {
                if (try? fileLoader(candidate)) != nil { return candidate }
            }
        }
        throw LuaError.runtime("include file not found: \(requestedPath)")
    }

    private func normalizeLogicalPath(_ path: String) throws -> String {
        try GMLuaMountedFileSystem.normalize(path, allowEmpty: false)
    }

    private func stripSourceMarker(_ sourceName: String) -> String {
        sourceName.hasPrefix("@") ? String(sourceName.dropFirst()) : sourceName
    }

    private func markCompatibilityGap(_ gap: String) {
        guard bootstrapMode == .discovery, !compatibilityGapStorage.contains(gap) else { return }
        compatibilityGapStorage.append(gap)
    }

    private func unwrappedKeyValuesRoot(
        _ entries: [SourceKeyValuesParser.Entry]
    ) -> [SourceKeyValuesParser.Entry] {
        guard entries.count == 1, case let .object(children) = entries[0].value else {
            return entries
        }
        return children
    }

    private func makeKeyValuesTable(
        from entries: [SourceKeyValuesParser.Entry]
    ) throws -> LuaTable {
        let table = LuaTable()
        for entry in entries {
            let value: LuaValue
            switch entry.value {
            case let .string(string): value = .string(LuaString(string))
            case let .object(children): value = .table(try makeKeyValuesTable(from: children))
            }
            let key: LuaValue
            if let numeric = Double(entry.key), numeric.isFinite {
                key = .number(numeric)
            } else {
                key = .string(LuaString(entry.key))
            }
            // Normal Lua tables cannot represent repeated keys. Source/GMod
            // semantics keep the last occurrence, so later entries overwrite.
            try state.setRawTableValue(value, for: key, in: table)
        }
        return table
    }

    private func makeOrderedKeyValuesTable(
        from entries: [SourceKeyValuesParser.Entry]
    ) throws -> LuaTable {
        let result = LuaTable()
        for (index, entry) in entries.enumerated() {
            let pair = LuaTable()
            try state.setRawTableValue(
                .string(LuaString(entry.key)),
                for: .string("Key"),
                in: pair
            )
            let value: LuaValue
            switch entry.value {
            case let .string(string): value = .string(LuaString(string))
            case let .object(children): value = .table(try makeOrderedKeyValuesTable(from: children))
            }
            try state.setRawTableValue(value, for: .string("Value"), in: pair)
            if let conditional = entry.conditional {
                try state.setRawTableValue(
                    .string(LuaString(conditional)),
                    for: .string("Conditional"),
                    in: pair
                )
            }
            try state.setRawTableValue(.table(pair), for: .number(Double(index + 1)), in: result)
        }
        return result
    }

    /// Broad runtime smoke test. This is intentionally much wider than the old
    /// phase-by-phase tests and exercises the Lua 5.1 runtime as one subsystem.
    public static func lua51ComprehensiveSmokeTest() -> String {
        var lines: [String] = []
        let files: [String: String] = [
            "gmod_test_module.lua": "return { value = 77 }"
        ]

        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { lines.append($0) },
            fileLoader: { path in
                if let source = files[path] { return source }
                throw LuaError.runtime("file not found: \(path)")
            }
        )

        do {
            try runtime.execute(
                #"""
                print("Lua", _VERSION)

                -- arithmetic / control flow / GLua aliases
                local total = 0
                for i = 1, 10 do
                    if i % 2 == 0 && !false then
                        total = total + i
                    end
                end
                print("control", total, 2 + 3 * 4, 2^3^2)

                local i, acc = 0, 0
                while i < 5 do
                    i = i + 1
                    if i == 3 then continue end
                    acc = acc + i
                end
                repeat acc = acc - 1 until acc <= 10
                print("loops", acc)

                -- multiple return / vararg / pcall
                local function vararg(...)
                    return select("#", ...), ...
                end
                local ok, n, a, b, c = pcall(vararg, 10, 20, 30)
                print("vararg", ok, n, a, b, c)

                -- table / closure / method
                local object = { value = 40 }
                function object:Add(x) return self.value + x end
                local function counter()
                    local n = 0
                    return function() n = n + 1; return n end
                end
                local nextCount = counter()
                print("object", object:Add(2), nextCount(), nextCount())

                -- metatables
                local mt = {}
                mt.__add = function(a,b) return a.v + b.v end
                mt.__lt = function(a,b) return a.v < b.v end
                mt.__concat = function(a,b) return a.v .. b.v end
                mt.__call = function(a,x) return a.v + x end
                mt.__tostring = function(a) return "OBJ:" .. a.v end
                local ma = setmetatable({v=3}, mt)
                local mb = setmetatable({v=4}, mt)
                print("meta", ma+mb, ma<mb, ma..mb, ma(9), tostring(ma))

                -- environments
                local function envtest() return X end
                local env = { X = 55 }
                setmetatable(env, { __index = _G })
                setfenv(envtest, env)
                print("env", envtest(), getfenv(envtest) == env)

                -- load / dump round trip in this runtime
                local loaded = assert(loadstring("return 20+22"))
                print("load", loaded())
                local function twice(x) return x*2 end
                local dumped = string.dump(twice)
                print("dump", assert(loadstring(dumped))(21))

                -- coroutine with nested yield
                local function foo(a) return coroutine.yield(2*a) end
                local co = coroutine.create(function(a,b)
                    local r = foo(a+1)
                    local r2,s2 = coroutine.yield(a+b, a-b)
                    return b, "end", r, r2, s2
                end)
                print("co1", coroutine.resume(co, 1, 10))
                print("co2", coroutine.resume(co, "r"))
                print("co3", coroutine.resume(co, "x", "y"))
                print("co4", coroutine.resume(co))

                -- Lua patterns
                local s = "abc 123 def 456"
                print("pattern-find", string.find(s, "%d+"))
                print("pattern-match", string.match(s, "(%a+)%s+(%d+)"))
                local g = string.gmatch("a1 b22", "(%a)(%d+)")
                print("pattern-g1", g())
                print("pattern-g2", g())
                print("pattern-sub", string.gsub("hello 123", "%d", "X"))
                print("pattern-bal", string.match("x(a(b)c)y", "%b()"))

                -- package / require
                package.path = "?.lua"
                local mod = require("gmod_test_module")
                print("require", mod.value, require("gmod_test_module") == mod)

                package.preload["inline_module"] = function(name)
                    module(name, package.seeall)
                    VALUE = 88
                    TYPE_OF_PRINT = type(print)
                end
                local inline = require("inline_module")
                print("module", inline.VALUE, inline.TYPE_OF_PRINT)

                -- standard libraries
                print("math", math.floor(3.9), math.fmod(7,4), math.max(2,9,4))
                local t={3,1,2}; table.sort(t)
                print("table", table.concat(t,","), table.maxn(t))
                print("string", ("AbC"):lower(), string.reverse("abc"), string.format("%04d %.1f",7,2.25))
                print("bytes", string.byte(string.char(65,0,66),1,3))

                -- userdata proxy / debug surface
                local u = newproxy(true)
                print("userdata", type(u), type(getmetatable(u)))
                local info = debug.getinfo(function() return 1 end)
                print("debug", type(info), type(debug.traceback()))

                -- protected errors
                local ok2, err2 = xpcall(function() error("boom") end, function(e) return "handled:" .. e end)
                print("error", ok2, err2)

                // GLua comment syntax is deliberately accepted by GModLua.
                /* GLua block comments are accepted too. */
                """#,
                sourceName: "@lua51-comprehensive-smoke.lua"
            )
        } catch {
            lines.append("[SERVER][Lua][FATAL] \(error)")
        }

        return lines.joined(separator: "\n")
    }
}

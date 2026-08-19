import Foundation
import GModLua

public enum GMLuaGamemodeLoadPhase: String, Sendable, Equatable {
    case entry
    case registration
}

public enum GMLuaGamemodeLoaderError: Error, CustomStringConvertible {
    case runtimeUnavailable
    case invalidName(String)
    case unknownManifest(name: String, path: String)
    case invalidManifest(name: String, path: String, reason: String)
    case inheritanceCycle([String])
    case missingEntry(name: String, path: String, realm: GMLuaRealm)
    case baseStageRequired(String)
    case registrationUnavailable(String)
    case partialLoad(
        name: String,
        path: String,
        phase: GMLuaGamemodeLoadPhase,
        registered: [String],
        reason: String
    )

    public var description: String {
        switch self {
        case .runtimeUnavailable:
            return "gamemode loader runtime is no longer available"
        case let .invalidName(name):
            return "invalid gamemode name or path traversal: \(name)"
        case let .unknownManifest(name, path):
            return "unknown gamemode '\(name)' (manifest not found: \(path))"
        case let .invalidManifest(name, path, reason):
            return "invalid gamemode manifest for '\(name)' at \(path): \(reason)"
        case let .inheritanceCycle(chain):
            return "gamemode inheritance cycle: \(chain.joined(separator: " -> "))"
        case let .missingEntry(name, path, realm):
            return "gamemode '\(name)' has no \(realm.rawValue) entry file: \(path)"
        case let .baseStageRequired(name):
            return "cannot load target gamemode '\(name)' before the base gamemode stage"
        case let .registrationUnavailable(reason):
            return "gamemode.Register is unavailable: \(reason)"
        case let .partialLoad(name, path, phase, registered, reason):
            let completed = registered.isEmpty ? "<none>" : registered.joined(separator: ",")
            return "partial gamemode load for '\(name)' during \(phase.rawValue) at \(path) " +
                "(registered: \(completed)): \(reason)"
        }
    }
}

public struct GMLuaGamemodeLoadReport: Sendable, Equatable {
    public let requestedName: String
    public let loadOrder: [String]
    public let newlyLoaded: [String]
    public let entryPaths: [String]

    /// Autorun and addon discovery are separate engine lifecycle stages. This
    /// loader deliberately does not claim to have executed either one.
    public let autorunLoaded: Bool
    public let addonsLoaded: Bool
}

/// Host-owned production boundary for loading one active gamemode hierarchy.
///
/// Manifests and entries come only from the mounted VFS. The complete chain is
/// validated before Lua execution, then registered base-first through the real
/// `gamemode.Register` function using `LuaState.call`.
public final class GMLuaGamemodeLoader {
    private struct Manifest {
        let name: String
        let base: String
        let path: String
        let entryPath: String
    }

    private struct Record {
        let value: LuaValue
        let manifest: Manifest
        let chain: [String]
    }

    private weak var runtime: GMLuaRuntime?
    private let fileSystem: LuaVirtualFileSystem
    private var records: [String: Record] = [:]
    private var registrationOrder: [String] = []

    public init(runtime: GMLuaRuntime, fileSystem: LuaVirtualFileSystem) {
        self.runtime = runtime
        self.fileSystem = fileSystem
    }

    public var loadedGamemodeNames: [String] { registrationOrder }

    public func gamemode(named rawName: String) -> LuaValue? {
        guard let name = try? Self.normalizedName(rawName) else { return nil }
        return records[name]?.value
    }

    /// Loads and activates the engine's always-present base gamemode stage.
    /// Repeated calls are safe and return a report whose `newlyLoaded` list is
    /// empty after the first successful registration.
    @discardableResult
    public func loadBaseGamemode() throws -> GMLuaGamemodeLoadReport {
        try loadGamemode(named: "base")
    }

    /// Loads the selected gamemode after the explicit base/autorun boundary.
    ///
    /// `loadGamemode(named:)` remains the compatibility API which can resolve
    /// an entire hierarchy in one operation. Startup orchestration uses this
    /// staged entry point so a target such as Sandbox cannot accidentally run
    /// before autorun, and the already registered Base record is not executed
    /// a second time.
    @discardableResult
    public func loadTargetGamemode(
        named rawName: String
    ) throws -> GMLuaGamemodeLoadReport {
        let name = try Self.normalizedName(rawName)
        guard records["base"] != nil else {
            throw GMLuaGamemodeLoaderError.baseStageRequired(name)
        }
        return try loadGamemode(named: name)
    }

    @discardableResult
    public func loadGamemode(named rawName: String) throws -> GMLuaGamemodeLoadReport {
        guard let runtime else { throw GMLuaGamemodeLoaderError.runtimeUnavailable }
        let name = try Self.normalizedName(rawName)
        let state = runtime.state
        let previousGM = state.getGlobal("GM")
        let previousGamemode = state.getGlobal("GAMEMODE")
        let previousGamemodeName = state.getGlobal("GAMEMODE_NAME")

        do {
            var stack: [String] = []
            let plan = try buildPlan(name: name, realm: runtime.realm, stack: &stack)
            let registrationCountBefore = registrationOrder.count
            let register = try registrationFunction(state: state)

            for manifest in plan {
                try execute(
                    manifest,
                    register: register,
                    registrationCountBefore: registrationCountBefore,
                    runtime: runtime
                )
            }

            guard let final = records[name] else {
                throw GMLuaGamemodeLoaderError.invalidManifest(
                    name: name,
                    path: Self.manifestPath(for: name),
                    reason: "validated hierarchy did not produce a registered gamemode"
                )
            }
            state.setGlobal("GM", value: final.value)
            state.setGlobal("GAMEMODE", value: final.value)
            state.setGlobal("GAMEMODE_NAME", value: .string(LuaString(name)))

            return GMLuaGamemodeLoadReport(
                requestedName: name,
                loadOrder: final.chain,
                newlyLoaded: Array(registrationOrder.dropFirst(registrationCountBefore)),
                entryPaths: final.chain.compactMap { records[$0]?.manifest.entryPath },
                autorunLoaded: false,
                addonsLoaded: false
            )
        } catch {
            state.setGlobal("GM", value: previousGM)
            state.setGlobal("GAMEMODE", value: previousGamemode)
            state.setGlobal("GAMEMODE_NAME", value: previousGamemodeName)
            throw error
        }
    }

    private func buildPlan(
        name: String,
        realm: GMLuaRealm,
        stack: inout [String]
    ) throws -> [Manifest] {
        if records[name] != nil { return [] }
        if let cycleStart = stack.firstIndex(of: name) {
            throw GMLuaGamemodeLoaderError.inheritanceCycle(
                Array(stack[cycleStart...]) + [name]
            )
        }

        let manifest = try readManifest(name: name, realm: realm)
        guard fileSystem.fileExists(at: manifest.entryPath) else {
            throw GMLuaGamemodeLoaderError.missingEntry(
                name: name,
                path: manifest.entryPath,
                realm: realm
            )
        }

        stack.append(name)
        defer { stack.removeLast() }
        var result: [Manifest] = []
        if !manifest.base.isEmpty {
            result.append(contentsOf: try buildPlan(
                name: manifest.base,
                realm: realm,
                stack: &stack
            ))
        }
        if records[name] == nil { result.append(manifest) }
        return result
    }

    private func readManifest(name: String, realm: GMLuaRealm) throws -> Manifest {
        let path = Self.manifestPath(for: name)
        guard fileSystem.fileExists(at: path) else {
            throw GMLuaGamemodeLoaderError.unknownManifest(name: name, path: path)
        }

        let data: Data
        do {
            data = try fileSystem.readFile(at: path)
        } catch {
            throw GMLuaGamemodeLoaderError.invalidManifest(
                name: name,
                path: path,
                reason: String(describing: error)
            )
        }
        guard let source = LuaSourceDecoder.decode(data) else {
            throw GMLuaGamemodeLoaderError.invalidManifest(
                name: name,
                path: path,
                reason: "source encoding is not supported"
            )
        }

        let roots: [SourceKeyValuesParser.Entry]
        do {
            var parser = SourceKeyValuesParser(source: source)
            roots = try parser.parse()
        } catch {
            throw GMLuaGamemodeLoaderError.invalidManifest(
                name: name,
                path: path,
                reason: String(describing: error)
            )
        }

        guard roots.count == 1,
              roots[0].key.caseInsensitiveCompare(name) == .orderedSame,
              case let .object(fields) = roots[0].value else {
            throw GMLuaGamemodeLoaderError.invalidManifest(
                name: name,
                path: path,
                reason: "expected one '\(name)' root object"
            )
        }

        var rawBase: String?
        for field in fields where field.key == "base" {
            guard case let .string(value) = field.value else {
                throw GMLuaGamemodeLoaderError.invalidManifest(
                    name: name,
                    path: path,
                    reason: "base must be a string"
                )
            }
            rawBase = value
        }
        guard let rawBase else {
            throw GMLuaGamemodeLoaderError.invalidManifest(
                name: name,
                path: path,
                reason: "missing base field"
            )
        }
        let trimmedBase = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if trimmedBase.isEmpty {
            base = ""
        } else {
            do {
                base = try Self.normalizedName(trimmedBase)
            } catch {
                throw GMLuaGamemodeLoaderError.invalidManifest(
                    name: name,
                    path: path,
                    reason: "invalid base name or path traversal: \(trimmedBase)"
                )
            }
        }
        let entryName = realm == .server ? "init.lua" : "cl_init.lua"
        return Manifest(
            name: name,
            base: base,
            path: path,
            entryPath: "gamemodes/\(name)/gamemode/\(entryName)"
        )
    }

    private func execute(
        _ manifest: Manifest,
        register: LuaValue,
        registrationCountBefore: Int,
        runtime: GMLuaRuntime
    ) throws {
        let state = runtime.state
        let table = LuaTable()
        try state.setRawTableValue(
            .string(LuaString(manifest.name)),
            for: .string("FolderName"),
            in: table
        )
        try state.setRawTableValue(
            .string(LuaString("gamemodes/\(manifest.name)")),
            for: .string("Folder"),
            in: table
        )
        try state.setRawTableValue(
            .string(LuaString(manifest.base)),
            for: .string("Base"),
            in: table
        )
        let value = LuaValue.table(table)
        state.setGlobal("GM", value: value)
        state.setGlobal("GAMEMODE_NAME", value: .string(LuaString(manifest.name)))

        do {
            try runtime.loadFile(manifest.entryPath)
        } catch {
            throw GMLuaGamemodeLoaderError.partialLoad(
                name: manifest.name,
                path: manifest.entryPath,
                phase: .entry,
                registered: Array(registrationOrder.dropFirst(registrationCountBefore)),
                reason: GMLuaRuntime.describe(error)
            )
        }

        do {
            _ = try state.call(
                register,
                arguments: [
                    value,
                    .string(LuaString(manifest.name)),
                    .string(LuaString(manifest.base))
                ]
            )
        } catch {
            throw GMLuaGamemodeLoaderError.partialLoad(
                name: manifest.name,
                path: manifest.entryPath,
                phase: .registration,
                registered: Array(registrationOrder.dropFirst(registrationCountBefore)),
                reason: GMLuaRuntime.describe(error)
            )
        }

        let chain: [String]
        if manifest.base.isEmpty {
            chain = [manifest.name]
        } else if let baseRecord = records[manifest.base] {
            chain = baseRecord.chain + [manifest.name]
        } else {
            chain = [manifest.base, manifest.name]
        }
        records[manifest.name] = Record(value: value, manifest: manifest, chain: chain)
        registrationOrder.append(manifest.name)
    }

    private func registrationFunction(state: LuaState) throws -> LuaValue {
        guard case let .table(library) = state.getGlobal("gamemode") else {
            throw GMLuaGamemodeLoaderError.registrationUnavailable(
                "global gamemode table has not been loaded"
            )
        }
        let function = try state.rawTableValue(for: .string("Register"), in: library)
        switch function {
        case .luaFunction, .nativeFunction:
            return function
        default:
            throw GMLuaGamemodeLoaderError.registrationUnavailable(
                "gamemode.Register is \(function.typeName), expected function"
            )
        }
    }

    private static func manifestPath(for name: String) -> String {
        "gamemodes/\(name)/\(name).txt"
    }

    private static func normalizedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) ||
                  (byte >= 65 && byte <= 90) ||
                  (byte >= 97 && byte <= 122) ||
                  byte == 45 || byte == 95
              }) else {
            throw GMLuaGamemodeLoaderError.invalidName(rawName)
        }
        return name.lowercased()
    }
}

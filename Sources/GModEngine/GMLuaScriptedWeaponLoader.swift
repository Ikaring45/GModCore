import Foundation
import GModLua

public enum GMLuaScriptedWeaponLoadPhase: String, Sendable, Equatable {
    case enumeration
    case entry
    case registration
    case completion
}

public enum GMLuaScriptedWeaponLoaderError: Error, CustomStringConvertible {
    case unsupportedRealm(GMLuaRealm)
    case runtimeUnavailable
    case invalidGamemodeName(String)
    case libraryUnavailable(function: String, reason: String)
    case failed(
        phase: GMLuaScriptedWeaponLoadPhase,
        className: String?,
        path: String,
        reason: String
    )

    public var description: String {
        switch self {
        case let .unsupportedRealm(realm):
            return "scripted weapon loading is not defined for the \(realm.rawValue) realm"
        case .runtimeUnavailable:
            return "scripted weapon loader runtime is no longer available"
        case let .invalidGamemodeName(name):
            return "invalid scripted weapon gamemode name or path traversal: \(name)"
        case let .libraryUnavailable(function, reason):
            return "\(function) is unavailable: \(reason)"
        case let .failed(phase, className, path, reason):
            let classDetail = className.map { " for '\($0)'" } ?? ""
            return "scripted weapon \(phase.rawValue) failed\(classDetail) at \(path): \(reason)"
        }
    }
}

public struct GMLuaScriptedWeaponClassRecord: Sendable, Equatable {
    public let className: String
    public let sourceRoot: String
    public let entryPath: String
    public let transitiveIncludePaths: [String]

    public init(
        className: String,
        sourceRoot: String,
        entryPath: String,
        transitiveIncludePaths: [String]
    ) {
        self.className = className
        self.sourceRoot = sourceRoot
        self.entryPath = entryPath
        self.transitiveIncludePaths = transitiveIncludePaths
    }
}

public struct GMLuaScriptedWeaponLoadReport: Sendable, Equatable {
    public let realm: GMLuaRealm
    public let targetGamemode: String
    public let roots: [String]
    public let classes: [GMLuaScriptedWeaponClassRecord]

    public var directPaths: [String] { classes.map(\.entryPath) }
    public var transitiveIncludePaths: [String] {
        classes.flatMap(\.transitiveIncludePaths)
    }
}

/// Loads the engine-owned scripted weapon stage from a mounted GMod VFS.
///
/// Facepunch's documented state order projects physical roots into the one
/// `weapons/` namespace: Base, global Lua, then every remaining gamemode in
/// base-first inheritance order. The host builds that merged, file-level VFS
/// before enumerating it once. A loose `.lua` file is shared;
/// a directory runs `cl_init.lua` on CLIENT or `init.lua` on SERVER, falling
/// back to `shared.lua` only when the realm entry is absent. Realm entries own
/// their normal `include("shared.lua")` behavior and therefore are not double
/// executed by the host.
///
/// The host creates exactly one `SWEP` table for each entry, including the
/// engine-provided `Primary`, `Secondary`, and `Folder` fields, and passes that
/// same table to the real `weapons.Register`. `SWEP.Folder` is always the
/// canonical `weapons/<class>` path, including while entry code is executing.
public final class GMLuaScriptedWeaponLoader {
    private static let projectionMountName =
        "__garrys_pad_internal_scripted_weapons_projection"
    private static let canonicalRoot = "lua/weapons"

    private struct Candidate {
        let className: String
        let sourceRoot: String
        let entryPath: String
    }

    private weak var runtime: GMLuaRuntime?
    private let fileSystem: LuaVirtualFileSystem

    public init(runtime: GMLuaRuntime, fileSystem: LuaVirtualFileSystem) {
        self.runtime = runtime
        self.fileSystem = fileSystem
    }

    public func load(targetGamemodeNamed rawName: String) throws
        -> GMLuaScriptedWeaponLoadReport
    {
        let targetName = try Self.normalizedGamemodeName(rawName)
        return try load(gamemodeLoadOrder: ["base", targetName])
    }

    public func load(gamemodeLoadOrder rawLoadOrder: [String]) throws
        -> GMLuaScriptedWeaponLoadReport
    {
        guard let runtime else {
            throw GMLuaScriptedWeaponLoaderError.runtimeUnavailable
        }
        guard runtime.realm == .client || runtime.realm == .server else {
            throw GMLuaScriptedWeaponLoaderError.unsupportedRealm(runtime.realm)
        }
        guard !rawLoadOrder.isEmpty else {
            throw GMLuaScriptedWeaponLoaderError.invalidGamemodeName("<empty load order>")
        }
        let loadOrder = try rawLoadOrder.map(Self.normalizedGamemodeName)
        let targetName = loadOrder[loadOrder.count - 1]
        let roots = Self.weaponRoots(gamemodeLoadOrder: loadOrder)
        guard let mountedFileSystem = fileSystem as? GMLuaMountedFileSystem else {
            throw GMLuaScriptedWeaponLoaderError.libraryUnavailable(
                function: "scripted weapon merged VFS",
                reason: "GMLuaMountedFileSystem is required"
            )
        }
        let physicalSnapshot = mountedFileSystem.snapshot(
            excludingMountNamed: Self.projectionMountName
        )
        let projection = try Self.makeProjection(
            roots: roots,
            backing: physicalSnapshot
        )
        mountedFileSystem.replaceMount(try GMLuaFileMount(
            name: Self.projectionMountName,
            virtualRoot: Self.canonicalRoot,
            priority: Int.max,
            writable: false,
            fileSystem: projection
        ))
        let register = try libraryFunction(
            named: "Register",
            libraryName: "weapons",
            runtime: runtime
        )
        let onLoaded = try libraryFunction(
            named: "OnLoaded",
            libraryName: "weapons",
            runtime: runtime
        )

        let previousSWEP = runtime.state.getGlobal("SWEP")
        defer { runtime.state.setGlobal("SWEP", value: previousSWEP) }

        var records: [GMLuaScriptedWeaponClassRecord] = []
        for candidate in try candidates(
            in: Self.canonicalRoot,
            physicalRoots: roots,
            physicalFileSystem: physicalSnapshot,
            realm: runtime.realm
        ) {
            let includesBefore = runtime.includedFiles.count
            let table = try makeWeaponTable(for: candidate, runtime: runtime)
            runtime.state.setGlobal("SWEP", value: .table(table))

            do {
                try runtime.loadFile(candidate.entryPath)
            } catch {
                throw GMLuaScriptedWeaponLoaderError.failed(
                    phase: .entry,
                    className: candidate.className,
                    path: candidate.entryPath,
                    reason: GMLuaRuntime.describe(error)
                )
            }

            do {
                _ = try runtime.state.call(
                    register,
                    arguments: [
                        .table(table),
                        .string(LuaString(candidate.className)),
                    ]
                )
            } catch {
                throw GMLuaScriptedWeaponLoaderError.failed(
                    phase: .registration,
                    className: candidate.className,
                    path: candidate.entryPath,
                    reason: GMLuaRuntime.describe(error)
                )
            }
            records.append(GMLuaScriptedWeaponClassRecord(
                className: candidate.className,
                sourceRoot: candidate.sourceRoot,
                entryPath: candidate.entryPath,
                transitiveIncludePaths: runtime.includedFiles
                    .dropFirst(includesBefore)
                    .filter { $0 != candidate.entryPath }
            ))
        }

        do {
            _ = try runtime.state.call(onLoaded, arguments: [])
        } catch {
            throw GMLuaScriptedWeaponLoaderError.failed(
                phase: .completion,
                className: nil,
                path: "weapons.OnLoaded",
                reason: GMLuaRuntime.describe(error)
            )
        }

        return GMLuaScriptedWeaponLoadReport(
            realm: runtime.realm,
            targetGamemode: targetName,
            roots: roots,
            classes: records
        )
    }

    private func candidates(
        in root: String,
        physicalRoots: [String],
        physicalFileSystem: LuaVirtualFileSystem,
        realm: GMLuaRealm
    ) throws -> [Candidate] {
        guard fileSystem.directoryExists(at: root) else { return [] }
        let entries: [LuaVirtualFileSystemEntry]
        do {
            entries = try fileSystem.listDirectory(at: root)
        } catch {
            throw GMLuaScriptedWeaponLoaderError.failed(
                phase: .enumeration,
                className: nil,
                path: root,
                reason: String(describing: error)
            )
        }

        var result: [Candidate] = []
        for entry in entries.sorted(by: Self.alphabetical) {
            if entry.isDirectory {
                guard let className = try? Self.normalizedClassName(entry.name) else {
                    continue
                }
                let folder = root + "/" + entry.name
                let realmEntry = realm == .server ? "init.lua" : "cl_init.lua"
                let realmPath = folder + "/" + realmEntry
                let sharedPath = folder + "/shared.lua"
                let entryPath: String
                if fileSystem.fileExists(at: realmPath) {
                    entryPath = realmPath
                } else if fileSystem.fileExists(at: sharedPath) {
                    entryPath = sharedPath
                } else {
                    continue
                }
                result.append(Candidate(
                    className: className,
                    sourceRoot: Self.sourceRoot(
                        forRelativePath: String(entryPath.dropFirst(root.count + 1)),
                        roots: physicalRoots,
                        fileSystem: physicalFileSystem
                    ) ?? root,
                    entryPath: entryPath
                ))
            } else if entry.name.lowercased().hasSuffix(".lua") {
                let stem = String(entry.name.dropLast(4))
                guard let className = try? Self.normalizedClassName(stem) else {
                    continue
                }
                result.append(Candidate(
                    className: className,
                    sourceRoot: Self.sourceRoot(
                        forRelativePath: entry.name,
                        roots: physicalRoots,
                        fileSystem: physicalFileSystem
                    ) ?? root,
                    entryPath: root + "/" + entry.name
                ))
            }
        }
        return result
    }

    private func makeWeaponTable(
        for candidate: Candidate,
        runtime: GMLuaRuntime
    ) throws -> LuaTable {
        let table = LuaTable()
        try runtime.state.setRawTableValue(
            .table(LuaTable()),
            for: .string("Primary"),
            in: table
        )
        try runtime.state.setRawTableValue(
            .table(LuaTable()),
            for: .string("Secondary"),
            in: table
        )
        try runtime.state.setRawTableValue(
            .string(LuaString("weapons/\(candidate.className)")),
            for: .string("Folder"),
            in: table
        )
        return table
    }

    private func libraryFunction(
        named functionName: String,
        libraryName: String,
        runtime: GMLuaRuntime
    ) throws -> LuaValue {
        guard case let .table(library) = runtime.state.getGlobal(libraryName) else {
            throw GMLuaScriptedWeaponLoaderError.libraryUnavailable(
                function: "\(libraryName).\(functionName)",
                reason: "global \(libraryName) table is unavailable"
            )
        }
        let function = try runtime.state.rawTableValue(
            for: .string(LuaString(functionName)),
            in: library
        )
        switch function {
        case .luaFunction, .nativeFunction:
            return function
        default:
            throw GMLuaScriptedWeaponLoaderError.libraryUnavailable(
                function: "\(libraryName).\(functionName)",
                reason: "value is \(function.typeName), expected function"
            )
        }
    }

    private static func weaponRoots(gamemodeLoadOrder: [String]) -> [String] {
        var roots: [String] = []
        if let base = gamemodeLoadOrder.first {
            roots.append("gamemodes/\(base)/entities/weapons")
        }
        roots.append("lua/weapons")
        roots.append(contentsOf: gamemodeLoadOrder.dropFirst().map {
            "gamemodes/\($0)/entities/weapons"
        })
        var unique: [String] = []
        for root in roots where !unique.contains(root) { unique.append(root) }
        return unique
    }

    private static func makeProjection(
        roots: [String],
        backing: LuaVirtualFileSystem
    ) throws -> GMLuaMountedFileSystem {
        GMLuaMountedFileSystem(mounts: try roots.enumerated().map { index, root in
            try GMLuaFileMount(
                name: "scripted-weapons-root-\(index)",
                sourceRoot: root,
                priority: index,
                writable: false,
                fileSystem: backing
            )
        })
    }

    private static func sourceRoot(
        forRelativePath relativePath: String,
        roots: [String],
        fileSystem: LuaVirtualFileSystem
    ) -> String? {
        roots.reversed().first { root in
            fileSystem.fileExists(at: root + "/" + relativePath)
        }
    }

    private static func normalizedGamemodeName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isIdentifier(name) else {
            throw GMLuaScriptedWeaponLoaderError.invalidGamemodeName(rawName)
        }
        return name.lowercased()
    }

    private static func normalizedClassName(_ rawName: String) throws -> String {
        guard !rawName.isEmpty, isIdentifier(rawName) else {
            throw GMLuaScriptedWeaponLoaderError.failed(
                phase: .enumeration,
                className: nil,
                path: rawName,
                reason: "invalid scripted weapon class name"
            )
        }
        return rawName.lowercased()
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 || byte == 95
        }
    }

    private static func alphabetical(
        _ lhs: LuaVirtualFileSystemEntry,
        _ rhs: LuaVirtualFileSystemEntry
    ) -> Bool {
        let left = lhs.name.lowercased()
        let right = rhs.name.lowercased()
        if left != right { return left < right }
        return lhs.name < rhs.name
    }
}

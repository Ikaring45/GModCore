import Foundation

// Source reference contract:
// - Source SDK 2013: src/public/filesystem.h (IFileSystem, SearchPathAdd_t,
//   PathTypeFilter_t, PathTypeQuery_t and by-request-only path IDs)
// - Source SDK 2013: src/public/filesystem_init.cpp (ordered GameInfo search paths)
//
// The iPad backend must not leak APFS case sensitivity or sandbox layout to
// game code. Providers therefore expose Source-style, case-insensitive logical
// paths and the search-path stack owns all priority and PathID decisions.

public enum SourceFileSystemError: Error, Equatable, CustomStringConvertible {
    case invalidPath(String)
    case fileNotFound(String)
    case notDirectory(String)
    case malformedGameInfo(String)
    case unknownSearchPathMacro(String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            return "invalid Source filesystem path: \(path)"
        case let .fileNotFound(path):
            return "Source filesystem file not found: \(path)"
        case let .notDirectory(path):
            return "Source filesystem path is not a directory: \(path)"
        case let .malformedGameInfo(reason):
            return "malformed Source GameInfo: \(reason)"
        case let .unknownSearchPathMacro(name):
            return "unknown Source search-path macro: |\(name)|"
        }
    }
}

public enum SourceSearchPathAdd: Sendable {
    case head
    case tail
}

public enum SourcePathTypeFilter: Sendable {
    case none
    case cullPack
    case cullNonPack
}

/// Mirrors Source's PathTypeQuery_t flags.
public struct SourceSearchPathKind: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let normal = SourceSearchPathKind([])
    public static let packFile = SourceSearchPathKind(rawValue: 0x01)
    public static let mapPackFile = SourceSearchPathKind(rawValue: 0x02)
    public static let remote = SourceSearchPathKind(rawValue: 0x04)

    public var isPack: Bool {
        contains(.packFile) || contains(.mapPackFile)
    }
}

public struct SourceFileSystemEntry: Sendable, Equatable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// A physical directory, VPK, BSP pak lump, or other backing store. Search
/// ordering never lives in a provider; this keeps backend substitutions from
/// changing Source-visible priority.
public protocol SourceFileProvider: AnyObject, Sendable {
    func fileExists(at logicalPath: String) -> Bool
    func directoryExists(at logicalPath: String) -> Bool
    func readFile(at logicalPath: String) throws -> Data
    func listDirectory(at logicalPath: String) throws -> [SourceFileSystemEntry]
    func displayPath(for logicalPath: String) -> String?
}

public struct SourceResolvedFile: Sendable, Equatable {
    public let mountToken: UInt64
    public let mountName: String
    public let pathIDs: [String]
    public let kind: SourceSearchPathKind
    public let logicalPath: String
    public let displayPath: String?
}

public struct SourceSearchPathSnapshot: Sendable, Equatable {
    public let token: UInt64
    public let name: String
    public let pathIDs: [String]
    public let kind: SourceSearchPathKind
}

private struct SourceSearchPathMount: @unchecked Sendable {
    let token: UInt64
    let name: String
    var pathIDs: [String]
    var foldedPathIDs: Set<String>
    let kind: SourceSearchPathKind
    let provider: any SourceFileProvider
}

/// Ordered implementation of the Source search-path contract.
public final class SourceSearchPathFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var mounts: [SourceSearchPathMount] = []
    private var requestOnlyPathIDs: Set<String> = []
    private var nextMountToken: UInt64 = 1

    public init() {}

    @discardableResult
    public func addSearchPath(
        provider: any SourceFileProvider,
        name: String,
        pathIDs: [String],
        kind: SourceSearchPathKind = .normal,
        add: SourceSearchPathAdd = .tail
    ) throws -> UInt64 {
        let normalizedIDs = try Self.normalizedPathIDs(pathIDs)
        lock.lock()
        defer { lock.unlock() }
        let token = nextMountToken
        nextMountToken &+= 1
        if nextMountToken == 0 { nextMountToken = 1 }
        let newAssociations = normalizedIDs.map { pathID in
            SourceSearchPathMount(
                token: token,
                name: name,
                pathIDs: [pathID],
                foldedPathIDs: [Self.fold(pathID)],
                kind: kind,
                provider: provider
            )
        }
        switch add {
        case .head:
            // GameInfo expands `game+mod` into sequential AddSearchPath calls.
            // Repeated head insertion therefore reverses the PathID order.
            for association in newAssociations {
                mounts.insert(association, at: 0)
            }
        case .tail:
            mounts.append(contentsOf: newAssociations)
        }
        return token
    }

    @discardableResult
    public func removeSearchPath(name: String, pathID: String? = nil) -> Bool {
        let foldedName = Self.fold(name)
        let foldedID = pathID.map(Self.fold)
        lock.lock()
        defer { lock.unlock() }

        guard let foldedID else {
            let oldCount = mounts.count
            mounts.removeAll { Self.fold($0.name) == foldedName }
            return mounts.count != oldCount
        }

        var removedAssociation = false
        for index in mounts.indices.reversed() {
            guard Self.fold(mounts[index].name) == foldedName,
                  mounts[index].foldedPathIDs.contains(foldedID) else {
                continue
            }
            removedAssociation = true
            mounts[index].pathIDs.removeAll { Self.fold($0) == foldedID }
            mounts[index].foldedPathIDs.remove(foldedID)
            if mounts[index].pathIDs.isEmpty {
                mounts.remove(at: index)
            }
        }
        return removedAssociation
    }

    public func removeAllSearchPaths() {
        lock.lock()
        mounts.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func removeSearchPaths(pathID: String) {
        let foldedID = Self.fold(pathID)
        lock.lock()
        for index in mounts.indices.reversed() {
            guard mounts[index].foldedPathIDs.contains(foldedID) else { continue }
            mounts[index].pathIDs.removeAll { Self.fold($0) == foldedID }
            mounts[index].foldedPathIDs.remove(foldedID)
            if mounts[index].pathIDs.isEmpty {
                mounts.remove(at: index)
            }
        }
        lock.unlock()
    }

    public func markPathIDByRequestOnly(_ pathID: String, enabled: Bool) throws {
        let ids = try Self.normalizedPathIDs([pathID])
        let folded = Self.fold(ids[0])
        lock.lock()
        if enabled {
            requestOnlyPathIDs.insert(folded)
        } else {
            requestOnlyPathIDs.remove(folded)
        }
        lock.unlock()
    }

    public func searchPaths(pathID: String? = nil, includePackFiles: Bool = true)
        -> [SourceSearchPathSnapshot]
    {
        let requested = pathID.map(Self.fold)
        lock.lock()
        let snapshot = mounts
        lock.unlock()
        return snapshot.compactMap { mount in
            if let requested, !mount.foldedPathIDs.contains(requested) { return nil }
            if !includePackFiles, mount.kind.isPack { return nil }
            return SourceSearchPathSnapshot(
                token: mount.token,
                name: mount.name,
                pathIDs: mount.pathIDs,
                kind: mount.kind
            )
        }
    }

    public func resolveFile(
        _ rawPath: String,
        pathID: String? = nil,
        filter: SourcePathTypeFilter = .none
    ) throws -> SourceResolvedFile? {
        let logicalPath = try SourceLogicalPath.normalize(rawPath, allowEmpty: false)
        let candidates = eligibleMounts(pathID: pathID, filter: filter)
        for mount in candidates where mount.provider.fileExists(at: logicalPath) {
            return SourceResolvedFile(
                mountToken: mount.token,
                mountName: mount.name,
                pathIDs: mount.pathIDs,
                kind: mount.kind,
                logicalPath: logicalPath,
                displayPath: mount.provider.displayPath(for: logicalPath)
            )
        }
        return nil
    }

    public func fileExists(
        _ rawPath: String,
        pathID: String? = nil,
        filter: SourcePathTypeFilter = .none
    ) -> Bool {
        (try? resolveFile(rawPath, pathID: pathID, filter: filter)) != nil
    }

    public func readFile(
        _ rawPath: String,
        pathID: String? = nil,
        filter: SourcePathTypeFilter = .none
    ) throws -> Data {
        let logicalPath = try SourceLogicalPath.normalize(rawPath, allowEmpty: false)
        let candidates = eligibleMounts(pathID: pathID, filter: filter)
        for mount in candidates where mount.provider.fileExists(at: logicalPath) {
            return try mount.provider.readFile(at: logicalPath)
        }
        throw SourceFileSystemError.fileNotFound(logicalPath)
    }

    /// Union enumeration follows the same first-visible-entry rule as file
    /// lookup. This prevents a lower directory from leaking through an upper
    /// file with the same case-insensitive name (and vice versa).
    public func listDirectory(
        _ rawPath: String = "",
        pathID: String? = nil,
        filter: SourcePathTypeFilter = .none
    ) throws -> [SourceFileSystemEntry] {
        let logicalPath = try SourceLogicalPath.normalize(rawPath, allowEmpty: true)
        let candidates = eligibleMounts(pathID: pathID, filter: filter)
        var visible: [String: SourceFileSystemEntry] = [:]
        var sawDirectory = logicalPath.isEmpty
        for mount in candidates {
            guard logicalPath.isEmpty || mount.provider.directoryExists(at: logicalPath) else {
                continue
            }
            sawDirectory = true
            for entry in try mount.provider.listDirectory(at: logicalPath) {
                let key = Self.fold(entry.name)
                if visible[key] == nil { visible[key] = entry }
            }
        }
        guard sawDirectory else { throw SourceFileSystemError.notDirectory(logicalPath) }
        return visible.values.sorted(by: Self.entrySort)
    }

    private func eligibleMounts(
        pathID: String?,
        filter: SourcePathTypeFilter
    ) -> [SourceSearchPathMount] {
        let requested = pathID.map(Self.fold)
        lock.lock()
        let snapshot = mounts
        let requestOnly = requestOnlyPathIDs
        lock.unlock()
        return snapshot.filter { mount in
            if let requested {
                guard mount.foldedPathIDs.contains(requested) else { return false }
            } else if !mount.foldedPathIDs.contains(where: { !requestOnly.contains($0) }) {
                return false
            }
            switch filter {
            case .none: return true
            case .cullPack: return !mount.kind.isPack
            case .cullNonPack: return mount.kind.isPack
            }
        }
    }

    private static func normalizedPathIDs(_ rawIDs: [String]) throws -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for raw in rawIDs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("+"),
                  !trimmed.contains("\0") else {
                throw SourceFileSystemError.invalidPath(raw)
            }
            let key = fold(trimmed)
            if seen.insert(key).inserted { result.append(trimmed) }
        }
        guard !result.isEmpty else { throw SourceFileSystemError.invalidPath("") }
        return result
    }

    fileprivate static func fold(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func entrySort(
        _ lhs: SourceFileSystemEntry,
        _ rhs: SourceFileSystemEntry
    ) -> Bool {
        let a = fold(lhs.name)
        let b = fold(rhs.name)
        if a != b { return a < b }
        return lhs.name < rhs.name
    }
}

public enum SourceLogicalPath {
    public static func normalize(_ rawPath: String, allowEmpty: Bool) throws -> String {
        guard !rawPath.contains("\0") else {
            throw SourceFileSystemError.invalidPath(rawPath)
        }
        let slashed = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !slashed.hasPrefix("/"),
              !(slashed.count >= 2 && slashed[slashed.index(after: slashed.startIndex)] == ":") else {
            throw SourceFileSystemError.invalidPath(rawPath)
        }
        var components: [Substring] = []
        for component in slashed.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw SourceFileSystemError.invalidPath(rawPath)
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        guard allowEmpty || !components.isEmpty else {
            throw SourceFileSystemError.invalidPath(rawPath)
        }
        return components.joined(separator: "/")
    }
}

/// Test/tool provider that follows the same case-insensitive lookup rules as
/// the production providers. It is intentionally read-only once constructed.
public final class SourceMemoryFileProvider: SourceFileProvider, @unchecked Sendable {
    private struct Record {
        let path: String
        let data: Data
    }

    private let records: [String: Record]
    private let directories: [String: String]
    private let children: [String: [SourceFileSystemEntry]]

    public init(files: [String: Data]) throws {
        var records: [String: Record] = [:]
        var directories: [String: String] = ["": ""]
        var childMaps: [String: [String: SourceFileSystemEntry]] = [:]
        for (rawPath, data) in files {
            let path = try SourceLogicalPath.normalize(rawPath, allowEmpty: false)
            let foldedPath = SourceSearchPathFileSystem.fold(path)
            guard records[foldedPath] == nil else {
                throw SourceFileSystemError.invalidPath(rawPath)
            }
            records[foldedPath] = Record(path: path, data: data)
            let parts = path.split(separator: "/").map(String.init)
            var parent = ""
            for index in parts.indices {
                let name = parts[index]
                let isDirectory = index < parts.count - 1
                var map = childMaps[SourceSearchPathFileSystem.fold(parent)] ?? [:]
                let foldedName = SourceSearchPathFileSystem.fold(name)
                if map[foldedName] == nil {
                    map[foldedName] = SourceFileSystemEntry(
                        name: name,
                        isDirectory: isDirectory
                    )
                }
                childMaps[SourceSearchPathFileSystem.fold(parent)] = map
                if isDirectory {
                    parent = parent.isEmpty ? name : parent + "/" + name
                    directories[SourceSearchPathFileSystem.fold(parent)] = parent
                }
            }
        }
        self.records = records
        self.directories = directories
        self.children = childMaps.mapValues { map in
            map.values.sorted {
                let a = SourceSearchPathFileSystem.fold($0.name)
                let b = SourceSearchPathFileSystem.fold($1.name)
                return a == b ? $0.name < $1.name : a < b
            }
        }
    }

    public convenience init(utf8Files: [String: String]) throws {
        try self.init(files: utf8Files.mapValues { Data($0.utf8) })
    }

    public func fileExists(at logicalPath: String) -> Bool {
        records[SourceSearchPathFileSystem.fold(logicalPath)] != nil
    }

    public func directoryExists(at logicalPath: String) -> Bool {
        directories[SourceSearchPathFileSystem.fold(logicalPath)] != nil
    }

    public func readFile(at logicalPath: String) throws -> Data {
        guard let record = records[SourceSearchPathFileSystem.fold(logicalPath)] else {
            throw SourceFileSystemError.fileNotFound(logicalPath)
        }
        return record.data
    }

    public func listDirectory(at logicalPath: String) throws -> [SourceFileSystemEntry] {
        let key = SourceSearchPathFileSystem.fold(logicalPath)
        guard directories[key] != nil else {
            throw SourceFileSystemError.notDirectory(logicalPath)
        }
        return children[key] ?? []
    }

    public func displayPath(for logicalPath: String) -> String? {
        records[SourceSearchPathFileSystem.fold(logicalPath)]?.path
    }
}

/// Read-only host directory adapter. Every component is resolved
/// case-insensitively inside the configured root so APFS behavior matches the
/// Windows Source filesystem surface.
public final class SourceHostDirectoryProvider: SourceFileProvider, @unchecked Sendable {
    private let rootURL: URL

    public init(rootURL: URL) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SourceFileSystemError.notDirectory(root.path)
        }
        self.rootURL = root
    }

    public func fileExists(at logicalPath: String) -> Bool {
        guard let url = try? resolveExisting(logicalPath) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    public func directoryExists(at logicalPath: String) -> Bool {
        guard let url = try? resolveExisting(logicalPath, allowEmpty: true) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func readFile(at logicalPath: String) throws -> Data {
        let url = try resolveExisting(logicalPath)
        guard fileExists(at: logicalPath) else {
            throw SourceFileSystemError.fileNotFound(logicalPath)
        }
        return try Data(contentsOf: url)
    }

    public func listDirectory(at logicalPath: String) throws -> [SourceFileSystemEntry] {
        let url = try resolveExisting(logicalPath, allowEmpty: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SourceFileSystemError.notDirectory(logicalPath)
        }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ).map { child in
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            return SourceFileSystemEntry(
                name: child.lastPathComponent,
                isDirectory: values.isDirectory == true
            )
        }.sorted {
            let a = SourceSearchPathFileSystem.fold($0.name)
            let b = SourceSearchPathFileSystem.fold($1.name)
            return a == b ? $0.name < $1.name : a < b
        }
    }

    public func displayPath(for logicalPath: String) -> String? {
        (try? resolveExisting(logicalPath))?.path
    }

    private func resolveExisting(_ rawPath: String, allowEmpty: Bool = false) throws -> URL {
        let path = try SourceLogicalPath.normalize(rawPath, allowEmpty: allowEmpty)
        var current = rootURL
        if path.isEmpty { return current }
        for component in path.split(separator: "/").map(String.init) {
            let children = try FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            let exact = children.first { $0.lastPathComponent == component }
            let matches = children.filter {
                SourceSearchPathFileSystem.fold($0.lastPathComponent)
                    == SourceSearchPathFileSystem.fold(component)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let selected = exact ?? matches.first else {
                throw SourceFileSystemError.fileNotFound(rawPath)
            }
            let resolved = selected.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isContained(resolved, by: rootURL) else {
                throw SourceFileSystemError.invalidPath(rawPath)
            }
            current = resolved
        }
        return current
    }

    private static func isContained(_ child: URL, by root: URL) -> Bool {
        let childComponents = child.pathComponents
        let rootComponents = root.pathComponents
        guard childComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, childComponents).allSatisfy { lhs, rhs in
            SourceSearchPathFileSystem.fold(lhs) == SourceSearchPathFileSystem.fold(rhs)
        }
    }
}

public struct SourceGameInfoSearchPath: Sendable, Equatable {
    public let pathIDs: [String]
    public let rawLocation: String
    public let resolvedLocation: String
    public let conditional: String?
    public let isWildcard: Bool
}

/// Parses the duplicate-key, ordered SearchPaths block used by GameInfo.txt.
/// Composite keys such as game+mod register one location under every PathID.
public enum SourceGameInfoSearchPathParser {
    public static func parse(
        source: String,
        macros: [String: String]
    ) throws -> [SourceGameInfoSearchPath] {
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(
                usesEscapeSequences: false,
                preserveKeyCase: true,
                preserveConditionals: true
            )
        )
        let roots = try parser.parse()
        guard let gameInfo = object(named: "gameinfo", in: roots) else {
            throw SourceFileSystemError.malformedGameInfo("missing GameInfo root")
        }
        guard let fileSystem = object(named: "filesystem", in: gameInfo) else {
            throw SourceFileSystemError.malformedGameInfo("missing FileSystem block")
        }
        guard let searchPaths = object(named: "searchpaths", in: fileSystem) else {
            throw SourceFileSystemError.malformedGameInfo("missing SearchPaths block")
        }
        let foldedMacros = Dictionary(uniqueKeysWithValues: macros.map {
            (SourceSearchPathFileSystem.fold($0.key), $0.value)
        })
        return try searchPaths.map { entry in
            guard case let .string(location) = entry.value else {
                throw SourceFileSystemError.malformedGameInfo(
                    "SearchPaths value for \(entry.key) is not a string"
                )
            }
            let ids = entry.key.split(separator: "+", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else {
                throw SourceFileSystemError.malformedGameInfo(
                    "invalid composite PathID \(entry.key)"
                )
            }
            let expanded = try expand(location, macros: foldedMacros)
                .replacingOccurrences(of: "\\", with: "/")
            return SourceGameInfoSearchPath(
                pathIDs: ids,
                rawLocation: location,
                resolvedLocation: expanded,
                conditional: entry.conditional,
                isWildcard: expanded.hasSuffix("/*")
            )
        }
    }

    private static func object(
        named name: String,
        in entries: [SourceKeyValuesParser.Entry]
    ) -> [SourceKeyValuesParser.Entry]? {
        for entry in entries where entry.key.caseInsensitiveCompare(name) == .orderedSame {
            if case let .object(children) = entry.value { return children }
        }
        return nil
    }

    private static func expand(
        _ raw: String,
        macros: [String: String]
    ) throws -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "|" else {
                output.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let nameStart = raw.index(after: index)
            guard let close = raw[nameStart...].firstIndex(of: "|") else {
                throw SourceFileSystemError.malformedGameInfo(
                    "unterminated search-path macro in \(raw)"
                )
            }
            let name = String(raw[nameStart..<close])
            guard let replacement = macros[SourceSearchPathFileSystem.fold(name)] else {
                throw SourceFileSystemError.unknownSearchPathMacro(name)
            }
            output += replacement
            index = raw.index(after: close)
        }
        return output
    }
}

import Foundation

/// Byte-oriented filesystem boundary used by Lua IO, loadfile, and require.
/// GMod mounts can implement this protocol without exposing host filesystem
/// paths to Lua code.
public protocol LuaVirtualFileSystem: AnyObject {
    func fileExists(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool
    func listDirectory(at path: String) throws -> [LuaVirtualFileSystemEntry]
    func readFile(at path: String) throws -> Data
    func writeFile(_ data: Data, at path: String) throws
    func removeFile(at path: String) throws
    func moveFile(from sourcePath: String, to destinationPath: String) throws
    func createDirectory(at path: String) throws
    func removeDirectory(at path: String) throws
    func moveDirectory(from sourcePath: String, to destinationPath: String) throws
}

public struct LuaVirtualFileSystemEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum LuaVirtualFileSystemError: Error, LocalizedError {
    case invalidPath(String)
    case fileNotFound(String)
    case notDirectory(String)
    case directoryNotEmpty(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): return "invalid virtual path: \(path)"
        case let .fileNotFound(path): return "file not found: \(path)"
        case let .notDirectory(path): return "not a directory: \(path)"
        case let .directoryNotEmpty(path): return "directory is not empty: \(path)"
        }
    }
}

/// Writable in-memory filesystem used by the official conformance runner and
/// suitable as the writable layer above read-only GMod mounts.
public final class LuaMemoryFileSystem: LuaVirtualFileSystem, @unchecked Sendable {
    private struct FileRecord {
        var path: String
        var data: Data
    }

    // GMod content is authored against a case-insensitive filesystem. Keep the
    // spelling most recently written for deterministic directory listings,
    // while addressing records by their folded virtual path.
    private var files: [String: FileRecord] = [:]
    private var directories: [String: String] = [:]
    private let lock = NSLock()

    public init(initialFiles: [String: Data] = [:]) throws {
        for (path, data) in initialFiles {
            let normalized = try Self.normalize(path, allowEmpty: false)
            guard directories[Self.fold(normalized)] == nil else {
                throw LuaVirtualFileSystemError.notDirectory(path)
            }
            try validateParentDirectories(of: normalized)
            files[Self.fold(normalized)] = FileRecord(path: normalized, data: data)
            addParentDirectories(of: normalized)
        }
    }

    public func fileExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path, allowEmpty: false) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return files[Self.fold(normalized)] != nil
    }

    public func directoryExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path, allowEmpty: true) else { return false }
        if normalized.isEmpty { return true }
        lock.lock()
        defer { lock.unlock() }
        return directories[Self.fold(normalized)] != nil
    }

    public func listDirectory(at path: String) throws -> [LuaVirtualFileSystemEntry] {
        let normalized = try Self.normalize(path, allowEmpty: true)
        let requestedComponents = normalized.split(separator: "/").map(String.init)
        lock.lock()
        defer { lock.unlock() }

        if !normalized.isEmpty, files[Self.fold(normalized)] != nil {
            throw LuaVirtualFileSystemError.notDirectory(path)
        }

        var entries: [String: LuaVirtualFileSystemEntry] = [:]
        var foundDirectory = normalized.isEmpty || directories[Self.fold(normalized)] != nil
        for directory in directories.values {
            let recordComponents = directory.split(separator: "/").map(String.init)
            guard recordComponents.count > requestedComponents.count else { continue }
            let matchesDirectory = zip(requestedComponents, recordComponents).allSatisfy {
                $0.0.caseInsensitiveCompare($0.1) == .orderedSame
            }
            guard matchesDirectory else { continue }
            let stringName = recordComponents[requestedComponents.count]
            let key = Self.fold(stringName)
            entries[key] = LuaVirtualFileSystemEntry(name: stringName, isDirectory: true)
        }
        for record in files.values {
            let recordComponents = record.path.split(separator: "/").map(String.init)
            guard recordComponents.count > requestedComponents.count else { continue }
            let matchesDirectory = zip(requestedComponents, recordComponents).allSatisfy {
                $0.0.caseInsensitiveCompare($0.1) == .orderedSame
            }
            guard matchesDirectory else { continue }
            foundDirectory = true
            let stringName = recordComponents[requestedComponents.count]
            let isDirectory = recordComponents.count > requestedComponents.count + 1
            let key = Self.fold(stringName)
            if let existing = entries[key] {
                entries[key] = LuaVirtualFileSystemEntry(
                    name: min(existing.name, stringName),
                    isDirectory: existing.isDirectory || isDirectory
                )
            } else {
                entries[key] = LuaVirtualFileSystemEntry(
                    name: stringName,
                    isDirectory: isDirectory
                )
            }
        }
        guard foundDirectory else { throw LuaVirtualFileSystemError.fileNotFound(path) }
        return Self.sorted(Array(entries.values))
    }

    public func readFile(at path: String) throws -> Data {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard let record = files[Self.fold(normalized)] else {
            throw LuaVirtualFileSystemError.fileNotFound(path)
        }
        return record.data
    }

    public func writeFile(_ data: Data, at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard directories[Self.fold(normalized)] == nil else {
            throw LuaVirtualFileSystemError.notDirectory(path)
        }
        try validateParentDirectories(of: normalized)
        addParentDirectories(of: normalized)
        files[Self.fold(normalized)] = FileRecord(path: normalized, data: data)
    }

    public func removeFile(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard files.removeValue(forKey: Self.fold(normalized)) != nil else {
            throw LuaVirtualFileSystemError.fileNotFound(path)
        }
    }

    public func moveFile(from sourcePath: String, to destinationPath: String) throws {
        let source = try Self.normalize(sourcePath, allowEmpty: false)
        let destination = try Self.normalize(destinationPath, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard let record = files[Self.fold(source)] else {
            throw LuaVirtualFileSystemError.fileNotFound(sourcePath)
        }
        if Self.fold(source) == Self.fold(destination) { return }
        guard directories[Self.fold(destination)] == nil else {
            throw LuaVirtualFileSystemError.notDirectory(destinationPath)
        }
        try validateParentDirectories(of: destination)
        files.removeValue(forKey: Self.fold(source))
        addParentDirectories(of: destination)
        files[Self.fold(destination)] = FileRecord(path: destination, data: record.data)
    }

    public func createDirectory(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        var validationComponents: [String] = []
        for component in normalized.split(separator: "/").map(String.init) {
            validationComponents.append(component)
            let directory = validationComponents.joined(separator: "/")
            guard files[Self.fold(directory)] == nil else {
                throw LuaVirtualFileSystemError.notDirectory(path)
            }
        }
        var components: [String] = []
        for component in normalized.split(separator: "/").map(String.init) {
            components.append(component)
            let directory = components.joined(separator: "/")
            directories[Self.fold(directory)] = directory
        }
    }

    public func removeDirectory(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        let folded = Self.fold(normalized)
        let prefix = folded + "/"
        lock.lock()
        defer { lock.unlock() }
        guard directories[folded] != nil else {
            throw LuaVirtualFileSystemError.fileNotFound(path)
        }
        guard !files.keys.contains(where: { $0.hasPrefix(prefix) }),
              !directories.keys.contains(where: { $0.hasPrefix(prefix) }) else {
            throw LuaVirtualFileSystemError.directoryNotEmpty(path)
        }
        directories.removeValue(forKey: folded)
    }

    public func moveDirectory(from sourcePath: String, to destinationPath: String) throws {
        let source = try Self.normalize(sourcePath, allowEmpty: false)
        let destination = try Self.normalize(destinationPath, allowEmpty: false)
        let foldedSource = Self.fold(source)
        let foldedDestination = Self.fold(destination)
        guard foldedSource != foldedDestination,
              !foldedDestination.hasPrefix(foldedSource + "/") else {
            throw LuaVirtualFileSystemError.invalidPath(destinationPath)
        }

        lock.lock()
        defer { lock.unlock() }
        guard directories[foldedSource] != nil else {
            throw LuaVirtualFileSystemError.fileNotFound(sourcePath)
        }
        guard files[foldedDestination] == nil, directories[foldedDestination] == nil else {
            throw LuaVirtualFileSystemError.invalidPath(destinationPath)
        }
        try validateParentDirectories(of: destination)

        let directoryMoves = directories
            .filter { $0.key == foldedSource || $0.key.hasPrefix(foldedSource + "/") }
            .map { (key: $0.key, path: $0.value) }
        let fileMoves = files
            .filter { $0.key.hasPrefix(foldedSource + "/") }
            .map { (key: $0.key, record: $0.value) }
        for move in directoryMoves { directories.removeValue(forKey: move.key) }
        for move in fileMoves { files.removeValue(forKey: move.key) }
        addParentDirectories(of: destination + "/placeholder")
        for move in directoryMoves {
            let suffix = move.path.count == source.count
                ? ""
                : String(move.path.dropFirst(source.count + 1))
            let moved = suffix.isEmpty ? destination : destination + "/" + suffix
            directories[Self.fold(moved)] = moved
        }
        for move in fileMoves {
            let suffix = String(move.record.path.dropFirst(source.count + 1))
            let moved = destination + "/" + suffix
            files[Self.fold(moved)] = FileRecord(path: moved, data: move.record.data)
        }
    }

    public func snapshot() -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: files.values.map { ($0.path, $0.data) })
    }

    private static func normalize(_ rawPath: String, allowEmpty: Bool) throws -> String {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":") else {
            throw LuaVirtualFileSystemError.invalidPath(rawPath)
        }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw LuaVirtualFileSystemError.invalidPath(rawPath)
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }

        guard !components.isEmpty else {
            if allowEmpty { return "" }
            throw LuaVirtualFileSystemError.invalidPath(rawPath)
        }
        return components.joined(separator: "/")
    }

    private static func fold(_ path: String) -> String { path.lowercased() }

    /// Must be called with `lock` held (or during initialization).
    private func addParentDirectories(of path: String) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var parents: [String] = []
        for component in components.dropLast() {
            parents.append(component)
            let directory = parents.joined(separator: "/")
            directories[Self.fold(directory)] = directory
        }
    }

    /// Must be called with `lock` held (or during initialization).
    private func validateParentDirectories(of path: String) throws {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var parents: [String] = []
        for component in components.dropLast() {
            parents.append(component)
            let parent = parents.joined(separator: "/")
            if files[Self.fold(parent)] != nil {
                throw LuaVirtualFileSystemError.notDirectory(parent)
            }
        }
    }

    private static func sorted(
        _ entries: [LuaVirtualFileSystemEntry]
    ) -> [LuaVirtualFileSystemEntry] {
        entries.sorted { lhs, rhs in
            let foldedLHS = fold(lhs.name)
            let foldedRHS = fold(rhs.name)
            if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
            return lhs.name < rhs.name
        }
    }
}

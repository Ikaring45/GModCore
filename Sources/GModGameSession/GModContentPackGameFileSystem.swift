import Foundation
import GModEngine
import GModLua

/// Allocation and indexing limits for the read-only GAME projection of one
/// validated Garry's PAD content pack.
public struct GModContentPackGameFileSystemLimits: Sendable, Equatable {
    public let maximumFileByteCount: UInt64
    public let maximumIndexedEntryCount: Int
    public let maximumPathByteCount: Int
    public let maximumPathComponentCount: Int
    public let maximumIndexPathByteCount: UInt64

    public init(
        maximumFileByteCount: UInt64 = 256 * 1_024 * 1_024,
        maximumIndexedEntryCount: Int = 1_000_000,
        maximumPathByteCount: Int = 4_096,
        maximumPathComponentCount: Int = 128,
        maximumIndexPathByteCount: UInt64 = 128 * 1_024 * 1_024
    ) {
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumIndexedEntryCount = maximumIndexedEntryCount
        self.maximumPathByteCount = maximumPathByteCount
        self.maximumPathComponentCount = maximumPathComponentCount
        self.maximumIndexPathByteCount = maximumIndexPathByteCount
    }
}

public enum GModContentPackGameFileSystemError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case invalidLimits
    case tooManyEntries(actual: Int, maximum: Int)
    case pathTooLong(path: String, actual: Int, maximum: Int)
    case tooManyPathComponents(path: String, actual: Int, maximum: Int)
    case indexTooLarge(actual: UInt64, maximum: UInt64)
    case conflictingNode(path: String)

    public var description: String {
        switch self {
        case .invalidLimits:
            return "invalid content-pack GAME filesystem limits"
        case let .tooManyEntries(actual, maximum):
            return "content-pack GAME filesystem has \(actual) indexed entries, exceeding \(maximum)"
        case let .pathTooLong(path, actual, maximum):
            return "content-pack GAME path \(path) has \(actual) bytes, exceeding \(maximum)"
        case let .tooManyPathComponents(path, actual, maximum):
            return "content-pack GAME path \(path) has \(actual) components, exceeding \(maximum)"
        case let .indexTooLarge(actual, maximum):
            return "content-pack GAME path index has \(actual) bytes, exceeding \(maximum)"
        case let .conflictingNode(path):
            return "content-pack GAME path is both a file and directory: \(path)"
        }
    }
}

/// Immutable, case-insensitive Source GAME view over loose content roots and
/// their nested VPKs. Priority is the same as `GModContentPackAssetSource`:
/// loose garrysmod/platform/sourceengine roots first, then its ordered VPKs.
public final class GModContentPackGameFileSystem:
    LuaVirtualFileSystem, @unchecked Sendable
{
    private enum Storage: @unchecked Sendable {
        case loose(packPath: String)
        case vpk(archive: GMLuaVPKArchive, logicalPath: LuaString)
    }

    private struct FileRecord: @unchecked Sendable {
        let path: String
        let byteCount: UInt64
        let storage: Storage
    }

    private struct CandidateLayer {
        let records: [FileRecord]
    }

    public let limits: GModContentPackGameFileSystemLimits
    public let fileCount: Int

    private let source: GModContentPackAssetSource
    private let records: [String: FileRecord]
    private let directories: [String: String]
    private let children: [String: [LuaVirtualFileSystemEntry]]

    public init(
        source: GModContentPackAssetSource,
        limits: GModContentPackGameFileSystemLimits = .init()
    ) throws {
        guard limits.maximumIndexedEntryCount >= 0,
              limits.maximumPathByteCount >= 0,
              limits.maximumPathComponentCount >= 0 else {
            throw GModContentPackGameFileSystemError.invalidLimits
        }
        self.source = source
        self.limits = limits

        var scannedEntryCount = 0
        var scannedPathByteCount: UInt64 = 0
        var layers: [CandidateLayer] = []

        for root in ["garrysmod", "platform", "sourceengine"] {
            let prefix = root + "/"
            let paths = source.pack.entries.values.lazy
                .map(\.path)
                .filter { $0.hasPrefix(prefix) }
                .sorted()
            var layerRecords: [FileRecord] = []
            layerRecords.reserveCapacity(paths.count)
            for packPath in paths {
                let logicalPath = String(packPath.dropFirst(prefix.count))
                try Self.account(
                    logicalPath,
                    count: &scannedEntryCount,
                    pathBytes: &scannedPathByteCount,
                    limits: limits
                )
                guard let entry = source.pack.entries[packPath] else { continue }
                layerRecords.append(FileRecord(
                    path: logicalPath,
                    byteCount: entry.uncompressedByteCount,
                    storage: .loose(packPath: packPath)
                ))
            }
            try Self.validateLayer(layerRecords)
            layers.append(CandidateLayer(records: layerRecords))
        }

        for archive in source.archives {
            var layerRecords: [FileRecord] = []
            layerRecords.reserveCapacity(archive.logicalFilePaths.count)
            for bytesPath in archive.logicalFilePaths {
                try Self.account(
                    bytesPath,
                    count: &scannedEntryCount,
                    pathBytes: &scannedPathByteCount,
                    limits: limits
                )
                // LuaVirtualFileSystem is String-addressed. Invalid UTF-8 VPK
                // entries remain available through GMLuaVPKArchive's byte API
                // but cannot be projected without corrupting their identity.
                guard let logicalPath = String(
                    bytes: bytesPath.bytes,
                    encoding: .utf8
                ) else { continue }
                guard let byteCount = try archive.byteCount(for: bytesPath) else {
                    continue
                }
                layerRecords.append(FileRecord(
                    path: logicalPath,
                    byteCount: byteCount,
                    storage: .vpk(
                        archive: archive,
                        logicalPath: bytesPath
                    )
                ))
            }
            try Self.validateLayer(layerRecords)
            layers.append(CandidateLayer(records: layerRecords))
        }

        var visibleRecords: [String: FileRecord] = [:]
        var visibleDirectories: [String: String] = ["": ""]
        for layer in layers {
            for record in layer.records {
                let key = Self.fold(record.path)
                guard visibleRecords[key] == nil,
                      visibleDirectories[key] == nil,
                      !Self.hasFileAncestor(
                        record.path,
                        records: visibleRecords
                      ) else { continue }
                visibleRecords[key] = record
                Self.addParentDirectories(
                    of: record.path,
                    to: &visibleDirectories
                )
            }
        }

        records = visibleRecords
        directories = visibleDirectories
        children = Self.makeChildren(
            records: visibleRecords,
            directories: visibleDirectories
        )
        fileCount = visibleRecords.count
    }

    public func fileExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path, allowEmpty: false) else {
            return false
        }
        return records[Self.fold(normalized)] != nil
    }

    public func directoryExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path, allowEmpty: true) else {
            return false
        }
        return directories[Self.fold(normalized)] != nil
    }

    public func listDirectory(at path: String) throws
        -> [LuaVirtualFileSystemEntry]
    {
        let normalized = try Self.normalize(path, allowEmpty: true)
        let key = Self.fold(normalized)
        if records[key] != nil { throw GMLuaFileSystemError.notDirectory(path) }
        guard directories[key] != nil else {
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        return children[key] ?? []
    }

    public func readFile(at path: String) throws -> Data {
        let normalized = try Self.normalize(path, allowEmpty: false)
        guard let record = records[Self.fold(normalized)] else {
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        guard record.byteCount <= limits.maximumFileByteCount else {
            throw GModContentPackAssetSourceError.assetTooLarge(
                path: record.path,
                byteCount: record.byteCount,
                maximum: limits.maximumFileByteCount
            )
        }
        switch record.storage {
        case let .loose(packPath):
            return try source.pack.data(
                for: packPath,
                maximumByteCount: limits.maximumFileByteCount
            )
        case let .vpk(archive, logicalPath):
            guard let result = try archive.data(for: logicalPath) else {
                throw GMLuaFileSystemError.fileNotFound(path)
            }
            return result
        }
    }

    public func writeFile(_ data: Data, at path: String) throws {
        throw GMLuaFileSystemError.readOnly(path)
    }

    public func removeFile(at path: String) throws {
        throw GMLuaFileSystemError.readOnly(path)
    }

    public func moveFile(from sourcePath: String, to destinationPath: String) throws {
        throw GMLuaFileSystemError.readOnly(sourcePath)
    }

    public func createDirectory(at path: String) throws {
        throw GMLuaFileSystemError.readOnly(path)
    }

    public func removeDirectory(at path: String) throws {
        throw GMLuaFileSystemError.readOnly(path)
    }

    public func moveDirectory(
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        throw GMLuaFileSystemError.readOnly(sourcePath)
    }

    private static func account(
        _ path: String,
        count: inout Int,
        pathBytes: inout UInt64,
        limits: GModContentPackGameFileSystemLimits
    ) throws {
        try account(
            Array(path.utf8),
            displayPath: path,
            count: &count,
            pathBytes: &pathBytes,
            limits: limits
        )
    }

    private static func account(
        _ path: LuaString,
        count: inout Int,
        pathBytes: inout UInt64,
        limits: GModContentPackGameFileSystemLimits
    ) throws {
        try account(
            path.bytes,
            displayPath: path.description,
            count: &count,
            pathBytes: &pathBytes,
            limits: limits
        )
    }

    private static func account(
        _ bytes: [UInt8],
        displayPath: String,
        count: inout Int,
        pathBytes: inout UInt64,
        limits: GModContentPackGameFileSystemLimits
    ) throws {
        let nextCount = count + 1
        guard nextCount <= limits.maximumIndexedEntryCount else {
            throw GModContentPackGameFileSystemError.tooManyEntries(
                actual: nextCount,
                maximum: limits.maximumIndexedEntryCount
            )
        }
        guard bytes.count <= limits.maximumPathByteCount else {
            throw GModContentPackGameFileSystemError.pathTooLong(
                path: displayPath,
                actual: bytes.count,
                maximum: limits.maximumPathByteCount
            )
        }
        let componentCount = bytes.reduce(into: 1) { count, byte in
            if byte == 0x2F || byte == 0x5C { count += 1 }
        }
        guard componentCount <= limits.maximumPathComponentCount else {
            throw GModContentPackGameFileSystemError.tooManyPathComponents(
                path: displayPath,
                actual: componentCount,
                maximum: limits.maximumPathComponentCount
            )
        }
        let added = UInt64(bytes.count)
        guard pathBytes <= UInt64.max - added else {
            throw GModContentPackGameFileSystemError.indexTooLarge(
                actual: .max,
                maximum: limits.maximumIndexPathByteCount
            )
        }
        let nextPathBytes = pathBytes + added
        guard nextPathBytes <= limits.maximumIndexPathByteCount else {
            throw GModContentPackGameFileSystemError.indexTooLarge(
                actual: nextPathBytes,
                maximum: limits.maximumIndexPathByteCount
            )
        }
        count = nextCount
        pathBytes = nextPathBytes
    }

    private static func validateLayer(_ records: [FileRecord]) throws {
        let keys = Set(records.map { fold($0.path) })
        for record in records {
            var components = record.path.split(separator: "/").map(String.init)
            components.removeLast()
            var ancestors: [String] = []
            for component in components {
                ancestors.append(component)
                let path = ancestors.joined(separator: "/")
                if keys.contains(fold(path)) {
                    throw GModContentPackGameFileSystemError.conflictingNode(
                        path: path
                    )
                }
            }
        }
    }

    private static func hasFileAncestor(
        _ path: String,
        records: [String: FileRecord]
    ) -> Bool {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var ancestors: [String] = []
        for component in components {
            ancestors.append(component)
            if records[fold(ancestors.joined(separator: "/"))] != nil {
                return true
            }
        }
        return false
    }

    private static func addParentDirectories(
        of path: String,
        to directories: inout [String: String]
    ) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var parents: [String] = []
        for component in components.dropLast() {
            parents.append(component)
            let directory = parents.joined(separator: "/")
            directories[fold(directory)] =
                directories[fold(directory)] ?? directory
        }
    }

    private static func makeChildren(
        records: [String: FileRecord],
        directories: [String: String]
    ) -> [String: [LuaVirtualFileSystemEntry]] {
        var result: [String: [String: LuaVirtualFileSystemEntry]] = [:]
        for directory in directories.values where !directory.isEmpty {
            let components = directory.split(separator: "/").map(String.init)
            let parent = components.dropLast().joined(separator: "/")
            let name = components.last!
            result[fold(parent), default: [:]][fold(name)] =
                LuaVirtualFileSystemEntry(name: name, isDirectory: true)
        }
        for record in records.values {
            let components = record.path.split(separator: "/").map(String.init)
            let parent = components.dropLast().joined(separator: "/")
            let name = components.last!
            result[fold(parent), default: [:]][fold(name)] =
                LuaVirtualFileSystemEntry(name: name, isDirectory: false)
        }
        return result.mapValues { entries in
            entries.values.sorted { lhs, rhs in
                let left = fold(lhs.name)
                let right = fold(rhs.name)
                if left != right { return left < right }
                return lhs.name < rhs.name
            }
        }
    }

    private static func normalize(_ rawPath: String, allowEmpty: Bool) throws
        -> String
    {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.contains("\0") else {
            throw GMLuaFileSystemError.invalidPath(rawPath)
        }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw GMLuaFileSystemError.invalidPath(rawPath)
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        guard !components.isEmpty else {
            if allowEmpty { return "" }
            throw GMLuaFileSystemError.invalidPath(rawPath)
        }
        return components.joined(separator: "/")
    }

    private static func fold(_ path: String) -> String { path.lowercased() }
}

/// Read-only bridge from the validated content-pack GAME projection into the
/// canonical Source search-path stack. The adapter does not add a writable
/// DATA overlay and does not alter the content pack's loose/VPK priority.
public final class GModContentPackSourceFileProvider:
    SourceFileProvider, @unchecked Sendable
{
    public let fileSystem: GModContentPackGameFileSystem

    public init(fileSystem: GModContentPackGameFileSystem) {
        self.fileSystem = fileSystem
    }

    public func fileExists(at logicalPath: String) -> Bool {
        fileSystem.fileExists(at: logicalPath)
    }

    public func directoryExists(at logicalPath: String) -> Bool {
        fileSystem.directoryExists(at: logicalPath)
    }

    public func readFile(at logicalPath: String) throws -> Data {
        do {
            return try fileSystem.readFile(at: logicalPath)
        } catch {
            throw Self.sourceError(error, path: logicalPath)
        }
    }

    public func listDirectory(at logicalPath: String) throws
        -> [SourceFileSystemEntry]
    {
        do {
            return try fileSystem.listDirectory(at: logicalPath).map {
                SourceFileSystemEntry(
                    name: $0.name,
                    isDirectory: $0.isDirectory
                )
            }
        } catch {
            throw Self.sourceError(error, path: logicalPath)
        }
    }

    public func displayPath(for logicalPath: String) -> String? { nil }

    private static func sourceError(_ error: Error, path: String) -> Error {
        guard let fileError = error as? GMLuaFileSystemError else {
            return error
        }
        switch fileError {
        case .fileNotFound:
            return SourceFileSystemError.fileNotFound(path)
        case .notDirectory:
            return SourceFileSystemError.notDirectory(path)
        case .invalidPath:
            return SourceFileSystemError.invalidPath(path)
        case .readOnly, .directoryNotEmpty, .crossMountMove:
            return error
        }
    }
}

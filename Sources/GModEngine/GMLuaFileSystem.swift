import Foundation
import GModLua

public enum GMLuaFileSystemError: Error, LocalizedError {
    case invalidPath(String)
    case readOnly(String)
    case fileNotFound(String)
    case crossMountMove(String, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): return "invalid GMod virtual path: \(path)"
        case let .readOnly(path): return "read-only GMod mount: \(path)"
        case let .fileNotFound(path): return "file not found: \(path)"
        case let .crossMountMove(source, destination):
            return "cannot move across GMod mounts: \(source) -> \(destination)"
        }
    }
}

/// A sandboxed host-directory adapter used by the Windows corpus runner and by
/// app-owned unpacked content on iPad. Every access is containment checked.
public final class GMLuaHostDirectoryFileSystem: LuaVirtualFileSystem, @unchecked Sendable {
    private let rootURL: URL
    private let writable: Bool

    public init(rootURL: URL, writable: Bool = false) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GMLuaFileSystemError.fileNotFound(root.path)
        }
        self.rootURL = root
        self.writable = writable
    }

    public func fileExists(at path: String) -> Bool {
        guard let url = try? resolve(path, allowMissingLeaf: false) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    public func readFile(at path: String) throws -> Data {
        let url = try resolve(path, allowMissingLeaf: false)
        guard fileExists(at: path) else { throw GMLuaFileSystemError.fileNotFound(path) }
        return try Data(contentsOf: url)
    }

    public func writeFile(_ data: Data, at path: String) throws {
        guard writable else { throw GMLuaFileSystemError.readOnly(path) }
        let url = try resolve(path, allowMissingLeaf: true)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func removeFile(at path: String) throws {
        guard writable else { throw GMLuaFileSystemError.readOnly(path) }
        let url = try resolve(path, allowMissingLeaf: false)
        guard fileExists(at: path) else { throw GMLuaFileSystemError.fileNotFound(path) }
        try FileManager.default.removeItem(at: url)
    }

    public func moveFile(from sourcePath: String, to destinationPath: String) throws {
        guard writable else { throw GMLuaFileSystemError.readOnly(sourcePath) }
        let source = try resolve(sourcePath, allowMissingLeaf: false)
        let destination = try resolve(destinationPath, allowMissingLeaf: true)
        guard fileExists(at: sourcePath) else { throw GMLuaFileSystemError.fileNotFound(sourcePath) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func resolve(_ path: String, allowMissingLeaf: Bool) throws -> URL {
        let normalized = try GMLuaMountedFileSystem.normalize(path, allowEmpty: false)
        let components = normalized.split(separator: "/").map(String.init)
        var candidate = rootURL
        for (index, component) in components.enumerated() {
            // Source content is authored for Windows' case-insensitive lookup,
            // while iPad app storage is case-sensitive. Prefer an exact name;
            // otherwise choose the lexically first case-folded match so an
            // accidentally ambiguous mount remains deterministic.
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )) ?? []
            if let exactMatch = entries.first(where: { $0.lastPathComponent == component }) {
                candidate = exactMatch
                continue
            }
            let foldedMatches = entries
                .filter { $0.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let match = foldedMatches.first {
                candidate = match
                continue
            }

            let isLeaf = index == components.count - 1
            if isLeaf && allowMissingLeaf {
                candidate = candidate.appendingPathComponent(component)
                continue
            }
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        candidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path.replacingOccurrences(of: "\\", with: "/")
        let candidatePath = candidate.path.replacingOccurrences(of: "\\", with: "/")
        let containmentPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(containmentPrefix) else {
            throw GMLuaFileSystemError.invalidPath(path)
        }
        return candidate
    }
}

public struct GMLuaFileMount {
    public let name: String
    public let virtualRoot: String
    public let sourceRoot: String
    public let priority: Int
    public let writable: Bool
    public let fileSystem: LuaVirtualFileSystem

    public init(
        name: String,
        virtualRoot: String = "",
        sourceRoot: String = "",
        priority: Int = 0,
        writable: Bool = false,
        fileSystem: LuaVirtualFileSystem
    ) throws {
        self.name = name
        self.virtualRoot = try GMLuaMountedFileSystem.normalize(virtualRoot, allowEmpty: true)
        self.sourceRoot = try GMLuaMountedFileSystem.normalize(sourceRoot, allowEmpty: true)
        self.priority = priority
        self.writable = writable
        self.fileSystem = fileSystem
    }
}

/// Priority ordered VFS mounts. A writable memory layer can be placed above the
/// read-only Garry's Mod install, keeping engine content immutable.
public final class GMLuaMountedFileSystem: LuaVirtualFileSystem, @unchecked Sendable {
    private let mounts: [GMLuaFileMount]

    public init(mounts: [GMLuaFileMount]) {
        self.mounts = mounts.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public func fileExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path, allowEmpty: false) else { return false }
        return mounts.contains { mount in
            guard let routed = route(normalized, through: mount) else { return false }
            return mount.fileSystem.fileExists(at: routed)
        }
    }

    public func readFile(at path: String) throws -> Data {
        let normalized = try Self.normalize(path, allowEmpty: false)
        for mount in mounts {
            guard let routed = route(normalized, through: mount),
                  mount.fileSystem.fileExists(at: routed) else { continue }
            return try mount.fileSystem.readFile(at: routed)
        }
        throw GMLuaFileSystemError.fileNotFound(path)
    }

    public func writeFile(_ data: Data, at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        guard let target = writableRoute(normalized) else {
            throw GMLuaFileSystemError.readOnly(path)
        }
        try target.mount.fileSystem.writeFile(data, at: target.path)
    }

    public func removeFile(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        guard let target = mounts.lazy.compactMap({ mount -> (mount: GMLuaFileMount, path: String)? in
            guard mount.writable, let routed = self.route(normalized, through: mount),
                  mount.fileSystem.fileExists(at: routed) else { return nil }
            return (mount, routed)
        }).first else {
            throw GMLuaFileSystemError.readOnly(path)
        }
        try target.mount.fileSystem.removeFile(at: target.path)
    }

    public func moveFile(from sourcePath: String, to destinationPath: String) throws {
        let source = try Self.normalize(sourcePath, allowEmpty: false)
        let destination = try Self.normalize(destinationPath, allowEmpty: false)
        for mount in mounts where mount.writable {
            guard let routedSource = route(source, through: mount),
                  mount.fileSystem.fileExists(at: routedSource) else { continue }
            guard let routedDestination = route(destination, through: mount) else {
                throw GMLuaFileSystemError.crossMountMove(sourcePath, destinationPath)
            }
            try mount.fileSystem.moveFile(from: routedSource, to: routedDestination)
            return
        }
        throw GMLuaFileSystemError.readOnly(sourcePath)
    }

    private func writableRoute(_ path: String) -> (mount: GMLuaFileMount, path: String)? {
        for mount in mounts where mount.writable {
            if let routed = route(path, through: mount) { return (mount, routed) }
        }
        return nil
    }

    private func route(_ path: String, through mount: GMLuaFileMount) -> String? {
        let relative: String
        if mount.virtualRoot.isEmpty {
            relative = path
        } else if path == mount.virtualRoot {
            relative = ""
        } else if path.hasPrefix(mount.virtualRoot + "/") {
            relative = String(path.dropFirst(mount.virtualRoot.count + 1))
        } else {
            return nil
        }
        if mount.sourceRoot.isEmpty { return relative }
        if relative.isEmpty { return mount.sourceRoot }
        return mount.sourceRoot + "/" + relative
    }

    static func normalize(_ rawPath: String, allowEmpty: Bool) throws -> String {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":") else {
            throw GMLuaFileSystemError.invalidPath(rawPath)
        }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw GMLuaFileSystemError.invalidPath(rawPath) }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        if components.isEmpty {
            if allowEmpty { return "" }
            throw GMLuaFileSystemError.invalidPath(rawPath)
        }
        return components.joined(separator: "/")
    }
}

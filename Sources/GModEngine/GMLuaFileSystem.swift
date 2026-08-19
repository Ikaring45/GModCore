import Foundation
import GModLua

public enum GMLuaFileSystemError: Error, LocalizedError {
    case invalidPath(String)
    case readOnly(String)
    case fileNotFound(String)
    case notDirectory(String)
    case directoryNotEmpty(String)
    case crossMountMove(String, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): return "invalid GMod virtual path: \(path)"
        case let .readOnly(path): return "read-only GMod mount: \(path)"
        case let .fileNotFound(path): return "file not found: \(path)"
        case let .notDirectory(path): return "not a directory: \(path)"
        case let .directoryNotEmpty(path): return "directory is not empty: \(path)"
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

    public func directoryExists(at path: String) -> Bool {
        guard let url = try? resolve(path, allowMissingLeaf: false, allowEmpty: true) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func listDirectory(at path: String) throws -> [LuaVirtualFileSystemEntry] {
        let url = try resolve(path, allowMissingLeaf: false, allowEmpty: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        guard isDirectory.boolValue else { throw GMLuaFileSystemError.notDirectory(path) }

        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )
        var entries: [LuaVirtualFileSystemEntry] = []
        for child in urls {
            let relative = path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent
            // Resolve every entry again so a symlink escaping the sandbox is
            // never exposed by directory enumeration.
            let resolved = try resolve(relative, allowMissingLeaf: false, allowEmpty: false)
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
            entries.append(LuaVirtualFileSystemEntry(
                name: child.lastPathComponent,
                isDirectory: values.isDirectory == true
            ))
        }
        return Self.sorted(entries)
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

    public func createDirectory(at path: String) throws {
        guard writable else { throw GMLuaFileSystemError.readOnly(path) }
        let url = try resolve(path, allowMissingLeaf: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func removeDirectory(at path: String) throws {
        guard writable else { throw GMLuaFileSystemError.readOnly(path) }
        let url = try resolve(path, allowMissingLeaf: false)
        guard directoryExists(at: path) else { throw GMLuaFileSystemError.fileNotFound(path) }
        guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
            throw GMLuaFileSystemError.directoryNotEmpty(path)
        }
        try FileManager.default.removeItem(at: url)
    }

    public func moveDirectory(from sourcePath: String, to destinationPath: String) throws {
        guard writable else { throw GMLuaFileSystemError.readOnly(sourcePath) }
        let source = try resolve(sourcePath, allowMissingLeaf: false)
        let destination = try resolve(destinationPath, allowMissingLeaf: true)
        guard directoryExists(at: sourcePath) else {
            throw GMLuaFileSystemError.fileNotFound(sourcePath)
        }
        let sourceNormalized = try GMLuaMountedFileSystem.normalize(sourcePath, allowEmpty: false)
        let destinationNormalized = try GMLuaMountedFileSystem.normalize(
            destinationPath,
            allowEmpty: false
        )
        guard sourceNormalized.caseInsensitiveCompare(destinationNormalized) != .orderedSame,
              !destinationNormalized.lowercased().hasPrefix(sourceNormalized.lowercased() + "/"),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw GMLuaFileSystemError.invalidPath(destinationPath)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func resolve(
        _ path: String,
        allowMissingLeaf: Bool,
        allowEmpty: Bool = false
    ) throws -> URL {
        let normalized = try GMLuaMountedFileSystem.normalize(
            path,
            allowEmpty: allowEmpty,
            allowReservedWhiteout: true
        )
        let components = normalized.split(separator: "/").map(String.init)
        var candidate = rootURL
        var index = 0
        while index < components.count {
            let component = components[index]
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
                index += 1
                continue
            }
            let foldedMatches = entries
                .filter { $0.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let match = foldedMatches.first {
                candidate = match
                index += 1
                continue
            }

            if allowMissingLeaf {
                // Writes may create an entirely new nested tree in an empty
                // app-owned overlay, not just a missing final filename.
                for remaining in components[index...] {
                    candidate = candidate.appendingPathComponent(remaining)
                }
                break
            }
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        candidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path.replacingOccurrences(of: "\\", with: "/")
        let candidatePath = candidate.path.replacingOccurrences(of: "\\", with: "/")
        let containmentPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath == rootPath || candidatePath.hasPrefix(containmentPrefix) else {
            throw GMLuaFileSystemError.invalidPath(path)
        }
        return candidate
    }

    private static func sorted(
        _ entries: [LuaVirtualFileSystemEntry]
    ) -> [LuaVirtualFileSystemEntry] {
        entries.sorted { lhs, rhs in
            let foldedLHS = lhs.name.lowercased()
            let foldedRHS = rhs.name.lowercased()
            if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
            return lhs.name < rhs.name
        }
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
    private enum VisibleNodeKind {
        case file
        case directory
    }

    private static let whiteoutDirectory = ".garrys-pad-vfs-whiteouts"
    private static let whiteoutVersion = "v1"

    private let mounts: [GMLuaFileMount]
    private let lock = NSRecursiveLock()

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
        lock.lock()
        defer { lock.unlock() }
        return visibleNode(for: normalized)?.kind == .file
    }

    public func directoryExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path, allowEmpty: true) else { return false }
        if normalized.isEmpty { return true }
        lock.lock()
        defer { lock.unlock() }
        return visibleNode(for: normalized)?.kind == .directory
    }

    public func listDirectory(at path: String) throws -> [LuaVirtualFileSystemEntry] {
        let normalized = try Self.normalize(path, allowEmpty: true)
        lock.lock()
        defer { lock.unlock() }

        if !normalized.isEmpty, visibleNode(for: normalized)?.kind == .file {
            throw GMLuaFileSystemError.notDirectory(path)
        }

        var resolved: [String: LuaVirtualFileSystemEntry] = [:]
        var foundDirectory = normalized.isEmpty
        for (index, mount) in mounts.enumerated() {
            guard !isWhiteouted(normalized, throughMountIndex: index) else { continue }
            let entries: [LuaVirtualFileSystemEntry]
            if let synthetic = syntheticMountEntry(directory: normalized, mount: mount) {
                entries = [synthetic]
                foundDirectory = true
            } else if let routed = route(normalized, through: mount),
                      let listed = try? mount.fileSystem.listDirectory(at: routed) {
                entries = listed
                foundDirectory = true
            } else {
                continue
            }

            for entry in entries where entry.name.caseInsensitiveCompare(Self.whiteoutDirectory) != .orderedSame {
                let fullPath = normalized.isEmpty ? entry.name : normalized + "/" + entry.name
                let folded = fullPath.lowercased()
                guard resolved[folded] == nil else { continue }
                guard !isWhiteouted(fullPath, throughMountIndex: index) else { continue }
                resolved[folded] = entry
            }
        }
        guard foundDirectory else { throw GMLuaFileSystemError.fileNotFound(path) }
        return Self.sorted(Array(resolved.values))
    }

    public func readFile(at path: String) throws -> Data {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        if let node = visibleNode(for: normalized),
           node.kind == .file,
           let routed = route(normalized, through: mounts[node.mountIndex]) {
            return try mounts[node.mountIndex].fileSystem.readFile(at: routed)
        }
        throw GMLuaFileSystemError.fileNotFound(path)
    }

    public func writeFile(_ data: Data, at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard let target = writableRoute(normalized) else {
            throw GMLuaFileSystemError.readOnly(path)
        }
        try target.mount.fileSystem.writeFile(data, at: target.path)
        try clearWhiteoutsForPathAndAncestors(for: normalized, in: target.mount)
    }

    public func removeFile(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard visibleNode(for: normalized)?.kind == .file else {
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        guard let whiteoutTarget = writableRoute(normalized) else {
            throw GMLuaFileSystemError.readOnly(path)
        }

        // Remove every writable copy. If a lower read-only copy remains, the
        // marker in the highest writable layer prevents it from resurrecting.
        for mount in mounts where mount.writable {
            guard let routed = route(normalized, through: mount),
                  mount.fileSystem.fileExists(at: routed) else { continue }
            try mount.fileSystem.removeFile(at: routed)
        }
        if physicalNodeExists(normalized) {
            try writeWhiteout(for: normalized, in: whiteoutTarget.mount)
        } else {
            try clearWhiteout(for: normalized, in: whiteoutTarget.mount)
        }
    }

    public func moveFile(from sourcePath: String, to destinationPath: String) throws {
        let source = try Self.normalize(sourcePath, allowEmpty: false)
        let destination = try Self.normalize(destinationPath, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        if source.caseInsensitiveCompare(destination) == .orderedSame { return }
        let data = try readFile(at: source)
        try writeFile(data, at: destination)
        try removeFile(at: source)
    }

    public func createDirectory(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard visibleNode(for: normalized)?.kind != .file else {
            throw GMLuaFileSystemError.notDirectory(path)
        }
        guard let target = writableRoute(normalized) else {
            throw GMLuaFileSystemError.readOnly(path)
        }
        try target.mount.fileSystem.createDirectory(at: target.path)
        try clearWhiteoutsForPathAndAncestors(for: normalized, in: target.mount)
    }

    public func removeDirectory(at path: String) throws {
        let normalized = try Self.normalize(path, allowEmpty: false)
        lock.lock()
        defer { lock.unlock() }
        guard visibleNode(for: normalized)?.kind == .directory else {
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        let entries = try listDirectory(at: normalized)
        guard entries.isEmpty else { throw GMLuaFileSystemError.directoryNotEmpty(path) }
        guard let whiteoutTarget = writableRoute(normalized) else {
            throw GMLuaFileSystemError.readOnly(path)
        }

        for mount in mounts where mount.writable {
            guard let routed = route(normalized, through: mount),
                  mount.fileSystem.directoryExists(at: routed) else { continue }
            try mount.fileSystem.removeDirectory(at: routed)
        }
        if physicalNodeExists(normalized) {
            try writeWhiteout(for: normalized, in: whiteoutTarget.mount)
        } else {
            try clearWhiteout(for: normalized, in: whiteoutTarget.mount)
        }
    }

    public func moveDirectory(from sourcePath: String, to destinationPath: String) throws {
        let source = try Self.normalize(sourcePath, allowEmpty: false)
        let destination = try Self.normalize(destinationPath, allowEmpty: false)
        let foldedSource = source.lowercased()
        let foldedDestination = destination.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if foldedSource == foldedDestination { return }
        guard !foldedDestination.hasPrefix(foldedSource + "/") else {
            throw GMLuaFileSystemError.invalidPath(destinationPath)
        }
        guard visibleNode(for: source)?.kind == .directory else {
            throw GMLuaFileSystemError.fileNotFound(sourcePath)
        }
        guard visibleNode(for: destination) == nil else {
            throw GMLuaFileSystemError.invalidPath(destinationPath)
        }
        try copyDirectoryTree(from: source, to: destination)
        try removeDirectoryTree(at: source)
    }

    private func writableRoute(_ path: String) -> (mount: GMLuaFileMount, path: String)? {
        for mount in mounts where mount.writable {
            if let routed = route(path, through: mount) { return (mount, routed) }
        }
        return nil
    }

    /// Resolves the first node visible at a logical path across the priority
    /// ordered mount stack. A node's type is part of that winning entry: an
    /// upper directory hides a lower file with the same name, and an upper
    /// file hides a lower directory. Keeping both public existence queries on
    /// this one resolver prevents a path from being observable as both types.
    private func visibleNode(
        for path: String
    ) -> (mountIndex: Int, kind: VisibleNodeKind)? {
        for (index, mount) in mounts.enumerated() {
            if isWhiteouted(path, throughMountIndex: index) { continue }
            if isVirtualMountDirectory(path, for: mount) {
                return (index, .directory)
            }
            guard let routed = route(path, through: mount) else { continue }
            if mount.fileSystem.fileExists(at: routed) {
                return (index, .file)
            }
            if mount.fileSystem.directoryExists(at: routed) {
                return (index, .directory)
            }
        }
        return nil
    }

    private func physicalNodeExists(_ path: String) -> Bool {
        mounts.contains { mount in
            if isVirtualMountDirectory(path, for: mount) {
                return true
            }
            guard let routed = route(path, through: mount) else { return false }
            return mount.fileSystem.fileExists(at: routed)
                || mount.fileSystem.directoryExists(at: routed)
        }
    }

    private func isWhiteouted(_ path: String, throughMountIndex index: Int) -> Bool {
        guard index >= 0 else { return false }
        for candidateIndex in 0...index {
            let mount = mounts[candidateIndex]
            guard mount.writable, route(path, through: mount) != nil else { continue }
            if whiteoutExistsForPathOrAncestor(of: path, in: mount) { return true }
        }
        return false
    }

    private func whiteoutExistsForPathOrAncestor(
        of path: String,
        in mount: GMLuaFileMount
    ) -> Bool {
        var components: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            components.append(component)
            if whiteoutExists(for: components.joined(separator: "/"), in: mount) {
                return true
            }
        }
        return false
    }

    private func whiteoutExists(for path: String, in mount: GMLuaFileMount) -> Bool {
        mount.fileSystem.fileExists(at: whiteoutMarkerPath(for: path, in: mount))
    }

    private func writeWhiteout(for path: String, in mount: GMLuaFileMount) throws {
        try mount.fileSystem.writeFile(Data(), at: whiteoutMarkerPath(for: path, in: mount))
    }

    private func clearWhiteout(for path: String, in mount: GMLuaFileMount) throws {
        let marker = whiteoutMarkerPath(for: path, in: mount)
        if mount.fileSystem.fileExists(at: marker) {
            try mount.fileSystem.removeFile(at: marker)
        }
    }

    private func clearWhiteoutsForPathAndAncestors(
        for path: String,
        in mount: GMLuaFileMount
    ) throws {
        var components: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            components.append(component)
            try clearWhiteout(for: components.joined(separator: "/"), in: mount)
        }
    }

    private func copyDirectoryTree(from source: String, to destination: String) throws {
        try createDirectory(at: destination)
        for entry in try listDirectory(at: source) {
            let childSource = source + "/" + entry.name
            let childDestination = destination + "/" + entry.name
            if entry.isDirectory {
                try copyDirectoryTree(from: childSource, to: childDestination)
            } else {
                try writeFile(try readFile(at: childSource), at: childDestination)
            }
        }
    }

    private func removeDirectoryTree(at path: String) throws {
        for entry in try listDirectory(at: path) {
            let child = path + "/" + entry.name
            if entry.isDirectory {
                try removeDirectoryTree(at: child)
            } else {
                try removeFile(at: child)
            }
        }
        try removeDirectory(at: path)
    }

    private func whiteoutMarkerPath(for path: String, in mount: GMLuaFileMount) -> String {
        let prefix = mount.sourceRoot.isEmpty ? "" : mount.sourceRoot + "/"
        return prefix + Self.whiteoutDirectory + "/" + Self.whiteoutVersion + "/" + path + ".deleted"
    }

    private func syntheticMountEntry(
        directory: String,
        mount: GMLuaFileMount
    ) -> LuaVirtualFileSystemEntry? {
        guard !mount.virtualRoot.isEmpty else { return nil }
        let directoryComponents = directory.split(separator: "/").map(String.init)
        let rootComponents = mount.virtualRoot.split(separator: "/").map(String.init)
        guard directoryComponents.count < rootComponents.count,
              zip(directoryComponents, rootComponents).allSatisfy({
                  $0.0.caseInsensitiveCompare($0.1) == .orderedSame
              }) else { return nil }
        return LuaVirtualFileSystemEntry(
            name: rootComponents[directoryComponents.count],
            isDirectory: true
        )
    }

    private func route(_ path: String, through mount: GMLuaFileMount) -> String? {
        let pathComponents = path.split(separator: "/").map(String.init)
        let rootComponents = mount.virtualRoot.split(separator: "/").map(String.init)
        guard pathComponents.count >= rootComponents.count,
              zip(rootComponents, pathComponents).allSatisfy({
                  $0.0.caseInsensitiveCompare($0.1) == .orderedSame
              }) else { return nil }
        let relative = pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
        if mount.sourceRoot.isEmpty { return relative }
        if relative.isEmpty { return mount.sourceRoot }
        return mount.sourceRoot + "/" + relative
    }

    private func isVirtualMountDirectory(_ path: String, for mount: GMLuaFileMount) -> Bool {
        guard !mount.virtualRoot.isEmpty else { return false }
        let pathComponents = path.split(separator: "/").map(String.init)
        let rootComponents = mount.virtualRoot.split(separator: "/").map(String.init)
        guard pathComponents.count <= rootComponents.count else { return false }
        return zip(pathComponents, rootComponents).allSatisfy {
            $0.0.caseInsensitiveCompare($0.1) == .orderedSame
        }
    }

    static func normalize(
        _ rawPath: String,
        allowEmpty: Bool,
        allowReservedWhiteout: Bool = false
    ) throws -> String {
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
                guard allowReservedWhiteout ||
                        String(component).caseInsensitiveCompare(Self.whiteoutDirectory) != .orderedSame else {
                    throw GMLuaFileSystemError.invalidPath(rawPath)
                }
                components.append(component)
            }
        }
        if components.isEmpty {
            if allowEmpty { return "" }
            throw GMLuaFileSystemError.invalidPath(rawPath)
        }
        return components.joined(separator: "/")
    }

    private static func sorted(
        _ entries: [LuaVirtualFileSystemEntry]
    ) -> [LuaVirtualFileSystemEntry] {
        entries.sorted { lhs, rhs in
            let foldedLHS = lhs.name.lowercased()
            let foldedRHS = rhs.name.lowercased()
            if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
            return lhs.name < rhs.name
        }
    }
}

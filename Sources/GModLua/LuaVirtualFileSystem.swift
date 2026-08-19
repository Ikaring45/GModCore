import Foundation

/// Byte-oriented filesystem boundary used by Lua IO, loadfile, and require.
/// GMod mounts can implement this protocol without exposing host filesystem
/// paths to Lua code.
public protocol LuaVirtualFileSystem: AnyObject {
    func fileExists(at path: String) -> Bool
    func readFile(at path: String) throws -> Data
    func writeFile(_ data: Data, at path: String) throws
    func removeFile(at path: String) throws
    func moveFile(from sourcePath: String, to destinationPath: String) throws
}

public enum LuaVirtualFileSystemError: Error, LocalizedError {
    case invalidPath(String)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): return "invalid virtual path: \(path)"
        case let .fileNotFound(path): return "file not found: \(path)"
        }
    }
}

/// Writable in-memory filesystem used by the official conformance runner and
/// suitable as the writable layer above read-only GMod mounts.
public final class LuaMemoryFileSystem: LuaVirtualFileSystem, @unchecked Sendable {
    private var files: [String: Data] = [:]
    private let lock = NSLock()

    public init(initialFiles: [String: Data] = [:]) throws {
        for (path, data) in initialFiles {
            files[try Self.normalize(path)] = data
        }
    }

    public func fileExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalize(path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return files[normalized] != nil
    }

    public func readFile(at path: String) throws -> Data {
        let normalized = try Self.normalize(path)
        lock.lock()
        defer { lock.unlock() }
        guard let data = files[normalized] else {
            throw LuaVirtualFileSystemError.fileNotFound(path)
        }
        return data
    }

    public func writeFile(_ data: Data, at path: String) throws {
        let normalized = try Self.normalize(path)
        lock.lock()
        files[normalized] = data
        lock.unlock()
    }

    public func removeFile(at path: String) throws {
        let normalized = try Self.normalize(path)
        lock.lock()
        defer { lock.unlock() }
        guard files.removeValue(forKey: normalized) != nil else {
            throw LuaVirtualFileSystemError.fileNotFound(path)
        }
    }

    public func moveFile(from sourcePath: String, to destinationPath: String) throws {
        let source = try Self.normalize(sourcePath)
        let destination = try Self.normalize(destinationPath)
        lock.lock()
        defer { lock.unlock() }
        guard let data = files.removeValue(forKey: source) else {
            throw LuaVirtualFileSystemError.fileNotFound(sourcePath)
        }
        files[destination] = data
    }

    public func snapshot() -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return files
    }

    private static func normalize(_ rawPath: String) throws -> String {
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
            throw LuaVirtualFileSystemError.invalidPath(rawPath)
        }
        return components.joined(separator: "/")
    }
}

import Foundation

public enum GModBundledMap: String, CaseIterable, Sendable {
    case construct = "gm_construct"
    case flatgrass = "gm_flatgrass"
}

public enum GModBundledMapAssetKind: String, CaseIterable, Sendable {
    case bsp
    case nav
    case ain
}

public struct GModBundledGameAsset: Codable, Equatable, Sendable {
    public let logicalPath: String
    public let byteCount: Int
    public let sha256: String
}

public struct GModBundledGameAssetManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceScope: String
    public let assets: [GModBundledGameAsset]
}

public struct GModBundledClientContentFile: Codable, Equatable, Sendable {
    public let logicalPath: String
    public let byteCount: Int
    public let sha256: String
}

public struct GModBundledClientContentManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let sourceScope: String
    public let fileCount: Int
    public let byteCount: Int
    public let files: [GModBundledClientContentFile]
}

public enum GModGameAssetError: Error, CustomStringConvertible {
    case missingResource(String)
    case invalidManifest(String)
    case invalidContentPath(String)

    public var description: String {
        switch self {
        case let .missingResource(path):
            return "missing bundled GMod game asset: \(path)"
        case let .invalidManifest(message):
            return "invalid bundled GMod game asset manifest: \(message)"
        case let .invalidContentPath(path):
            return "invalid bundled GMod client-content path: \(path)"
        }
    }
}

/// Access to the exact, project-authorized base-game fixtures used by the
/// Source compatibility tests and by the Apple host. Workshop and addon
/// content is deliberately outside this bundle.
public enum GModGameAssets {
    private static let clientContentSourceScope =
        "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
        "gamemodes/sandbox/, and all materials/**/*.png entries from the base " +
        "garrysmod_dir.vpk; Workshop, cache, addons, downloads, and non-PNG " +
        "VPK material content excluded."

    public static func url(
        for map: GModBundledMap,
        kind: GModBundledMapAssetKind
    ) throws -> URL {
        let relativePath: String
        switch kind {
        case .bsp, .nav:
            relativePath = "Maps/\(map.rawValue).\(kind.rawValue)"
        case .ain:
            relativePath = "Maps/graphs/\(map.rawValue).ain"
        }
        return try resourceURL(relativePath: relativePath)
    }

    public static func data(
        for map: GModBundledMap,
        kind: GModBundledMapAssetKind,
        mappedIfSafe: Bool = true
    ) throws -> Data {
        try Data(
            contentsOf: url(for: map, kind: kind),
            options: mappedIfSafe ? .mappedIfSafe : []
        )
    }

    public static func manifest() throws -> GModBundledGameAssetManifest {
        let url = try resourceURL(relativePath: "GModGameAssetManifest.json")
        do {
            let decoded = try JSONDecoder().decode(
                GModBundledGameAssetManifest.self,
                from: Data(contentsOf: url)
            )
            guard decoded.schemaVersion == 1 else {
                throw GModGameAssetError.invalidManifest(
                    "unsupported schema version \(decoded.schemaVersion)"
                )
            }
            return decoded
        } catch let error as GModGameAssetError {
            throw error
        } catch {
            throw GModGameAssetError.invalidManifest(String(describing: error))
        }
    }

    /// Root of the project-authorized, read-only base Lua/gamemode content.
    /// It is suitable for a host-directory VFS mount on Apple platforms and
    /// deliberately excludes Workshop, cache, downloads, and addons.
    public static func clientContentRootURL() throws -> URL {
        try resourceDirectoryURL(relativePath: "ClientContent")
    }

    public static func clientContentManifest() throws
        -> GModBundledClientContentManifest
    {
        let url = try resourceURL(relativePath: "GModClientContentManifest.json")
        do {
            let decoded = try JSONDecoder().decode(
                GModBundledClientContentManifest.self,
                from: Data(contentsOf: url)
            )
            guard decoded.formatVersion == 1 else {
                throw GModGameAssetError.invalidManifest(
                    "unsupported client-content schema version \(decoded.formatVersion)"
                )
            }
            guard decoded.sourceScope == clientContentSourceScope else {
                throw GModGameAssetError.invalidManifest(
                    "unexpected client-content source scope"
                )
            }
            guard decoded.fileCount == decoded.files.count else {
                throw GModGameAssetError.invalidManifest(
                    "client-content fileCount does not match its entries"
                )
            }
            let paths = decoded.files.map(\.logicalPath)
            guard Set(paths).count == paths.count else {
                throw GModGameAssetError.invalidManifest(
                    "client-content logical paths are not unique"
                )
            }
            guard Set(paths.map { $0.lowercased() }).count == paths.count else {
                throw GModGameAssetError.invalidManifest(
                    "client-content paths collide under Source case folding"
                )
            }
            var byteCount = 0
            for file in decoded.files {
                guard file.logicalPath == (try normalizedClientContentPath(file.logicalPath)) else {
                    throw GModGameAssetError.invalidManifest(
                        "non-canonical client-content path: \(file.logicalPath)"
                    )
                }
                guard isAuthorizedClientContentPath(file.logicalPath) else {
                    throw GModGameAssetError.invalidManifest(
                        "client-content path is outside the authorized bundle scope: " +
                            file.logicalPath
                    )
                }
                guard file.byteCount >= 0 else {
                    throw GModGameAssetError.invalidManifest(
                        "negative client-content byte count: \(file.logicalPath)"
                    )
                }
                let addition = byteCount.addingReportingOverflow(file.byteCount)
                guard !addition.overflow else {
                    throw GModGameAssetError.invalidManifest(
                        "client-content byte count overflow"
                    )
                }
                byteCount = addition.partialValue
                guard file.sha256.count == 64,
                      file.sha256.utf8.allSatisfy({
                          (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
                      }) else {
                    throw GModGameAssetError.invalidManifest(
                        "invalid client-content SHA-256: \(file.logicalPath)"
                    )
                }
            }
            guard decoded.byteCount == byteCount else {
                throw GModGameAssetError.invalidManifest(
                    "client-content byteCount does not match its entries"
                )
            }
            return decoded
        } catch let error as GModGameAssetError {
            throw error
        } catch {
            throw GModGameAssetError.invalidManifest(String(describing: error))
        }
    }

    /// Resolves one manifest-style logical path without allowing traversal out
    /// of the immutable resource root.
    public static func clientContentURL(for logicalPath: String) throws -> URL {
        let normalized = try normalizedClientContentPath(logicalPath)
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)

        let root = try clientContentRootURL()
        let candidate = components.reduce(root) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw GModGameAssetError.missingResource("ClientContent/\(normalized)")
        }
        return candidate
    }

    public static func clientContentData(
        for logicalPath: String,
        mappedIfSafe: Bool = true
    ) throws -> Data {
        try Data(
            contentsOf: clientContentURL(for: logicalPath),
            options: mappedIfSafe ? .mappedIfSafe : []
        )
    }

    private static func resourceURL(relativePath: String) throws -> URL {
        guard let root = Bundle.module.resourceURL else {
            throw GModGameAssetError.missingResource(relativePath)
        }
        let candidates = [
            root.appendingPathComponent("Resources").appendingPathComponent(relativePath),
            root.appendingPathComponent(relativePath),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw GModGameAssetError.missingResource(relativePath)
    }

    private static func resourceDirectoryURL(relativePath: String) throws -> URL {
        guard let root = Bundle.module.resourceURL else {
            throw GModGameAssetError.missingResource(relativePath)
        }
        let candidates = [
            root.appendingPathComponent("Resources").appendingPathComponent(
                relativePath,
                isDirectory: true
            ),
            root.appendingPathComponent(relativePath, isDirectory: true),
        ]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return candidate
            }
        }
        throw GModGameAssetError.missingResource(relativePath)
    }

    private static func normalizedClientContentPath(_ logicalPath: String) throws -> String {
        guard !logicalPath.isEmpty,
              logicalPath == logicalPath.replacingOccurrences(of: "\\", with: "/"),
              !logicalPath.contains(":"),
              !logicalPath.hasPrefix("/") else {
            throw GModGameAssetError.invalidContentPath(logicalPath)
        }
        let components = logicalPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GModGameAssetError.invalidContentPath(logicalPath)
        }
        let normalized = components.map(String.init).joined(separator: "/")
        guard isAuthorizedClientContentPath(normalized) else {
            throw GModGameAssetError.invalidContentPath(logicalPath)
        }
        return normalized
    }

    private static func isAuthorizedClientContentPath(_ path: String) -> Bool {
        path.hasPrefix("lua/") ||
            path.hasPrefix("gamemodes/base/") ||
            path.hasPrefix("gamemodes/sandbox/") ||
            (path.hasPrefix("materials/") && path.lowercased().hasSuffix(".png"))
    }
}

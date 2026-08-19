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

public enum GModGameAssetError: Error, CustomStringConvertible {
    case missingResource(String)
    case invalidManifest(String)

    public var description: String {
        switch self {
        case let .missingResource(path):
            return "missing bundled GMod game asset: \(path)"
        case let .invalidManifest(message):
            return "invalid bundled GMod game asset manifest: \(message)"
        }
    }
}

/// Access to the exact, project-authorized base-game fixtures used by the
/// Source compatibility tests and by the Apple host. Workshop and addon
/// content is deliberately outside this bundle.
public enum GModGameAssets {
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
}

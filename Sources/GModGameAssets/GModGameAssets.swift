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

public struct GModSourceMaterialAsset: Codable, Equatable, Sendable {
    public let logicalPath: String
    public let sourceArchive: String
    public let byteCount: Int
    public let sha256: String
}

public struct GModSourceMaterialAllowlist: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceArchives: [String]
    public let selectionCriterion: String
    public let fileCount: Int
    public let byteCount: Int
    public let vmtCount: Int
    public let vtfCount: Int
    public let decodedMip0ByteCount: Int
    public let surfaceTextureMaterialPaths: [String]
    public let assets: [GModSourceMaterialAsset]
    public let unresolvedDynamicBaseTextures: [String]
    public let unresolvedMaterialLiterals: [String]
    public let unresolvedVMTDependencies: [String]
}

public enum GModGameAssetError: Error, Sendable, CustomStringConvertible {
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
        "gamemodes/sandbox/, all materials/**/*.png entries, and the exact " +
        "generated GModSourceMaterialAllowlist.json VMT/VTF closure from " +
        "garrysmod/garrysmod_dir.vpk and platform/platform_misc_dir.vpk; " +
        "Workshop, cache, addons, downloads, and all other VPK content excluded."

    private static let cachedSourceMaterialAllowlist:
        Result<GModSourceMaterialAllowlist, GModGameAssetError> = {
            do {
                return .success(try loadSourceMaterialAllowlist())
            } catch let error as GModGameAssetError {
                return .failure(error)
            } catch {
                return .failure(.invalidManifest(String(describing: error)))
            }
        }()

    private static let cachedSourceMaterialPaths:
        Result<Set<String>, GModGameAssetError> = {
            do {
                return .success(Set(try sourceMaterialAllowlist().assets.map(\.logicalPath)))
            } catch let error as GModGameAssetError {
                return .failure(error)
            } catch {
                return .failure(.invalidManifest(String(describing: error)))
            }
        }()

    public static func sourceMaterialAllowlist() throws
        -> GModSourceMaterialAllowlist
    {
        try cachedSourceMaterialAllowlist.get()
    }

    private static func loadSourceMaterialAllowlist() throws
        -> GModSourceMaterialAllowlist
    {
        let url = try resourceURL(relativePath: "GModSourceMaterialAllowlist.json")
        do {
            let decoded = try JSONDecoder().decode(
                GModSourceMaterialAllowlist.self,
                from: Data(contentsOf: url)
            )
            guard decoded.schemaVersion == 2,
                  decoded.sourceArchives == [
                      "garrysmod/garrysmod_dir.vpk",
                      "platform/platform_misc_dir.vpk",
                  ],
                  decoded.selectionCriterion ==
                    "Generated from bundled stock Lua literal Material/SetImage/" +
                    "SetMaterial roots present in garrysmod/garrysmod_dir.vpk and every " +
                    "literal surface.GetTextureID root in the exact garrysmod then " +
                    "platform VPK precedence, plus recursively existing Patch includes " +
                    "and resolved $basetexture VTFs. Dynamic and missing dependencies " +
                    "remain explicit.",
                  decoded.fileCount == 118,
                  decoded.byteCount == 3_013_414,
                  decoded.vmtCount == 72,
                  decoded.vtfCount == 46,
                  decoded.decodedMip0ByteCount == 8_075_776,
                  decoded.assets.count == decoded.fileCount else {
                throw GModGameAssetError.invalidManifest(
                    "unexpected Source material allowlist contract"
                )
            }
            let paths = decoded.assets.map(\.logicalPath)
            let surfacePaths = Set(decoded.surfaceTextureMaterialPaths)
            guard Set(paths).count == paths.count,
                  Set(paths.map { $0.lowercased() }).count == paths.count,
                  surfacePaths.count == decoded.surfaceTextureMaterialPaths.count,
                  surfacePaths.isSubset(of: Set(paths)) else {
                throw GModGameAssetError.invalidManifest(
                    "Source material allowlist paths are not unique"
                )
            }
            var byteCount = 0
            var vmtCount = 0
            var vtfCount = 0
            for asset in decoded.assets {
                guard asset.logicalPath == asset.logicalPath.lowercased(),
                      try normalizedSourceMaterialPath(asset.logicalPath)
                        == asset.logicalPath,
                      decoded.sourceArchives.contains(asset.sourceArchive) else {
                    throw GModGameAssetError.invalidManifest(
                        "invalid Source material allowlist path: \(asset.logicalPath)"
                    )
                }
                if asset.logicalPath.hasSuffix(".vmt") { vmtCount += 1 }
                if asset.logicalPath.hasSuffix(".vtf") { vtfCount += 1 }
                let addition = byteCount.addingReportingOverflow(asset.byteCount)
                guard asset.byteCount >= 0,
                      !addition.overflow,
                      isLowercaseSHA256(asset.sha256) else {
                    throw GModGameAssetError.invalidManifest(
                        "invalid Source material allowlist entry: \(asset.logicalPath)"
                    )
                }
                byteCount = addition.partialValue
            }
            guard byteCount == decoded.byteCount,
                  vmtCount == decoded.vmtCount,
                  vtfCount == decoded.vtfCount,
                  Set(decoded.unresolvedDynamicBaseTextures) == Set([
                      "materials/_gmod_frameblend.vtf",
                      "materials/_rt_fullframefb.vtf",
                      "materials/sprites/glow_test02.vtf",
                      "materials/sprites/light_glow01.vtf",
                  ]),
                  Set(decoded.unresolvedMaterialLiterals) == Set([
                      "effects/fire_cloud1",
                      "effects/spark",
                      "effects/strider_muzzle",
                      "sprites/heatwave",
                      "sprites/light_glow02_add",
                      "vgui/white_additive",
                      "scripted/breen_fakemonitor_1",
                      "../",
                  ]),
                  Set(decoded.unresolvedVMTDependencies) == Set([
                      "materials/effects/fire_cloud1.vmt",
                      "materials/effects/spark.vmt",
                      "materials/effects/strider_muzzle.vmt",
                      "materials/scripted/breen_fakemonitor_1.vmt",
                      "materials/sprites/heatwave.vmt",
                      "materials/sprites/light_glow02_add.vmt",
                      "materials/vgui/white_additive.vmt",
                  ]),
                  Set(decoded.surfaceTextureMaterialPaths) == Set([
                      "materials/gui/corner16.vmt",
                      "materials/gui/corner32.vmt",
                      "materials/gui/corner512.vmt",
                      "materials/gui/corner64.vmt",
                      "materials/gui/corner8.vmt",
                      "materials/gui/faceposer_indicator.vmt",
                      "materials/gui/gradient.vmt",
                      "materials/gui/icorner8.vmt",
                      "materials/gui/info.vmt",
                      "materials/gui/speech_lid.vmt",
                      "materials/models/weapons/v_toolgun/screen_bg.vmt",
                      "materials/vgui/gmod_camera.vmt",
                      "materials/vgui/gmod_tool.vmt",
                      "materials/vgui/white.vmt",
                      "materials/weapons/swep.vmt",
                  ]) else {
                throw GModGameAssetError.invalidManifest(
                    "Source material allowlist totals or diagnostics do not match"
                )
            }
            return decoded
        } catch let error as GModGameAssetError {
            throw error
        } catch {
            throw GModGameAssetError.invalidManifest(String(describing: error))
        }
    }

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
            let sourceMaterialAllowlist = try sourceMaterialAllowlist()
            let sourceMaterialPaths = try sourceMaterialPaths()
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
                guard file.logicalPath == (try normalizedClientContentPath(
                    file.logicalPath,
                    sourceMaterialPaths: sourceMaterialPaths
                )) else {
                    throw GModGameAssetError.invalidManifest(
                        "non-canonical client-content path: \(file.logicalPath)"
                    )
                }
                guard isAuthorizedClientContentPath(
                    file.logicalPath,
                    sourceMaterialPaths: sourceMaterialPaths
                ) else {
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
                guard isLowercaseSHA256(file.sha256) else {
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
            let sourceMaterialEntries = decoded.files.filter {
                $0.logicalPath.hasSuffix(".vmt") || $0.logicalPath.hasSuffix(".vtf")
            }
            let sourceMaterialEntriesByPath = Dictionary(
                uniqueKeysWithValues: sourceMaterialEntries.map {
                    ($0.logicalPath, $0)
                }
            )
            guard sourceMaterialEntriesByPath.count == sourceMaterialAllowlist.assets.count,
                  sourceMaterialAllowlist.assets.allSatisfy({ asset in
                      sourceMaterialEntriesByPath[asset.logicalPath].map {
                          $0.byteCount == asset.byteCount && $0.sha256 == asset.sha256
                      } == true
                  }) else {
                throw GModGameAssetError.invalidManifest(
                    "client-content Source materials do not exactly match the allowlist"
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
        let sourceMaterialPaths = try sourceMaterialPaths()
        let normalized = try normalizedClientContentPath(
            logicalPath,
            sourceMaterialPaths: sourceMaterialPaths
        )
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)

        let root = try clientContentRootURL()
        var candidate = root
        for componentValue in components {
            let component = String(componentValue)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )) ?? []
            if let exact = children.first(where: { $0.lastPathComponent == component }) {
                candidate = exact
            } else if let folded = children
                .filter({
                    $0.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame
                })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first {
                candidate = folded
            } else {
                candidate.appendPathComponent(component, isDirectory: false)
            }
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

    private static func normalizedClientContentPath(
        _ logicalPath: String,
        sourceMaterialPaths: Set<String>
    ) throws -> String {
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
        guard isAuthorizedClientContentPath(
            normalized,
            sourceMaterialPaths: sourceMaterialPaths
        ) else {
            throw GModGameAssetError.invalidContentPath(logicalPath)
        }
        return normalized
    }

    private static func isAuthorizedClientContentPath(
        _ path: String,
        sourceMaterialPaths: Set<String>
    ) -> Bool {
        path.hasPrefix("lua/") ||
            path.hasPrefix("gamemodes/base/") ||
            path.hasPrefix("gamemodes/sandbox/") ||
            (path.hasPrefix("materials/") && path.lowercased().hasSuffix(".png")) ||
            sourceMaterialPaths.contains(path.lowercased())
    }

    private static func normalizedSourceMaterialPath(
        _ logicalPath: String
    ) throws -> String {
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
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              logicalPath.hasPrefix("materials/"),
              logicalPath.hasSuffix(".vmt") || logicalPath.hasSuffix(".vtf") else {
            throw GModGameAssetError.invalidContentPath(logicalPath)
        }
        return components.map(String.init).joined(separator: "/")
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func sourceMaterialPaths() throws -> Set<String> {
        try cachedSourceMaterialPaths.get()
    }
}

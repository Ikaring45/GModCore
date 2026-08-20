import Foundation
import GModEngine
import GModGameAssets
import GModLua

public enum GModContentPackAssetSourceError: Error, Sendable, Equatable {
    case assetTooLarge(path: String, byteCount: UInt64, maximum: UInt64)
}

/// Unified loose-file and nested-VPK view of one Playgrounds content ZIP.
/// Large VPK chunks stay inside the ZIP and are read by exact byte range.
public final class GModContentPackAssetSource: @unchecked Sendable {
    public let pack: GarrysPADContentPack
    public let archives: [GMLuaVPKArchive]

    public init(pack: GarrysPADContentPack) throws {
        self.pack = pack
        let randomAccess = GMLuaVPKRandomAccessSource(
            byteCount: { [pack] path in
                try pack.byteCount(for: path)
            },
            read: { [pack] path, offset, count in
                try pack.data(for: path, offset: offset, count: count)
            }
        )
        let priority = [
            "garrysmod/garrysmod_dir.vpk",
            "platform/platform_misc_dir.vpk",
            "sourceengine/hl2_misc_dir.vpk",
            "sourceengine/hl2_textures_dir.vpk",
            "sourceengine/content_hl2_dir.vpk",
            "sourceengine/hl2_sound_misc_dir.vpk",
        ]
        archives = try priority.compactMap { path in
            guard pack.contains(path) else { return nil }
            return try GMLuaVPKArchive(
                directoryFilePath: path,
                randomAccessSource: randomAccess
            )
        }
    }

    public func data(
        for logicalPath: String,
        maximumByteCount: UInt64 = 64 * 1_024 * 1_024
    ) throws -> Data? {
        let normalized = logicalPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty,
              !normalized.split(separator: "/").contains("..") else {
            return nil
        }
        for root in ["garrysmod", "platform", "sourceengine"] {
            let candidate = "\(root)/\(normalized)"
            if pack.contains(candidate) {
                let byteCount = try pack.byteCount(for: candidate) ?? 0
                guard byteCount <= maximumByteCount else {
                    throw GModContentPackAssetSourceError.assetTooLarge(
                        path: candidate,
                        byteCount: byteCount,
                        maximum: maximumByteCount
                    )
                }
                return try pack.data(
                    for: candidate,
                    maximumByteCount: maximumByteCount
                )
            }
        }
        for archive in archives {
            if let byteCount = try archive.byteCount(for: normalized) {
                guard byteCount <= maximumByteCount else {
                    throw GModContentPackAssetSourceError.assetTooLarge(
                        path: normalized,
                        byteCount: byteCount,
                        maximum: maximumByteCount
                    )
                }
            }
            if let data = try archive.data(for: LuaString(normalized)) {
                return data
            }
        }
        return nil
    }
}

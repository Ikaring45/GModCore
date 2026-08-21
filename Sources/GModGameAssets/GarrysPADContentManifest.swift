import Foundation

public struct GarrysPADContentManifest: Decodable, Equatable, Sendable {
    public struct File: Decodable, Equatable, Sendable {
        public let path: String
        public let byteCount: UInt64
        public let sha256: String
    }

    public let schemaVersion: Int
    public let format: String
    public let profile: String
    public let createdAtUTC: String
    public let source: String
    public let mountRoots: [String]
    public let excludedRoots: [String]
    public let optionalCompleteBaseFamilies: [String]
    public let fileCount: Int
    public let byteCount: UInt64
    public let files: [File]
}

public struct GarrysPADContentVerificationProgress: Equatable, Sendable {
    public let currentPath: String?
    public let completedFileCount: Int
    public let totalFileCount: Int
    public let completedByteCount: UInt64
    public let totalByteCount: UInt64

    public init(
        currentPath: String?,
        completedFileCount: Int,
        totalFileCount: Int,
        completedByteCount: UInt64,
        totalByteCount: UInt64
    ) {
        self.currentPath = currentPath
        self.completedFileCount = completedFileCount
        self.totalFileCount = totalFileCount
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
    }
}

public enum GarrysPADContentManifestError: Error, Equatable,
    CustomStringConvertible, Sendable
{
    case invalid(String)
    case hashMismatch(path: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case let .invalid(reason):
            return "content-pack manifest is invalid: \(reason)"
        case let .hashMismatch(path, expected, actual):
            return "content-pack SHA-256 mismatch for \(path): " +
                "expected \(expected), got \(actual)"
        }
    }
}

/// Schema, authorization and streamed integrity checks shared by the Windows
/// test host and the Apple/Swift Playgrounds application.
public enum GarrysPADContentManifestValidator {
    private static let supportedProfiles = ["Playground", "Playable", "CompleteBase"]

    /// Reads the bounded root manifest (stored or method 8), parses every v1
    /// field, and requires the manifest's authorized payload set to exactly
    /// equal the ZIP index. Index equality is not a full content hash check.
    public static func loadAndValidateIndex(
        from pack: GarrysPADContentPack
    ) throws -> GarrysPADContentManifest {
        guard let root = try pack.entry(for: GarrysPADContentPack.rootManifestPath) else {
            throw GarrysPADContentManifestError.invalid(
                "root GarrysPADContentManifest.json is missing"
            )
        }
        guard root.compressionMethod == 0 || root.compressionMethod == 8 else {
            throw GarrysPADContentPackError.unsupportedCompression(
                path: root.path,
                method: root.compressionMethod
            )
        }
        let data = try pack.data(
            for: GarrysPADContentPack.rootManifestPath,
            maximumByteCount: GarrysPADContentPack.maximumDecodedManifestByteCount
        )
        let manifest: GarrysPADContentManifest
        do {
            manifest = try JSONDecoder().decode(
                GarrysPADContentManifest.self,
                from: data
            )
        } catch {
            throw GarrysPADContentManifestError.invalid(
                "root JSON does not match the complete v1 schema: \(error)"
            )
        }
        try validateSchema(manifest, pack: pack)
        return manifest
    }

    /// Streams the requested authorized payloads through both the ZIP CRC and
    /// manifest SHA-256. Passing nil verifies every authorized payload.
    public static func verifyPayloads(
        in pack: GarrysPADContentPack,
        manifest: GarrysPADContentManifest,
        paths requestedPaths: Set<String>? = nil,
        chunkByteCount: Int = 1 * 1_024 * 1_024,
        shouldCancel: () -> Bool = { false },
        progress: (GarrysPADContentVerificationProgress) -> Void = { _ in }
    ) throws {
        var manifestByPath: [String: GarrysPADContentManifest.File] = [:]
        for file in manifest.files {
            let normalized = normalizedPathForComparison(file.path)
            guard manifestByPath.updateValue(file, forKey: normalized) == nil else {
                throw GarrysPADContentManifestError.invalid(
                    "duplicate verification path: \(file.path)"
                )
            }
        }
        let selected: [GarrysPADContentManifest.File]
        if let requestedPaths {
            let normalized = Set(requestedPaths.map { normalizedPathForComparison($0) })
            let missing = normalized.subtracting(manifestByPath.keys)
            guard missing.isEmpty else {
                throw GarrysPADContentManifestError.invalid(
                    "verification requested undeclared path: \(missing.sorted().first!)"
                )
            }
            selected = manifest.files.filter {
                normalized.contains(normalizedPathForComparison($0.path))
            }
        } else {
            selected = manifest.files
        }
        let totalBytes = try sumByteCounts(selected)
        var completedBytes: UInt64 = 0
        var completedFiles = 0
        progress(GarrysPADContentVerificationProgress(
            currentPath: selected.first?.path,
            completedFileCount: 0,
            totalFileCount: selected.count,
            completedByteCount: 0,
            totalByteCount: totalBytes
        ))
        for file in selected {
            if shouldCancel() { throw CancellationError() }
            var hasher = GModContentSHA256()
            let bytesBeforeFile = completedBytes
            try pack.streamVerifiedData(
                for: file.path,
                chunkByteCount: chunkByteCount,
                shouldCancel: shouldCancel
            ) { chunk, fileBytes in
                hasher.update(chunk)
                progress(GarrysPADContentVerificationProgress(
                    currentPath: file.path,
                    completedFileCount: completedFiles,
                    totalFileCount: selected.count,
                    completedByteCount: bytesBeforeFile + fileBytes,
                    totalByteCount: totalBytes
                ))
            }
            let actual = hasher.hexadecimalDigest()
            guard actual == file.sha256 else {
                throw GarrysPADContentManifestError.hashMismatch(
                    path: file.path,
                    expected: file.sha256,
                    actual: actual
                )
            }
            completedBytes = bytesBeforeFile + file.byteCount
            completedFiles += 1
            progress(GarrysPADContentVerificationProgress(
                currentPath: completedFiles < selected.count
                    ? selected[completedFiles].path
                    : nil,
                completedFileCount: completedFiles,
                totalFileCount: selected.count,
                completedByteCount: completedBytes,
                totalByteCount: totalBytes
            ))
        }
    }

    private static func validateSchema(
        _ manifest: GarrysPADContentManifest,
        pack: GarrysPADContentPack
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw GarrysPADContentManifestError.invalid("unsupported schemaVersion")
        }
        guard manifest.format == "GarrysPADContentPack" else {
            throw GarrysPADContentManifestError.invalid("unexpected format")
        }
        guard supportedProfiles.contains(manifest.profile) else {
            throw GarrysPADContentManifestError.invalid("unsupported profile")
        }
        guard !manifest.createdAtUTC.isEmpty,
              manifest.createdAtUTC.contains("T"),
              manifest.createdAtUTC.hasSuffix("Z") else {
            throw GarrysPADContentManifestError.invalid("createdAtUTC is not UTC ISO-8601")
        }
        guard !manifest.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GarrysPADContentManifestError.invalid("source is empty")
        }
        guard !manifest.mountRoots.isEmpty,
              Set(manifest.mountRoots).count == manifest.mountRoots.count,
              manifest.mountRoots.allSatisfy({ root in
                  root == normalizedPathForComparison(root) && !root.contains("/")
              }) else {
            throw GarrysPADContentManifestError.invalid("mountRoots are invalid")
        }
        guard Set(manifest.excludedRoots).count == manifest.excludedRoots.count,
              Set(manifest.optionalCompleteBaseFamilies).count ==
                manifest.optionalCompleteBaseFamilies.count else {
            throw GarrysPADContentManifestError.invalid("root policy arrays contain duplicates")
        }
        guard manifest.fileCount >= 0,
              manifest.fileCount == manifest.files.count else {
            throw GarrysPADContentManifestError.invalid("fileCount does not match files")
        }

        var declaredPaths = Set<String>()
        for file in manifest.files {
            let normalized = normalizedPathForComparison(file.path)
            guard isSafeManifestPath(file.path),
                  manifest.mountRoots.contains(where: {
                      normalized == normalizedPathForComparison($0) ||
                          normalized.hasPrefix(normalizedPathForComparison($0) + "/")
                  }) else {
                throw GarrysPADContentManifestError.invalid(
                    "unsafe or unauthorized path: \(file.path)"
                )
            }
            guard declaredPaths.insert(normalized).inserted else {
                throw GarrysPADContentManifestError.invalid(
                    "duplicate or case-colliding path: \(file.path)"
                )
            }
            guard isLowercaseSHA256(file.sha256) else {
                throw GarrysPADContentManifestError.invalid(
                    "invalid SHA-256 for \(file.path)"
                )
            }
            guard let entry = try pack.entry(for: file.path),
                  entry.uncompressedByteCount == file.byteCount else {
                throw GarrysPADContentManifestError.invalid(
                    "declared entry does not match the ZIP index: \(file.path)"
                )
            }
            guard entry.compressionMethod == 0 else {
                throw GarrysPADContentManifestError.invalid(
                    "payload must be stored for bounded range verification: \(file.path)"
                )
            }
        }
        let indexedPaths = Set(pack.entries.keys).subtracting([
            GarrysPADContentPack.rootManifestPath,
        ])
        let unexpected = indexedPaths.subtracting(declaredPaths)
        guard unexpected.isEmpty else {
            throw GarrysPADContentManifestError.invalid(
                "ZIP contains undeclared entry: \(unexpected.sorted().first!)"
            )
        }
        let missing = declaredPaths.subtracting(indexedPaths)
        guard missing.isEmpty else {
            throw GarrysPADContentManifestError.invalid(
                "manifest entry is missing from ZIP: \(missing.sorted().first!)"
            )
        }
        guard indexedPaths.count == manifest.fileCount else {
            throw GarrysPADContentManifestError.invalid(
                "fileCount does not match the authorized ZIP payload set"
            )
        }
        guard try sumByteCounts(manifest.files) == manifest.byteCount else {
            throw GarrysPADContentManifestError.invalid(
                "byteCount does not match files"
            )
        }
    }

    private static func sumByteCounts(
        _ files: [GarrysPADContentManifest.File]
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for file in files {
            let sum = total.addingReportingOverflow(file.byteCount)
            guard !sum.overflow else {
                throw GarrysPADContentManifestError.invalid("byteCount overflow")
            }
            total = sum.partialValue
        }
        return total
    }

    private static func normalizedPathForComparison(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func isSafeManifestPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

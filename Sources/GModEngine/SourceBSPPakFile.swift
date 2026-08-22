import Foundation
import GModLua

/// Hard allocation and indexing boundaries for a map-embedded ZIP.
public struct SourceBSPPakFileLimits: Sendable, Equatable {
    public let maximumArchiveByteCount: UInt64
    public let maximumEntryCount: Int
    public let maximumCompressedEntryByteCount: UInt64
    public let maximumEntryByteCount: UInt64
    public let maximumTotalByteCount: UInt64
    public let maximumPathByteCount: Int
    public let maximumPathComponentCount: Int
    public let maximumIndexPathByteCount: UInt64

    public init(
        maximumArchiveByteCount: UInt64 = 512 * 1_024 * 1_024,
        maximumEntryCount: Int = 65_535,
        maximumCompressedEntryByteCount: UInt64 = 256 * 1_024 * 1_024,
        maximumEntryByteCount: UInt64 = 256 * 1_024 * 1_024,
        maximumTotalByteCount: UInt64 = 1_024 * 1_024 * 1_024,
        maximumPathByteCount: Int = 4_096,
        maximumPathComponentCount: Int = 128,
        maximumIndexPathByteCount: UInt64 = 64 * 1_024 * 1_024
    ) {
        self.maximumArchiveByteCount = maximumArchiveByteCount
        self.maximumEntryCount = maximumEntryCount
        self.maximumCompressedEntryByteCount = maximumCompressedEntryByteCount
        self.maximumEntryByteCount = maximumEntryByteCount
        self.maximumTotalByteCount = maximumTotalByteCount
        self.maximumPathByteCount = maximumPathByteCount
        self.maximumPathComponentCount = maximumPathComponentCount
        self.maximumIndexPathByteCount = maximumIndexPathByteCount
    }
}

public enum SourceBSPPakFileCompression: UInt16, Sendable, Equatable {
    case stored = 0
    case deflated = 8
}

public struct SourceBSPPakFileEntry: Sendable, Equatable {
    public let path: String
    public let compression: SourceBSPPakFileCompression
    public let compressedByteCount: UInt64
    public let uncompressedByteCount: UInt64
    public let crc32: UInt32
}

public enum SourceBSPPakFileError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case compressedLump(declaredUncompressedSize: UInt32)
    case unsupportedLumpVersion(Int32)
    case archiveTooLarge(actual: UInt64, maximum: UInt64)
    case invalidLimits
    case invalidArchive(String)
    case invalidPath(String)
    case duplicatePath(String)
    case unsupportedFlags(path: String, flags: UInt16)
    case unsupportedCompression(path: String, method: UInt16)
    case tooManyEntries(actual: Int, maximum: Int)
    case compressedEntryTooLarge(path: String, byteCount: UInt64, maximum: UInt64)
    case entryTooLarge(path: String, byteCount: UInt64, maximum: UInt64)
    case totalSizeTooLarge(byteCount: UInt64, maximum: UInt64)
    case pathTooLong(actual: Int, maximum: Int)
    case tooManyPathComponents(actual: Int, maximum: Int)
    case indexTooLarge(byteCount: UInt64, maximum: UInt64)
    case requestedCompressedSizeTooLarge(
        path: String,
        byteCount: UInt64,
        maximum: UInt64
    )
    case requestedSizeTooLarge(path: String, byteCount: UInt64, maximum: UInt64)
    case checksumMismatch(String)
    case decodeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .compressedLump(size):
            return "BSP LUMP_PAKFILE is LZMA-compressed (declared size \(size))"
        case let .unsupportedLumpVersion(version):
            return "BSP LUMP_PAKFILE version \(version) is unsupported"
        case let .archiveTooLarge(actual, maximum):
            return "BSP pakfile has \(actual) bytes, exceeding \(maximum)"
        case .invalidLimits:
            return "BSP pakfile limits are invalid"
        case let .invalidArchive(reason):
            return "invalid BSP pakfile ZIP: \(reason)"
        case let .invalidPath(path):
            return "invalid BSP pakfile path: \(path)"
        case let .duplicatePath(path):
            return "duplicate BSP pakfile path: \(path)"
        case let .unsupportedFlags(path, flags):
            return "BSP pakfile entry \(path) uses unsupported flags 0x\(String(flags, radix: 16))"
        case let .unsupportedCompression(path, method):
            return "BSP pakfile entry \(path) uses unsupported ZIP method \(method)"
        case let .tooManyEntries(actual, maximum):
            return "BSP pakfile has \(actual) entries, exceeding \(maximum)"
        case let .compressedEntryTooLarge(path, byteCount, maximum):
            return "BSP pakfile entry \(path) has \(byteCount) compressed bytes, " +
                "exceeding \(maximum)"
        case let .entryTooLarge(path, byteCount, maximum):
            return "BSP pakfile entry \(path) has \(byteCount) bytes, exceeding \(maximum)"
        case let .totalSizeTooLarge(byteCount, maximum):
            return "BSP pakfile expands to \(byteCount) bytes, exceeding \(maximum)"
        case let .pathTooLong(actual, maximum):
            return "BSP pakfile path has \(actual) bytes, exceeding \(maximum)"
        case let .tooManyPathComponents(actual, maximum):
            return "BSP pakfile path has \(actual) components, exceeding \(maximum)"
        case let .indexTooLarge(byteCount, maximum):
            return "BSP pakfile path index has \(byteCount) bytes, exceeding \(maximum)"
        case let .requestedCompressedSizeTooLarge(path, byteCount, maximum):
            return "BSP pakfile entry \(path) has \(byteCount) compressed bytes, " +
                "exceeding request limit \(maximum)"
        case let .requestedSizeTooLarge(path, byteCount, maximum):
            return "BSP pakfile entry \(path) has \(byteCount) bytes, exceeding request limit \(maximum)"
        case let .checksumMismatch(path):
            return "BSP pakfile entry failed ZIP CRC32: \(path)"
        case let .decodeFailed(path, reason):
            return "BSP pakfile entry \(path) failed DEFLATE decoding: \(reason)"
        }
    }
}

/// Read-only view of Source BSP `LUMP_PAKFILE`.
///
/// Source SDK 2013 commit c8f4c6351162fbff83bfa5a428d45d1e6eed3824,
/// `src/public/bspfile.h` lines 313-316, specifies that this embedded ZIP is
/// searched before the game and base content paths. `makeSourcePriorityMount`
/// expresses that ordering without coupling the parser to a particular
/// session. The ZIP index is immutable and parsed once; entry bytes are decoded
/// and CRC-checked only when requested.
public final class SourceBSPPakFileSystem:
    LuaVirtualFileSystem, @unchecked Sendable
{
    private struct Record: Sendable {
        let metadata: SourceBSPPakFileEntry
        let dataOffset: Int
        let compressedByteCount: Int
    }

    private struct ParsedIndex {
        let records: [String: Record]
        let entries: [SourceBSPPakFileEntry]
        let directories: [String: String]
        let children: [String: [LuaVirtualFileSystemEntry]]
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let allowedFlags: UInt16 = 0x0806
    private static let utf8NameFlag: UInt16 = 0x0800
    private static let deflateOptionFlags: UInt16 = 0x0006
    private static let reservedWhiteoutDirectory = ".garrys-pad-vfs-whiteouts"

    private let archive: Data
    private let records: [String: Record]
    private let directories: [String: String]
    private let children: [String: [LuaVirtualFileSystemEntry]]

    public let limits: SourceBSPPakFileLimits
    public let entries: [SourceBSPPakFileEntry]

    public convenience init(
        bsp: SourceBSP,
        limits: SourceBSPPakFileLimits = SourceBSPPakFileLimits()
    ) throws {
        let lump = bsp.lump(.pakFile)
        guard !lump.descriptor.isCompressed else {
            throw SourceBSPPakFileError.compressedLump(
                declaredUncompressedSize: lump.descriptor.uncompressedSize
            )
        }
        guard lump.descriptor.version == 0 else {
            throw SourceBSPPakFileError.unsupportedLumpVersion(
                lump.descriptor.version
            )
        }
        try self.init(archiveData: lump.data, limits: limits)
    }

    public init(
        archiveData: Data,
        limits: SourceBSPPakFileLimits = SourceBSPPakFileLimits()
    ) throws {
        guard limits.maximumEntryCount >= 0,
              limits.maximumPathByteCount >= 0,
              limits.maximumPathComponentCount >= 0 else {
            throw SourceBSPPakFileError.invalidLimits
        }
        let archiveByteCount = UInt64(archiveData.count)
        guard archiveByteCount <= limits.maximumArchiveByteCount else {
            throw SourceBSPPakFileError.archiveTooLarge(
                actual: archiveByteCount,
                maximum: limits.maximumArchiveByteCount
            )
        }
        archive = archiveData
        self.limits = limits
        let parsed = try Self.parse(archiveData, limits: limits)
        records = parsed.records
        entries = parsed.entries
        directories = parsed.directories
        children = parsed.children
    }

    public func contains(_ logicalPath: String) -> Bool {
        guard let normalized = try? Self.normalizedQueryPath(
            logicalPath,
            allowEmpty: false,
            limits: limits
        ) else { return false }
        return records[Self.fold(normalized)] != nil
    }

    public func byteCount(for logicalPath: String) throws -> UInt64? {
        guard let normalized = try? Self.normalizedQueryPath(
            logicalPath,
            allowEmpty: false,
            limits: limits
        ) else { return nil }
        return records[Self.fold(normalized)]?.metadata.uncompressedByteCount
    }

    /// Returns an integrity-checked map-local asset, or `nil` when it is absent.
    public func data(
        for logicalPath: String,
        maximumByteCount: UInt64 = 64 * 1_024 * 1_024,
        maximumCompressedByteCount: UInt64 = 64 * 1_024 * 1_024
    ) throws -> Data? {
        guard let normalized = try? Self.normalizedQueryPath(
            logicalPath,
            allowEmpty: false,
            limits: limits
        ), let record = records[Self.fold(normalized)] else { return nil }
        let metadata = record.metadata
        guard metadata.uncompressedByteCount <= maximumByteCount else {
            throw SourceBSPPakFileError.requestedSizeTooLarge(
                path: metadata.path,
                byteCount: metadata.uncompressedByteCount,
                maximum: maximumByteCount
            )
        }
        let compressedLimit = min(
            limits.maximumCompressedEntryByteCount,
            maximumCompressedByteCount
        )
        guard metadata.compressedByteCount <= compressedLimit else {
            throw SourceBSPPakFileError.requestedCompressedSizeTooLarge(
                path: metadata.path,
                byteCount: metadata.compressedByteCount,
                maximum: compressedLimit
            )
        }

        let result: Data
        switch metadata.compression {
        case .stored:
            result = Self.slice(
                archive,
                offset: record.dataOffset,
                count: record.compressedByteCount
            )
        case .deflated:
            do {
                result = try SourceBSPRawDeflate.decode(
                    archive,
                    offset: record.dataOffset,
                    compressedByteCount: record.compressedByteCount,
                    expectedByteCount: metadata.uncompressedByteCount,
                    maximumCompressedByteCount: compressedLimit,
                    maximumDecodedByteCount: min(
                        limits.maximumEntryByteCount,
                        maximumByteCount
                    )
                )
            } catch {
                throw SourceBSPPakFileError.decodeFailed(
                    path: metadata.path,
                    reason: String(describing: error)
                )
            }
        }
        guard UInt64(result.count) == metadata.uncompressedByteCount else {
            throw SourceBSPPakFileError.decodeFailed(
                path: metadata.path,
                reason: "decoded size mismatch"
            )
        }
        guard Self.crc32(result) == metadata.crc32 else {
            throw SourceBSPPakFileError.checksumMismatch(metadata.path)
        }
        return result
    }

    /// A mount suitable for insertion at the head of Source's GAME search path.
    public func makeSourcePriorityMount(
        name: String = "source-bsp-pakfile",
        priority: Int = .max
    ) throws -> GMLuaFileMount {
        try GMLuaFileMount(
            name: name,
            priority: priority,
            writable: false,
            fileSystem: self
        )
    }

    /// Adapts the pak to the canonical Source GAME search-path provider API.
    public func makeSourceFileProvider() -> SourceBSPPakFileSourceProvider {
        SourceBSPPakFileSourceProvider(fileSystem: self)
    }

    public func fileExists(at path: String) -> Bool { contains(path) }

    public func directoryExists(at path: String) -> Bool {
        guard let normalized = try? Self.normalizedQueryPath(
            path,
            allowEmpty: true,
            limits: limits
        ) else { return false }
        return directories[Self.fold(normalized)] != nil
    }

    public func listDirectory(at path: String) throws
        -> [LuaVirtualFileSystemEntry]
    {
        let normalized = try Self.normalizedQueryPath(
            path,
            allowEmpty: true,
            limits: limits
        )
        let key = Self.fold(normalized)
        if records[key] != nil { throw GMLuaFileSystemError.notDirectory(path) }
        guard directories[key] != nil else {
            throw GMLuaFileSystemError.fileNotFound(path)
        }
        return children[key] ?? []
    }

    public func readFile(at path: String) throws -> Data {
        _ = try Self.normalizedQueryPath(
            path,
            allowEmpty: false,
            limits: limits
        )
        guard let data = try data(
            for: path,
            maximumByteCount: limits.maximumEntryByteCount,
            maximumCompressedByteCount: limits.maximumCompressedEntryByteCount
        ) else { throw GMLuaFileSystemError.fileNotFound(path) }
        return data
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

    private static func parse(
        _ archive: Data,
        limits: SourceBSPPakFileLimits
    ) throws -> ParsedIndex {
        if archive.isEmpty {
            return ParsedIndex(
                records: [:],
                entries: [],
                directories: ["": ""],
                children: [:]
            )
        }
        guard archive.count >= 22 else {
            throw SourceBSPPakFileError.invalidArchive("missing end record")
        }
        let minimumEndOffset = max(0, archive.count - 22 - 65_535)
        var endOffset: Int?
        for candidate in stride(
            from: archive.count - 22,
            through: minimumEndOffset,
            by: -1
        ) where u32(archive, candidate) == endSignature {
            let commentLength = Int(u16(archive, candidate + 20))
            if candidate + 22 + commentLength == archive.count {
                endOffset = candidate
                break
            }
        }
        guard let endOffset else {
            throw SourceBSPPakFileError.invalidArchive("missing end record")
        }

        let disk = u16(archive, endOffset + 4)
        let centralDisk = u16(archive, endOffset + 6)
        let diskEntryCount = Int(u16(archive, endOffset + 8))
        let entryCount = Int(u16(archive, endOffset + 10))
        let centralByteCount32 = u32(archive, endOffset + 12)
        let centralOffset32 = u32(archive, endOffset + 16)
        guard disk == 0, centralDisk == 0, diskEntryCount == entryCount else {
            throw SourceBSPPakFileError.invalidArchive(
                "multi-disk ZIPs are unsupported"
            )
        }
        guard diskEntryCount != 0xFFFF,
              centralByteCount32 != UInt32.max,
              centralOffset32 != UInt32.max else {
            throw SourceBSPPakFileError.invalidArchive("ZIP64 is unsupported")
        }
        guard entryCount <= limits.maximumEntryCount else {
            throw SourceBSPPakFileError.tooManyEntries(
                actual: entryCount,
                maximum: limits.maximumEntryCount
            )
        }
        let centralOffset = Int(centralOffset32)
        let centralByteCount = Int(centralByteCount32)
        guard let centralEnd = checkedEnd(
            offset: centralOffset,
            count: centralByteCount,
            limit: archive.count
        ), centralEnd == endOffset else {
            throw SourceBSPPakFileError.invalidArchive(
                "central directory is out of bounds"
            )
        }

        var records: [String: Record] = [:]
        var explicitDirectories: [String: String] = [:]
        var centralKeys = Set<String>()
        var localRanges: [Range<Int>] = []
        var totalByteCount: UInt64 = 0
        var indexPathByteCount: UInt64 = 0
        var cursor = centralOffset

        for _ in 0..<entryCount {
            guard let fixedEnd = checkedEnd(
                offset: cursor,
                count: 46,
                limit: centralEnd
            ), u32(archive, cursor) == centralHeaderSignature else {
                throw SourceBSPPakFileError.invalidArchive(
                    "malformed central directory entry"
                )
            }
            let flags = u16(archive, cursor + 8)
            let methodRaw = u16(archive, cursor + 10)
            let expectedCRC = u32(archive, cursor + 16)
            let compressed32 = u32(archive, cursor + 20)
            let uncompressed32 = u32(archive, cursor + 24)
            let nameByteCount = Int(u16(archive, cursor + 28))
            let extraByteCount = Int(u16(archive, cursor + 30))
            let commentByteCount = Int(u16(archive, cursor + 32))
            let startDisk = u16(archive, cursor + 34)
            let localOffset32 = u32(archive, cursor + 42)
            guard nameByteCount <= limits.maximumPathByteCount else {
                throw SourceBSPPakFileError.pathTooLong(
                    actual: nameByteCount,
                    maximum: limits.maximumPathByteCount
                )
            }
            guard startDisk == 0,
                  compressed32 != UInt32.max,
                  uncompressed32 != UInt32.max,
                  localOffset32 != UInt32.max else {
                throw SourceBSPPakFileError.invalidArchive(
                    "ZIP64 entry metadata is unsupported"
                )
            }
            guard let variableEnd = checkedEnd(
                offset: fixedEnd,
                count: nameByteCount + extraByteCount + commentByteCount,
                limit: centralEnd
            ) else {
                throw SourceBSPPakFileError.invalidArchive(
                    "truncated central directory entry"
                )
            }
            let centralNameData = slice(
                archive,
                offset: fixedEnd,
                count: nameByteCount
            )
            let centralName = try decodedName(centralNameData, flags: flags)
            let normalized = try normalizedArchivePath(
                centralName,
                limits: limits
            )
            let path = normalized.path
            let pathKey = fold(path)
            guard centralKeys.insert(pathKey).inserted else {
                throw SourceBSPPakFileError.duplicatePath(path)
            }
            indexPathByteCount = try addingIndexPathBytes(
                UInt64(path.utf8.count),
                to: indexPathByteCount,
                limits: limits
            )
            guard flags & ~allowedFlags == 0 else {
                throw SourceBSPPakFileError.unsupportedFlags(
                    path: path,
                    flags: flags
                )
            }
            guard let compression = SourceBSPPakFileCompression(
                rawValue: methodRaw
            ) else {
                throw SourceBSPPakFileError.unsupportedCompression(
                    path: path,
                    method: methodRaw
                )
            }
            if compression == .stored, flags & deflateOptionFlags != 0 {
                throw SourceBSPPakFileError.unsupportedFlags(
                    path: path,
                    flags: flags
                )
            }

            let compressedByteCount = UInt64(compressed32)
            let uncompressedByteCount = UInt64(uncompressed32)
            guard compressedByteCount <= limits.maximumCompressedEntryByteCount else {
                throw SourceBSPPakFileError.compressedEntryTooLarge(
                    path: path,
                    byteCount: compressedByteCount,
                    maximum: limits.maximumCompressedEntryByteCount
                )
            }
            guard uncompressedByteCount <= limits.maximumEntryByteCount else {
                throw SourceBSPPakFileError.entryTooLarge(
                    path: path,
                    byteCount: uncompressedByteCount,
                    maximum: limits.maximumEntryByteCount
                )
            }
            if compression == .stored,
               compressedByteCount != uncompressedByteCount {
                throw SourceBSPPakFileError.invalidArchive(
                    "stored entry size mismatch for \(path)"
                )
            }
            if normalized.isDirectory,
               (compressedByteCount != 0 || uncompressedByteCount != 0 ||
                compression != .stored || expectedCRC != 0) {
                throw SourceBSPPakFileError.invalidArchive(
                    "directory entry has payload: \(path)"
                )
            }

            if !normalized.isDirectory {
                let (nextTotal, overflow) = totalByteCount.addingReportingOverflow(
                    uncompressedByteCount
                )
                guard !overflow, nextTotal <= limits.maximumTotalByteCount else {
                    throw SourceBSPPakFileError.totalSizeTooLarge(
                        byteCount: overflow ? .max : nextTotal,
                        maximum: limits.maximumTotalByteCount
                    )
                }
                totalByteCount = nextTotal
            }

            let localOffset = Int(localOffset32)
            guard let localFixedEnd = checkedEnd(
                offset: localOffset,
                count: 30,
                limit: centralOffset
            ), u32(archive, localOffset) == localHeaderSignature else {
                throw SourceBSPPakFileError.invalidArchive(
                    "missing local header for \(path)"
                )
            }
            let localFlags = u16(archive, localOffset + 6)
            let localMethod = u16(archive, localOffset + 8)
            let localCRC = u32(archive, localOffset + 14)
            let localCompressed = u32(archive, localOffset + 18)
            let localUncompressed = u32(archive, localOffset + 22)
            let localNameByteCount = Int(u16(archive, localOffset + 26))
            let localExtraByteCount = Int(u16(archive, localOffset + 28))
            guard localNameByteCount <= limits.maximumPathByteCount else {
                throw SourceBSPPakFileError.pathTooLong(
                    actual: localNameByteCount,
                    maximum: limits.maximumPathByteCount
                )
            }
            guard localFlags == flags, localMethod == methodRaw else {
                throw SourceBSPPakFileError.invalidArchive(
                    "local and central metadata differ for \(path)"
                )
            }
            guard let localVariableEnd = checkedEnd(
                offset: localFixedEnd,
                count: localNameByteCount + localExtraByteCount,
                limit: centralOffset
            ) else {
                throw SourceBSPPakFileError.invalidArchive(
                    "truncated local header for \(path)"
                )
            }
            let localNameData = slice(
                archive,
                offset: localFixedEnd,
                count: localNameByteCount
            )
            let localName = try decodedName(localNameData, flags: localFlags)
            guard try normalizedArchivePath(
                localName,
                limits: limits
            ) == normalized else {
                throw SourceBSPPakFileError.invalidArchive(
                    "local and central names differ for \(path)"
                )
            }
            guard localCRC == expectedCRC,
                  localCompressed == compressed32,
                  localUncompressed == uncompressed32 else {
                throw SourceBSPPakFileError.invalidArchive(
                    "local and central sizes/CRC differ for \(path)"
                )
            }
            guard let dataEnd = checkedEnd(
                offset: localVariableEnd,
                count: Int(compressed32),
                limit: centralOffset
            ) else {
                throw SourceBSPPakFileError.invalidArchive(
                    "entry data is out of bounds: \(path)"
                )
            }
            localRanges.append(localOffset..<dataEnd)

            if normalized.isDirectory {
                explicitDirectories[pathKey] = path
            } else {
                let metadata = SourceBSPPakFileEntry(
                    path: path,
                    compression: compression,
                    compressedByteCount: compressedByteCount,
                    uncompressedByteCount: uncompressedByteCount,
                    crc32: expectedCRC
                )
                records[pathKey] = Record(
                    metadata: metadata,
                    dataOffset: localVariableEnd,
                    compressedByteCount: Int(compressed32)
                )
            }
            cursor = variableEnd
        }
        guard cursor == centralEnd else {
            throw SourceBSPPakFileError.invalidArchive(
                "central directory byte count does not match entries"
            )
        }

        let orderedRanges = localRanges.sorted { lhs, rhs in
            if lhs.lowerBound != rhs.lowerBound {
                return lhs.lowerBound < rhs.lowerBound
            }
            return lhs.upperBound < rhs.upperBound
        }
        for pair in zip(orderedRanges, orderedRanges.dropFirst())
            where pair.0.upperBound > pair.1.lowerBound {
            throw SourceBSPPakFileError.invalidArchive(
                "local entry ranges overlap"
            )
        }

        var directorySpelling: [String: String] = ["": ""]
        for (key, path) in explicitDirectories {
            directorySpelling[key] = path
        }
        let allNodePaths = records.values.map(\.metadata.path) +
            Array(explicitDirectories.values)
        for path in allNodePaths {
            let components = path.split(separator: "/")
            guard components.count > 1 else { continue }
            var parent = ""
            for component in components.dropLast() {
                if parent.isEmpty {
                    parent = String(component)
                } else {
                    parent.append("/")
                    parent.append(contentsOf: component)
                }
                let key = fold(parent)
                if records[key] != nil {
                    throw SourceBSPPakFileError.invalidArchive(
                        "file is also a parent directory: \(parent)"
                    )
                }
                if let previous = directorySpelling[key] {
                    directorySpelling[key] = min(previous, parent)
                } else {
                    indexPathByteCount = try addingIndexPathBytes(
                        UInt64(parent.utf8.count),
                        to: indexPathByteCount,
                        limits: limits
                    )
                    directorySpelling[key] = parent
                }
            }
        }

        var childMaps: [String: [String: LuaVirtualFileSystemEntry]] = [:]
        for (key, directory) in directorySpelling where !key.isEmpty {
            let parent = directory.split(separator: "/").dropLast()
                .joined(separator: "/")
            let name = String(directory.split(separator: "/").last!)
            insertChild(
                LuaVirtualFileSystemEntry(name: name, isDirectory: true),
                into: &childMaps[fold(parent), default: [:]]
            )
        }
        for record in records.values {
            let path = record.metadata.path
            let components = path.split(separator: "/").map(String.init)
            let parent = components.dropLast().joined(separator: "/")
            insertChild(
                LuaVirtualFileSystemEntry(
                    name: components.last!,
                    isDirectory: false
                ),
                into: &childMaps[fold(parent), default: [:]]
            )
        }
        let children = childMaps.mapValues { map in
            map.values.sorted { lhs, rhs in
                let foldedLHS = fold(lhs.name)
                let foldedRHS = fold(rhs.name)
                if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
                return lhs.name < rhs.name
            }
        }
        let entries = records.values.map(\.metadata).sorted {
            let foldedLHS = fold($0.path)
            let foldedRHS = fold($1.path)
            if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
            return $0.path < $1.path
        }
        return ParsedIndex(
            records: records,
            entries: entries,
            directories: directorySpelling,
            children: children
        )
    }

    private static func normalizedArchivePath(
        _ rawPath: String,
        limits: SourceBSPPakFileLimits
    ) throws
        -> (path: String, isDirectory: Bool)
    {
        let pathByteCount = rawPath.utf8.count
        guard pathByteCount <= limits.maximumPathByteCount else {
            throw SourceBSPPakFileError.pathTooLong(
                actual: pathByteCount,
                maximum: limits.maximumPathByteCount
            )
        }
        let replaced = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.isEmpty,
              !replaced.hasPrefix("/"),
              !replaced.contains(":"),
              !replaced.contains("\0") else {
            throw SourceBSPPakFileError.invalidPath(rawPath)
        }
        let isDirectory = replaced.hasSuffix("/")
        let body = isDirectory ? String(replaced.dropLast()) : replaced
        let components = body.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count <= limits.maximumPathComponentCount else {
            throw SourceBSPPakFileError.tooManyPathComponents(
                actual: components.count,
                maximum: limits.maximumPathComponentCount
            )
        }
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." &&
                      String($0).caseInsensitiveCompare(
                          reservedWhiteoutDirectory
                      ) != .orderedSame
              }) else {
            throw SourceBSPPakFileError.invalidPath(rawPath)
        }
        return (components.joined(separator: "/"), isDirectory)
    }

    private static func normalizedQueryPath(
        _ rawPath: String,
        allowEmpty: Bool,
        limits: SourceBSPPakFileLimits
    ) throws -> String {
        let byteCount = rawPath.utf8.count
        guard byteCount <= limits.maximumPathByteCount else {
            throw SourceBSPPakFileError.pathTooLong(
                actual: byteCount,
                maximum: limits.maximumPathByteCount
            )
        }
        let normalized = try GMLuaMountedFileSystem.normalize(
            rawPath,
            allowEmpty: allowEmpty
        )
        let componentCount = normalized.split(separator: "/").count
        guard componentCount <= limits.maximumPathComponentCount else {
            throw SourceBSPPakFileError.tooManyPathComponents(
                actual: componentCount,
                maximum: limits.maximumPathComponentCount
            )
        }
        return normalized
    }

    private static func decodedName(_ data: Data, flags: UInt16) throws -> String {
        if flags & utf8NameFlag != 0 {
            guard let name = String(data: data, encoding: .utf8) else {
                throw SourceBSPPakFileError.invalidArchive(
                    "UTF-8 entry name is malformed"
                )
            }
            return name
        }
        guard data.allSatisfy({ $0 < 0x80 }),
              let name = String(data: data, encoding: .ascii) else {
            throw SourceBSPPakFileError.invalidArchive(
                "non-ASCII entry name lacks the ZIP UTF-8 flag"
            )
        }
        return name
    }

    private static func addingIndexPathBytes(
        _ additional: UInt64,
        to current: UInt64,
        limits: SourceBSPPakFileLimits
    ) throws -> UInt64 {
        let (next, overflow) = current.addingReportingOverflow(additional)
        guard !overflow, next <= limits.maximumIndexPathByteCount else {
            throw SourceBSPPakFileError.indexTooLarge(
                byteCount: overflow ? .max : next,
                maximum: limits.maximumIndexPathByteCount
            )
        }
        return next
    }

    private static func insertChild(
        _ entry: LuaVirtualFileSystemEntry,
        into map: inout [String: LuaVirtualFileSystemEntry]
    ) {
        let key = fold(entry.name)
        if let previous = map[key] {
            map[key] = LuaVirtualFileSystemEntry(
                name: min(previous.name, entry.name),
                isDirectory: previous.isDirectory || entry.isDirectory
            )
        } else {
            map[key] = entry
        }
    }

    private static func checkedEnd(
        offset: Int,
        count: Int,
        limit: Int
    ) -> Int? {
        guard offset >= 0, count >= 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow, end <= limit else { return nil }
        return end
    }

    private static func slice(_ data: Data, offset: Int, count: Int) -> Data {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        return Data(data[start..<end])
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let first = data.index(data.startIndex, offsetBy: offset)
        let second = data.index(after: first)
        return UInt16(data[first]) | UInt16(data[second]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let first = data.index(data.startIndex, offsetBy: offset)
        return UInt32(data[first]) |
            UInt32(data[data.index(first, offsetBy: 1)]) << 8 |
            UInt32(data[data.index(first, offsetBy: 2)]) << 16 |
            UInt32(data[data.index(first, offsetBy: 3)]) << 24
    }

    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32Table[index]
        }
        return ~crc
    }

    private static func fold(_ path: String) -> String { path.lowercased() }
}

/// Immutable bridge from a BSP pak to Source's ordered search-path stack.
public final class SourceBSPPakFileSourceProvider:
    SourceFileProvider, @unchecked Sendable
{
    public let fileSystem: SourceBSPPakFileSystem

    public init(fileSystem: SourceBSPPakFileSystem) {
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

private enum SourceBSPRawDeflateError: Error, CustomStringConvertible {
    case compressedInputTooLarge(UInt64)
    case decodedOutputTooLarge(UInt64)
    case truncated
    case invalidBlockType
    case invalidStoredBlock
    case invalidHuffmanTree
    case invalidSymbol(Int)
    case invalidDistance(Int)
    case missingEndOfBlock
    case trailingData
    case sizeMismatch(expected: UInt64, actual: UInt64)

    var description: String {
        switch self {
        case let .compressedInputTooLarge(count):
            return "compressed input exceeds bound (\(count))"
        case let .decodedOutputTooLarge(count):
            return "decoded output exceeds bound (\(count))"
        case .truncated: return "truncated stream"
        case .invalidBlockType: return "reserved block type"
        case .invalidStoredBlock: return "invalid stored block"
        case .invalidHuffmanTree: return "invalid Huffman tree"
        case let .invalidSymbol(symbol): return "invalid symbol \(symbol)"
        case let .invalidDistance(distance): return "invalid distance \(distance)"
        case .missingEndOfBlock: return "missing end-of-block symbol"
        case .trailingData: return "trailing compressed data"
        case let .sizeMismatch(expected, actual):
            return "size mismatch (expected \(expected), got \(actual))"
        }
    }
}

/// Bounded raw RFC1951 decoder. ZIP supplies the surrounding CRC and sizes.
private enum SourceBSPRawDeflate {
    static func decode(
        _ compressed: Data,
        offset: Int,
        compressedByteCount: Int,
        expectedByteCount: UInt64,
        maximumCompressedByteCount: UInt64,
        maximumDecodedByteCount: UInt64
    ) throws -> Data {
        guard compressedByteCount >= 0,
              UInt64(compressedByteCount) <= maximumCompressedByteCount else {
            throw SourceBSPRawDeflateError.compressedInputTooLarge(
                compressedByteCount < 0 ? .max : UInt64(compressedByteCount)
            )
        }
        guard offset >= 0,
              offset <= compressed.count,
              compressedByteCount <= compressed.count - offset else {
            throw SourceBSPRawDeflateError.truncated
        }
        guard expectedByteCount <= maximumDecodedByteCount,
              expectedByteCount <= UInt64(Int.max) else {
            throw SourceBSPRawDeflateError.decodedOutputTooLarge(
                expectedByteCount
            )
        }
        let maximum = min(expectedByteCount, maximumDecodedByteCount)
        var reader = BitReader(
            bytes: compressed,
            byteOffset: offset,
            byteCount: compressedByteCount
        )
        var output: [UInt8] = []
        output.reserveCapacity(Int(expectedByteCount))
        var isFinal = false
        while !isFinal {
            isFinal = try reader.readBits(1) == 1
            switch try reader.readBits(2) {
            case 0:
                try decodeStored(
                    reader: &reader,
                    output: &output,
                    maximum: maximum
                )
            case 1:
                try decodeHuffman(
                    reader: &reader,
                    literalLengths: fixedLiteralLengths,
                    distanceLengths: Array(repeating: 5, count: 32),
                    output: &output,
                    maximum: maximum
                )
            case 2:
                let trees = try dynamicTrees(reader: &reader)
                try decodeHuffman(
                    reader: &reader,
                    literalLengths: trees.literal,
                    distanceLengths: trees.distance,
                    output: &output,
                    maximum: maximum
                )
            default:
                throw SourceBSPRawDeflateError.invalidBlockType
            }
        }
        guard reader.consumedByteCount == compressedByteCount else {
            throw SourceBSPRawDeflateError.trailingData
        }
        guard UInt64(output.count) == expectedByteCount else {
            throw SourceBSPRawDeflateError.sizeMismatch(
                expected: expectedByteCount,
                actual: UInt64(output.count)
            )
        }
        return Data(output)
    }

    private static let fixedLiteralLengths: [UInt8] = {
        var result = Array(repeating: UInt8(0), count: 288)
        for index in 0...143 { result[index] = 8 }
        for index in 144...255 { result[index] = 9 }
        for index in 256...279 { result[index] = 7 }
        for index in 280...287 { result[index] = 8 }
        return result
    }()

    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]
    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtraBits = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBases = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
        193, 257, 385, 513, 769, 1_025, 1_537, 2_049, 3_073,
        4_097, 6_145, 8_193, 12_289, 16_385, 24_577,
    ]
    private static let distanceExtraBits = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
        6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    private static func decodeStored(
        reader: inout BitReader,
        output: inout [UInt8],
        maximum: UInt64
    ) throws {
        reader.alignToByte()
        let count = Int(try reader.readBits(16))
        let complement = Int(try reader.readBits(16))
        guard (count ^ 0xFFFF) == complement else {
            throw SourceBSPRawDeflateError.invalidStoredBlock
        }
        try appendBounded(count: count, current: output.count, maximum: maximum)
        for _ in 0..<count { output.append(UInt8(try reader.readBits(8))) }
    }

    private static func dynamicTrees(reader: inout BitReader) throws
        -> (literal: [UInt8], distance: [UInt8])
    {
        let literalCount = Int(try reader.readBits(5)) + 257
        let distanceCount = Int(try reader.readBits(5)) + 1
        let codeLengthCount = Int(try reader.readBits(4)) + 4
        guard literalCount <= 286, distanceCount <= 32 else {
            throw SourceBSPRawDeflateError.invalidHuffmanTree
        }
        var codeLengthLengths = Array(repeating: UInt8(0), count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[index]] = UInt8(
                try reader.readBits(3)
            )
        }
        let codeLengthTree = try Huffman(
            lengths: codeLengthLengths,
            kind: .codeLength
        )
        let total = literalCount + distanceCount
        var lengths: [UInt8] = []
        lengths.reserveCapacity(total)
        while lengths.count < total {
            let symbol = try codeLengthTree.decode(reader: &reader)
            switch symbol {
            case 0...15:
                lengths.append(UInt8(symbol))
            case 16:
                guard let previous = lengths.last else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                let count = Int(try reader.readBits(2)) + 3
                guard lengths.count + count <= total else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                lengths.append(contentsOf: repeatElement(previous, count: count))
            case 17:
                let count = Int(try reader.readBits(3)) + 3
                guard lengths.count + count <= total else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                lengths.append(
                    contentsOf: repeatElement(UInt8(0), count: count)
                )
            case 18:
                let count = Int(try reader.readBits(7)) + 11
                guard lengths.count + count <= total else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                lengths.append(
                    contentsOf: repeatElement(UInt8(0), count: count)
                )
            default:
                throw SourceBSPRawDeflateError.invalidSymbol(symbol)
            }
        }
        let literal = Array(lengths[..<literalCount])
        let distance = Array(lengths[literalCount...])
        guard literal.count > 256, literal[256] != 0 else {
            throw SourceBSPRawDeflateError.missingEndOfBlock
        }
        _ = try Huffman(lengths: literal, kind: .literalLength)
        if distance.contains(where: { $0 != 0 }) {
            _ = try Huffman(lengths: distance, kind: .distance)
        }
        return (literal, distance)
    }

    private static func decodeHuffman(
        reader: inout BitReader,
        literalLengths: [UInt8],
        distanceLengths: [UInt8],
        output: inout [UInt8],
        maximum: UInt64
    ) throws {
        let literalTree = try Huffman(
            lengths: literalLengths,
            kind: .literalLength
        )
        let distanceTree = distanceLengths.contains(where: { $0 != 0 })
            ? try Huffman(lengths: distanceLengths, kind: .distance)
            : nil
        while true {
            let symbol = try literalTree.decode(reader: &reader)
            switch symbol {
            case 0...255:
                try appendBounded(
                    count: 1,
                    current: output.count,
                    maximum: maximum
                )
                output.append(UInt8(symbol))
            case 256:
                return
            case 257...285:
                let index = symbol - 257
                let length = lengthBases[index] +
                    Int(try reader.readBits(lengthExtraBits[index]))
                guard let distanceTree else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                let distanceSymbol = try distanceTree.decode(reader: &reader)
                guard distanceSymbol >= 0,
                      distanceSymbol < distanceBases.count else {
                    throw SourceBSPRawDeflateError.invalidSymbol(distanceSymbol)
                }
                let distance = distanceBases[distanceSymbol] +
                    Int(try reader.readBits(distanceExtraBits[distanceSymbol]))
                guard distance > 0, distance <= output.count else {
                    throw SourceBSPRawDeflateError.invalidDistance(distance)
                }
                try appendBounded(
                    count: length,
                    current: output.count,
                    maximum: maximum
                )
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            default:
                throw SourceBSPRawDeflateError.invalidSymbol(symbol)
            }
        }
    }

    private static func appendBounded(
        count: Int,
        current: Int,
        maximum: UInt64
    ) throws {
        guard count >= 0 else {
            throw SourceBSPRawDeflateError.decodedOutputTooLarge(.max)
        }
        let (next, overflow) = UInt64(current).addingReportingOverflow(
            UInt64(count)
        )
        guard !overflow, next <= maximum, next <= UInt64(Int.max) else {
            throw SourceBSPRawDeflateError.decodedOutputTooLarge(next)
        }
    }

    private struct BitReader {
        let bytes: Data
        let byteOffset: Int
        let byteCount: Int
        var bitOffset = 0

        var consumedByteCount: Int { (bitOffset + 7) / 8 }

        mutating func readBits(_ count: Int) throws -> UInt32 {
            guard count >= 0, count <= 24,
                  bitOffset <= byteCount * 8 - count else {
                throw SourceBSPRawDeflateError.truncated
            }
            var result: UInt32 = 0
            for index in 0..<count {
                let absolute = bitOffset + index
                let dataOffset = byteOffset + absolute / 8
                let dataIndex = bytes.index(
                    bytes.startIndex,
                    offsetBy: dataOffset
                )
                let bit = (bytes[dataIndex] >> UInt8(absolute % 8)) & 1
                result |= UInt32(bit) << UInt32(index)
            }
            bitOffset += count
            return result
        }

        mutating func alignToByte() {
            bitOffset = (bitOffset + 7) & ~7
        }
    }

    private struct Huffman {
        enum Kind { case codeLength, literalLength, distance }

        let symbolsByLengthAndCode: [[Int: Int]]
        let maximumLength: Int

        init(lengths: [UInt8], kind: Kind) throws {
            var counts = Array(repeating: 0, count: 16)
            for length in lengths {
                guard length <= 15 else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                if length > 0 { counts[Int(length)] += 1 }
            }
            let used = counts.dropFirst().reduce(0, +)
            guard used > 0 else {
                throw SourceBSPRawDeflateError.invalidHuffmanTree
            }
            var left = 1
            var maximumLength = 0
            for bits in 1...15 {
                left = (left << 1) - counts[bits]
                guard left >= 0 else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                if counts[bits] > 0 { maximumLength = bits }
            }
            if left > 0 {
                guard kind != .codeLength, used == 1, maximumLength == 1 else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
            }

            var nextCode = Array(repeating: 0, count: 16)
            var code = 0
            for bits in 1...15 {
                code = (code + counts[bits - 1]) << 1
                nextCode[bits] = code
            }
            var tables = Array(repeating: [Int: Int](), count: 16)
            for (symbol, rawLength) in lengths.enumerated() where rawLength > 0 {
                let length = Int(rawLength)
                let canonical = nextCode[length]
                nextCode[length] += 1
                let transmitted = Self.reverseBits(canonical, count: length)
                guard tables[length][transmitted] == nil else {
                    throw SourceBSPRawDeflateError.invalidHuffmanTree
                }
                tables[length][transmitted] = symbol
            }
            symbolsByLengthAndCode = tables
            self.maximumLength = maximumLength
        }

        func decode(reader: inout BitReader) throws -> Int {
            var code = 0
            for length in 1...maximumLength {
                code |= Int(try reader.readBits(1)) << (length - 1)
                if let symbol = symbolsByLengthAndCode[length][code] {
                    return symbol
                }
            }
            throw SourceBSPRawDeflateError.invalidHuffmanTree
        }

        private static func reverseBits(_ value: Int, count: Int) -> Int {
            var source = value
            var result = 0
            for _ in 0..<count {
                result = (result << 1) | (source & 1)
                source >>= 1
            }
            return result
        }
    }
}

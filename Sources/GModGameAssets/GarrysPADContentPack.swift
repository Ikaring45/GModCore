import Foundation

public enum GarrysPADContentPackError: Error, Sendable, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case invalidArchive(String)
    case unsafePath(String)
    case duplicatePath(String)
    case missingRequiredEntry(String)
    case unsupportedCompression(path: String, method: UInt16)
    case entryTooLarge(path: String, byteCount: UInt64)
    case truncatedEntry(String)
    case checksumMismatch(String)

    public var description: String {
        switch self {
        case let .fileNotFound(path):
            return "content pack not found: \(path)"
        case let .invalidArchive(message):
            return "invalid Garry's PAD content pack: \(message)"
        case let .unsafePath(path):
            return "unsafe content-pack path: \(path)"
        case let .duplicatePath(path):
            return "duplicate content-pack path: \(path)"
        case let .missingRequiredEntry(path):
            return "content pack is missing required entry: \(path)"
        case let .unsupportedCompression(path, method):
            return "content-pack entry \(path) uses unsupported ZIP method \(method)"
        case let .entryTooLarge(path, byteCount):
            return "content-pack entry \(path) is too large to read (\(byteCount) bytes)"
        case let .truncatedEntry(path):
            return "content-pack entry is truncated: \(path)"
        case let .checksumMismatch(path):
            return "content-pack entry failed its ZIP CRC32: \(path)"
        }
    }
}

/// Random-access reader for a Garry's PAD content ZIP placed in an app or
/// Swift Playgrounds resource bundle.
///
/// The packer stores large maps, images, audio, and VPK payloads without ZIP
/// compression. This reader therefore needs only the ZIP/ZIP64 index and reads
/// selected entries directly from the bundle instead of expanding a second
/// multi-gigabyte copy into the iPad container. Deflated metadata and text
/// remain indexed, but are rejected explicitly until a streaming inflater is
/// connected.
public final class GarrysPADContentPack: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let uncompressedByteCount: UInt64
        public let compressedByteCount: UInt64
        public let compressionMethod: UInt16

        fileprivate let localHeaderOffset: UInt64
        fileprivate let crc32: UInt32
    }

    public static let preferredFileNamePrefix = "GarrysPAD_Content_"
    public static let requiredPlayablePaths = [
        "garrysmod/maps/gm_construct.bsp",
        "garrysmod/maps/gm_flatgrass.bsp",
        "garrysmod/html/img/bg.jpg",
    ]

    public let archiveURL: URL
    public let entries: [String: Entry]

    private let lock = NSLock()

    public init(url: URL, requirePlayableContent: Bool = true) throws {
        archiveURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw GarrysPADContentPackError.fileNotFound(archiveURL.path)
        }
        entries = try Self.readCentralDirectory(from: archiveURL)
        if requirePlayableContent {
            for path in Self.requiredPlayablePaths where entries[path] == nil {
                throw GarrysPADContentPackError.missingRequiredEntry(path)
            }
        }
    }

    public func contains(_ logicalPath: String) -> Bool {
        guard let normalized = try? Self.normalizedPath(logicalPath) else { return false }
        return entries[normalized] != nil
    }

    public func entry(for logicalPath: String) throws -> Entry? {
        entries[try Self.normalizedPath(logicalPath)]
    }

    /// Reads a stored entry. `maximumByteCount` is an allocation boundary, not
    /// a claim about the ZIP entry's trustworthiness.
    public func data(
        for logicalPath: String,
        maximumByteCount: UInt64 = 512 * 1_024 * 1_024
    ) throws -> Data {
        let path = try Self.normalizedPath(logicalPath)
        guard let entry = entries[path] else {
            throw GarrysPADContentPackError.missingRequiredEntry(path)
        }
        guard entry.compressionMethod == 0 else {
            throw GarrysPADContentPackError.unsupportedCompression(
                path: path,
                method: entry.compressionMethod
            )
        }
        guard entry.uncompressedByteCount == entry.compressedByteCount else {
            throw GarrysPADContentPackError.invalidArchive(
                "stored entry has unequal compressed and uncompressed sizes: \(path)"
            )
        }
        guard entry.uncompressedByteCount <= maximumByteCount,
              entry.uncompressedByteCount <= UInt64(Int.max) else {
            throw GarrysPADContentPackError.entryTooLarge(
                path: path,
                byteCount: entry.uncompressedByteCount
            )
        }

        lock.lock()
        defer { lock.unlock() }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            throw GarrysPADContentPackError.fileNotFound(archiveURL.path)
        }
        defer { try? handle.close() }

        let header = try Self.readExactly(
            handle,
            offset: entry.localHeaderOffset,
            count: 30,
            context: path
        )
        guard Self.u32(header, 0) == 0x0403_4B50 else {
            throw GarrysPADContentPackError.invalidArchive(
                "local header signature is invalid for \(path)"
            )
        }
        let localMethod = Self.u16(header, 8)
        guard localMethod == entry.compressionMethod else {
            throw GarrysPADContentPackError.invalidArchive(
                "local and central compression methods differ for \(path)"
            )
        }
        let nameLength = UInt64(Self.u16(header, 26))
        let extraLength = UInt64(Self.u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        let result = try Self.readExactly(
            handle,
            offset: dataOffset,
            count: Int(entry.uncompressedByteCount),
            context: path
        )
        guard Self.crc32(result) == entry.crc32 else {
            throw GarrysPADContentPackError.checksumMismatch(path)
        }
        return result
    }

    /// Finds exactly one Garry's PAD ZIP in a resource bundle. This is shallow
    /// by design: Swift Playgrounds places user resources at the bundle root.
    public static func discover(in bundle: Bundle = .main) throws -> GarrysPADContentPack? {
        guard let root = bundle.resourceURL else { return nil }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter {
            $0.pathExtension.caseInsensitiveCompare("zip") == .orderedSame &&
                $0.deletingPathExtension().lastPathComponent.hasPrefix(
                    preferredFileNamePrefix
                )
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1 else {
            throw GarrysPADContentPackError.invalidArchive(
                "place exactly one \(preferredFileNamePrefix)*.zip in Resources; found " +
                    candidates.map(\.lastPathComponent).joined(separator: ", ")
            )
        }
        return try GarrysPADContentPack(url: candidates[0])
    }

    private static func readCentralDirectory(from url: URL) throws -> [String: Entry] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GarrysPADContentPackError.fileNotFound(url.path)
        }
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            throw GarrysPADContentPackError.invalidArchive("cannot determine ZIP size")
        }
        guard fileSize >= 22 else {
            throw GarrysPADContentPackError.invalidArchive("ZIP is shorter than its end record")
        }
        let tailCount = Int(min(fileSize, 65_557))
        let tail = try readExactly(
            handle,
            offset: fileSize - UInt64(tailCount),
            count: tailCount,
            context: "end of central directory"
        )
        guard let eocdInTail = lastSignature(0x0605_4B50, in: tail) else {
            throw GarrysPADContentPackError.invalidArchive("end-of-central-directory record missing")
        }
        guard eocdInTail + 22 <= tail.count else {
            throw GarrysPADContentPackError.invalidArchive("truncated end-of-central-directory record")
        }
        let archiveCommentCount = Int(u16(tail, eocdInTail + 20))
        guard eocdInTail + 22 + archiveCommentCount == tail.count else {
            throw GarrysPADContentPackError.invalidArchive(
                "end-of-central-directory comment length is inconsistent"
            )
        }
        let eocdOffset = fileSize - UInt64(tailCount) + UInt64(eocdInTail)
        let diskNumber = u16(tail, eocdInTail + 4)
        let centralDisk = u16(tail, eocdInTail + 6)
        guard diskNumber == 0, centralDisk == 0 else {
            throw GarrysPADContentPackError.invalidArchive("multi-disk ZIPs are unsupported")
        }
        var entryCount = UInt64(u16(tail, eocdInTail + 10))
        var centralSize = UInt64(u32(tail, eocdInTail + 12))
        var centralOffset = UInt64(u32(tail, eocdInTail + 16))
        if entryCount == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            guard eocdOffset >= 20 else {
                throw GarrysPADContentPackError.invalidArchive("ZIP64 locator missing")
            }
            let locator = try readExactly(
                handle,
                offset: eocdOffset - 20,
                count: 20,
                context: "ZIP64 locator"
            )
            guard u32(locator, 0) == 0x0706_4B50,
                  u32(locator, 4) == 0,
                  u32(locator, 16) == 1 else {
                throw GarrysPADContentPackError.invalidArchive("invalid ZIP64 locator")
            }
            let zip64Offset = u64(locator, 8)
            let zip64 = try readExactly(
                handle,
                offset: zip64Offset,
                count: 56,
                context: "ZIP64 end record"
            )
            guard u32(zip64, 0) == 0x0606_4B50,
                  u32(zip64, 16) == 0,
                  u32(zip64, 20) == 0 else {
                throw GarrysPADContentPackError.invalidArchive("invalid ZIP64 end record")
            }
            entryCount = u64(zip64, 32)
            centralSize = u64(zip64, 40)
            centralOffset = u64(zip64, 48)
        }
        guard centralSize <= UInt64(Int.max),
              centralOffset <= fileSize,
              centralSize <= fileSize - centralOffset else {
            throw GarrysPADContentPackError.invalidArchive("central directory is out of bounds")
        }
        let central = try readExactly(
            handle,
            offset: centralOffset,
            count: Int(centralSize),
            context: "central directory"
        )
        var result: [String: Entry] = [:]
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= central.count,
                  u32(central, cursor) == 0x0201_4B50 else {
                throw GarrysPADContentPackError.invalidArchive("malformed central directory entry")
            }
            let flags = u16(central, cursor + 8)
            guard flags & 0x0001 == 0 else {
                throw GarrysPADContentPackError.invalidArchive("encrypted entries are unsupported")
            }
            let method = u16(central, cursor + 10)
            let crc32 = u32(central, cursor + 16)
            let compressed32 = u32(central, cursor + 20)
            let uncompressed32 = u32(central, cursor + 24)
            let nameCount = Int(u16(central, cursor + 28))
            let extraCount = Int(u16(central, cursor + 30))
            let commentCount = Int(u16(central, cursor + 32))
            let diskStart = u16(central, cursor + 34)
            let localOffset32 = u32(central, cursor + 42)
            let recordEnd = cursor + 46 + nameCount + extraCount + commentCount
            guard recordEnd <= central.count else {
                throw GarrysPADContentPackError.invalidArchive("truncated central directory entry")
            }
            let nameData = central.subdata(in: cursor + 46..<cursor + 46 + nameCount)
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw GarrysPADContentPackError.invalidArchive("entry name is not UTF-8")
            }
            let path = try normalizedPath(rawName)
            var compressed = UInt64(compressed32)
            var uncompressed = UInt64(uncompressed32)
            var localOffset = UInt64(localOffset32)
            var resolvedDisk = UInt32(diskStart)
            if compressed32 == 0xFFFF_FFFF || uncompressed32 == 0xFFFF_FFFF ||
                localOffset32 == 0xFFFF_FFFF || diskStart == 0xFFFF {
                let extraStart = cursor + 46 + nameCount
                let extra = central.subdata(in: extraStart..<extraStart + extraCount)
                guard let zip64 = extraField(0x0001, in: extra) else {
                    throw GarrysPADContentPackError.invalidArchive(
                        "ZIP64 values missing for \(path)"
                    )
                }
                var offset = 0
                if uncompressed32 == 0xFFFF_FFFF {
                    guard offset + 8 <= zip64.count else { throw truncatedZip64(path) }
                    uncompressed = u64(zip64, offset); offset += 8
                }
                if compressed32 == 0xFFFF_FFFF {
                    guard offset + 8 <= zip64.count else { throw truncatedZip64(path) }
                    compressed = u64(zip64, offset); offset += 8
                }
                if localOffset32 == 0xFFFF_FFFF {
                    guard offset + 8 <= zip64.count else { throw truncatedZip64(path) }
                    localOffset = u64(zip64, offset); offset += 8
                }
                if diskStart == 0xFFFF {
                    guard offset + 4 <= zip64.count else { throw truncatedZip64(path) }
                    resolvedDisk = u32(zip64, offset)
                }
            }
            guard resolvedDisk == 0 else {
                throw GarrysPADContentPackError.invalidArchive("multi-disk entry: \(path)")
            }
            guard result[path] == nil else {
                throw GarrysPADContentPackError.duplicatePath(path)
            }
            result[path] = Entry(
                path: path,
                uncompressedByteCount: uncompressed,
                compressedByteCount: compressed,
                compressionMethod: method,
                localHeaderOffset: localOffset,
                crc32: crc32
            )
            cursor = recordEnd
        }
        guard UInt64(result.count) == entryCount else {
            throw GarrysPADContentPackError.invalidArchive("entry count mismatch")
        }
        return result
    }

    private static func normalizedPath(_ value: String) throws -> String {
        let replaced = value.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.isEmpty,
              !replaced.hasPrefix("/"),
              !replaced.contains("\0") else {
            throw GarrysPADContentPackError.unsafePath(value)
        }
        let components = replaced.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GarrysPADContentPackError.unsafePath(value)
        }
        return components.joined(separator: "/").lowercased()
    }

    private static func extraField(_ identifier: UInt16, in data: Data) -> Data? {
        var cursor = 0
        while cursor + 4 <= data.count {
            let fieldID = u16(data, cursor)
            let count = Int(u16(data, cursor + 2))
            guard cursor + 4 + count <= data.count else { return nil }
            if fieldID == identifier {
                return data.subdata(in: cursor + 4..<cursor + 4 + count)
            }
            cursor += 4 + count
        }
        return nil
    }

    private static func truncatedZip64(_ path: String) -> GarrysPADContentPackError {
        .invalidArchive("truncated ZIP64 extra field for \(path)")
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for index in stride(from: data.count - 4, through: 0, by: -1) {
            if u32(data, index) == signature { return index }
        }
        return nil
    }

    private static func readExactly(
        _ handle: FileHandle,
        offset: UInt64,
        count: Int,
        context: String
    ) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                let next = try handle.read(upToCount: count - result.count) ?? Data()
                guard !next.isEmpty else {
                    throw GarrysPADContentPackError.truncatedEntry(context)
                }
                result.append(next)
            }
            return result
        } catch let error as GarrysPADContentPackError {
            throw error
        } catch {
            throw GarrysPADContentPackError.truncatedEntry(context)
        }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) | UInt64(u32(data, offset + 4)) << 32
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
}

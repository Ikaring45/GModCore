import Foundation
import GModLua

public enum GMLuaVPKError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidHeader(String)
    case malformedTree(String)
    case unsafePath(String)
    case missingArchive(String)
    case truncatedData(String)
    case checksumMismatch(String)

    public var description: String {
        switch self {
        case let .invalidHeader(message): return "invalid VPK header: \(message)"
        case let .malformedTree(message): return "malformed VPK tree: \(message)"
        case let .unsafePath(path): return "unsafe VPK path: \(path)"
        case let .missingArchive(path): return "missing VPK archive: \(path)"
        case let .truncatedData(path): return "truncated VPK data: \(path)"
        case let .checksumMismatch(path): return "VPK CRC32 mismatch: \(path)"
        }
    }
}

/// Read-only Valve VPK v1/v2 archive index.
///
/// File payloads are stored verbatim in VPK archives, so Source assets can be
/// decoded without invoking desktop tools or copying them into the package.
public final class GMLuaVPKArchive: @unchecked Sendable {
    private struct Entry: Sendable {
        let crc32: UInt32
        let preloadData: Data
        let archiveIndex: UInt16
        let offset: UInt32
        let length: UInt32
    }

    private static let signature: UInt32 = 0x55AA_1234
    private static let directoryArchiveIndex: UInt16 = 0x7FFF

    public let directoryFileURL: URL
    public let version: UInt32
    public let fileCount: Int

    private let directoryDataOffset: UInt64
    private let chunkBaseName: String
    private let entries: [Data: Entry]

    public init(directoryFileURL: URL) throws {
        self.directoryFileURL = directoryFileURL.standardizedFileURL
        let fileName = self.directoryFileURL.lastPathComponent
        guard fileName.lowercased().hasSuffix("_dir.vpk") else {
            throw GMLuaVPKError.invalidHeader("expected an *_dir.vpk file")
        }
        chunkBaseName = String(fileName.dropLast("_dir.vpk".count))

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: self.directoryFileURL)
        } catch {
            throw GMLuaVPKError.missingArchive(self.directoryFileURL.path)
        }
        defer { try? handle.close() }

        let directoryFileSize: UInt64
        do {
            directoryFileSize = try handle.seekToEnd()
        } catch {
            throw GMLuaVPKError.truncatedData(fileName)
        }

        let baseHeader = try Self.readExactly(handle, offset: 0, count: 12, path: fileName)
        var headerCursor = ByteCursor(data: baseHeader)
        let parsedSignature = try headerCursor.readUInt32(context: "signature")
        guard parsedSignature == Self.signature else {
            throw GMLuaVPKError.invalidHeader("unexpected signature 0x\(String(parsedSignature, radix: 16))")
        }
        version = try headerCursor.readUInt32(context: "version")
        let treeSize = try headerCursor.readUInt32(context: "tree size")

        let headerSize: UInt64
        let declaredDirectoryDataLength: UInt64?
        var trailingSectionLength: UInt64 = 0
        switch version {
        case 1:
            headerSize = 12
            declaredDirectoryDataLength = nil
        case 2:
            let extendedHeader = try Self.readExactly(
                handle,
                offset: 12,
                count: 16,
                path: fileName
            )
            var extendedCursor = ByteCursor(data: extendedHeader)
            declaredDirectoryDataLength = UInt64(
                try extendedCursor.readUInt32(context: "file data section size")
            )
            trailingSectionLength = UInt64(
                try extendedCursor.readUInt32(context: "archive MD5 section size")
            )
            trailingSectionLength += UInt64(
                try extendedCursor.readUInt32(context: "other MD5 section size")
            )
            trailingSectionLength += UInt64(
                try extendedCursor.readUInt32(context: "signature section size")
            )
            headerSize = 28
        default:
            throw GMLuaVPKError.invalidHeader("unsupported version \(version)")
        }

        guard UInt64(treeSize) <= UInt64(Int.max) else {
            throw GMLuaVPKError.invalidHeader("tree is too large")
        }
        let treeData = try Self.readExactly(
            handle,
            offset: headerSize,
            count: Int(treeSize),
            path: fileName
        )
        directoryDataOffset = headerSize + UInt64(treeSize)
        guard directoryDataOffset <= directoryFileSize else {
            throw GMLuaVPKError.truncatedData(fileName)
        }
        let directoryDataLength: UInt64
        if let declaredDirectoryDataLength {
            directoryDataLength = declaredDirectoryDataLength
            let declaredEnd = directoryDataOffset
                + declaredDirectoryDataLength
                + trailingSectionLength
            guard declaredEnd <= directoryFileSize else {
                throw GMLuaVPKError.truncatedData(fileName)
            }
        } else {
            directoryDataLength = directoryFileSize - directoryDataOffset
        }

        var treeCursor = ByteCursor(data: treeData)
        var parsedEntries: [Data: Entry] = [:]
        while true {
            let fileExtension = try treeCursor.readCString(context: "extension")
            if fileExtension.isEmpty { break }
            while true {
                let directoryPath = try treeCursor.readCString(context: "directory")
                if directoryPath.isEmpty { break }
                while true {
                    let fileStem = try treeCursor.readCString(context: "file name")
                    if fileStem.isEmpty { break }

                    let crc32 = try treeCursor.readUInt32(context: "CRC32")
                    let preloadLength = try treeCursor.readUInt16(context: "preload length")
                    let archiveIndex = try treeCursor.readUInt16(context: "archive index")
                    let offset = try treeCursor.readUInt32(context: "entry offset")
                    let length = try treeCursor.readUInt32(context: "entry length")
                    let terminator = try treeCursor.readUInt16(context: "entry terminator")
                    guard terminator == 0xFFFF else {
                        throw GMLuaVPKError.malformedTree("entry terminator is not 0xFFFF")
                    }
                    let preloadData = try treeCursor.readData(
                        count: Int(preloadLength),
                        context: "preload data"
                    )
                    let logicalPath = try Self.makeLogicalPath(
                        directory: directoryPath,
                        stem: fileStem,
                        extension: fileExtension
                    )
                    if archiveIndex == Self.directoryArchiveIndex {
                        let entryEnd = UInt64(offset) + UInt64(length)
                        guard entryEnd <= directoryDataLength else {
                            throw GMLuaVPKError.malformedTree(
                                "directory data range exceeds its section for "
                                    + Self.displayPath(logicalPath)
                            )
                        }
                    }
                    guard parsedEntries[logicalPath] == nil else {
                        throw GMLuaVPKError.malformedTree(
                            "duplicate path \(Self.displayPath(logicalPath))"
                        )
                    }
                    parsedEntries[logicalPath] = Entry(
                        crc32: crc32,
                        preloadData: preloadData,
                        archiveIndex: archiveIndex,
                        offset: offset,
                        length: length
                    )
                }
            }
        }
        guard treeCursor.isAtEnd else {
            throw GMLuaVPKError.malformedTree("bytes remain after the tree terminator")
        }
        entries = parsedEntries
        fileCount = parsedEntries.count
    }

    public func contains(_ logicalPath: LuaString) -> Bool {
        guard let normalized = try? Self.normalizedPath(Data(logicalPath.bytes)) else { return false }
        return entries[normalized] != nil
    }

    public func contains(_ logicalPath: String) -> Bool {
        contains(LuaString(logicalPath))
    }

    public func data(for logicalPath: String) throws -> Data? {
        try data(for: LuaString(logicalPath))
    }

    public func data(for logicalPath: LuaString) throws -> Data? {
        let normalized = try Self.normalizedPath(Data(logicalPath.bytes))
        guard let entry = entries[normalized] else { return nil }

        var result = entry.preloadData
        if entry.length > 0 {
            let payloadURL: URL
            let payloadOffset: UInt64
            if entry.archiveIndex == Self.directoryArchiveIndex {
                payloadURL = directoryFileURL
                payloadOffset = directoryDataOffset + UInt64(entry.offset)
            } else {
                payloadURL = directoryFileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(chunkBaseName)_\(String(format: "%03u", entry.archiveIndex)).vpk"
                    )
                payloadOffset = UInt64(entry.offset)
            }

            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: payloadURL)
            } catch {
                throw GMLuaVPKError.missingArchive(payloadURL.path)
            }
            defer { try? handle.close() }
            let payload = try Self.readExactly(
                handle,
                offset: payloadOffset,
                count: Int(entry.length),
                path: Self.displayPath(normalized)
            )
            result.append(payload)
        }

        guard Self.crc32(result) == entry.crc32 else {
            throw GMLuaVPKError.checksumMismatch(Self.displayPath(normalized))
        }
        return result
    }

    private static func makeLogicalPath(
        directory: Data,
        stem: Data,
        extension fileExtension: Data
    ) throws -> Data {
        var path = Data()
        if directory != Data([0x20]) {
            path.append(directory)
            path.append(0x2F)
        }
        path.append(stem)
        if fileExtension != Data([0x20]) {
            path.append(0x2E)
            path.append(fileExtension)
        }
        return try normalizedPath(path)
    }

    private static func normalizedPath(_ rawPath: Data) throws -> Data {
        guard !rawPath.isEmpty else { throw GMLuaVPKError.unsafePath("") }
        var components: [Data] = []
        var current = Data()
        for rawByte in rawPath {
            guard rawByte != 0 else {
                throw GMLuaVPKError.unsafePath(displayPath(rawPath))
            }
            let byte = rawByte == 0x5C ? UInt8(0x2F) : asciiLowercased(rawByte)
            if byte == 0x2F {
                guard !current.isEmpty,
                      current != Data([0x2E]),
                      current != Data([0x2E, 0x2E]) else {
                    throw GMLuaVPKError.unsafePath(displayPath(rawPath))
                }
                components.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        guard !current.isEmpty,
              current != Data([0x2E]),
              current != Data([0x2E, 0x2E]) else {
            throw GMLuaVPKError.unsafePath(displayPath(rawPath))
        }
        components.append(current)

        var normalized = Data()
        for (index, component) in components.enumerated() {
            if index > 0 { normalized.append(0x2F) }
            normalized.append(component)
        }
        return normalized
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func readExactly(
        _ handle: FileHandle,
        offset: UInt64,
        count: Int,
        path: String
    ) throws -> Data {
        guard count >= 0 else { throw GMLuaVPKError.truncatedData(path) }
        do {
            try handle.seek(toOffset: offset)
            var result = Data()
            while result.count < count {
                let chunk = try handle.read(upToCount: count - result.count) ?? Data()
                guard !chunk.isEmpty else { throw GMLuaVPKError.truncatedData(path) }
                result.append(chunk)
            }
            return result
        } catch let error as GMLuaVPKError {
            throw error
        } catch {
            throw GMLuaVPKError.truncatedData(path)
        }
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

    private static func displayPath(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

private struct ByteCursor {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt16(context: String) throws -> UInt16 {
        let bytes = try readData(count: 2, context: context)
        return UInt16(bytes[bytes.startIndex])
            | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32(context: String) throws -> UInt32 {
        let bytes = try readData(count: 4, context: context)
        return UInt32(bytes[bytes.startIndex])
            | (UInt32(bytes[bytes.startIndex + 1]) << 8)
            | (UInt32(bytes[bytes.startIndex + 2]) << 16)
            | (UInt32(bytes[bytes.startIndex + 3]) << 24)
    }

    mutating func readCString(context: String) throws -> Data {
        let start = offset
        while offset < data.count {
            if data[offset] == 0 {
                let value = data.subdata(in: start..<offset)
                offset += 1
                return value
            }
            offset += 1
        }
        throw GMLuaVPKError.malformedTree("unterminated \(context)")
    }

    mutating func readData(count: Int, context: String) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw GMLuaVPKError.malformedTree("truncated \(context)")
        }
        let value = data.subdata(in: offset..<(offset + count))
        offset += count
        return value
    }
}

/// Material pixel resolver backed by one or more real Source VPK archives.
public final class GMLuaVPKMaterialPixelResolver: GMLuaMaterialMetadataResolver,
    @unchecked Sendable
{
    public let sourceMaterialResolver: GMLuaSourceMaterialResolver

    public init(
        looseFileSystem: (any LuaVirtualFileSystem & Sendable)? = nil,
        archivesInPriorityOrder archives: [GMLuaVPKArchive]
    ) {
        sourceMaterialResolver = GMLuaSourceMaterialResolver { logicalPath in
            if let looseFileSystem,
               looseFileSystem.fileExists(at: logicalPath) {
                return try looseFileSystem.readFile(at: logicalPath)
            }
            for archive in archives {
                if let encodedImage = try archive.data(for: LuaString(logicalPath)) {
                    return encodedImage
                }
            }
            return nil
        }
    }

    public func dimensions(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaImageDimensions? {
        try sourceMaterialResolver.dimensions(
            materialPath: materialPath,
            encodedParameters: encodedParameters
        )
    }

    public func pixel(
        materialPath: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int
    ) throws -> GMLuaRGBA8? {
        try sourceMaterialResolver.pixel(
            materialPath: materialPath,
            encodedParameters: encodedParameters,
            x: x,
            y: y
        )
    }

    public func metadata(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaMaterialMetadata {
        try sourceMaterialResolver.metadata(
            materialPath: materialPath,
            encodedParameters: encodedParameters
        )
    }

    public func resolve(
        named materialName: String,
        encodedParameters: LuaString? = nil
    ) throws -> GMLuaResolvedSourceMaterial {
        try sourceMaterialResolver.resolve(
            named: materialName,
            encodedParameters: encodedParameters
        )
    }

    public func removeAllCachedImages() {
        sourceMaterialResolver.removeAllCachedMaterials()
    }
}

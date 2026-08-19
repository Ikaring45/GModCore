import Foundation
import GModLua

private enum GMLuaPresetPersistenceError: Error, CustomStringConvertible {
    case invalidData(String)
    case unsupportedValue(String)

    var description: String {
        switch self {
        case let .invalidData(message): return "invalid preset data: \(message)"
        case let .unsupportedValue(message): return "cannot save presets: \(message)"
        }
    }
}

/// VFS-backed implementation of Garry's Mod's desktop preset store.
///
/// Each preset is a Valve KeyValues text file at
/// `settings/presets/<group>/<number>-<safe-name>.txt`. SavePresets receives
/// complete groups, so every supplied group is replaced while groups omitted
/// from the call remain untouched. Mounted VFS whiteouts keep removed built-in
/// files hidden when the writable data layer sits above a read-only install.
public final class GMLuaPresetStore: @unchecked Sendable {
    public static let defaultStorageRoot = "settings/presets"
    // Retained as a source-compatible spelling for early callers. The value is
    // now a directory, not the removed private Garry's PAD snapshot file.
    public static let defaultStoragePath = defaultStorageRoot

    public let storageRoot: String
    public var storagePath: String { storageRoot }

    private let fileSystem: LuaVirtualFileSystem
    private let lock = NSLock()

    public init(
        fileSystem: LuaVirtualFileSystem,
        storageRoot: String = GMLuaPresetStore.defaultStorageRoot
    ) {
        self.fileSystem = fileSystem
        self.storageRoot = storageRoot
    }

    public var hasStoredPresets: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let groups = try? fileSystem.listDirectory(at: storageRoot) else { return false }
        return groups.contains { group in
            guard group.isDirectory,
                  let files = try? fileSystem.listDirectory(at: storageRoot + "/" + group.name)
            else { return false }
            return files.contains { !$0.isDirectory && Self.parsePresetFilename($0.name) != nil }
        }
    }

    fileprivate func load(into state: LuaState) throws -> LuaTable {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(into: state)
    }

    fileprivate func replaceAndSave(_ partial: LuaTable, from state: LuaState) throws {
        lock.lock()
        defer { lock.unlock() }

        struct PendingGroup {
            let path: String
            let files: [(name: String, data: Data)]
        }

        var pending: [PendingGroup] = []
        for (groupKey, groupValue) in try state.rawTablePairs(in: partial) {
            guard case let .string(groupString) = groupKey else {
                throw GMLuaPresetPersistenceError.unsupportedValue(
                    "SavePresets: Group Key is a \(groupKey.typeName), string expected"
                )
            }
            let group = groupString.utf8String
            try Self.validateGroupName(group)
            guard case let .table(groupTable) = groupValue else {
                throw GMLuaPresetPersistenceError.unsupportedValue(
                    "SavePresets: Group Value is a \(groupValue.typeName), table expected"
                )
            }

            var encoded: [(displayName: String, data: Data)] = []
            for (nameKey, presetValue) in try state.rawTablePairs(in: groupTable) {
                guard case let .string(nameString) = nameKey else {
                    throw GMLuaPresetPersistenceError.unsupportedValue(
                        "SavePresets: Preset Key is a \(nameKey.typeName), string expected"
                    )
                }
                let displayName = nameString.utf8String
                guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GMLuaPresetPersistenceError.unsupportedValue(
                        "preset names must not be empty"
                    )
                }
                guard case let .table(values) = presetValue else {
                    throw GMLuaPresetPersistenceError.unsupportedValue(
                        "SavePresets: Preset value is a \(presetValue.typeName), table expected"
                    )
                }
                encoded.append((
                    displayName: displayName,
                    data: try GMLuaPresetKeyValuesCodec.encode(
                        displayName: displayName,
                        values: values,
                        state: state
                    )
                ))
            }
            // Native SavePresets numbers entries in Lua table traversal order.
            // rawTablePairs is this runtime's corresponding stable traversal.
            let files = encoded.enumerated().map { index, preset in
                (
                    name: "\(index + 1)-\(Self.filenameSlug(preset.displayName)).txt",
                    data: preset.data
                )
            }
            pending.append(PendingGroup(
                path: storageRoot + "/" + group,
                files: files
            ))
        }

        // Validate and encode all Lua data before mutating the VFS. Each group
        // is then updated by writing its new files before deleting stale names.
        for group in pending {
            let existing = ((try? fileSystem.listDirectory(at: group.path)) ?? [])
                .filter { !$0.isDirectory && Self.parsePresetFilename($0.name) != nil }
            let newNames = Set(group.files.map { $0.name.lowercased() })
            for file in group.files {
                try fileSystem.writeFile(file.data, at: group.path + "/" + file.name)
            }
            for oldFile in existing where !newNames.contains(oldFile.name.lowercased()) {
                try fileSystem.removeFile(at: group.path + "/" + oldFile.name)
            }
        }
    }

    private func loadUnlocked(into state: LuaState) throws -> LuaTable {
        let result = LuaTable()
        guard let entries = try? fileSystem.listDirectory(at: storageRoot) else { return result }

        for groupEntry in entries where groupEntry.isDirectory {
            let groupPath = storageRoot + "/" + groupEntry.name
            let groupTable = LuaTable()
            let listed = try fileSystem.listDirectory(at: groupPath)
            let files = listed.compactMap { entry -> (entry: LuaVirtualFileSystemEntry, order: Int)? in
                guard !entry.isDirectory, let parsed = Self.parsePresetFilename(entry.name) else {
                    return nil
                }
                return (entry, parsed.number)
            }.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                let foldedLHS = lhs.entry.name.lowercased()
                let foldedRHS = rhs.entry.name.lowercased()
                if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
                return lhs.entry.name < rhs.entry.name
            }

            for file in files {
                let path = groupPath + "/" + file.entry.name
                let document = try GMLuaPresetKeyValuesCodec.decode(
                    try fileSystem.readFile(at: path),
                    state: state,
                    sourceName: path
                )
                try state.setRawTableValue(
                    .table(document.values),
                    for: .string(LuaString(document.displayName)),
                    in: groupTable
                )
            }
            try state.setRawTableValue(
                .table(groupTable),
                for: .string(LuaString(groupEntry.name)),
                in: result
            )
        }
        return result
    }

    private static func validateGroupName(_ name: String) throws {
        let invalidFilenameCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")
        let windowsStem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        let reservedWindowsStems: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ]
        guard !name.isEmpty, name != ".", name != "..",
              name.rangeOfCharacter(from: invalidFilenameCharacters) == nil,
              !name.hasSuffix("."), !name.hasSuffix(" "),
              !reservedWindowsStems.contains(windowsStem.uppercased()),
              name.caseInsensitiveCompare(".garrys-pad-vfs-whiteouts") != .orderedSame,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw GMLuaPresetPersistenceError.unsupportedValue(
                "unsafe preset group name \(String(reflecting: name))"
            )
        }
    }

    /// Mirrors the ASCII transform in the current desktop client: lowercase
    /// A-Z, then replace its explicit unsafe-character set with underscores.
    /// Bytes above ASCII are left unchanged by the desktop loop, so Unicode
    /// scalars are preserved here rather than applying locale-aware lowercase.
    private static func filenameSlug(_ displayName: String) -> String {
        let replacedASCII = Set<UInt32>([
            9, 10, 33, 34, 35, 37, 38, 39, 42, 46, 47, 58,
            60, 62, 63, 64, 92, 96, 123, 125,
        ])
        var result = ""
        for scalar in displayName.unicodeScalars {
            if replacedASCII.contains(scalar.value) {
                result.append("_")
            } else if (65...90).contains(scalar.value),
                      let lowered = UnicodeScalar(scalar.value + 32) {
                result.unicodeScalars.append(lowered)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func parsePresetFilename(_ filename: String) -> (number: Int, slug: String)? {
        guard filename.lowercased().hasSuffix(".txt") else { return nil }
        let stem = String(filename.dropLast(4))
        guard let separator = stem.firstIndex(of: "-") else { return nil }
        let numberText = stem[..<separator]
        let slug = String(stem[stem.index(after: separator)...])
        guard !numberText.isEmpty, numberText.allSatisfy({ $0.isNumber }),
              let number = Int(numberText), number > 0, !slug.isEmpty else { return nil }
        return (number, slug)
    }
}

/// Installs the two native functions consumed by
/// `lua/includes/modules/presets.lua` in client-capable realms.
public enum GMLuaPresets {
    @discardableResult
    public static func install(
        into state: LuaState,
        fileSystem: LuaVirtualFileSystem
    ) -> GMLuaPresetStore {
        let store = GMLuaPresetStore(fileSystem: fileSystem)

        let load = LuaNativeFunctionBox(
            { [weak state, store] _ in
                guard let state else { throw LuaError.runtime("Lua state is unavailable") }
                do {
                    return [.table(try store.load(into: state))]
                } catch let error as LuaError {
                    throw error
                } catch {
                    throw LuaError.runtime("LoadPresets failed: \(String(describing: error))")
                }
            },
            debugName: "LoadPresets"
        )
        state.setGlobal("LoadPresets", value: .nativeFunction(load))

        let save = LuaNativeFunctionBox(
            { [weak state, store] arguments in
                guard let state else { throw LuaError.runtime("Lua state is unavailable") }
                guard let first = arguments.first else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'SavePresets' (table expected, got no value)"
                    )
                }
                guard case let .table(partial) = first else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'SavePresets' " +
                        "(table expected, got \(first.typeName))"
                    )
                }
                do {
                    try store.replaceAndSave(partial, from: state)
                    return []
                } catch let error as LuaError {
                    throw error
                } catch {
                    throw LuaError.runtime("SavePresets failed: \(String(describing: error))")
                }
            },
            debugName: "SavePresets"
        )
        state.setGlobal("SavePresets", value: .nativeFunction(save))
        return store
    }
}

private enum GMLuaPresetKeyValuesCodec {
    private static let maximumBytes = 16 * 1_024 * 1_024
    private static let maximumEntries = 100_000

    struct Document {
        let displayName: String
        let values: LuaTable
    }

    static func decode(_ data: Data, state: LuaState, sourceName: String) throws -> Document {
        guard data.count <= maximumBytes else {
            throw GMLuaPresetPersistenceError.invalidData("\(sourceName) is too large")
        }
        guard let source = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .windowsCP1252) else {
            throw GMLuaPresetPersistenceError.invalidData("\(sourceName) is not text")
        }
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(usesEscapeSequences: true, preserveKeyCase: true)
        )
        let roots = try parser.parse()
        guard roots.count == 1, case let .object(children) = roots[0].value else {
            throw GMLuaPresetPersistenceError.invalidData(
                "\(sourceName) must contain one named KeyValues object"
            )
        }
        return Document(
            displayName: roots[0].key,
            values: try makeTable(children, state: state, sourceName: sourceName)
        )
    }

    static func encode(displayName: String, values: LuaTable, state: LuaState) throws -> Data {
        let body = try encodeTable(values, state: state)
        let source = "\"\(escape(displayName))\"\n{\n\(body)}\n"
        let data = Data(source.utf8)
        guard data.count <= maximumBytes else {
            throw GMLuaPresetPersistenceError.unsupportedValue(
                "encoded preset exceeds \(maximumBytes) bytes"
            )
        }
        return data
    }

    private static func makeTable(
        _ entries: [SourceKeyValuesParser.Entry],
        state: LuaState,
        sourceName: String
    ) throws -> LuaTable {
        guard entries.count <= maximumEntries else {
            throw GMLuaPresetPersistenceError.invalidData("\(sourceName) has too many entries")
        }
        let table = LuaTable()
        for entry in entries {
            guard case let .string(string) = entry.value else {
                throw GMLuaPresetPersistenceError.invalidData(
                    "\(sourceName) contains a non-string preset value"
                )
            }
            try state.setRawTableValue(
                .string(LuaString(string)),
                for: .string(LuaString(entry.key)),
                in: table
            )
        }
        return table
    }

    private static func encodeTable(
        _ table: LuaTable,
        state: LuaState
    ) throws -> String {
        let pairs = try state.rawTablePairs(in: table)
        guard pairs.count <= maximumEntries else {
            throw GMLuaPresetPersistenceError.unsupportedValue(
                "table exceeds \(maximumEntries) entries"
            )
        }
        var entries: [(key: String, value: LuaValue)] = []
        for (key, value) in pairs {
            guard case let .string(string) = key else {
                throw GMLuaPresetPersistenceError.unsupportedValue(
                    "SavePresets: Preset keyvalue key is a \(key.typeName), string expected"
                )
            }
            guard case .string = value else {
                throw GMLuaPresetPersistenceError.unsupportedValue(
                    "SavePresets: Preset keyvalue value is a \(value.typeName), string expected"
                )
            }
            entries.append((string.utf8String, value))
        }
        entries.sort { lhs, rhs in
            let foldedLHS = lhs.key.lowercased()
            let foldedRHS = rhs.key.lowercased()
            if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
            return lhs.key < rhs.key
        }

        let indent = "\t"
        var output = ""
        for entry in entries {
            switch entry.value {
            case let .string(string):
                output += "\(indent)\"\(escape(entry.key))\"\t\t\"\(escape(string.utf8String))\"\n"
            case .nilValue, .boolean, .number, .table, .luaFunction, .nativeFunction, .userdata, .thread:
                preconditionFailure("preset value type was validated before encoding")
            }
        }
        return output
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        for character in string {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }
}

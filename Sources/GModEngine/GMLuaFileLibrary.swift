import Foundation
import GModLua

/// Native GLua `file` library boundary backed exclusively by the mounted VFS.
///
/// Search-path translation lives here instead of in Lua so `GAME`, `DATA`, and
/// the realm-selected `LUA` namespace cannot escape into host paths. The LUA
/// namespace covers both the ordinary `lua/` tree and the canonical
/// `gamemodes/<name>/gamemode/` projection used by real gamemode code.
public enum GMLuaFileLibrary {
    private enum SearchPath {
        case game
        case lua
        case data
        case download

        init?(_ rawValue: String) {
            switch rawValue.uppercased() {
            case "GAME", "MOD", "GARRYSMOD", "THIRDPARTY": self = .game
            case "LUA", "LCL", "LSV", "LUAMENU": self = .lua
            case "DATA": self = .data
            case "DOWNLOAD": self = .download
            default: return nil
            }
        }
    }

    private static let writableExtensions: Set<String> = [
        "txt", "dat", "json", "xml", "csv", "dem", "vcd", "gma",
        "mdl", "phy", "vvd", "vtx", "ani", "vtf", "vmt", "png",
        "jpg", "jpeg", "mp3", "wav", "ogg"
    ]

    public static func install(
        into state: LuaState,
        fileSystem: LuaVirtualFileSystem,
        realm: GMLuaRealm
    ) throws {
        let fileTable: LuaTable
        if case let .table(existing) = state.getGlobal("file") {
            fileTable = existing
        } else {
            fileTable = LuaTable()
            state.setGlobal("file", value: .table(fileTable))
        }

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) throws {
            let value = LuaValue.nativeFunction(
                LuaNativeFunctionBox(body, debugName: "file.\(name)")
            )
            try state.setRawTableValue(
                value,
                for: .string(LuaString(name)),
                in: fileTable
            )
        }

        // `file.Open` remains the File-userdata implementation from the Lua
        // bootstrap, but its path decision crosses this native boundary.
        state.setGlobal(
            "__gmod_file_ResolvePath",
            value: .nativeFunction(LuaNativeFunctionBox({ arguments in
                guard let name = stringArgument(arguments, index: 0) else {
                    throw badArgument(1, function: "Open", expected: "string", arguments: arguments)
                }
                let mode = stringArgument(arguments, index: 2) ?? "rb"
                let pathID = stringArgument(arguments, index: 1) ?? "DATA"
                let writing = mode.contains("w") || mode.contains("a") || mode.contains("+")
                guard let resolved = resolveExact(
                    name,
                    pathID: pathID,
                    writing: writing,
                    fileSystem: fileSystem
                ) else {
                    return [.nilValue]
                }
                return [.string(LuaString(resolved))]
            }, debugName: "file.Open path resolver"))
        )

        try native("Find") { [weak state] arguments in
            guard let state else { throw LuaError.runtime("Lua state is unavailable") }
            guard let wildcardPath = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Find", expected: "string", arguments: arguments)
            }
            guard let pathID = stringArgument(arguments, index: 1) else {
                throw badArgument(2, function: "Find", expected: "string", arguments: arguments)
            }
            let sorting = stringArgument(arguments, index: 2)?.lowercased() ?? "nameasc"
            guard let request = try? splitFindRequest(wildcardPath),
                  let candidates = try? candidatePaths(
                    request.directory,
                    pathID: pathID,
                    allowEmpty: true
                  ) else {
                return [.nilValue, .nilValue]
            }

            var visible: [String: LuaVirtualFileSystemEntry] = [:]
            var foundDirectory = false
            for candidate in candidates {
                guard let entries = try? fileSystem.listDirectory(at: candidate) else { continue }
                foundDirectory = true
                for entry in entries where globMatches(request.pattern, entry.name) {
                    let folded = entry.name.lowercased()
                    if visible[folded] == nil { visible[folded] = entry }
                }
            }
            guard foundDirectory else { return [.nilValue, .nilValue] }

            // The VFS does not expose timestamps yet. Keep date modes stable
            // through the same name fallback, but do not claim date-order
            // compatibility until per-entry modification times are available.
            let descending = sorting == "namedesc" || sorting == "datedesc"
            let ordered = visible.values.sorted { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                if left != right { return descending ? left > right : left < right }
                return descending ? lhs.name > rhs.name : lhs.name < rhs.name
            }
            let files = ordered.filter { !$0.isDirectory }.map(\.name)
            let directories = ordered.filter(\.isDirectory).map(\.name)
            return [
                .table(try makeArray(files, state: state)),
                .table(try makeArray(directories, state: state))
            ]
        }

        try native("Exists") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Exists", expected: "string", arguments: arguments)
            }
            guard let pathID = stringArgument(arguments, index: 1) else {
                throw badArgument(2, function: "Exists", expected: "string", arguments: arguments)
            }
            let paths = (try? candidatePaths(name, pathID: pathID, allowEmpty: true)) ?? []
            let exists = paths.contains {
                fileSystem.fileExists(at: $0) || fileSystem.directoryExists(at: $0)
            }
            return [.boolean(exists)]
        }

        try native("IsDir") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "IsDir", expected: "string", arguments: arguments)
            }
            guard let pathID = stringArgument(arguments, index: 1) else {
                throw badArgument(2, function: "IsDir", expected: "string", arguments: arguments)
            }
            let paths = (try? candidatePaths(name, pathID: pathID, allowEmpty: true)) ?? []
            return [.boolean(paths.contains { fileSystem.directoryExists(at: $0) })]
        }

        try native("Read") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Read", expected: "string", arguments: arguments)
            }
            let pathID: String
            if arguments.count < 2 {
                pathID = "DATA"
            } else {
                switch arguments[1] {
                case .nilValue, .boolean(false): pathID = "DATA"
                case .boolean(true): pathID = "GAME"
                case let .string(value): pathID = value.utf8String
                default:
                    throw badArgument(2, function: "Read", expected: "string", arguments: arguments)
                }
            }
            guard let path = resolveExistingFile(name, pathID: pathID, fileSystem: fileSystem),
                  let contents = try? fileSystem.readFile(at: path) else {
                return [.nilValue]
            }
            return [.string(LuaString(bytes: Array(contents)))]
        }

        try native("Write") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Write", expected: "string", arguments: arguments)
            }
            guard case let .string(contents)? = arguments[safe: 1] else {
                throw badArgument(2, function: "Write", expected: "string", arguments: arguments)
            }
            guard let path = writableDataPath(name) else { return [.boolean(false)] }
            do {
                try fileSystem.writeFile(Data(contents.bytes), at: path)
                return [.boolean(true)]
            } catch {
                return [.boolean(false)]
            }
        }

        try native("Append") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Append", expected: "string", arguments: arguments)
            }
            guard case let .string(contents)? = arguments[safe: 1] else {
                throw badArgument(2, function: "Append", expected: "string", arguments: arguments)
            }
            guard let path = writableDataPath(name) else { return [.boolean(false)] }
            do {
                var data = fileSystem.fileExists(at: path)
                    ? try fileSystem.readFile(at: path)
                    : Data()
                data.append(contentsOf: contents.bytes)
                try fileSystem.writeFile(data, at: path)
                return [.boolean(true)]
            } catch {
                return [.boolean(false)]
            }
        }

        try native("CreateDir") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "CreateDir", expected: "string", arguments: arguments)
            }
            guard let path = writableDirectoryPath(name) else { return [] }
            try? fileSystem.createDirectory(at: path)
            return []
        }

        try native("Delete") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Delete", expected: "string", arguments: arguments)
            }
            let requestedPathID = stringArgument(arguments, index: 1) ?? "DATA"
            if realm != .menu && requestedPathID.uppercased() != "DATA" {
                return [.boolean(false)]
            }
            guard let path = resolveDeletable(
                name,
                pathID: requestedPathID,
                realm: realm,
                fileSystem: fileSystem
            ) else {
                return [.boolean(false)]
            }
            do {
                if fileSystem.fileExists(at: path) {
                    try fileSystem.removeFile(at: path)
                } else if fileSystem.directoryExists(at: path) {
                    try fileSystem.removeDirectory(at: path)
                } else {
                    return [.boolean(false)]
                }
                return [.boolean(true)]
            } catch {
                return [.boolean(false)]
            }
        }

        try native("Rename") { arguments in
            guard let sourceName = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Rename", expected: "string", arguments: arguments)
            }
            guard let destinationName = stringArgument(arguments, index: 1) else {
                throw badArgument(2, function: "Rename", expected: "string", arguments: arguments)
            }
            guard let source = writableDataItemPath(sourceName),
                  let destination = writableDataItemPath(destinationName) else {
                return [.boolean(false)]
            }
            do {
                if fileSystem.fileExists(at: source) {
                    guard isAllowedWritableFile(destinationName) else {
                        return [.boolean(false)]
                    }
                    try fileSystem.moveFile(from: source, to: destination)
                } else if fileSystem.directoryExists(at: source) {
                    try fileSystem.moveDirectory(from: source, to: destination)
                } else {
                    return [.boolean(false)]
                }
                return [.boolean(true)]
            } catch {
                return [.boolean(false)]
            }
        }

        try native("Size") { arguments in
            guard let name = stringArgument(arguments, index: 0) else {
                throw badArgument(1, function: "Size", expected: "string", arguments: arguments)
            }
            guard let pathID = stringArgument(arguments, index: 1) else {
                throw badArgument(2, function: "Size", expected: "string", arguments: arguments)
            }
            guard let path = resolveExistingFile(name, pathID: pathID, fileSystem: fileSystem),
                  let data = try? fileSystem.readFile(at: path) else {
                return [.number(-1)]
            }
            return [.number(Double(data.count))]
        }
    }

    private static func resolveExact(
        _ name: String,
        pathID: String,
        writing: Bool,
        fileSystem: LuaVirtualFileSystem
    ) -> String? {
        if writing { return pathID.uppercased() == "DATA" ? writableDataPath(name) : nil }
        return resolveExistingFile(name, pathID: pathID, fileSystem: fileSystem)
            ?? (try? candidatePaths(name, pathID: pathID, allowEmpty: false).first)
    }

    private static func resolveExistingFile(
        _ name: String,
        pathID: String,
        fileSystem: LuaVirtualFileSystem
    ) -> String? {
        guard let candidates = try? candidatePaths(name, pathID: pathID, allowEmpty: false) else {
            return nil
        }
        return candidates.first { fileSystem.fileExists(at: $0) }
    }

    private static func resolveDeletable(
        _ name: String,
        pathID: String,
        realm: GMLuaRealm,
        fileSystem: LuaVirtualFileSystem
    ) -> String? {
        if pathID.uppercased() == "DATA" { return writableDataItemPath(name) }
        guard realm == .menu,
              let candidates = try? candidatePaths(name, pathID: pathID, allowEmpty: false) else {
            return nil
        }
        return candidates.first {
            fileSystem.fileExists(at: $0) || fileSystem.directoryExists(at: $0)
        }
    }

    private static func candidatePaths(
        _ name: String,
        pathID: String,
        allowEmpty: Bool
    ) throws -> [String] {
        guard let searchPath = SearchPath(pathID) else {
            throw GMLuaFileSystemError.invalidPath(pathID)
        }
        let normalized = try GMLuaMountedFileSystem.normalize(name, allowEmpty: allowEmpty)
        switch searchPath {
        case .game:
            return [normalized]
        case .data:
            return [normalized.isEmpty ? "data" : "data/" + normalized]
        case .download:
            return [normalized.isEmpty ? "download" : "download/" + normalized]
        case .lua:
            if normalized == "lua" || normalized.hasPrefix("lua/")
                || normalized == "gamemodes" || normalized.hasPrefix("gamemodes/") {
                return [normalized]
            }
            let components = normalized.split(separator: "/")
            if components.count >= 2,
               String(components[1]).caseInsensitiveCompare("gamemode") == .orderedSame {
                return ["gamemodes/" + normalized, "lua/" + normalized]
            }
            if normalized.isEmpty { return ["lua", "gamemodes"] }
            return ["lua/" + normalized, "gamemodes/" + normalized]
        }
    }

    private static func writableDataPath(_ name: String) -> String? {
        guard isAllowedWritableFile(name) else { return nil }
        return writableDataItemPath(name)
    }

    private static func writableDirectoryPath(_ name: String) -> String? {
        guard isAllowedWritablePath(name, requireExtension: false) else { return nil }
        return writableDataItemPath(name)
    }

    private static func writableDataItemPath(_ name: String) -> String? {
        guard isAllowedWritablePath(name, requireExtension: false),
              let normalized = try? GMLuaMountedFileSystem.normalize(name.lowercased(), allowEmpty: false) else {
            return nil
        }
        return "data/" + normalized
    }

    private static func isAllowedWritableFile(_ name: String) -> Bool {
        guard isAllowedWritablePath(name, requireExtension: true) else { return false }
        let last = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? ""
        guard let dot = last.lastIndex(of: "."), dot < last.index(before: last.endIndex) else {
            return false
        }
        return writableExtensions.contains(String(last[last.index(after: dot)...]).lowercased())
    }

    private static func isAllowedWritablePath(
        _ name: String,
        requireExtension: Bool
    ) -> Bool {
        guard !name.isEmpty,
              !name.contains("  "),
              !name.contains(":"),
              !name.hasPrefix("/"),
              !name.hasPrefix("\\") else { return false }
        let punctuation = Set("_-. /\\".unicodeScalars.map(\.value))
        guard name.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || punctuation.contains(value)
        }) else { return false }
        guard (try? GMLuaMountedFileSystem.normalize(name, allowEmpty: false)) != nil else {
            return false
        }
        return !requireExtension || name.contains(".")
    }

    private static func splitFindRequest(_ raw: String) throws -> (directory: String, pattern: String) {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.isEmpty else {
            throw GMLuaFileSystemError.invalidPath(raw)
        }
        let directory: String
        let pattern: String
        if let slash = path.lastIndex(of: "/") {
            directory = String(path[..<slash])
            pattern = String(path[path.index(after: slash)...])
        } else {
            directory = ""
            pattern = path
        }
        guard !pattern.isEmpty,
              !directory.split(separator: "/").contains(where: { $0.contains("*") || $0.contains("?") }) else {
            throw GMLuaFileSystemError.invalidPath(raw)
        }
        if !directory.isEmpty {
            _ = try GMLuaMountedFileSystem.normalize(directory, allowEmpty: true)
        }
        return (directory, pattern)
    }

    /// Source's filesystem wildcard accepts `*` and `?` in the final path
    /// component. Matching is case-insensitive to preserve desktop GMod's
    /// mounted-content behavior on iPad's case-sensitive filesystem.
    private static func globMatches(_ pattern: String, _ value: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let value = Array(value.lowercased())
        var previous = Array(repeating: false, count: value.count + 1)
        previous[0] = true
        for token in pattern {
            var current = Array(repeating: false, count: value.count + 1)
            if token == "*" { current[0] = previous[0] }
            if !value.isEmpty {
                for index in 1...value.count {
                    if token == "*" {
                        current[index] = previous[index] || current[index - 1]
                    } else if token == "?" || token == value[index - 1] {
                        current[index] = previous[index - 1]
                    }
                }
            }
            previous = current
        }
        return previous[value.count]
    }

    private static func makeArray(_ values: [String], state: LuaState) throws -> LuaTable {
        let table = LuaTable()
        for (offset, value) in values.enumerated() {
            try state.setRawTableValue(
                .string(LuaString(value)),
                for: .number(Double(offset + 1)),
                in: table
            )
        }
        return table
    }

    private static func stringArgument(_ arguments: [LuaValue], index: Int) -> String? {
        guard case let .string(value)? = arguments[safe: index] else { return nil }
        return value.utf8String
    }

    private static func badArgument(
        _ position: Int,
        function: String,
        expected: String,
        arguments: [LuaValue]
    ) -> LuaError {
        let actual = arguments.indices.contains(position - 1)
            ? arguments[position - 1].typeName
            : "no value"
        return .runtime(
            "bad argument #\(position) to '\(function)' (\(expected) expected, got \(actual))"
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

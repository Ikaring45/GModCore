import Foundation
import GModLua

/// Native client ABI captured by `lua/includes/modules/spawnmenu.lua` before
/// that module replaces the global `spawnmenu` table with its Lua library.
public enum GMLuaSpawnMenuEngine {
    private static let directory = "settings/spawnlist"

    public static func install(
        into state: LuaState,
        fileSystem: LuaVirtualFileSystem
    ) throws {
        let engineTable: LuaTable
        if case let .table(existing) = state.getGlobal("spawnmenu") {
            engineTable = existing
        } else {
            engineTable = LuaTable()
        }

        let populate = LuaNativeFunctionBox(
            { [weak state, fileSystem] arguments in
                guard let state else { throw LuaError.runtime("Lua state is unavailable") }
                guard let callback = arguments.first,
                      callback.typeName == "function" else {
                    let actual = arguments.first?.typeName ?? "no value"
                    throw LuaError.runtime(
                        "bad argument #1 to 'PopulateFromTextFiles' " +
                            "(function expected, got \(actual))"
                    )
                }

                guard fileSystem.directoryExists(at: directory) else { return [] }
                let entries: [LuaVirtualFileSystemEntry]
                do {
                    entries = try fileSystem.listDirectory(at: directory)
                } catch {
                    throw LuaError.runtime(
                        "spawnmenu.PopulateFromTextFiles failed to enumerate \(directory): " +
                            String(describing: error)
                    )
                }

                for entry in entries where !entry.isDirectory &&
                    entry.name.lowercased().hasSuffix(".txt") {
                    let path = directory + "/" + entry.name
                    let document: SpawnListDocument
                    do {
                        document = try decodeSpawnList(
                            try fileSystem.readFile(at: path),
                            state: state,
                            sourceName: path
                        )
                    } catch let error as LuaError {
                        throw error
                    } catch {
                        throw LuaError.runtime(
                            "spawnmenu.PopulateFromTextFiles failed for \(path): " +
                                String(describing: error)
                        )
                    }

                    _ = try state.call(callback, arguments: [
                        .string(LuaString(entry.name)),
                        .string(LuaString(document.name)),
                        .table(document.contents),
                        .string(LuaString(document.icon)),
                        .number(document.identifier),
                        .number(document.parentIdentifier),
                        .string(LuaString(document.requiredApp))
                    ])
                }
                return []
            },
            debugName: "spawnmenu.PopulateFromTextFiles"
        )
        try state.setRawTableValue(
            .nativeFunction(populate),
            for: .string("PopulateFromTextFiles"),
            in: engineTable
        )

        let save = LuaNativeFunctionBox(
            { arguments in
                guard let first = arguments.first, case .table = first else {
                    let actual = arguments.first?.typeName ?? "no value"
                    throw LuaError.runtime(
                        "bad argument #1 to 'SaveToTextFiles' " +
                            "(table expected, got \(actual))"
                    )
                }
                // A spawnlist save replaces a directory worth of files. The
                // generic VFS protocol cannot promise an atomic replacement,
                // so do not claim success or partially overwrite user data.
                throw LuaError.runtime(
                    "spawnmenu.SaveToTextFiles is unavailable: " +
                        "no atomic writable spawnlist store is connected"
                )
            },
            debugName: "spawnmenu.SaveToTextFiles"
        )
        try state.setRawTableValue(
            .nativeFunction(save),
            for: .string("SaveToTextFiles"),
            in: engineTable
        )
        state.setGlobal("spawnmenu", value: .table(engineTable))
    }

    private struct SpawnListDocument {
        let name: String
        let contents: LuaTable
        let icon: String
        let identifier: Double
        let parentIdentifier: Double
        let requiredApp: String
    }

    private static func decodeSpawnList(
        _ data: Data,
        state: LuaState,
        sourceName: String
    ) throws -> SpawnListDocument {
        guard let source = LuaSourceDecoder.decode(data) else {
            throw LuaError.runtime("\(sourceName) is not decodable text")
        }
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(usesEscapeSequences: true, preserveKeyCase: false)
        )
        let roots: [SourceKeyValuesParser.Entry]
        do {
            roots = try parser.parse()
        } catch {
            throw LuaError.runtime("\(sourceName): \(String(describing: error))")
        }
        guard roots.count == 1,
              roots[0].key.caseInsensitiveCompare("TableToKeyValues") == .orderedSame,
              case let .object(entries) = roots[0].value else {
            throw LuaError.runtime(
                "\(sourceName) must contain one TableToKeyValues object"
            )
        }

        let name = try requiredString("name", in: entries, sourceName: sourceName)
        let identifier = try requiredNumber("id", in: entries, sourceName: sourceName)
        let parentIdentifier = try optionalNumber(
            "parentid",
            in: entries,
            defaultValue: 0,
            sourceName: sourceName
        )
        let icon = try optionalString(
            "icon",
            in: entries,
            defaultValue: "icon16/page.png",
            sourceName: sourceName
        )
        let requiredApp = try optionalString(
            "needsapp",
            in: entries,
            defaultValue: "",
            sourceName: sourceName
        )
        let contents: LuaTable
        if let value = lastValue(named: "contents", in: entries) {
            guard case let .object(children) = value else {
                throw LuaError.runtime("\(sourceName): contents must be an object")
            }
            contents = try makeLuaTable(from: children, state: state)
        } else {
            contents = LuaTable()
        }

        return SpawnListDocument(
            name: name,
            contents: contents,
            icon: icon,
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            requiredApp: requiredApp
        )
    }

    private static func makeLuaTable(
        from entries: [SourceKeyValuesParser.Entry],
        state: LuaState
    ) throws -> LuaTable {
        let table = LuaTable()
        for entry in entries {
            let key: LuaValue
            if let numeric = Double(entry.key), numeric.isFinite {
                key = .number(numeric)
            } else {
                key = .string(LuaString(entry.key))
            }
            let value: LuaValue
            switch entry.value {
            case let .string(string):
                value = .string(LuaString(string))
            case let .object(children):
                value = .table(try makeLuaTable(from: children, state: state))
            }
            try state.setRawTableValue(value, for: key, in: table)
        }
        return table
    }

    private static func lastValue(
        named name: String,
        in entries: [SourceKeyValuesParser.Entry]
    ) -> SourceKeyValuesParser.Value? {
        entries.last(where: {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        })?.value
    }

    private static func requiredString(
        _ name: String,
        in entries: [SourceKeyValuesParser.Entry],
        sourceName: String
    ) throws -> String {
        guard let value = lastValue(named: name, in: entries),
              case let .string(string) = value else {
            throw LuaError.runtime("\(sourceName): missing string field '\(name)'")
        }
        return string
    }

    private static func optionalString(
        _ name: String,
        in entries: [SourceKeyValuesParser.Entry],
        defaultValue: String,
        sourceName: String
    ) throws -> String {
        guard let value = lastValue(named: name, in: entries) else { return defaultValue }
        guard case let .string(string) = value else {
            throw LuaError.runtime("\(sourceName): field '\(name)' must be a string")
        }
        return string
    }

    private static func requiredNumber(
        _ name: String,
        in entries: [SourceKeyValuesParser.Entry],
        sourceName: String
    ) throws -> Double {
        guard let value = lastValue(named: name, in: entries),
              case let .string(string) = value,
              let number = Double(string), number.isFinite else {
            throw LuaError.runtime("\(sourceName): missing numeric field '\(name)'")
        }
        return number
    }

    private static func optionalNumber(
        _ name: String,
        in entries: [SourceKeyValuesParser.Entry],
        defaultValue: Double,
        sourceName: String
    ) throws -> Double {
        guard let value = lastValue(named: name, in: entries) else { return defaultValue }
        guard case let .string(string) = value,
              let number = Double(string), number.isFinite else {
            throw LuaError.runtime("\(sourceName): field '\(name)' must be numeric")
        }
        return number
    }
}

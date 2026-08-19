import Foundation
import GModEngine
import GModLua

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum GModLuaConformanceMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--keyvalues-file", arguments.count == 2 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                guard let source = GMLuaRuntime.decodeSource(data) else {
                    throw ConformanceCLIError.cannotDecode(arguments[1])
                }
                var parser = SourceKeyValuesParser(
                    source: source,
                    options: .init(
                        usesEscapeSequences: false,
                        preserveKeyCase: false,
                        preserveConditionals: true
                    )
                )
                let entries = try parser.parse()
                print("[PASS][KEYVALUES] roots=\(entries.count) bytes=\(data.count)")
            } catch {
                print("[FAIL][KEYVALUES] \(error)")
                terminate(1)
            }
            return
        }

        if arguments == ["--gmod-bootstrap-selftest"] {
            do {
                let caseFixtureRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GarrysPAD-CaseFixture-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: caseFixtureRoot) }
                let caseFixtureDirectory = caseFixtureRoot
                    .appendingPathComponent("lua", isDirectory: true)
                    .appendingPathComponent("includes", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: caseFixtureDirectory,
                    withIntermediateDirectories: true
                )
                let caseFixtureBytes = Data("return 'case-fallback'".utf8)
                try caseFixtureBytes.write(
                    to: caseFixtureDirectory.appendingPathComponent("IconEditor.lua")
                )
                let caseFixture = try GMLuaHostDirectoryFileSystem(
                    rootURL: caseFixtureRoot,
                    writable: false
                )
                guard caseFixture.fileExists(at: "LUA/INCLUDES/iconeditor.lua"),
                      try caseFixture.readFile(at: "lua/includes/ICONEDITOR.LUA") == caseFixtureBytes else {
                    throw ConformanceCLIError.caseInsensitiveMountMismatch
                }

                let base = try LuaMemoryFileSystem(initialFiles: [
                    "lua/includes/init.lua": Data(#"""
                    assert(SERVER and not CLIENT and not MENU)
                    local nested = include("nested/a.lua")
                    AddCSLuaFile("client.lua")
                    local fixture = require("fixture")
                    assert(nested == 42 and fixture.value == 77)
                    assert(type(bit) == "table")
                    assert(require("bit") == bit and package.loaded.bit == bit)
                    assert(bit.band(0xff, 0x3c) == 0x3c)
                    assert(bit.bor(1, 2, 4) == 7)
                    assert(bit.bxor(0xff, 0x0f) == 0xf0)
                    assert(bit.bnot(0) == -1)
                    assert(bit.lshift(1, 31) == -2147483648)
                    assert(bit.rshift(-1, 31) == 1)
                    assert(bit.arshift(-2, 1) == -1)
                    assert(bit.tohex(0x12ab, -8) == "000012AB")
                    """#.utf8),
                    "lua/includes/nested/a.lua": Data("return include(\"b.lua\")".utf8),
                    "lua/includes/nested/b.lua": Data("return 42".utf8),
                    "lua/includes/client.lua": Data("return true".utf8),
                    "lua/includes/modules/fixture.lua": Data("return { value = 77 }".utf8)
                ])
                let overlay = try LuaMemoryFileSystem()
                let mounted = GMLuaMountedFileSystem(mounts: [
                    try GMLuaFileMount(
                        name: "writable",
                        priority: 100,
                        writable: true,
                        fileSystem: overlay
                    ),
                    try GMLuaFileMount(
                        name: "fixtures",
                        priority: 0,
                        writable: false,
                        fileSystem: base
                    )
                ])
                let runtime = GMLuaRuntime(
                    realm: .server,
                    logger: { print($0) },
                    virtualFileSystem: mounted
                )
                try runtime.loadFile("lua/includes/init.lua")
                try runtime.execute(
                    #"""
                    local parsed = util.KeyValuesToTable([==[
                    // leading comment
                    "Root"
                    {
                        "MixedCase" "first"
                        mixedcase "last"
                        bareKey bareValue
                        "7" "numeric-key"
                        "escaped" "line\nquote\"slash\\"
                        "nested" { "Child" "yes" }
                    }
                    ]==], true, false)
                    assert(parsed.mixedcase == "last")
                    assert(parsed.barekey == "bareValue")
                    assert(parsed[7] == "numeric-key")
                    assert(parsed.escaped == "line\nquote\"slash\\")
                    assert(parsed.nested.child == "yes")

                    local preserved = util.KeyValuesToTable('"Root" { "MixedCase" "ok" }', false, true)
                    assert(preserved.MixedCase == "ok" and preserved.mixedcase == nil)

                    local ordered = util.KeyValuesToTablePreserveOrder(
                        '"Root" { "Same" "one" "Same" "two" [$WIN32] }',
                        false,
                        true
                    )
                    assert(#ordered == 2)
                    assert(ordered[1].Key == "Same" and ordered[1].Value == "one")
                    assert(ordered[2].Key == "Same" and ordered[2].Value == "two")
                    assert(ordered[2].Conditional == "$WIN32")
                    """#,
                    sourceName: "=(Source KeyValues V1 selftest)"
                )
                guard runtime.includedFiles == [
                    "lua/includes/nested/a.lua",
                    "lua/includes/nested/b.lua"
                ], runtime.clientLuaFiles == ["lua/includes/client.lua"] else {
                    throw ConformanceCLIError.bootstrapObservationMismatch
                }

                for realm in [GMLuaRealm.client, .menu] {
                    let check = GMLuaRuntime(realm: realm, logger: { _ in })
                    try check.execute(
                        realm == .client
                            ? "assert(CLIENT and not SERVER and not MENU and not MENU_DLL)"
                            : "assert(MENU and MENU_DLL and CLIENT and not SERVER)"
                    )
                }
                print("[PASS][GLUA-M1] realms, nested include/AddCSLuaFile, GMod require+bit, Source KeyValues V1, and case-folded mounts")
            } catch {
                print("[FAIL][GLUA-M1] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--gmod-file", (3...5).contains(arguments.count) {
            var runtime: GMLuaRuntime?
            do {
                let rootURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
                let logicalPath = arguments[2].replacingOccurrences(of: "\\", with: "/")
                let realm: GMLuaRealm
                switch arguments.count >= 4 ? arguments[3].lowercased() : "server" {
                case "server": realm = .server
                case "client": realm = .client
                case "menu": realm = .menu
                default: throw ConformanceCLIError.invalidRealm(arguments[3])
                }
                let bootstrapMode: GMLuaBootstrapMode
                switch arguments.count == 5 ? arguments[4].lowercased() : "strict" {
                case "strict": bootstrapMode = .strict
                case "discovery": bootstrapMode = .discovery
                default: throw ConformanceCLIError.invalidBootstrapMode(arguments[4])
                }

                let install = try GMLuaHostDirectoryFileSystem(rootURL: rootURL, writable: false)
                let writable = try LuaMemoryFileSystem()
                let mounted = GMLuaMountedFileSystem(mounts: [
                    try GMLuaFileMount(
                        name: "runtime-data",
                        priority: 1_000,
                        writable: true,
                        fileSystem: writable
                    ),
                    try GMLuaFileMount(
                        name: "garrysmod",
                        priority: 0,
                        writable: false,
                        fileSystem: install
                    )
                ])
                let created = GMLuaRuntime(
                    realm: realm,
                    logger: { print($0) },
                    virtualFileSystem: mounted,
                    bootstrapMode: bootstrapMode
                )
                runtime = created
                try created.loadFile(logicalPath)
                print("[GLUA][M1] realm=\(realm.rawValue) mode=\(bootstrapMode.rawValue) includes=\(created.includedFiles.count) clientFiles=\(created.clientLuaFiles.count) commands=\(created.consoleCommands.count) compatibilityGaps=\(created.compatibilityGaps.count)")
                for gap in created.compatibilityGaps {
                    print("[GLUA][GAP] \(gap)")
                }
            } catch {
                if let runtime {
                    let lastInclude = runtime.includedFiles.last ?? "<none>"
                    print("[GLUA][M1] includes=\(runtime.includedFiles.count) lastInclude=\(lastInclude)")
                }
                print("[FILE][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if ["--file", "--trace-file", "--line-trace-file"].contains(arguments.first ?? ""),
           arguments.count == 2 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                guard let source = GMLuaRuntime.decodeSource(data) else {
                    throw ConformanceCLIError.cannotDecode(arguments[1])
                }
                let runtime = GMLuaRuntime(realm: .server) { print($0) }
                defer { _ = runtime.close() }
                if arguments.first == "--trace-file" || arguments.first == "--line-trace-file" {
                    try runtime.execute(
                        """
                        local original_assert = assert
                        function assert(value, ...)
                          if not value then print(debug.traceback("ASSERT TRACE", 2)) end
                          return original_assert(value, ...)
                        end
                        """,
                        sourceName: "=(trace bootstrap)"
                    )
                }
                if arguments.first == "--line-trace-file" {
                    try runtime.execute(
                        """
                        debug.sethook(function(event, line)
                          if event == "line" then print("[TRACE]", line) end
                        end, "l")
                        """,
                        sourceName: "=(line trace bootstrap)"
                    )
                }
                try runtime.execute(source, sourceName: "@\(arguments[1])")
            } catch {
                print("[FILE][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--eval" {
            let source = arguments.dropFirst().joined(separator: " ")
            guard !source.isEmpty else {
                print("usage: GModLuaConformance --eval <lua source>")
                terminate(2)
                return
            }

            let runtime = GMLuaRuntime(realm: .server) { print($0) }
            defer { _ = runtime.close() }
            do {
                try runtime.execute(source, sourceName: "=(command line)")
            } catch {
                print("[EVAL][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--eval-name", arguments.count >= 3 {
            let sourceName = arguments[1]
            let source = arguments.dropFirst(2).joined(separator: " ")
            let runtime = GMLuaRuntime(realm: .server) { print($0) }
            defer { _ = runtime.close() }
            do {
                try runtime.execute(source, sourceName: sourceName)
            } catch {
                print("[EVAL][FAIL] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        let sourceDirectory: URL?
        if arguments.first == "--suite-dir", arguments.count == 2 {
            sourceDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        } else {
            sourceDirectory = nil
        }

        let report = await Lua51ConformanceRunner.runBasicSuite(sourceDirectory: sourceDirectory) { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        print("")
        print("========== Lua 5.1 Official Conformance ==========")
        print(report.summaryText)

        guard report.passed else {
            terminate(1)
            return
        }
    }

    private static func terminate(_ code: Int32) {
        #if os(Windows)
        ExitProcess(UINT(code))
        #else
        exit(code)
        #endif
    }
}

private enum ConformanceCLIError: Error {
    case cannotDecode(String)
    case invalidRealm(String)
    case invalidBootstrapMode(String)
    case bootstrapObservationMismatch
    case caseInsensitiveMountMismatch
}

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
                func writeCaseFixture(_ logicalPath: String, source: String) throws {
                    let destination = logicalPath.split(separator: "/").reduce(caseFixtureRoot) {
                        $0.appendingPathComponent(String($1))
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(source.utf8).write(to: destination)
                }

                try writeCaseFixture(
                    "lua/includes/IconEditor.lua",
                    source: "return 'case-fallback'"
                )
                try writeCaseFixture(
                    "lua/includes/init.lua",
                    source: #"""
                    SEQUENCE_SHARED = { count = 1 }
                    SEQUENCE_INITIAL_RELATIVE = include("sequence_relative.lua")
                    """#
                )
                try writeCaseFixture(
                    "lua/includes/sequence_relative.lua",
                    source: "return 'includes-relative'"
                )
                try writeCaseFixture(
                    "gamemodes/base/gamemode/init.lua",
                    source: #"""
                    assert(SEQUENCE_SHARED.count == 1)
                    assert(SEQUENCE_INITIAL_RELATIVE == "includes-relative")
                    SEQUENCE_SHARED.count = 2
                    SEQUENCE_BASE_SHARED = SEQUENCE_SHARED
                    SEQUENCE_BASE_RELATIVE = include("sequence_relative.lua")
                    """#
                )
                try writeCaseFixture(
                    "gamemodes/base/gamemode/sequence_relative.lua",
                    source: "return 'base-relative'"
                )
                try writeCaseFixture(
                    "gamemodes/sandbox/gamemode/init.lua",
                    source: #"""
                    assert(SEQUENCE_SHARED == SEQUENCE_BASE_SHARED)
                    assert(SEQUENCE_SHARED.count == 2)
                    assert(SEQUENCE_BASE_RELATIVE == "base-relative")
                    SEQUENCE_SHARED.count = 3
                    SEQUENCE_SANDBOX_RELATIVE = include("sequence_relative.lua")
                    """#
                )
                try writeCaseFixture(
                    "gamemodes/sandbox/gamemode/sequence_relative.lua",
                    source: "return 'sandbox-relative'"
                )
                let caseFixtureBytes = Data("return 'case-fallback'".utf8)
                let caseFixture = try GMLuaHostDirectoryFileSystem(
                    rootURL: caseFixtureRoot,
                    writable: false
                )
                guard caseFixture.fileExists(at: "LUA/INCLUDES/iconeditor.lua"),
                      try caseFixture.readFile(at: "lua/includes/ICONEDITOR.LUA") == caseFixtureBytes else {
                    throw ConformanceCLIError.caseInsensitiveMountMismatch
                }

                let sequenceOverlay = try LuaMemoryFileSystem()
                let sequenceMount = GMLuaMountedFileSystem(mounts: [
                    try GMLuaFileMount(
                        name: "sequence-data",
                        priority: 1_000,
                        writable: true,
                        fileSystem: sequenceOverlay
                    ),
                    try GMLuaFileMount(
                        name: "sequence-fixtures",
                        priority: 0,
                        writable: false,
                        fileSystem: caseFixture
                    )
                ])
                let sequenceRuntime = GMLuaRuntime(
                    realm: .server,
                    logger: { _ in },
                    virtualFileSystem: sequenceMount,
                    bootstrapMode: .strict
                )
                defer { _ = sequenceRuntime.close() }
                for logicalPath in [
                    "lua/includes/init.lua",
                    "gamemodes/base/gamemode/init.lua",
                    "gamemodes/sandbox/gamemode/init.lua"
                ] {
                    try sequenceRuntime.loadFile(logicalPath)
                }
                try sequenceRuntime.execute(
                    #"""
                    assert(SEQUENCE_SHARED == SEQUENCE_BASE_SHARED)
                    assert(SEQUENCE_SHARED.count == 3)
                    assert(SEQUENCE_SANDBOX_RELATIVE == "sandbox-relative")
                    """#,
                    sourceName: "=(ordered sequence continuity selftest)"
                )
                guard sequenceRuntime.includedFiles == [
                    "lua/includes/sequence_relative.lua",
                    "gamemodes/base/gamemode/sequence_relative.lua",
                    "gamemodes/sandbox/gamemode/sequence_relative.lua"
                ] else {
                    throw ConformanceCLIError.sequenceObservationMismatch
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
                print("[PASS][GLUA-M1] realms, nested include/AddCSLuaFile, ordered same-runtime sequence continuity, GMod require+bit, Source KeyValues V1, and case-folded mounts")
            } catch {
                print("[FAIL][GLUA-M1] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--gmod-startup" {
            guard arguments.count == 5 else {
                print(
                    "usage: GModLuaConformance --gmod-startup " +
                    "<gmod root> <server|client> <strict|discovery> <name>"
                )
                terminate(2)
                return
            }

            var runtime: GMLuaRuntime?
            var startup: GMLuaStartupOrchestrator?
            var phase = "setup"
            do {
                let realm = try gmodRealm(arguments[2])
                let bootstrapMode = try gmodBootstrapMode(arguments[3])
                let name = arguments[4]
                let context = try makeGModRuntimeContext(
                    rootPath: arguments[1],
                    realm: realm,
                    bootstrapMode: bootstrapMode,
                    logger: { print($0) }
                )
                let created = context.runtime
                runtime = created
                defer { _ = created.close() }
                print(
                    "[GLUA][STARTUP][START] realm=\(realm.rawValue) " +
                    "mode=\(bootstrapMode.rawValue) name=\(name)"
                )

                phase = "core"
                try created.loadFile("lua/includes/init.lua")
                print(
                    "[GLUA][STARTUP][CORE]" +
                    (bootstrapMode == .discovery ? "[SKIP][DISCOVERY]" : "[PASS]") +
                    " path=lua/includes/init.lua"
                )

                phase = "startup"
                let orchestrator = GMLuaStartupOrchestrator(
                    runtime: created,
                    fileSystem: context.fileSystem
                )
                startup = orchestrator
                let report = try orchestrator.start(targetGamemodeNamed: name)
                for stage in report.stages {
                    let status: String
                    if bootstrapMode == .discovery {
                        status = "SKIP][DISCOVERY"
                    } else {
                        status = stage.outcome == .completed ? "PASS" : "SKIP"
                    }
                    print(
                        "[GLUA][STARTUP][STAGE][\(status)] " +
                        "name=\(stage.stage.rawValue) " +
                        "direct=\(stage.directPaths.count) " +
                        "transitiveIncludes=\(stage.transitiveIncludePaths.count) " +
                        "detail=\(stage.detail)"
                    )
                    for path in stage.directPaths {
                        print("[GLUA][STARTUP][DIRECT] stage=\(stage.stage.rawValue) path=\(path)")
                    }
                    for path in stage.transitiveIncludePaths {
                        print("[GLUA][STARTUP][INCLUDE] stage=\(stage.stage.rawValue) path=\(path)")
                    }
                }
                print(
                    "[GLUA][STARTUP][BOUNDARY] addonsLoaded=\(report.addonsLoaded) " +
                    "playerConnectionModeled=\(report.playerConnectionModeled) " +
                    "engineEntityReadiness=false"
                )
                if bootstrapMode == .discovery {
                    print(
                        "[GLUA][STARTUP][SKIP][DISCOVERY] target=\(report.targetGamemode) " +
                        "directAutorun=\(report.directAutorunPaths.count) " +
                        "autorunIncludes=\(report.autorunTransitiveIncludePaths.count) " +
                        "passed=false desktopStartupComplete=false"
                    )
                } else {
                    print(
                        "[GLUA][STARTUP][MODELED-STAGES-COMPLETE] " +
                        "target=\(report.targetGamemode) " +
                        "directAutorun=\(report.directAutorunPaths.count) " +
                        "autorunIncludes=\(report.autorunTransitiveIncludePaths.count) " +
                        "desktopStartupComplete=false"
                    )
                }
            } catch {
                if let runtime {
                    let completed = startup?.stages.map { $0.stage.rawValue }.joined(separator: ",")
                        ?? "<none>"
                    let active = startup?.activeStage?.rawValue ?? phase
                    let activePath = startup?.activePath ?? "<none>"
                    let lastInclude = runtime.includedFiles.last ?? "<none>"
                    print(
                        "[GLUA][STARTUP][FAIL] phase=\(active) path=\(activePath) " +
                        "completed=\(completed) " +
                        "includes=\(runtime.includedFiles.count) lastInclude=\(lastInclude)"
                    )
                } else {
                    print("[GLUA][STARTUP][FAIL] phase=\(phase)")
                }
                print(
                    "[GLUA][STARTUP][BOUNDARY] addonsLoaded=false " +
                    "playerConnectionModeled=false desktopStartupComplete=false"
                )
                print("[GLUA][STARTUP][ERROR] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--gmod-gamemode" {
            guard arguments.count == 5 else {
                print(
                    "usage: GModLuaConformance --gmod-gamemode " +
                    "<gmod root> <server|client|menu> <strict|discovery> <name>"
                )
                terminate(2)
                return
            }

            var runtime: GMLuaRuntime?
            var phase = "setup"
            do {
                let realm = try gmodRealm(arguments[2])
                let bootstrapMode = try gmodBootstrapMode(arguments[3])
                let name = arguments[4]
                let created = try makeGModRuntime(
                    rootPath: arguments[1],
                    realm: realm,
                    bootstrapMode: bootstrapMode,
                    logger: { print($0) }
                )
                runtime = created
                defer { _ = created.close() }
                print(
                    "[GLUA][GAMEMODE][START] realm=\(realm.rawValue) " +
                    "mode=\(bootstrapMode.rawValue) name=\(name)"
                )

                phase = "core"
                let coreIncludesBefore = created.includedFiles.count
                let coreClientFilesBefore = created.clientLuaFiles.count
                let coreCommandsBefore = created.consoleCommands.count
                let coreGapsBefore = created.compatibilityGaps.count
                try created.loadFile("lua/includes/init.lua")
                let coreStatus = bootstrapMode == .discovery
                    ? "[SKIP][DISCOVERY]"
                    : "[PASS]"
                print(
                    "[GLUA][GAMEMODE][CORE]\(coreStatus) path=lua/includes/init.lua " +
                    stageMetrics(
                        runtime: created,
                        includesBefore: coreIncludesBefore,
                        clientFilesBefore: coreClientFilesBefore,
                        commandsBefore: coreCommandsBefore,
                        gapsBefore: coreGapsBefore
                    )
                )

                phase = "gamemode"
                guard let loader = created.gamemodeLoader else {
                    throw ConformanceCLIError.gamemodeLoaderUnavailable
                }
                let loadIncludesBefore = created.includedFiles.count
                let loadClientFilesBefore = created.clientLuaFiles.count
                let loadCommandsBefore = created.consoleCommands.count
                let loadGapsBefore = created.compatibilityGaps.count
                let report = try loader.loadGamemode(named: name)
                let loadStatus = bootstrapMode == .discovery
                    ? "[SKIP][DISCOVERY]"
                    : "[PASS]"
                print(
                    "[GLUA][GAMEMODE][LOAD]\(loadStatus) " +
                    "requested=\(report.requestedName) " +
                    "order=\(report.loadOrder.joined(separator: ",")) " +
                    "new=\(report.newlyLoaded.joined(separator: ",")) " +
                    stageMetrics(
                        runtime: created,
                        includesBefore: loadIncludesBefore,
                        clientFilesBefore: loadClientFilesBefore,
                        commandsBefore: loadCommandsBefore,
                        gapsBefore: loadGapsBefore
                    )
                )
                for (offset, loadedName) in report.loadOrder.enumerated() {
                    let path = offset < report.entryPaths.count
                        ? report.entryPaths[offset]
                        : "<cached>"
                    print(
                        "[GLUA][GAMEMODE][ENTRY] index=\(offset + 1)/\(report.loadOrder.count) " +
                        "name=\(loadedName) path=\(path)"
                    )
                }

                phase = "verification"
                try created.execute(
                    #"""
                    assert(GM == GAMEMODE, "final GM/GAMEMODE identity mismatch")
                    assert(type(GAMEMODE.FolderName) == "string", "missing FolderName")
                    assert(type(GAMEMODE.Folder) == "string", "missing Folder")
                    assert(type(GAMEMODE.Base) == "string", "missing Base")
                    assert(baseclass.Get("gamemode_" .. GAMEMODE.FolderName) == GAMEMODE,
                        "baseclass registry identity mismatch")
                    if GAMEMODE.Base ~= "" then
                        local inherited = gamemode.Get(GAMEMODE.Base)
                        assert(inherited ~= nil, "registered base gamemode is unavailable")
                        assert(GAMEMODE.BaseClass == inherited, "BaseClass inheritance mismatch")
                    end
                    """#,
                    sourceName: "=(gamemode loader verification)"
                )
                print(
                    "[GLUA][GAMEMODE][VERIFY]\(loadStatus) " +
                    "gmIdentity=true baseclassRegistry=true inheritance=true"
                )
                print(
                    "[GLUA][GAMEMODE][LIFECYCLE] autorun=not-run addons=not-run"
                )
                for gap in created.compatibilityGaps {
                    print("[GLUA][GAMEMODE][GAP] \(gap)")
                }
                if bootstrapMode == .discovery {
                    print(
                        "[GLUA][GAMEMODE][SKIP][DISCOVERY] loadPassed=false " +
                        "compatibilityGaps=\(created.compatibilityGaps.count)"
                    )
                } else {
                    print(
                        "[GLUA][GAMEMODE][PASS] name=\(report.requestedName) " +
                        "compatibilityGaps=\(created.compatibilityGaps.count)"
                    )
                }
            } catch {
                if let runtime {
                    let loaded = runtime.gamemodeLoader?.loadedGamemodeNames ?? []
                    let lastInclude = runtime.includedFiles.last ?? "<none>"
                    print(
                        "[GLUA][GAMEMODE][FAIL] phase=\(phase) " +
                        "loaded=\(loaded.isEmpty ? "<none>" : loaded.joined(separator: ",")) " +
                        "includes=\(runtime.includedFiles.count) " +
                        "clientFiles=\(runtime.clientLuaFiles.count) " +
                        "commands=\(runtime.consoleCommands.count) " +
                        "gaps=\(runtime.compatibilityGaps.count) lastInclude=\(lastInclude)"
                    )
                } else {
                    print("[GLUA][GAMEMODE][FAIL] phase=\(phase)")
                }
                print("[GLUA][GAMEMODE][LIFECYCLE] autorun=not-run addons=not-run")
                print("[GLUA][GAMEMODE][ERROR] \(GMLuaRuntime.describe(error))")
                terminate(1)
            }
            return
        }

        if arguments.first == "--gmod-sequence" {
            guard arguments.count >= 5 else {
                print(
                    "usage: GModLuaConformance --gmod-sequence " +
                    "<gmod root> <server|client|menu> <strict|discovery> <logical paths...>"
                )
                terminate(2)
                return
            }

            do {
                let realm = try gmodRealm(arguments[2])
                let bootstrapMode = try gmodBootstrapMode(arguments[3])
                let logicalPaths = arguments.dropFirst(4).map {
                    $0.replacingOccurrences(of: "\\", with: "/")
                }
                let runtime = try makeGModRuntime(
                    rootPath: arguments[1],
                    realm: realm,
                    bootstrapMode: bootstrapMode,
                    logger: { print($0) }
                )
                defer { _ = runtime.close() }
                print(
                    "[GLUA][SEQUENCE][START] realm=\(realm.rawValue) " +
                    "mode=\(bootstrapMode.rawValue) stages=\(logicalPaths.count)"
                )

                for (offset, logicalPath) in logicalPaths.enumerated() {
                    let stage = offset + 1
                    let includesBefore = runtime.includedFiles.count
                    let clientFilesBefore = runtime.clientLuaFiles.count
                    let commandsBefore = runtime.consoleCommands.count
                    let gapsBefore = runtime.compatibilityGaps.count

                    do {
                        try runtime.loadFile(logicalPath)
                    } catch {
                        let lastInclude = runtime.includedFiles.last ?? "<none>"
                        print(
                            "[GLUA][SEQUENCE][STAGE][FAIL] " +
                            "index=\(stage)/\(logicalPaths.count) path=\(logicalPath) " +
                            stageMetrics(
                                runtime: runtime,
                                includesBefore: includesBefore,
                                clientFilesBefore: clientFilesBefore,
                                commandsBefore: commandsBefore,
                                gapsBefore: gapsBefore
                            ) + " lastInclude=\(lastInclude)"
                        )
                        for gap in runtime.compatibilityGaps.dropFirst(gapsBefore) {
                            print("[GLUA][SEQUENCE][GAP] stage=\(stage) \(gap)")
                        }
                        print(
                            "[GLUA][SEQUENCE][FAIL] failedStage=\(stage) " +
                            "path=\(logicalPath) lastInclude=\(lastInclude)"
                        )
                        print("[GLUA][SEQUENCE][ERROR] \(GMLuaRuntime.describe(error))")
                        terminate(1)
                        return
                    }

                    let stageStatus = bootstrapMode == .discovery
                        ? "[SKIP][DISCOVERY]"
                        : "[PASS]"
                    print(
                        "[GLUA][SEQUENCE][STAGE]\(stageStatus) " +
                        "index=\(stage)/\(logicalPaths.count) path=\(logicalPath) " +
                        stageMetrics(
                            runtime: runtime,
                            includesBefore: includesBefore,
                            clientFilesBefore: clientFilesBefore,
                            commandsBefore: commandsBefore,
                            gapsBefore: gapsBefore
                        )
                    )
                    for gap in runtime.compatibilityGaps.dropFirst(gapsBefore) {
                        print("[GLUA][SEQUENCE][GAP] stage=\(stage) \(gap)")
                    }
                }

                if bootstrapMode == .discovery {
                    print(
                        "[GLUA][SEQUENCE][SKIP][DISCOVERY] " +
                        "completedStages=\(logicalPaths.count) loadPassed=false " +
                        "compatibilityGaps=\(runtime.compatibilityGaps.count)"
                    )
                } else {
                    print(
                        "[GLUA][SEQUENCE][PASS] completedStages=\(logicalPaths.count) " +
                        "compatibilityGaps=\(runtime.compatibilityGaps.count)"
                    )
                }
            } catch {
                print("[GLUA][SEQUENCE][SETUP][FAIL] \(GMLuaRuntime.describe(error))")
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

    private static func gmodRealm(_ value: String) throws -> GMLuaRealm {
        switch value.lowercased() {
        case "server": return .server
        case "client": return .client
        case "menu": return .menu
        default: throw ConformanceCLIError.invalidRealm(value)
        }
    }

    private static func gmodBootstrapMode(_ value: String) throws -> GMLuaBootstrapMode {
        switch value.lowercased() {
        case "strict": return .strict
        case "discovery": return .discovery
        default: throw ConformanceCLIError.invalidBootstrapMode(value)
        }
    }

    private static func makeGModRuntime(
        rootPath: String,
        realm: GMLuaRealm,
        bootstrapMode: GMLuaBootstrapMode,
        logger: @escaping (String) -> Void
    ) throws -> GMLuaRuntime {
        try makeGModRuntimeContext(
            rootPath: rootPath,
            realm: realm,
            bootstrapMode: bootstrapMode,
            logger: logger
        ).runtime
    }

    private static func makeGModRuntimeContext(
        rootPath: String,
        realm: GMLuaRealm,
        bootstrapMode: GMLuaBootstrapMode,
        logger: @escaping (String) -> Void
    ) throws -> (runtime: GMLuaRuntime, fileSystem: GMLuaMountedFileSystem) {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
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
        // A filesystem snapshot cannot reveal live Source session state. Use
        // one explicit, deterministic headless fixture for strict/discovery
        // corpus runs; production app hosts remain disconnected until they
        // supply their real session configuration.
        let gameEnvironmentConfiguration = try GMLuaGameEnvironmentConfiguration(
            maxPlayers: 32,
            mapName: "gm_construct",
            sessionKind: .dedicatedServer
        )
        logger(
            "[GLUA][HOST] gameEnvironment=headless-conformance-fixture " +
                "maxPlayers=32 map=gm_construct session=dedicatedServer"
        )
        // The Lua directory cannot prove Steam ownership, installation, or
        // Source mount state. A connected empty snapshot is an explicit
        // headless fixture, not a claim about the desktop installation.
        let engineConfiguration = GMLuaEngineConfiguration(
            games: [],
            isPlayingDemo: false,
            isRecordingDemo: false
        )
        logger(
            "[GLUA][HOST] engineGames=headless-conformance-fixture " +
                "mountableGames=0 source=explicit-empty-snapshot"
        )
        let runtime = GMLuaRuntime(
            realm: realm,
            logger: logger,
            virtualFileSystem: mounted,
            bootstrapMode: bootstrapMode,
            gameEnvironmentConfiguration: gameEnvironmentConfiguration,
            engineConfiguration: engineConfiguration
        )
        // The desktop conformance process has no Source console. Connect one
        // deliberately narrow engine fixture so TTT's mandatory friendly-fire
        // initialization can be measured beyond the native dispatch boundary.
        // Every other engine command remains unhandled and therefore fails.
        if realm == .server, let dispatcher = runtime.consoleCommandDispatcher {
            let recognizedCommands: Set<String> = ["mp_friendlyfire"]
            dispatcher.connectHost { invocation in
                recognizedCommands.contains(invocation.command.lowercased())
                    ? .handled
                    : .unhandled
            }
            logger(
                "[GLUA][HOST] consoleCommands=headless-conformance-fixture " +
                    "recognized=mp_friendlyfire unknownPolicy=fail"
            )
        }
        return (runtime, mounted)
    }

    private static func stageMetrics(
        runtime: GMLuaRuntime,
        includesBefore: Int,
        clientFilesBefore: Int,
        commandsBefore: Int,
        gapsBefore: Int
    ) -> String {
        "includes=\(runtime.includedFiles.count) " +
        "includesDelta=\(runtime.includedFiles.count - includesBefore) " +
        "clientFiles=\(runtime.clientLuaFiles.count) " +
        "clientFilesDelta=\(runtime.clientLuaFiles.count - clientFilesBefore) " +
        "commands=\(runtime.consoleCommands.count) " +
        "commandsDelta=\(runtime.consoleCommands.count - commandsBefore) " +
        "gaps=\(runtime.compatibilityGaps.count) " +
        "gapsDelta=\(runtime.compatibilityGaps.count - gapsBefore)"
    }
}

private enum ConformanceCLIError: Error {
    case cannotDecode(String)
    case invalidRealm(String)
    case invalidBootstrapMode(String)
    case bootstrapObservationMismatch
    case caseInsensitiveMountMismatch
    case sequenceObservationMismatch
    case gamemodeLoaderUnavailable
}

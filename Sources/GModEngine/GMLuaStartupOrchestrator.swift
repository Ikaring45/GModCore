import Foundation
import GModLua

public enum GMLuaStartupStage: String, Sendable, Equatable {
    case clientVGUIBootstrap
    case baseGamemode
    case sharedAutorun
    case realmAutorun
    case addons
    case targetGamemode
    case postGamemodeLoaded
    case initialize
    case playerConnection
    case initPostEntity
}

public enum GMLuaStartupStageOutcome: String, Sendable, Equatable {
    case completed
    case skipped
}

public struct GMLuaStartupStageRecord: Sendable, Equatable {
    public let stage: GMLuaStartupStage
    public let outcome: GMLuaStartupStageOutcome
    public let directPaths: [String]
    public let transitiveIncludePaths: [String]
    public let detail: String

    public init(
        stage: GMLuaStartupStage,
        outcome: GMLuaStartupStageOutcome,
        directPaths: [String] = [],
        transitiveIncludePaths: [String] = [],
        detail: String
    ) {
        self.stage = stage
        self.outcome = outcome
        self.directPaths = directPaths
        self.transitiveIncludePaths = transitiveIncludePaths
        self.detail = detail
    }
}

public struct GMLuaStartupReport: Equatable {
    public let realm: GMLuaRealm
    public let targetGamemode: String
    public let baseReport: GMLuaGamemodeLoadReport
    public let targetReport: GMLuaGamemodeLoadReport
    public let stages: [GMLuaStartupStageRecord]

    /// These are only the direct files selected by the engine autorun folders.
    /// Files reached through `include()` are tracked by `GMLuaRuntime` and are
    /// intentionally not conflated with direct autorun discovery.
    public var directAutorunPaths: [String] {
        stages
            .filter { $0.stage == .sharedAutorun || $0.stage == .realmAutorun }
            .flatMap(\.directPaths)
    }

    public var addonsLoaded: Bool {
        stages.contains { $0.stage == .addons && $0.outcome == .completed }
    }

    public var autorunTransitiveIncludePaths: [String] {
        stages
            .filter { $0.stage == .sharedAutorun || $0.stage == .realmAutorun }
            .flatMap(\.transitiveIncludePaths)
    }

    public var playerConnectionModeled: Bool {
        stages.contains { $0.stage == .playerConnection && $0.outcome == .completed }
    }
}

public enum GMLuaStartupError: Error, CustomStringConvertible {
    case unsupportedRealm(GMLuaRealm)
    case alreadyStarted
    case runtimeUnavailable
    case gamemodeLoaderUnavailable
    case clientVGUIBootstrap(path: String, reason: String)
    case autorunEnumeration(path: String, reason: String)
    case autorunExecution(path: String, reason: String)
    case lifecycleUnavailable(event: String, reason: String)
    case lifecycleExecution(event: String, reason: String)

    public var description: String {
        switch self {
        case let .unsupportedRealm(realm):
            return "startup orchestration is not defined for the \(realm.rawValue) realm"
        case .alreadyStarted:
            return "startup orchestration is single-use and has already started"
        case .runtimeUnavailable:
            return "startup runtime is no longer available"
        case .gamemodeLoaderUnavailable:
            return "startup runtime has no mounted gamemode loader"
        case let .clientVGUIBootstrap(path, reason):
            return "client VGUI bootstrap failed at \(path): \(reason)"
        case let .autorunEnumeration(path, reason):
            return "cannot enumerate autorun directory \(path): \(reason)"
        case let .autorunExecution(path, reason):
            return "autorun file failed at \(path): \(reason)"
        case let .lifecycleUnavailable(event, reason):
            return "cannot dispatch lifecycle event \(event): \(reason)"
        case let .lifecycleExecution(event, reason):
            return "lifecycle event \(event) failed: \(reason)"
        }
    }
}

/// Host-owned M1 startup sequence for a mounted, unpacked GMod filesystem.
///
/// The runtime's core `lua/includes/init.lua` must already be loaded. This
/// orchestrator then reproduces the boundary which is material to gamemode
/// compatibility:
///
/// CLIENT VGUI bootstrap -> Base -> shared autorun -> realm autorun -> addon boundary -> target
///      -> PostGamemodeLoaded -> Initialize -> InitPostEntity
///
/// GMod asks the client Lua state to load `lua/includes/vgui_base.lua` after
/// core init and before Base. That engine-owned step is not included by
/// `lua/includes/init.lua` itself. The client report also inserts its observed
/// player/session boundary between the last two lifecycle events. Server
/// startup has neither client-only stage.
///
/// Autorun files are direct `.lua` children sorted A-Z, matching GMod's public
/// loading-order contract. Addon mount/GMA/VPK discovery and player/entity
/// creation do not exist in M1, so those stages are explicit SKIPs rather than
/// false passes. Lifecycle dispatch uses the already loaded `hook.Call` and the
/// active target gamemode through `LuaState.call`; no generated Lua source is
/// evaluated by the host.
public final class GMLuaStartupOrchestrator {
    private weak var runtime: GMLuaRuntime?
    private let fileSystem: LuaVirtualFileSystem
    private var didStart = false
    private var stageStorage: [GMLuaStartupStageRecord] = []
    private var activeStageStorage: GMLuaStartupStage?
    private var activePathStorage: String?

    public init(runtime: GMLuaRuntime, fileSystem: LuaVirtualFileSystem) {
        self.runtime = runtime
        self.fileSystem = fileSystem
    }

    public var stages: [GMLuaStartupStageRecord] { stageStorage }
    public var activeStage: GMLuaStartupStage? { activeStageStorage }
    public var activePath: String? { activePathStorage }

    @discardableResult
    public func start(targetGamemodeNamed rawName: String) throws -> GMLuaStartupReport {
        guard !didStart else { throw GMLuaStartupError.alreadyStarted }
        didStart = true
        guard let runtime else { throw GMLuaStartupError.runtimeUnavailable }
        guard runtime.realm == .server || runtime.realm == .client else {
            throw GMLuaStartupError.unsupportedRealm(runtime.realm)
        }
        guard let loader = runtime.gamemodeLoader else {
            throw GMLuaStartupError.gamemodeLoaderUnavailable
        }

        if runtime.realm == .client {
            try loadClientVGUIBootstrap(runtime: runtime)
        }

        activeStageStorage = .baseGamemode
        let baseReport = try loader.loadBaseGamemode()
        record(
            .baseGamemode,
            detail: baseReport.newlyLoaded.isEmpty
                ? "Base was already registered; no entry was re-executed"
                : "Base loaded and registered exactly once"
        )

        activeStageStorage = .sharedAutorun
        let sharedPaths = try autorunPaths(in: "lua/autorun")
        let sharedIncludesBefore = runtime.includedFiles.count
        try executeAutorun(sharedPaths, runtime: runtime)
        record(
            .sharedAutorun,
            paths: sharedPaths,
            includes: Array(runtime.includedFiles.dropFirst(sharedIncludesBefore)),
            detail: "direct shared autorun files executed A-Z; nested includes are reported separately"
        )

        activeStageStorage = .realmAutorun
        let realmDirectory = runtime.realm == .server
            ? "lua/autorun/server"
            : "lua/autorun/client"
        let realmPaths = try autorunPaths(in: realmDirectory)
        let realmIncludesBefore = runtime.includedFiles.count
        try executeAutorun(realmPaths, runtime: runtime)
        record(
            .realmAutorun,
            paths: realmPaths,
            includes: Array(runtime.includedFiles.dropFirst(realmIncludesBefore)),
            detail: "direct \(runtime.realm.rawValue)-only autorun files executed A-Z"
        )

        activeStageStorage = .addons
        record(
            .addons,
            outcome: .skipped,
            detail: "loose addon merge, GMA/VPK discovery, and addon precedence are not implemented"
        )

        activeStageStorage = .targetGamemode
        let targetReport = try loader.loadTargetGamemode(named: rawName)
        record(
            .targetGamemode,
            detail: targetReport.newlyLoaded.isEmpty
                ? "target was already registered; no entry was re-executed"
                : "target loaded after autorun; cached Base was not re-executed"
        )

        try dispatchLifecycle(
            event: "PostGamemodeLoaded",
            stage: .postGamemodeLoaded,
            runtime: runtime,
            loader: loader,
            targetName: targetReport.requestedName
        )
        try dispatchLifecycle(
            event: "Initialize",
            stage: .initialize,
            runtime: runtime,
            loader: loader,
            targetName: targetReport.requestedName
        )

        if runtime.realm == .client {
            activeStageStorage = .playerConnection
            record(
                .playerConnection,
                outcome: .skipped,
                detail: "player/session connection and LocalPlayer validity are not modeled"
            )
        }

        try dispatchLifecycle(
            event: "InitPostEntity",
            stage: .initPostEntity,
            runtime: runtime,
            loader: loader,
            targetName: targetReport.requestedName
        )
        activeStageStorage = nil

        return GMLuaStartupReport(
            realm: runtime.realm,
            targetGamemode: targetReport.requestedName,
            baseReport: baseReport,
            targetReport: targetReport,
            stages: stageStorage
        )
    }

    private func loadClientVGUIBootstrap(runtime: GMLuaRuntime) throws {
        let path = "lua/includes/vgui_base.lua"
        activeStageStorage = .clientVGUIBootstrap
        activePathStorage = path
        let includesBefore = runtime.includedFiles.count
        do {
            try runtime.loadFile(path)
        } catch {
            throw GMLuaStartupError.clientVGUIBootstrap(
                path: path,
                reason: GMLuaRuntime.describe(error)
            )
        }
        activePathStorage = nil
        record(
            .clientVGUIBootstrap,
            paths: [path],
            includes: Array(runtime.includedFiles.dropFirst(includesBefore)),
            detail: "engine-invoked client VGUI controls loaded before Base"
        )
    }

    private func autorunPaths(in directory: String) throws -> [String] {
        guard fileSystem.directoryExists(at: directory) else { return [] }
        let entries: [LuaVirtualFileSystemEntry]
        do {
            entries = try fileSystem.listDirectory(at: directory)
        } catch {
            throw GMLuaStartupError.autorunEnumeration(
                path: directory,
                reason: String(describing: error)
            )
        }
        return entries
            .filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".lua") }
            .sorted(by: Self.alphabetical)
            .map { directory + "/" + $0.name }
    }

    private func executeAutorun(_ paths: [String], runtime: GMLuaRuntime) throws {
        for path in paths {
            activePathStorage = path
            do {
                try runtime.loadFile(path)
            } catch {
                throw GMLuaStartupError.autorunExecution(
                    path: path,
                    reason: GMLuaRuntime.describe(error)
                )
            }
        }
        activePathStorage = nil
    }

    private func dispatchLifecycle(
        event: String,
        stage: GMLuaStartupStage,
        runtime: GMLuaRuntime,
        loader: GMLuaGamemodeLoader,
        targetName: String
    ) throws {
        activeStageStorage = stage
        activePathStorage = nil
        let state = runtime.state
        guard case let .table(hookLibrary) = state.getGlobal("hook") else {
            throw GMLuaStartupError.lifecycleUnavailable(
                event: event,
                reason: "global hook table is unavailable"
            )
        }
        let call: LuaValue
        do {
            call = try state.rawTableValue(for: .string("Call"), in: hookLibrary)
        } catch {
            throw GMLuaStartupError.lifecycleUnavailable(
                event: event,
                reason: GMLuaRuntime.describe(error)
            )
        }
        guard case .luaFunction = call else {
            if case .nativeFunction = call {
                return try invokeLifecycle(
                    call,
                    event: event,
                    stage: stage,
                    runtime: runtime,
                    loader: loader,
                    targetName: targetName
                )
            }
            throw GMLuaStartupError.lifecycleUnavailable(
                event: event,
                reason: "hook.Call is \(call.typeName), expected function"
            )
        }
        try invokeLifecycle(
            call,
            event: event,
            stage: stage,
            runtime: runtime,
            loader: loader,
            targetName: targetName
        )
    }

    private func invokeLifecycle(
        _ call: LuaValue,
        event: String,
        stage: GMLuaStartupStage,
        runtime: GMLuaRuntime,
        loader: GMLuaGamemodeLoader,
        targetName: String
    ) throws {
        guard let gamemode = loader.gamemode(named: targetName) else {
            throw GMLuaStartupError.lifecycleUnavailable(
                event: event,
                reason: "active target gamemode is unavailable"
            )
        }
        do {
            _ = try runtime.state.call(
                call,
                arguments: [.string(LuaString(event)), gamemode]
            )
        } catch {
            throw GMLuaStartupError.lifecycleExecution(
                event: event,
                reason: GMLuaRuntime.describe(error)
            )
        }
        record(
            stage,
            detail: "host dispatched hook.Call with the active target gamemode"
        )
    }

    private func record(
        _ stage: GMLuaStartupStage,
        outcome: GMLuaStartupStageOutcome = .completed,
        paths: [String] = [],
        includes: [String] = [],
        detail: String
    ) {
        stageStorage.append(GMLuaStartupStageRecord(
            stage: stage,
            outcome: outcome,
            directPaths: paths,
            transitiveIncludePaths: includes,
            detail: detail
        ))
    }

    private static func alphabetical(
        _ lhs: LuaVirtualFileSystemEntry,
        _ rhs: LuaVirtualFileSystemEntry
    ) -> Bool {
        let foldedLHS = lhs.name.lowercased()
        let foldedRHS = rhs.name.lowercased()
        if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
        return lhs.name < rhs.name
    }
}

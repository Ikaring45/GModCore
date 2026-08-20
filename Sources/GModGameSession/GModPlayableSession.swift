import Foundation
import GModEngine
import GModGameAssets
import GModLua

/// Host facts used to construct one local, paired SERVER/CLIENT game session.
/// A Playgrounds content pack can supply the selected map directly from its
/// ZIP; the audited base Lua/UI closure remains the deterministic fallback.
public struct GModPlayableSessionConfiguration: Sendable, Equatable {
    public let map: GModBundledMap
    public let gamemodeName: String
    public let maxPlayers: Int
    public let playerEntityIndex: Int
    public let playerUserID: Int
    public let initialViewport: GMLuaViewportSize
    public let contentPackURL: URL?

    public init(
        map: GModBundledMap = .construct,
        gamemodeName: String = "sandbox",
        maxPlayers: Int = 32,
        playerEntityIndex: Int = 1,
        playerUserID: Int = 1,
        initialViewport: GMLuaViewportSize = .logicalDesktopDefault,
        contentPackURL: URL? = nil
    ) {
        self.map = map
        self.gamemodeName = gamemodeName
        self.maxPlayers = maxPlayers
        self.playerEntityIndex = playerEntityIndex
        self.playerUserID = playerUserID
        self.initialViewport = initialViewport
        self.contentPackURL = contentPackURL
    }
}

public struct GModMapSpawnPoint: Sendable, Equatable {
    public let origin: SourceVector3
    public let angles: SourceQAngle

    public init(origin: SourceVector3, angles: SourceQAngle = .zero) {
        self.origin = origin
        self.angles = angles
    }
}

public struct GModPlayableSessionStartupReport: Sendable, Equatable {
    public let map: GModBundledMap
    public let spawnPoint: GModMapSpawnPoint
    public let worldIdentity: GMLuaSourceEntityIdentity
    public let serverStartup: GMLuaStartupReport
    public let clientStartup: GMLuaStartupReport
    public let deliveredMessages: Int
}

public struct GModPlayableMovementRejection: Equatable, Sendable {
    public let commandNumber: Int32
    public let reason: SourceWorldWalkUnsupportedReason
    public let preservedState: SourceWorldWalkState

    public init(
        commandNumber: Int32,
        reason: SourceWorldWalkUnsupportedReason,
        preservedState: SourceWorldWalkState
    ) {
        self.commandNumber = commandNumber
        self.reason = reason
        self.preservedState = preservedState
    }
}

/// An honest, value-semantic movement result. A rejected command is not
/// represented as a zero-distance successful `SourceWorldWalkTick`.
public enum GModPlayableMovementResult: Equatable, Sendable {
    case advanced(SourceWorldWalkTick)
    case rejected(GModPlayableMovementRejection)

    public var state: SourceWorldWalkState {
        switch self {
        case let .advanced(tick):
            return tick.state
        case let .rejected(rejection):
            return rejection.preservedState
        }
    }

    public var rejection: GModPlayableMovementRejection? {
        guard case let .rejected(rejection) = self else { return nil }
        return rejection
    }
}

public struct GModPlayableFixedTickReport: Equatable, Sendable {
    public let movement: GModPlayableMovementResult
    public let server: GMLuaSourceRuntimeRunReport
    public let client: GMLuaSourceRuntimeRunReport
    public let deliveredMessages: Int
    public let actionFailures: [GMLuaForwardedConsoleCommandFailure]
}

public struct GModPlayableMovementInput: Equatable, Sendable {
    public let viewAngles: SourceQAngle?
    public let forwardMove: Float
    public let sideMove: Float
    public let buttons: SourceInputButtons

    public init(
        viewAngles: SourceQAngle? = nil,
        forwardMove: Float = 0,
        sideMove: Float = 0,
        buttons: SourceInputButtons = []
    ) {
        self.viewAngles = viewAngles
        self.forwardMove = forwardMove
        self.sideMove = sideMove
        self.buttons = buttons
    }

    public static let idle = GModPlayableMovementInput()
}

public struct GModPlayableSessionCloseReport: Equatable, Sendable {
    public let clientFinalizerErrors: [String]
    public let serverFinalizerErrors: [String]

    public init(
        clientFinalizerErrors: [String],
        serverFinalizerErrors: [String]
    ) {
        self.clientFinalizerErrors = clientFinalizerErrors
        self.serverFinalizerErrors = serverFinalizerErrors
    }
}

public enum GModPlayableSessionError: Error, CustomStringConvertible, Equatable {
    case invalidGamemodeName(String)
    case missingEntityText(String)
    case missingPlayerStart(String)
    case malformedPlayerStart(String)
    case missingRuntimeSurface(GMLuaRealm, String)
    case deliveryLimitExceeded(Int)
    case deliveryStalled(Int)
    case closed

    public var description: String {
        switch self {
        case let .invalidGamemodeName(value):
            return "invalid gamemode name: \(value)"
        case let .missingEntityText(map):
            return "bundled map \(map) has no UTF-8 entity lump"
        case let .missingPlayerStart(map):
            return "bundled map \(map) has no info_player_start"
        case let .malformedPlayerStart(value):
            return "invalid info_player_start origin: \(value)"
        case let .missingRuntimeSurface(realm, surface):
            return "\(realm.rawValue) runtime has no \(surface)"
        case let .deliveryLimitExceeded(limit):
            return "paired session exceeded its \(limit)-delivery host boundary"
        case let .deliveryStalled(pending):
            return "paired session pump stalled with \(pending) queued deliveries"
        case .closed:
            return "playable session is closed"
        }
    }
}

/// Cross-platform ownership layer used by the iPad host and Windows tests.
///
/// It owns one paired SERVER/CLIENT runtime, the bundled read-only VFS, a
/// Source fixed-tick adapter, canonical Entity(0), a real bundled BSP trace
/// provider, and explicit net pumping. It does not own a render thread or
/// silently advance simulation: the Apple host must call `runFixedTick()` and
/// `runClientFrame()` from one serialized game lane.
public final class GModPlayableSession {
    public let configuration: GModPlayableSessionConfiguration
    public let serverRuntime: GMLuaRuntime
    public let clientRuntime: GMLuaRuntime
    public let sharedSession: GMLuaSharedSession
    public let sourceAdapter: GMLuaSourceRuntimeAdapter
    public let bsp: SourceBSP
    public let worldMesh: GModWorldRenderMesh
    public let worldIdentity: GMLuaSourceEntityIdentity
    public let spawnPoint: GModMapSpawnPoint
    public let startupReport: GModPlayableSessionStartupReport
    public private(set) var playerWalkState: SourceWorldWalkState

    private let serverFileSystem: GMLuaMountedFileSystem
    private let clientFileSystem: GMLuaMountedFileSystem
    private let worldWalkSolver: SourceWorldWalkSolver
    private var nextCommandNumber: Int32 = 1
    private var closedStorage = false

    public convenience init(
        configuration: GModPlayableSessionConfiguration = .init(),
        textMeasurer: (any GMLuaTextMeasurer)? = nil,
        logger: @escaping @Sendable (
            _ realm: GMLuaRealm,
            _ message: String
        ) -> Void = { _, _ in }
    ) throws {
        try self.init(
            configuration: configuration,
            textMeasurer: textMeasurer,
            logger: logger,
            worldWalkCollisionProvider: nil
        )
    }

    /// Internal construction seam for deterministic host-boundary tests. The
    /// shipped app always uses the bundled BSP provider selected below.
    init(
        configuration: GModPlayableSessionConfiguration,
        textMeasurer: (any GMLuaTextMeasurer)?,
        logger: @escaping @Sendable (
            _ realm: GMLuaRealm,
            _ message: String
        ) -> Void,
        worldWalkCollisionProvider:
            (any SourceWorldWalkCollisionProvider)?
    ) throws {
        let trimmedGamemode = configuration.gamemodeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGamemode.isEmpty,
              trimmedGamemode == configuration.gamemodeName,
              !trimmedGamemode.contains("/"),
              !trimmedGamemode.contains("\\") else {
            throw GModPlayableSessionError.invalidGamemodeName(
                configuration.gamemodeName
            )
        }

        let bspData: Data
        if let contentPackURL = configuration.contentPackURL {
            let pack = try GarrysPADContentPack(url: contentPackURL)
            bspData = try pack.data(
                for: "garrysmod/maps/\(configuration.map.rawValue).bsp"
            )
        } else {
            bspData = try GModGameAssets.data(
                for: configuration.map,
                kind: .bsp
            )
        }
        let loadedBSP = try SourceBSP(data: bspData)
        let loadedWorldMesh = try GModWorldRenderMesh.build(from: loadedBSP)
        let loadedSpawn = try Self.firstPlayerStart(
            in: loadedBSP,
            mapName: configuration.map.rawValue
        )
        let traceProvider = GMLuaSourceBSPTraceProvider(bsp: loadedBSP)
        let systemTime = GMLuaMonotonicSystemTimeSource()
        let session = GMLuaSharedSession()
        let serverFiles = try Self.makeMountedContentFileSystem()
        let clientFiles = try Self.makeMountedContentFileSystem()
        let environment = try GMLuaGameEnvironmentConfiguration(
            maxPlayers: configuration.maxPlayers,
            mapName: configuration.map.rawValue,
            sessionKind: .listenServer
        )
        let engine = GMLuaEngineConfiguration(
            games: [],
            isPlayingDemo: false,
            isRecordingDemo: false
        )
        let serverConVars = try GMLuaEngineConVarCatalog(descriptors: [
            GMLuaEngineConVarDescriptor(
                name: "mp_friendlyfire",
                defaultValue: "0"
            ),
        ])
        let clientConVars = try GMLuaEngineConVarCatalog(descriptors: [
            GMLuaEngineConVarDescriptor(
                name: "gmod_language",
                defaultValue: "en"
            ),
        ])
        let server = GMLuaRuntime(
            realm: .server,
            logger: { logger(.server, $0) },
            virtualFileSystem: serverFiles,
            bootstrapMode: .strict,
            textMeasurer: textMeasurer,
            gameEnvironmentConfiguration: environment,
            engineConfiguration: engine,
            engineConVarCatalog: serverConVars,
            netTransport: session.netTransport,
            traceProvider: traceProvider,
            systemTimeSource: systemTime,
            inputConfiguration: GMLuaInputConfiguration()
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { logger(.client, $0) },
            virtualFileSystem: clientFiles,
            bootstrapMode: .strict,
            initialViewport: configuration.initialViewport,
            textMeasurer: textMeasurer,
            gameEnvironmentConfiguration: environment,
            engineConfiguration: engine,
            engineConVarCatalog: clientConVars,
            netTransport: session.netTransport,
            traceProvider: traceProvider,
            systemTimeSource: systemTime,
            inputConfiguration: GMLuaInputConfiguration()
        )

        var adapter: GMLuaSourceRuntimeAdapter?
        do {
            server.consoleCommandDispatcher?.connectHost { invocation in
                guard invocation.command.caseInsensitiveCompare("mp_friendlyfire")
                    == .orderedSame else {
                    return .unhandled
                }
                if let value = invocation.arguments.first {
                    _ = serverConVars.setCurrentValue(
                        value,
                        for: "mp_friendlyfire"
                    )
                }
                return .handled
            }
            client.resourceRegistry?.setMaterialPixelResolver(
                GMLuaVPKMaterialPixelResolver(
                    looseFileSystem: clientFiles,
                    archivesInPriorityOrder: []
                )
            )

            let sourceAdapter = try GMLuaSourceRuntimeAdapter(
                serverRuntime: server
            )
            adapter = sourceAdapter
            try sourceAdapter.attach(client: client)
            let sourceWorldIdentity = try sourceAdapter.spawnNetworkableEntity(
                SourceEntity(className: "worldspawn"),
                at: 0
            )

            try server.loadFile("lua/includes/init.lua")
            let serverStartup = try GMLuaStartupOrchestrator(
                runtime: server,
                fileSystem: serverFiles
            ).start(targetGamemodeNamed: trimmedGamemode)

            try client.loadFile("lua/includes/init.lua")
            let clientStartup = try GMLuaStartupOrchestrator(
                runtime: client,
                fileSystem: clientFiles,
                playerConnection: {
                    try session.connect(
                        server: server,
                        client: client,
                        playerIndex: configuration.playerEntityIndex,
                        userID: configuration.playerUserID
                    )
                }
            ).start(targetGamemodeNamed: trimmedGamemode)
            let delivered = try Self.drain(
                session,
                maximumDeliveries: 10_000
            )

            self.configuration = configuration
            serverRuntime = server
            clientRuntime = client
            sharedSession = session
            self.sourceAdapter = sourceAdapter
            bsp = loadedBSP
            worldMesh = loadedWorldMesh
            worldIdentity = sourceWorldIdentity
            spawnPoint = loadedSpawn
            worldWalkSolver = SourceWorldWalkSolver(
                collisionProvider: worldWalkCollisionProvider ??
                    SourceBSPWorldWalkCollisionProvider(bsp: loadedBSP)
            )
            playerWalkState = SourceWorldWalkState(
                origin: loadedSpawn.origin,
                viewAngles: loadedSpawn.angles
            )
            serverFileSystem = serverFiles
            clientFileSystem = clientFiles
            startupReport = GModPlayableSessionStartupReport(
                map: configuration.map,
                spawnPoint: loadedSpawn,
                worldIdentity: sourceWorldIdentity,
                serverStartup: serverStartup,
                clientStartup: clientStartup,
                deliveredMessages: delivered
            )
        } catch {
            if session.connectedClientCount > 0 {
                try? session.disconnect(client: client)
            }
            try? adapter?.close()
            _ = client.close()
            _ = server.close()
            throw error
        }
    }

    deinit {
        _ = try? close()
    }

    public var isClosed: Bool { closedStorage }

    /// Publishes the host-selected digital button word to both realm-local
    /// Player mirrors. Analog movement is intentionally not interpreted here.
    public func updateCurrentPlayerInputButtons(
        _ buttons: SourceInputButtons
    ) throws {
        try ensureOpen()
        try sharedSession.updatePlayerInputButtons(
            for: clientRuntime,
            buttons: buttons
        )
    }

    /// Runs one Source SERVER fixed tick, drains its queued realm traffic, and
    /// then advances the CLIENT fixed tick. Render-frame Think stays separate.
    @discardableResult
    public func runFixedTick(
        movementInput: GModPlayableMovementInput = .idle,
        maximumDeliveries: Int = 10_000
    ) throws -> GModPlayableFixedTickReport {
        try ensureOpen()
        let commandNumber = nextCommandNumber
        let stateBeforeMovement = playerWalkState
        let command = SourceUserCommand(
            commandNumber: commandNumber,
            tickCount: commandNumber,
            viewAngles: movementInput.viewAngles ?? stateBeforeMovement.viewAngles,
            forwardMove: movementInput.forwardMove,
            sideMove: movementInput.sideMove,
            buttons: movementInput.buttons
        )
        let movement: GModPlayableMovementResult
        do {
            let tick = try worldWalkSolver.simulate(
                state: stateBeforeMovement,
                command: command
            )
            playerWalkState = tick.state
            movement = .advanced(tick)
        } catch let error as SourceWorldWalkError {
            guard let reason = error.recoverableUnsupportedReason else {
                throw error
            }
            movement = .rejected(GModPlayableMovementRejection(
                commandNumber: commandNumber,
                reason: reason,
                preservedState: stateBeforeMovement
            ))
        }
        nextCommandNumber &+= 1
        try updateCurrentPlayerInputButtons(movementInput.buttons)
        let serverReport = try sourceAdapter.runServerFixedTick()
        let delivery = try Self.drainReportingForwardedConsoleFailures(
            sharedSession,
            maximumDeliveries: maximumDeliveries
        )
        let clientReport = try sourceAdapter.runClientFixedTick()
        return GModPlayableFixedTickReport(
            movement: movement,
            server: serverReport,
            client: clientReport,
            deliveredMessages: delivery.successfulDeliveries,
            actionFailures: delivery.actionFailures
        )
    }

    /// Dispatches CLIENT Think once for a host render frame. This deliberately
    /// does not advance the fixed timer or pump packets.
    @discardableResult
    public func runClientFrame() throws -> GMLuaSourceRuntimeRunReport {
        try ensureOpen()
        return try sourceAdapter.runClientFrame()
    }

    /// Paints the live CLIENT VGUI tree into renderer-neutral surface
    /// commands using the same registry, surface state, and viewport exposed
    /// to the bundled Sandbox Lua runtime.
    public func renderClientVGUIFrame() throws -> GMLuaSurfaceFrameSnapshot {
        try ensureOpen()
        let registry = try clientVGUIRegistry()
        guard let surface = clientRuntime.surfaceCommandState else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "surface command state"
            )
        }
        guard let viewport = clientRuntime.screenMetrics?.viewport else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "screen metrics"
            )
        }
        return try registry.renderFrame(
            surface: surface,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
    }

    /// Routes one value-only host pointer sample through the live CLIENT VGUI
    /// hit-test and original Lua callbacks.
    public func dispatchClientVGUIPointerEvent(
        x: Double,
        y: Double,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval
    ) throws -> GMLuaPointerDispatchResult {
        try ensureOpen()
        let registry = try clientVGUIRegistry()
        guard let viewport = clientRuntime.screenMetrics?.viewport else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "screen metrics"
            )
        }
        return try registry.dispatchPointerEvent(
            x: x,
            y: y,
            phase: phase,
            timestamp: timestamp,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
    }

    /// Inserts UTF-8 text into the currently focused CLIENT TextEntry. A nil
    /// result means no eligible focused TextEntry existed; it is not promoted
    /// to a fabricated successful edit.
    public func insertClientVGUIText(_ text: String) throws -> Int? {
        try ensureOpen()
        return try clientVGUIRegistry().insertText(text)
    }

    /// Dispatches the stock CLIENT spawn-menu lifecycle hook used by GMod's
    /// `+menu`/`-menu` commands. Visibility remains owned by Sandbox Lua.
    public func setSpawnMenuOpen(_ isOpen: Bool) throws {
        try ensureOpen()
        try clientRuntime.dispatchHostHook(
            named: isOpen ? "OnSpawnMenuOpen" : "OnSpawnMenuClose"
        )
    }

    @discardableResult
    public func updateViewport(width: Int, height: Int) throws -> Bool {
        try ensureOpen()
        return clientRuntime.updateViewport(width: width, height: height)
    }

    /// Explicitly tears down player transport, Source mirrors, and both Lua
    /// states. The method is idempotent and must run outside Lua callbacks.
    @discardableResult
    public func close() throws -> GModPlayableSessionCloseReport {
        if closedStorage {
            return GModPlayableSessionCloseReport(
                clientFinalizerErrors: [],
                serverFinalizerErrors: []
            )
        }
        if sharedSession.connectedClientCount > 0 {
            try sharedSession.disconnect(client: clientRuntime)
        }
        try sourceAdapter.close()
        let clientReport = clientRuntime.close()
        let serverReport = serverRuntime.close()
        closedStorage = true
        return GModPlayableSessionCloseReport(
            clientFinalizerErrors: clientReport.errorMessages,
            serverFinalizerErrors: serverReport.errorMessages
        )
    }

    private func ensureOpen() throws {
        guard !closedStorage,
              !serverRuntime.isClosed,
              !clientRuntime.isClosed else {
            throw GModPlayableSessionError.closed
        }
    }

    private func clientVGUIRegistry() throws -> GMLuaVGUIRegistry {
        guard let registry = clientRuntime.vguiRegistry else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "VGUI registry"
            )
        }
        return registry
    }

    private static func makeMountedContentFileSystem() throws
        -> GMLuaMountedFileSystem
    {
        let bundled = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let writable = try LuaMemoryFileSystem()
        return GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "runtime-data",
                priority: 1_000,
                writable: true,
                fileSystem: writable
            ),
            try GMLuaFileMount(
                name: "bundled-gmod-base",
                priority: 0,
                writable: false,
                fileSystem: bundled
            ),
        ])
    }

    private static func drain(
        _ session: GMLuaSharedSession,
        maximumDeliveries: Int
    ) throws -> Int {
        guard maximumDeliveries >= 0 else {
            throw GModPlayableSessionError.deliveryLimitExceeded(
                maximumDeliveries
            )
        }
        var delivered = 0
        while session.netTransport.pendingDeliveryCount > 0 {
            guard delivered < maximumDeliveries else {
                throw GModPlayableSessionError.deliveryLimitExceeded(
                    maximumDeliveries
                )
            }
            let remaining = maximumDeliveries - delivered
            let step = try session.pump(maxDeliveries: remaining)
            guard step > 0 else {
                throw GModPlayableSessionError.deliveryStalled(
                    session.netTransport.pendingDeliveryCount
                )
            }
            delivered += step
        }
        return delivered
    }

    private struct ReportedDeliveryDrain {
        let successfulDeliveries: Int
        let actionFailures: [GMLuaForwardedConsoleCommandFailure]
    }

    /// Gameplay input may legitimately request a SERVER action whose host API
    /// is not implemented yet. Such a command packet is consumed and reported
    /// without preventing the paired CLIENT fixed tick. Transport, lifecycle,
    /// and net callback errors continue to escape this boundary.
    private static func drainReportingForwardedConsoleFailures(
        _ session: GMLuaSharedSession,
        maximumDeliveries: Int
    ) throws -> ReportedDeliveryDrain {
        guard maximumDeliveries >= 0 else {
            throw GModPlayableSessionError.deliveryLimitExceeded(
                maximumDeliveries
            )
        }
        var processed = 0
        var successful = 0
        var actionFailures: [GMLuaForwardedConsoleCommandFailure] = []
        while session.netTransport.pendingDeliveryCount > 0 {
            guard processed < maximumDeliveries else {
                throw GModPlayableSessionError.deliveryLimitExceeded(
                    maximumDeliveries
                )
            }
            let step = try session
                .pumpReportingForwardedConsoleFailures(
                    maxDeliveries: maximumDeliveries - processed
                )
            guard step.processedDeliveries > 0 else {
                if session.netTransport.pendingDeliveryCount == 0 { break }
                throw GModPlayableSessionError.deliveryStalled(
                    session.netTransport.pendingDeliveryCount
                )
            }
            processed += step.processedDeliveries
            successful += step.successfulDeliveries
            actionFailures.append(contentsOf: step.forwardedConsoleFailures)
        }
        return ReportedDeliveryDrain(
            successfulDeliveries: successful,
            actionFailures: actionFailures
        )
    }

    private static func firstPlayerStart(
        in bsp: SourceBSP,
        mapName: String
    ) throws -> GModMapSpawnPoint {
        guard let text = bsp.entities.text else {
            throw GModPlayableSessionError.missingEntityText(mapName)
        }
        var parser = SourceEntityLumpParser(text)
        for entity in try parser.parse() {
            guard entity["classname"] == "info_player_start" else { continue }
            guard let rawOrigin = entity["origin"] else {
                throw GModPlayableSessionError.malformedPlayerStart("<missing>")
            }
            let components = rawOrigin.split(whereSeparator: \.isWhitespace)
            guard components.count == 3,
                  let x = Float(components[0]),
                  let y = Float(components[1]),
                  let z = Float(components[2]),
                  x.isFinite,
                  y.isFinite,
                  z.isFinite else {
                throw GModPlayableSessionError.malformedPlayerStart(rawOrigin)
            }
            let angles: SourceQAngle
            if let rawAngles = entity["angles"] {
                let angleComponents = rawAngles.split(whereSeparator: \.isWhitespace)
                guard angleComponents.count == 3,
                      let pitch = Float(angleComponents[0]),
                      let yaw = Float(angleComponents[1]),
                      let roll = Float(angleComponents[2]),
                      pitch.isFinite,
                      yaw.isFinite,
                      roll.isFinite else {
                    throw GModPlayableSessionError.malformedPlayerStart(rawAngles)
                }
                angles = SourceQAngle(pitch: pitch, yaw: yaw, roll: roll)
            } else {
                angles = .zero
            }
            return GModMapSpawnPoint(
                origin: SourceVector3(x, y, z),
                angles: angles
            )
        }
        throw GModPlayableSessionError.missingPlayerStart(mapName)
    }
}

private struct SourceEntityLumpParser {
    private enum Token: Equatable {
        case open
        case close
        case string(String)
    }

    private let source: String
    private var index: String.Index

    init(_ source: String) {
        self.source = source
        index = source.startIndex
    }

    mutating func parse() throws -> [[String: String]] {
        var entities: [[String: String]] = []
        while let token = try nextToken() {
            guard token == .open else { continue }
            var entity: [String: String] = [:]
            while let keyToken = try nextToken() {
                if keyToken == .close { break }
                guard case let .string(key) = keyToken,
                      case let .string(value)? = try nextToken() else {
                    throw GModPlayableSessionError.malformedPlayerStart(
                        "malformed BSP entity key/value block"
                    )
                }
                entity[key] = value
            }
            entities.append(entity)
        }
        return entities
    }

    private mutating func nextToken() throws -> Token? {
        skipWhitespace()
        guard index < source.endIndex else { return nil }
        switch source[index] {
        case "{":
            source.formIndex(after: &index)
            return .open
        case "}":
            source.formIndex(after: &index)
            return .close
        case "\"":
            source.formIndex(after: &index)
            var value = ""
            while index < source.endIndex {
                let character = source[index]
                source.formIndex(after: &index)
                if character == "\"" { return .string(value) }
                if character == "\\", index < source.endIndex {
                    value.append(source[index])
                    source.formIndex(after: &index)
                } else {
                    value.append(character)
                }
            }
            throw GModPlayableSessionError.malformedPlayerStart(
                "unterminated BSP entity string"
            )
        default:
            let start = index
            while index < source.endIndex,
                  !source[index].isWhitespace,
                  source[index] != "{",
                  source[index] != "}" {
                source.formIndex(after: &index)
            }
            return .string(String(source[start..<index]))
        }
    }

    private mutating func skipWhitespace() {
        while index < source.endIndex, source[index].isWhitespace {
            source.formIndex(after: &index)
        }
    }
}

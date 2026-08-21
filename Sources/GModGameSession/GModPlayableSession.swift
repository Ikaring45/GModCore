import Foundation
import GModEngine
import GModGameAssets
import GModLua

/// Value-only loading boundaries shared by the session lane, Apple host, and
/// deterministic tests. Each case means every preceding unit has completed;
/// no value is inferred from elapsed time.
public enum GModPlayableSessionLoadingStage: Int, CaseIterable, Sendable,
    Equatable
{
    case readingBSP
    case parsingWorld
    case buildingWorldGeometry
    case preparingCollision
    case startingServerLua
    case loadingServerSandbox
    case startingClientLua
    case loadingClientSandbox
    case preparingMaterials
    case awaitingFirstMetalFrame
    case complete

    public static var totalUnitCount: Int { allCases.count - 1 }

    public var completedUnitCount: Int { rawValue }

    /// Stable diagnostic identifier. Presentation layers map this stage to a
    /// source-backed localized phrase rather than displaying this value.
    public var taskIdentifier: String {
        switch self {
        case .readingBSP:
            return "read-bsp"
        case .parsingWorld:
            return "parse-world"
        case .buildingWorldGeometry:
            return "build-world-geometry"
        case .preparingCollision:
            return "prepare-collision"
        case .startingServerLua:
            return "start-server-lua"
        case .loadingServerSandbox:
            return "load-server-gamemode"
        case .startingClientLua:
            return "start-client-lua"
        case .loadingClientSandbox:
            return "load-client-gamemode"
        case .preparingMaterials:
            return "prepare-materials-textures"
        case .awaitingFirstMetalFrame:
            return "await-first-metal-frame"
        case .complete:
            return "complete"
        }
    }
}

public struct GModPlayableSessionLoadingProgress: Sendable, Equatable {
    public let stage: GModPlayableSessionLoadingStage
    /// Real resource completion inside the first-frame stage. Both values are
    /// nil outside that stage; elapsed time is never converted into progress.
    public let completedSubunitCount: Int?
    public let totalSubunitCount: Int?

    public init(
        stage: GModPlayableSessionLoadingStage,
        completedSubunitCount: Int? = nil,
        totalSubunitCount: Int? = nil
    ) {
        self.stage = stage
        if stage == .awaitingFirstMetalFrame,
           let completedSubunitCount,
           let totalSubunitCount,
           completedSubunitCount >= 0,
           totalSubunitCount > 0,
           completedSubunitCount <= totalSubunitCount {
            self.completedSubunitCount = completedSubunitCount
            self.totalSubunitCount = totalSubunitCount
        } else {
            self.completedSubunitCount = nil
            self.totalSubunitCount = nil
        }
    }

    public static let initial = GModPlayableSessionLoadingProgress(
        stage: .readingBSP
    )

    public var completedUnitCount: Int { stage.completedUnitCount }
    public var totalUnitCount: Int {
        GModPlayableSessionLoadingStage.totalUnitCount
    }
    public var fractionCompleted: Double {
        let completed = Double(completedUnitCount)
        guard stage == .awaitingFirstMetalFrame,
              let completedSubunitCount,
              let totalSubunitCount else {
            return completed / Double(totalUnitCount)
        }
        // A fully uploaded scene still needs a successfully completed Metal
        // command buffer. Keep the truthful pre-presentation ceiling below 1.
        let subunitFraction = Swift.min(
            0.99,
            Double(completedSubunitCount) / Double(totalSubunitCount)
        )
        return (completed + subunitFraction) / Double(totalUnitCount)
    }
    public var percentComplete: Int {
        Int((fractionCompleted * 100).rounded(.down))
    }
    public var taskIdentifier: String { stage.taskIdentifier }
}

public typealias GModPlayableSessionLoadingProgressHandler =
    @Sendable (GModPlayableSessionLoadingProgress) -> Void

/// Pure monotonic reducer used at the MainActor publication boundary. A
/// failure records its description without manufacturing another completed
/// unit, and 100% is admitted only from the real first-frame wait boundary.
public struct GModPlayableSessionLoadingState: Sendable, Equatable {
    public private(set) var progress: GModPlayableSessionLoadingProgress
    public private(set) var failureDescription: String?

    public init(
        progress: GModPlayableSessionLoadingProgress = .initial,
        failureDescription: String? = nil
    ) {
        self.progress = progress
        self.failureDescription = failureDescription
    }

    @discardableResult
    public mutating func record(
        _ replacement: GModPlayableSessionLoadingProgress
    ) -> Bool {
        guard failureDescription == nil else {
            return false
        }
        if replacement.stage == progress.stage {
            guard replacement.stage == .awaitingFirstMetalFrame,
                  replacement.fractionCompleted >= progress.fractionCompleted,
                  replacement != progress,
                  progress.completedSubunitCount == nil ||
                    replacement.fractionCompleted > progress.fractionCompleted
            else { return false }
            progress = replacement
            return true
        }
        guard replacement.completedUnitCount > progress.completedUnitCount else {
            return false
        }
        if replacement.stage == .awaitingFirstMetalFrame {
            guard progress.stage.rawValue >=
                    GModPlayableSessionLoadingStage.preparingMaterials.rawValue
            else { return false }
        }
        if replacement.stage == .complete {
            guard progress.stage == .awaitingFirstMetalFrame else { return false }
        }
        progress = replacement
        return true
    }

    public mutating func fail(_ description: String) {
        guard failureDescription == nil else { return }
        failureDescription = description
    }
}

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
    public let languageCode: String
    public let languagePhrases: [String: String]
    public let hostName: String

    public init(
        map: GModBundledMap = .construct,
        gamemodeName: String = "sandbox",
        maxPlayers: Int = 32,
        playerEntityIndex: Int = 1,
        playerUserID: Int = 1,
        initialViewport: GMLuaViewportSize = .logicalDesktopDefault,
        contentPackURL: URL? = nil,
        languageCode: String = "en",
        languagePhrases: [String: String] = [:],
        hostName: String = "Garry's PAD"
    ) {
        self.map = map
        self.gamemodeName = gamemodeName
        self.maxPlayers = maxPlayers
        self.playerEntityIndex = playerEntityIndex
        self.playerUserID = playerUserID
        self.initialViewport = initialViewport
        self.contentPackURL = contentPackURL
        self.languageCode = languageCode
        self.languagePhrases = languagePhrases
        self.hostName = hostName
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

/// Evidence that one exact host button word was committed to the canonical
/// SERVER Player and every connected CLIENT mirror. The shared-session update
/// throws before this value is returned if either realm surface is unavailable.
public struct GModPlayableInputButtonReport: Equatable, Sendable {
    public let buttons: SourceInputButtons
    public let serverMirrorUpdated: Bool
    public let updatedClientMirrorCount: Int

    public init(
        buttons: SourceInputButtons,
        serverMirrorUpdated: Bool,
        updatedClientMirrorCount: Int
    ) {
        self.buttons = buttons
        self.serverMirrorUpdated = serverMirrorUpdated
        self.updatedClientMirrorCount = updatedClientMirrorCount
    }
}

public struct GModPlayableFixedTickReport: Equatable, Sendable {
    public let movement: GModPlayableMovementResult
    public let inputButtons: GModPlayableInputButtonReport
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
    case invalidLanguageCode(String)
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
        case let .invalidLanguageCode(value):
            return "invalid language code: \(value)"
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
    public let studioModelRepository: GModStudioModelRepository?
    public let attestedPropPhysicsAssetResolver:
        GModAttestedPropPhysicsAssetResolver?
    public let bsp: SourceBSP
    public let worldMesh: GModWorldRenderMesh
    public let worldIdentity: GMLuaSourceEntityIdentity
    public let spawnPoint: GModMapSpawnPoint
    public let startupReport: GModPlayableSessionStartupReport

    private let serverFileSystem: GMLuaMountedFileSystem
    private let clientFileSystem: GMLuaMountedFileSystem
    private let worldWalkSolver: SourceWorldWalkSolver
    private let playerIdentity: SourceCanonicalEntityIdentity
    private let studioRenderableModelCache: GModStudioRenderableModelCache?
    private let dynamicEntityRenderSceneProjector:
        GModDynamicEntityRenderSceneProjector?
    private var nextCommandNumber: Int32 = 1
    private var closedStorage = false

    /// The host reads movement from the engine-owned canonical Player. There
    /// is no second mutable session copy that can diverge from Entity/Player.
    public var playerWalkState: SourceWorldWalkState {
        guard let snapshot = sourceAdapter.canonicalSnapshot(
            for: playerIdentity
        ) else {
            preconditionFailure("canonical Player is unavailable")
        }
        return Self.playerWalkState(from: snapshot)
    }

    /// CLIENT-applied canonical state in Source entity-list order. Dynamic
    /// rendering consumes this replicated projection, never SERVER storage or
    /// Lua userdata directly.
    public var clientCanonicalEntitySnapshots: [SourceCanonicalEntitySnapshot] {
        clientRuntime.entityRegistry?.canonicalEntitySnapshots ?? []
    }

    /// Allocation-free change token for the CLIENT canonical projection.
    public var clientCanonicalEntityReplicationCursor:
        SourceEntityReplicationCursor?
    {
        clientRuntime.entityRegistry?.canonicalEntityReplicationCursor
    }

    public convenience init(
        configuration: GModPlayableSessionConfiguration = .init(),
        attestedPropPhysicsAssets: [SourceAttestedPropPhysicsAsset] = [],
        textMeasurer: (any GMLuaTextMeasurer)? = nil,
        logger: @escaping @Sendable (
            _ realm: GMLuaRealm,
            _ message: String
        ) -> Void = { _, _ in },
        progress: @escaping GModPlayableSessionLoadingProgressHandler = { _ in }
    ) throws {
        try self.init(
            configuration: configuration,
            textMeasurer: textMeasurer,
            logger: logger,
            progress: progress,
            worldWalkCollisionProvider: nil,
            attestedPropPhysicsAssets: attestedPropPhysicsAssets
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
        progress: @escaping GModPlayableSessionLoadingProgressHandler = { _ in },
        worldWalkCollisionProvider:
            (any SourceWorldWalkCollisionProvider)?,
        canonicalModelValidator: SourceCanonicalModelValidator? = nil,
        attestedPropPhysicsAssets: [SourceAttestedPropPhysicsAsset] = [],
        canonicalPropPhysicsAssetResolverForTesting:
            SourceCanonicalPropPhysicsAssetResolver? = nil,
        attestedPropPhysicsAssetResolverForTesting:
            GModAttestedPropPhysicsAssetResolver? = nil,
        studioModelRepositoryForTesting: GModStudioModelRepository? = nil,
        studioRenderableModelCacheForTesting:
            GModStudioRenderableModelCache? = nil
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
        guard Self.isValidLanguageCode(configuration.languageCode) else {
            throw GModPlayableSessionError.invalidLanguageCode(
                configuration.languageCode
            )
        }

        progress(.init(stage: .readingBSP))
        let mapAllocationPolicy = GModMapAllocationPolicy.iPadValidated
        let bspData: Data
        let loadedStudioModelRepository: GModStudioModelRepository?
        if let contentPackURL = configuration.contentPackURL {
            let pack = try GarrysPADContentPack(url: contentPackURL)
            bspData = try pack.data(
                for: "garrysmod/maps/\(configuration.map.rawValue).bsp",
                maximumByteCount:
                    mapAllocationPolicy.maximumBSPEncodedByteCount
            )
            loadedStudioModelRepository = GModStudioModelRepository(
                reader: try GModContentPackAssetSource(pack: pack)
            )
        } else {
            bspData = try GModGameAssets.data(
                for: configuration.map,
                kind: .bsp
            )
            loadedStudioModelRepository = studioModelRepositoryForTesting
        }
        let loadedAttestedPropPhysicsAssetResolver:
            GModAttestedPropPhysicsAssetResolver?
        if let attestedPropPhysicsAssetResolverForTesting {
            loadedAttestedPropPhysicsAssetResolver =
                attestedPropPhysicsAssetResolverForTesting
        } else if let loadedStudioModelRepository {
            loadedAttestedPropPhysicsAssetResolver = try
                GModAttestedPropPhysicsAssetResolver(
                    repository: loadedStudioModelRepository,
                    attestedAssets: attestedPropPhysicsAssets
                )
        } else {
            loadedAttestedPropPhysicsAssetResolver = nil
        }
        let loadedStudioRenderableModelCache: GModStudioRenderableModelCache?
        let loadedDynamicEntityRenderSceneProjector:
            GModDynamicEntityRenderSceneProjector?
        if let loadedStudioModelRepository {
            let cache = try studioRenderableModelCacheForTesting ??
                GModStudioRenderableModelCache(
                    repository: loadedStudioModelRepository
                )
            loadedStudioRenderableModelCache = cache
            loadedDynamicEntityRenderSceneProjector = try
                GModDynamicEntityRenderSceneProjector(resolver: cache)
        } else {
            loadedStudioRenderableModelCache = nil
            loadedDynamicEntityRenderSceneProjector = nil
        }
        try mapAllocationPolicy.validate(
            .bspEncodedBytes,
            requestedByteCount: UInt64(bspData.count)
        )
        progress(.init(stage: .parsingWorld))
        let loadedBSP = try SourceBSP(data: bspData)
        progress(.init(stage: .buildingWorldGeometry))
        let loadedWorldMesh = try GModWorldRenderMesh.build(
            from: loadedBSP,
            allocationPolicy: mapAllocationPolicy
        )
        progress(.init(stage: .preparingCollision))
        let loadedSpawn = try Self.firstPlayerStart(
            in: loadedBSP,
            mapName: configuration.map.rawValue
        )
        let traceProvider = GMLuaSourceBSPTraceProvider(bsp: loadedBSP)
        let loadedWorldWalkCollisionProvider:
            any SourceWorldWalkCollisionProvider =
                worldWalkCollisionProvider ??
                SourceBSPWorldWalkCollisionProvider(bsp: loadedBSP)
        progress(.init(stage: .startingServerLua))
        let systemTime = GMLuaMonotonicSystemTimeSource()
        let session = GMLuaSharedSession()
        let serverFiles = try Self.makeMountedContentFileSystem()
        let clientFiles = try Self.makeMountedContentFileSystem()
        let environment = try GMLuaGameEnvironmentConfiguration(
            maxPlayers: configuration.maxPlayers,
            mapName: configuration.map.rawValue,
            sessionKind: .listenServer,
            hostName: configuration.hostName
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
                defaultValue: configuration.languageCode
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
            inputConfiguration: GMLuaInputConfiguration(),
            languageConfiguration: GMLuaLanguageConfiguration(
                phrases: configuration.languagePhrases
            )
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

            let activeModelValidator: SourceCanonicalModelValidator?
            if let canonicalModelValidator {
                activeModelValidator = canonicalModelValidator
            } else if let loadedStudioModelRepository {
                activeModelValidator = { model, kind in
                    loadedStudioModelRepository.validation(
                        for: model,
                        kind: kind
                    )
                }
            } else {
                activeModelValidator = nil
            }
            let activeBodyGroupResolver: SourceCanonicalBodyGroupResolver?
            if let loadedStudioModelRepository {
                activeBodyGroupResolver = {
                    model,
                    subModelIDs,
                    currentBodyValue in
                    try loadedStudioModelRepository.bodyValue(
                        for: model,
                        applyingBodyGroups: subModelIDs,
                        to: currentBodyValue
                    )
                }
            } else {
                activeBodyGroupResolver = nil
            }
            let activePropPhysicsAssetResolver:
                SourceCanonicalPropPhysicsAssetResolver
            if let canonicalPropPhysicsAssetResolverForTesting {
                activePropPhysicsAssetResolver =
                    canonicalPropPhysicsAssetResolverForTesting
            } else {
                activePropPhysicsAssetResolver = { model in
                    guard let resolver =
                            loadedAttestedPropPhysicsAssetResolver else {
                        return .unavailable
                    }
                    return resolver.resolve(model).canonicalResolution
                }
            }
            let sourceAdapter = try GMLuaSourceRuntimeAdapter(
                serverRuntime: server,
                canonicalModelValidator: activeModelValidator,
                canonicalBodyGroupResolver: activeBodyGroupResolver,
                canonicalPropPhysicsAssetResolver:
                    activePropPhysicsAssetResolver
            )
            adapter = sourceAdapter
            try sourceAdapter.installCanonicalEntityLuaBridge()
            try sourceAdapter.installCanonicalPhysicsObjectLuaBridge()
            // This attachment owns only CLIENT Tick/Think clocking. The
            // adapter has no legacy entities in this session, and canonical
            // Entity state reaches CLIENT exclusively through SharedSession's
            // ordered replication FIFO.
            try sourceAdapter.attach(client: client)
            let createdSourceWorld = try sourceAdapter.createCanonicalEntity(
                kind: .world,
                at: 0
            )
            _ = try sourceAdapter.spawnCanonicalEntity(
                createdSourceWorld.identity
            )
            let sourceWorld = try sourceAdapter.activateCanonicalEntity(
                createdSourceWorld.identity
            )
            let sourceWorldIdentity = sourceWorld.identity

            try server.loadFile("lua/includes/init.lua")
            progress(.init(stage: .loadingServerSandbox))
            let serverStartup = try GMLuaStartupOrchestrator(
                runtime: server,
                fileSystem: serverFiles
            ).start(targetGamemodeNamed: trimmedGamemode)
            var playerState = SourceCanonicalEntityState.defaults(for: .player)
            playerState.applyPlayerWalkState(SourceWorldWalkState(
                origin: loadedSpawn.origin,
                viewAngles: loadedSpawn.angles
            ))
            let createdSourcePlayer = try sourceAdapter.createCanonicalEntity(
                kind: .player,
                at: configuration.playerEntityIndex,
                state: playerState,
                playerUserID: configuration.playerUserID
            )
            _ = try sourceAdapter.spawnCanonicalEntity(
                createdSourcePlayer.identity
            )
            let sourcePlayer = try sourceAdapter.activateCanonicalEntity(
                createdSourcePlayer.identity
            )
            progress(.init(stage: .startingClientLua))

            try client.loadFile("lua/includes/init.lua")
            progress(.init(stage: .loadingClientSandbox))
            var playerConnectionDeliveries = 0
            let clientStartup = try GMLuaStartupOrchestrator(
                runtime: client,
                fileSystem: clientFiles,
                playerConnection: {
                    try session.connectCanonical(
                        server: server,
                        client: client,
                        playerIdentity: sourcePlayer.identity,
                        userID: configuration.playerUserID,
                        authoritativeSnapshots:
                            sourceAdapter.canonicalEntitySnapshots
                    )
                    // The newly enqueued full snapshot already contains the
                    // active world and Player. Their construction journal is
                    // discarded only after enqueue succeeds, preventing both
                    // startup duplication and loss on connection failure.
                    _ = try sourceAdapter
                        .discardPendingCanonicalEntityOperations()
                    // StartupOrchestrator invokes this boundary after
                    // Initialize and before InitPostEntity. Pump the initial
                    // snapshot here so original CLIENT Lua observes the exact
                    // canonical world and LocalPlayer during InitPostEntity.
                    playerConnectionDeliveries += try Self.drain(
                        session,
                        maximumDeliveries: 10_000
                    )
                }
            ).start(targetGamemodeNamed: trimmedGamemode)
            let delivered = playerConnectionDeliveries + (try Self.drain(
                session,
                maximumDeliveries: 10_000
            ))
            progress(.init(stage: .preparingMaterials))

            self.configuration = configuration
            serverRuntime = server
            clientRuntime = client
            sharedSession = session
            self.sourceAdapter = sourceAdapter
            studioModelRepository = loadedStudioModelRepository
            attestedPropPhysicsAssetResolver =
                loadedAttestedPropPhysicsAssetResolver
            bsp = loadedBSP
            worldMesh = loadedWorldMesh
            worldIdentity = sourceWorldIdentity
            spawnPoint = loadedSpawn
            worldWalkSolver = SourceWorldWalkSolver(
                collisionProvider: loadedWorldWalkCollisionProvider
            )
            playerIdentity = sourcePlayer.identity
            serverFileSystem = serverFiles
            clientFileSystem = clientFiles
            studioRenderableModelCache = loadedStudioRenderableModelCache
            dynamicEntityRenderSceneProjector =
                loadedDynamicEntityRenderSceneProjector
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

    /// Projects only replicated CLIENT `prop_physics` entities into immutable
    /// renderer-neutral resources and instances. Player-only packets leave the
    /// prop cursor unchanged and therefore avoid both an entity-array copy and
    /// Studio cache work.
    public func clientDynamicEntityRenderScene(
        ifChangedFrom revision: UInt64?
    ) throws -> GModDynamicEntityRenderSceneSnapshot? {
        try ensureOpen()
        guard let projector = dynamicEntityRenderSceneProjector else {
            return nil
        }
        guard let registry = clientRuntime.entityRegistry else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "entity registry"
            )
        }
        if let projection = registry.canonicalEntityProjection(
            for: .propPhysics,
            ifChangedFrom: projector.sourceProjectionCursor
        ) {
            _ = try projector.update(from: projection)
        }
        return projector.snapshot(ifChangedFrom: revision)
    }

    /// Publishes the host-selected digital button word to both realm-local
    /// Player mirrors. Analog movement is intentionally not interpreted here.
    @discardableResult
    public func updateCurrentPlayerInputButtons(
        _ buttons: SourceInputButtons
    ) throws -> GModPlayableInputButtonReport {
        try ensureOpen()
        try sharedSession.updatePlayerInputButtons(
            for: clientRuntime,
            buttons: buttons
        )
        return GModPlayableInputButtonReport(
            buttons: buttons,
            serverMirrorUpdated: true,
            updatedClientMirrorCount: sharedSession.connectedClientCount
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
            if tick.state != stateBeforeMovement {
                _ = try sourceAdapter.updateCanonicalEntity(
                    playerIdentity
                ) { state in
                    state.applyPlayerWalkState(tick.state)
                }
            }
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
        let inputButtons = try updateCurrentPlayerInputButtons(
            movementInput.buttons
        )
        let serverReport = try sourceAdapter.runServerFixedTick()
        let delivery = try Self.drainReportingForwardedConsoleFailures(
            sharedSession,
            sourceAdapter: sourceAdapter,
            maximumDeliveries: maximumDeliveries
        )
        let clientReport = try sourceAdapter.runClientFixedTick()
        return GModPlayableFixedTickReport(
            movement: movement,
            inputButtons: inputButtons,
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

    /// Moves every retained CLIENT `surface.PlaySound` event into one bounded
    /// value report. The underlying surface state advances its sequence across
    /// drains, so a successful request can appear in exactly one host report.
    public func drainClientSurfaceSoundRequests() throws
        -> GMLuaSurfaceSoundRequestReport
    {
        try ensureOpen()
        guard let surface = clientRuntime.surfaceCommandState else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "surface command state"
            )
        }
        return surface.drainSoundRequestReport()
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
        guard let input = clientRuntime.input else {
            throw GModPlayableSessionError.missingRuntimeSurface(
                .client,
                "input"
            )
        }
        input.updateCursorPosition(x: x, y: y)
        let releasesLeftMouse: Bool
        switch phase {
        case .began:
            input.updateMouseButton(GMLuaInput.leftMouseButton, isDown: true)
            releasesLeftMouse = false
        case .ended, .cancelled:
            releasesLeftMouse = true
        case .moved, .scroll:
            releasesLeftMouse = false
        }
        defer {
            if releasesLeftMouse {
                // This release must survive a throwing Lua callback; otherwise
                // input.IsMouseDown can remain stuck across a retired pointer
                // epoch even though VGUI capture has already been cleared.
                input.updateMouseButton(
                    GMLuaInput.leftMouseButton,
                    isDown: false
                )
            }
        }
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

    /// Dispatches the stock CLIENT context-menu lifecycle used by GMod's
    /// `+menu_context`/`-menu_context` commands. Sandbox Lua remains the sole
    /// owner of `g_ContextMenu` visibility and contents.
    public func setContextMenuOpen(_ isOpen: Bool) throws {
        try ensureOpen()
        try clientRuntime.dispatchHostHook(
            named: isOpen ? "OnContextMenuOpen" : "OnContextMenuClose"
        )
    }

    /// Mirrors the engine notification sent before the in-game Home UI is
    /// shown. Stock Sandbox uses this hook to close both spawn-menu surfaces.
    public func notifyPauseMenuWillShow() throws {
        try ensureOpen()
        try clientRuntime.dispatchHostHook(named: "OnPauseMenuShow")
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
        _ = try dynamicEntityRenderSceneProjector?.reset()
        studioRenderableModelCache?.removeAll()
        studioModelRepository?.removeAllCachedAssets()
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

    private static func isValidLanguageCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 32,
              let first = value.unicodeScalars.first,
              isASCIILetter(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIILetter(scalar) ||
                (scalar.value >= 48 && scalar.value <= 57) ||
                scalar == "-" || scalar == "_"
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func playerWalkState(
        from snapshot: SourceCanonicalEntitySnapshot
    ) -> SourceWorldWalkState {
        SourceCanonicalEntityState(
            transform: snapshot.transform,
            motion: snapshot.motion,
            model: snapshot.model,
            solidType: snapshot.solidType,
            moveType: snapshot.moveType
        ).playerWalkState
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
        sourceAdapter: GMLuaSourceRuntimeAdapter,
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
        while session.netTransport.pendingDeliveryCount > 0 ||
            sourceAdapter.pendingCanonicalEntityOperationCount > 0
        {
            _ = try sourceAdapter.publishPendingCanonicalEntityOperations {
                try session.publishCanonicalEntityUpdates($0)
            }
            if session.netTransport.pendingDeliveryCount == 0 { continue }
            guard processed < maximumDeliveries else {
                throw GModPlayableSessionError.deliveryLimitExceeded(
                    maximumDeliveries
                )
            }
            let step = try session
                .pumpReportingForwardedConsoleFailures(
                    maxDeliveries: 1
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

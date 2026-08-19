import GModEngine

public struct GModPlayableSessionSnapshot: Sendable, Equatable {
    public let generation: UInt64
    public let startup: GModPlayableSessionStartupReport
    public let worldMesh: GModWorldRenderMesh
    public let playerWalkState: SourceWorldWalkState

    public init(
        generation: UInt64,
        startup: GModPlayableSessionStartupReport,
        worldMesh: GModWorldRenderMesh,
        playerWalkState: SourceWorldWalkState
    ) {
        self.generation = generation
        self.startup = startup
        self.worldMesh = worldMesh
        self.playerWalkState = playerWalkState
    }
}

public struct GModPlayableHostFrameReport: Sendable, Equatable {
    public let fixedTicks: [GModPlayableFixedTickReport]
    public let clientFrame: GMLuaSourceRuntimeRunReport?
    public let viewportChanged: Bool
    public let playerWalkState: SourceWorldWalkState

    public init(
        fixedTicks: [GModPlayableFixedTickReport],
        clientFrame: GMLuaSourceRuntimeRunReport?,
        viewportChanged: Bool,
        playerWalkState: SourceWorldWalkState
    ) {
        self.fixedTicks = fixedTicks
        self.clientFrame = clientFrame
        self.viewportChanged = viewportChanged
        self.playerWalkState = playerWalkState
    }

    public var deliveredMessages: Int {
        fixedTicks.reduce(0) { $0 + $1.deliveredMessages }
    }
}

public enum GModPlayableSessionLaneError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case notStarted
    case invalidFixedTickCount(Int)
    case unsupportedExecutionRealm(GMLuaRealm)
    case staleGeneration(expected: UInt64, actual: UInt64)

    public var description: String {
        switch self {
        case .notStarted:
            return "playable session lane has not started"
        case let .invalidFixedTickCount(value):
            return "playable session lane received invalid fixed tick count \(value)"
        case let .unsupportedExecutionRealm(realm):
            return "playable session lane cannot execute source in \(realm.rawValue)"
        case let .staleGeneration(expected, actual):
            return "playable session lane generation is \(actual), expected \(expected)"
        }
    }
}

/// Serialized ownership boundary for the non-Sendable Lua and Source runtime
/// graph. Apple UI code may await this actor without blocking MainActor; no
/// runtime, userdata, BSP provider, or transport endpoint crosses the actor.
public actor GModPlayableSessionLane {
    private let textMeasurer: (any GMLuaTextMeasurer)?
    private var session: GModPlayableSession?
    private var generation: UInt64 = 0

    public init(textMeasurer: (any GMLuaTextMeasurer)? = nil) {
        self.textMeasurer = textMeasurer
    }

    @discardableResult
    public func start(
        configuration: GModPlayableSessionConfiguration = .init(),
        logger: @escaping @Sendable (
            _ realm: GMLuaRealm,
            _ message: String
        ) -> Void = { _, _ in }
    ) throws -> GModPlayableSessionSnapshot {
        generation &+= 1
        if let prior = session {
            _ = try prior.close()
            session = nil
        }
        let replacement = try GModPlayableSession(
            configuration: configuration,
            textMeasurer: textMeasurer,
            logger: logger
        )
        session = replacement
        return GModPlayableSessionSnapshot(
            generation: generation,
            startup: replacement.startupReport,
            worldMesh: replacement.worldMesh,
            playerWalkState: replacement.playerWalkState
        )
    }

    @discardableResult
    public func runHostFrame(
        fixedTickCount: Int,
        renderClientFrame: Bool = true,
        viewport: GMLuaViewportSize? = nil,
        movementInput: GModPlayableMovementInput = .idle,
        expectedGeneration: UInt64? = nil,
        maximumDeliveries: Int = 10_000
    ) throws -> GModPlayableHostFrameReport {
        guard fixedTickCount >= 0 else {
            throw GModPlayableSessionLaneError.invalidFixedTickCount(
                fixedTickCount
            )
        }
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        let viewportChanged: Bool
        if let viewport {
            viewportChanged = try session.updateViewport(
                width: viewport.width,
                height: viewport.height
            )
        } else {
            viewportChanged = false
        }

        var fixedTicks: [GModPlayableFixedTickReport] = []
        fixedTicks.reserveCapacity(fixedTickCount)
        for _ in 0..<fixedTickCount {
            fixedTicks.append(
                try session.runFixedTick(
                    movementInput: movementInput,
                    maximumDeliveries: maximumDeliveries
                )
            )
        }
        let clientFrame = renderClientFrame
            ? try session.runClientFrame()
            : nil
        return GModPlayableHostFrameReport(
            fixedTicks: fixedTicks,
            clientFrame: clientFrame,
            viewportChanged: viewportChanged,
            playerWalkState: session.playerWalkState
        )
    }

    public func execute(
        _ source: String,
        realm: GMLuaRealm = .server,
        sourceName: String = "=(ipad-console)",
        expectedGeneration: UInt64? = nil
    ) throws {
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        switch realm {
        case .server:
            try session.serverRuntime.execute(source, sourceName: sourceName)
        case .client:
            try session.clientRuntime.execute(source, sourceName: sourceName)
        case .menu:
            throw GModPlayableSessionLaneError.unsupportedExecutionRealm(realm)
        }
    }

    @discardableResult
    public func close() throws -> GModPlayableSessionCloseReport {
        guard let prior = session else {
            return GModPlayableSessionCloseReport(
                clientFinalizerErrors: [],
                serverFinalizerErrors: []
            )
        }
        let report = try prior.close()
        session = nil
        generation &+= 1
        return report
    }

    private func validate(expectedGeneration: UInt64?) throws {
        guard let expectedGeneration else { return }
        guard expectedGeneration == generation else {
            throw GModPlayableSessionLaneError.staleGeneration(
                expected: expectedGeneration,
                actual: generation
            )
        }
    }
}

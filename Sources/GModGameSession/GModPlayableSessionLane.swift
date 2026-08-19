import Foundation
import GModEngine

public struct GModPlayableSessionSnapshot: Sendable, Equatable {
    public let generation: UInt64
    public let pointerEpoch: UInt64
    public let inputEpoch: UInt64
    public let startup: GModPlayableSessionStartupReport
    public let worldMesh: GModWorldRenderMesh
    public let playerWalkState: SourceWorldWalkState

    public init(
        generation: UInt64,
        pointerEpoch: UInt64,
        inputEpoch: UInt64,
        startup: GModPlayableSessionStartupReport,
        worldMesh: GModWorldRenderMesh,
        playerWalkState: SourceWorldWalkState
    ) {
        self.generation = generation
        self.pointerEpoch = pointerEpoch
        self.inputEpoch = inputEpoch
        self.startup = startup
        self.worldMesh = worldMesh
        self.playerWalkState = playerWalkState
    }
}

/// Result of an actor-serialized input boundary. Advancing the independent
/// pointer and frame-input epochs makes any sample admitted before this
/// boundary stale inside the actor itself, including work that a host mailbox
/// already popped for delivery.
public struct GModPlayableInputBoundaryReport: Sendable, Equatable {
    public let pointerEpoch: UInt64
    public let inputEpoch: UInt64
    public let cancelledActivePointer: Bool
    public let cancellationFailure: String?
    public let lifecycleFailure: String?

    public init(
        pointerEpoch: UInt64,
        inputEpoch: UInt64,
        cancelledActivePointer: Bool,
        cancellationFailure: String?,
        lifecycleFailure: String? = nil
    ) {
        self.pointerEpoch = pointerEpoch
        self.inputEpoch = inputEpoch
        self.cancelledActivePointer = cancelledActivePointer
        self.cancellationFailure = cancellationFailure
        self.lifecycleFailure = lifecycleFailure
    }
}

public struct GModPlayableHostFrameReport: Sendable, Equatable {
    public let fixedTicks: [GModPlayableFixedTickReport]
    public let clientFrame: GMLuaSourceRuntimeRunReport?
    public let clientVGUIFrame: GMLuaSurfaceFrameSnapshot?
    public let viewportChanged: Bool
    public let playerWalkState: SourceWorldWalkState

    public init(
        fixedTicks: [GModPlayableFixedTickReport],
        clientFrame: GMLuaSourceRuntimeRunReport?,
        clientVGUIFrame: GMLuaSurfaceFrameSnapshot?,
        viewportChanged: Bool,
        playerWalkState: SourceWorldWalkState
    ) {
        self.fixedTicks = fixedTicks
        self.clientFrame = clientFrame
        self.clientVGUIFrame = clientVGUIFrame
        self.viewportChanged = viewportChanged
        self.playerWalkState = playerWalkState
    }

    public var deliveredMessages: Int {
        fixedTicks.reduce(0) { $0 + $1.deliveredMessages }
    }

    /// User actions rejected by the currently implemented SERVER API surface.
    /// These are values, not fatal lane errors; transport and adapter failures
    /// still escape ``runHostFrame``.
    public var actionFailures: [GMLuaForwardedConsoleCommandFailure] {
        fixedTicks.flatMap(\.actionFailures)
    }
}

public enum GModPlayableSessionLaneError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case notStarted
    case invalidFixedTickCount(Int)
    case unsupportedExecutionRealm(GMLuaRealm)
    case staleGeneration(expected: UInt64, actual: UInt64)
    case stalePointerEpoch(expected: UInt64, actual: UInt64)
    case staleInputEpoch(expected: UInt64, actual: UInt64)

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
        case let .stalePointerEpoch(expected, actual):
            return "playable session pointer epoch is \(actual), expected \(expected)"
        case let .staleInputEpoch(expected, actual):
            return "playable session input epoch is \(actual), expected \(expected)"
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
    private var pointerEpoch: UInt64 = 0
    private var inputEpoch: UInt64 = 0
    private var pointerGestureActive = false
    private var lastPointerLocation: (x: Double, y: Double)?

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
        pointerEpoch &+= 1
        inputEpoch &+= 1
        pointerGestureActive = false
        lastPointerLocation = nil
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
            pointerEpoch: pointerEpoch,
            inputEpoch: inputEpoch,
            startup: replacement.startupReport,
            worldMesh: replacement.worldMesh,
            playerWalkState: replacement.playerWalkState
        )
    }

    @discardableResult
    public func runHostFrame(
        fixedTickCount: Int,
        renderClientFrame: Bool = true,
        renderClientVGUIFrame: Bool = false,
        viewport: GMLuaViewportSize? = nil,
        movementInput: GModPlayableMovementInput = .idle,
        expectedGeneration: UInt64? = nil,
        expectedInputEpoch: UInt64? = nil,
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
        try validate(expectedInputEpoch: expectedInputEpoch)
        let viewportChanged: Bool
        if let viewport {
            viewportChanged = try session.updateViewport(
                width: viewport.width,
                height: viewport.height
            )
        } else {
            viewportChanged = false
        }

        // Host-frame input can change on a gesture-only frame with no fixed
        // tick. Publish the exact supplied digital word before CLIENT Think or
        // pointer work; do not derive button bits from the analog axes.
        try session.updateCurrentPlayerInputButtons(movementInput.buttons)

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
        let clientVGUIFrame = renderClientVGUIFrame
            ? try session.renderClientVGUIFrame()
            : nil
        return GModPlayableHostFrameReport(
            fixedTicks: fixedTicks,
            clientFrame: clientFrame,
            clientVGUIFrame: clientVGUIFrame,
            viewportChanged: viewportChanged,
            playerWalkState: session.playerWalkState
        )
    }

    public func renderClientVGUIFrame(
        expectedGeneration: UInt64? = nil
    ) throws -> GMLuaSurfaceFrameSnapshot {
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        return try session.renderClientVGUIFrame()
    }

    @discardableResult
    public func setSpawnMenuOpen(
        _ isOpen: Bool,
        cancelActivePointer: Bool = false,
        cancellationTimestamp: TimeInterval = 0,
        expectedGeneration: UInt64? = nil,
        expectedPointerEpoch: UInt64? = nil,
        expectedInputEpoch: UInt64? = nil
    ) throws -> GModPlayableInputBoundaryReport {
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        try validate(expectedPointerEpoch: expectedPointerEpoch)
        try validate(expectedInputEpoch: expectedInputEpoch)
        try session.updateCurrentPlayerInputButtons([])
        let cancellation = cancelActivePointer
            ? cancelPointerIfNeeded(
                in: session,
                timestamp: cancellationTimestamp
            )
            : (cancelled: false, failure: nil)

        // Retire capture state before the lifecycle callback. Pointer dispatch
        // clears registry capture before invoking Lua, and a throwing callback
        // must not leave this lane believing that it can cancel the same
        // gesture again on a retry.
        pointerGestureActive = false
        lastPointerLocation = nil
        pointerEpoch &+= 1
        inputEpoch &+= 1
        let lifecycleFailure: String?
        do {
            try session.setSpawnMenuOpen(isOpen)
            lifecycleFailure = nil
        } catch {
            lifecycleFailure = GMLuaRuntime.describe(error)
        }
        return GModPlayableInputBoundaryReport(
            pointerEpoch: pointerEpoch,
            inputEpoch: inputEpoch,
            cancelledActivePointer: cancellation.cancelled,
            cancellationFailure: cancellation.failure,
            lifecycleFailure: lifecycleFailure
        )
    }

    public func dispatchClientVGUIPointerEvent(
        x: Double,
        y: Double,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval,
        expectedGeneration: UInt64? = nil,
        expectedPointerEpoch: UInt64? = nil
    ) throws -> GMLuaPointerDispatchResult {
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        try validate(expectedPointerEpoch: expectedPointerEpoch)
        lastPointerLocation = (x: x, y: y)
        defer {
            switch phase {
            case .began:
                pointerGestureActive = true
            case .ended, .cancelled:
                pointerGestureActive = false
            case .moved, .scroll:
                break
            }
        }
        return try session.dispatchClientVGUIPointerEvent(
            x: x,
            y: y,
            phase: phase,
            timestamp: timestamp
        )
    }

    /// Immediately clears the realm-visible button word and atomically closes
    /// any delivered pointer gesture before advancing both input epochs. Stale
    /// mailbox samples and already-popped frame batches are rejected when they
    /// eventually enter this actor.
    @discardableResult
    public func suspendInput(
        cancellationTimestamp: TimeInterval,
        expectedGeneration: UInt64? = nil,
        expectedPointerEpoch: UInt64? = nil,
        expectedInputEpoch: UInt64? = nil
    ) throws -> GModPlayableInputBoundaryReport {
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        try validate(expectedPointerEpoch: expectedPointerEpoch)
        try validate(expectedInputEpoch: expectedInputEpoch)
        try session.updateCurrentPlayerInputButtons([])
        let cancellation = cancelPointerIfNeeded(
            in: session,
            timestamp: cancellationTimestamp
        )
        pointerGestureActive = false
        lastPointerLocation = nil
        pointerEpoch &+= 1
        inputEpoch &+= 1
        return GModPlayableInputBoundaryReport(
            pointerEpoch: pointerEpoch,
            inputEpoch: inputEpoch,
            cancelledActivePointer: cancellation.cancelled,
            cancellationFailure: cancellation.failure
        )
    }

    public func insertClientVGUIText(
        _ text: String,
        expectedGeneration: UInt64? = nil
    ) throws -> Int? {
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        return try session.insertClientVGUIText(text)
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
        pointerEpoch &+= 1
        inputEpoch &+= 1
        pointerGestureActive = false
        lastPointerLocation = nil
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

    private func validate(expectedPointerEpoch: UInt64?) throws {
        guard let expectedPointerEpoch else { return }
        guard expectedPointerEpoch == pointerEpoch else {
            throw GModPlayableSessionLaneError.stalePointerEpoch(
                expected: expectedPointerEpoch,
                actual: pointerEpoch
            )
        }
    }

    private func validate(expectedInputEpoch: UInt64?) throws {
        guard let expectedInputEpoch else { return }
        guard expectedInputEpoch == inputEpoch else {
            throw GModPlayableSessionLaneError.staleInputEpoch(
                expected: expectedInputEpoch,
                actual: inputEpoch
            )
        }
    }

    /// Cancellation clears registry capture before invoking Lua callbacks. A
    /// callback failure is therefore reported without retrying the cancellation
    /// or preventing the enclosing lifecycle boundary from advancing.
    private func cancelPointerIfNeeded(
        in session: GModPlayableSession,
        timestamp: TimeInterval
    ) -> (cancelled: Bool, failure: String?) {
        guard pointerGestureActive else { return (false, nil) }
        let location = lastPointerLocation ?? (x: 0, y: 0)
        do {
            _ = try session.dispatchClientVGUIPointerEvent(
                x: location.x,
                y: location.y,
                phase: .cancelled,
                timestamp: timestamp
            )
            return (true, nil)
        } catch {
            return (true, GMLuaRuntime.describe(error))
        }
    }
}

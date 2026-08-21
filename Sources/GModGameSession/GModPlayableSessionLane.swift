import Foundation
import GModEngine

public struct GModPlayableSessionSnapshot: Sendable, Equatable {
    public let generation: UInt64
    public let pointerEpoch: UInt64
    public let inputEpoch: UInt64
    public let startup: GModPlayableSessionStartupReport
    public let worldMesh: GModWorldRenderMesh
    public let playerWalkState: SourceWorldWalkState
    public let canonicalEntities: [SourceCanonicalEntitySnapshot]

    public init(
        generation: UInt64,
        pointerEpoch: UInt64,
        inputEpoch: UInt64,
        startup: GModPlayableSessionStartupReport,
        worldMesh: GModWorldRenderMesh,
        playerWalkState: SourceWorldWalkState,
        canonicalEntities: [SourceCanonicalEntitySnapshot]
    ) {
        self.generation = generation
        self.pointerEpoch = pointerEpoch
        self.inputEpoch = inputEpoch
        self.startup = startup
        self.worldMesh = worldMesh
        self.playerWalkState = playerWalkState
        self.canonicalEntities = canonicalEntities
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

public enum GModPlayableClientMenu: String, Sendable, Equatable {
    case spawn
    case context
}

/// One actor-serialized Q/C ownership transaction. The prior lifecycle is
/// closed before the target opens. If either callback fails, the lane attempts
/// to restore the prior menu and reports any rollback failure explicitly.
public struct GModPlayableClientMenuTransitionReport: Sendable, Equatable {
    public let boundary: GModPlayableInputBoundaryReport
    public let requestedPriorMenu: GModPlayableClientMenu?
    public let requestedTargetMenu: GModPlayableClientMenu?
    public let committedMenu: GModPlayableClientMenu?
    public let rollbackFailure: String?

    public init(
        boundary: GModPlayableInputBoundaryReport,
        requestedPriorMenu: GModPlayableClientMenu?,
        requestedTargetMenu: GModPlayableClientMenu?,
        committedMenu: GModPlayableClientMenu?,
        rollbackFailure: String?
    ) {
        self.boundary = boundary
        self.requestedPriorMenu = requestedPriorMenu
        self.requestedTargetMenu = requestedTargetMenu
        self.committedMenu = committedMenu
        self.rollbackFailure = rollbackFailure
    }

    public var pointerEpoch: UInt64 { boundary.pointerEpoch }
    public var inputEpoch: UInt64 { boundary.inputEpoch }
    public var cancelledActivePointer: Bool {
        boundary.cancelledActivePointer
    }
    public var cancellationFailure: String? { boundary.cancellationFailure }
    public var lifecycleFailure: String? { boundary.lifecycleFailure }
}

public struct GModPlayableHostFrameReport: Sendable, Equatable {
    public let fixedTicks: [GModPlayableFixedTickReport]
    public let inputButtons: GModPlayableInputButtonReport
    public let clientFrame: GMLuaSourceRuntimeRunReport?
    public let clientVGUIFrame: GMLuaSurfaceFrameSnapshot?
    /// Ordered, exactly-once handoff of CLIENT `surface.PlaySound` calls made
    /// since the preceding host-frame drain. Repeated paths remain repeated.
    public let clientSurfaceSounds: GMLuaSurfaceSoundRequestReport
    public let viewportChanged: Bool
    public let playerWalkState: SourceWorldWalkState
    /// Cheap change token. The entity array is fetched from the lane only when
    /// this value changes, rather than sorted and copied every display frame.
    public let canonicalEntityCursor: SourceEntityReplicationCursor?

    public init(
        fixedTicks: [GModPlayableFixedTickReport],
        inputButtons: GModPlayableInputButtonReport,
        clientFrame: GMLuaSourceRuntimeRunReport?,
        clientVGUIFrame: GMLuaSurfaceFrameSnapshot?,
        clientSurfaceSounds: GMLuaSurfaceSoundRequestReport,
        viewportChanged: Bool,
        playerWalkState: SourceWorldWalkState,
        canonicalEntityCursor: SourceEntityReplicationCursor?
    ) {
        self.fixedTicks = fixedTicks
        self.inputButtons = inputButtons
        self.clientFrame = clientFrame
        self.clientVGUIFrame = clientVGUIFrame
        self.clientSurfaceSounds = clientSurfaceSounds
        self.viewportChanged = viewportChanged
        self.playerWalkState = playerWalkState
        self.canonicalEntityCursor = canonicalEntityCursor
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

    /// Unsupported movement capabilities rejected without claiming a
    /// successful walk step. Invariant failures still throw from the lane.
    public var movementRejections: [GModPlayableMovementRejection] {
        fixedTicks.compactMap { $0.movement.rejection }
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

struct GModPlayableSessionLaneShutdownCleanupObservation: Sendable, Equatable {
    let workerIdentity: String
    let sessionIsClosed: Bool
    let closeReport: GModPlayableSessionCloseReport?
    let closeFailure: String?
}

/// Serialized ownership boundary for the non-Sendable Lua and Source runtime
/// graph. Apple UI code may await this actor without blocking MainActor; no
/// runtime, userdata, BSP provider, or transport endpoint crosses the actor.
public actor GModPlayableSessionLane {
    private nonisolated let dedicatedExecutor =
        GModPlayableSessionDedicatedExecutor()
    private let textMeasurer: (any GMLuaTextMeasurer)?
    private let worldWalkCollisionProvider:
        (any SourceWorldWalkCollisionProvider)?
    private let shutdownCleanupObserverForTesting:
        (@Sendable (
            GModPlayableSessionLaneShutdownCleanupObservation
        ) -> Void)?
    private var session: GModPlayableSession?
    private var generation: UInt64 = 0
    private var pointerEpoch: UInt64 = 0
    private var inputEpoch: UInt64 = 0
    private var pointerGestureActive = false
    private var lastPointerLocation: (x: Double, y: Double)?

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        dedicatedExecutor.asUnownedSerialExecutor()
    }

    public init(textMeasurer: (any GMLuaTextMeasurer)? = nil) {
        self.textMeasurer = textMeasurer
        worldWalkCollisionProvider = nil
        shutdownCleanupObserverForTesting = nil
    }

    /// Internal deterministic seam; the app-facing initializer always uses
    /// collision from the selected bundled BSP.
    init(
        textMeasurer: (any GMLuaTextMeasurer)? = nil,
        worldWalkCollisionProvider:
            any SourceWorldWalkCollisionProvider
    ) {
        self.textMeasurer = textMeasurer
        self.worldWalkCollisionProvider = worldWalkCollisionProvider
        shutdownCleanupObserverForTesting = nil
    }

    /// Internal teardown observation seam. Production callers cannot install
    /// callbacks into the worker-owned session graph.
    init(
        shutdownCleanupObserverForTesting:
            @escaping @Sendable (
                GModPlayableSessionLaneShutdownCleanupObservation
            ) -> Void
    ) {
        textMeasurer = nil
        worldWalkCollisionProvider = nil
        self.shutdownCleanupObserverForTesting =
            shutdownCleanupObserverForTesting
    }

    @discardableResult
    public func start(
        configuration: GModPlayableSessionConfiguration = .init(),
        logger: @escaping @Sendable (
            _ realm: GMLuaRealm,
            _ message: String
        ) -> Void = { _, _ in },
        progress: @escaping GModPlayableSessionLoadingProgressHandler = { _ in }
    ) throws -> GModPlayableSessionSnapshot {
        dedicatedExecutor.preconditionIsCurrentWorker()
        generation &+= 1
        pointerEpoch &+= 1
        inputEpoch &+= 1
        pointerGestureActive = false
        lastPointerLocation = nil
        if let prior = session {
            _ = try prior.close()
            dedicatedExecutor.clearShutdownCleanup()
            session = nil
        }
        let replacement = try GModPlayableSession(
            configuration: configuration,
            textMeasurer: textMeasurer,
            logger: logger,
            progress: progress,
            worldWalkCollisionProvider: worldWalkCollisionProvider
        )
        session = replacement
        retainForShutdown(replacement)
        return GModPlayableSessionSnapshot(
            generation: generation,
            pointerEpoch: pointerEpoch,
            inputEpoch: inputEpoch,
            startup: replacement.startupReport,
            worldMesh: replacement.worldMesh,
            playerWalkState: replacement.playerWalkState,
            canonicalEntities: replacement.clientCanonicalEntitySnapshots
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
        dedicatedExecutor.preconditionIsCurrentWorker()
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
        let inputButtons = try session.updateCurrentPlayerInputButtons(
            movementInput.buttons
        )

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
        // Drain only after every requested CLIENT boundary has completed. The
        // command-state queue owns total order and does not collapse repeats.
        let clientSurfaceSounds = try session.drainClientSurfaceSoundRequests()
        return GModPlayableHostFrameReport(
            fixedTicks: fixedTicks,
            inputButtons: inputButtons,
            clientFrame: clientFrame,
            clientVGUIFrame: clientVGUIFrame,
            clientSurfaceSounds: clientSurfaceSounds,
            viewportChanged: viewportChanged,
            playerWalkState: session.playerWalkState,
            canonicalEntityCursor: session.clientCanonicalEntityReplicationCursor
        )
    }

    /// Returns the immutable CLIENT projection only on explicit demand. The
    /// caller compares the host-frame cursor first and can therefore avoid an
    /// O(entity count) allocation on unchanged frames.
    public func clientCanonicalEntitySnapshots(
        expectedGeneration: UInt64? = nil
    ) throws -> [SourceCanonicalEntitySnapshot] {
        dedicatedExecutor.preconditionIsCurrentWorker()
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        return session.clientCanonicalEntitySnapshots
    }

    public func renderClientVGUIFrame(
        expectedGeneration: UInt64? = nil
    ) throws -> GMLuaSurfaceFrameSnapshot {
        dedicatedExecutor.preconditionIsCurrentWorker()
        guard let session else {
            throw GModPlayableSessionLaneError.notStarted
        }
        try validate(expectedGeneration: expectedGeneration)
        return try session.renderClientVGUIFrame()
    }

    @discardableResult
    public func transitionClientMenu(
        from priorMenu: GModPlayableClientMenu?,
        to targetMenu: GModPlayableClientMenu?,
        cancelActivePointer: Bool = false,
        cancellationTimestamp: TimeInterval = 0,
        expectedGeneration: UInt64? = nil,
        expectedPointerEpoch: UInt64? = nil,
        expectedInputEpoch: UInt64? = nil
    ) throws -> GModPlayableClientMenuTransitionReport {
        dedicatedExecutor.preconditionIsCurrentWorker()
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

        pointerGestureActive = false
        lastPointerLocation = nil
        pointerEpoch &+= 1
        inputEpoch &+= 1

        var phase = "begin transition"
        var targetOpenAttempted = false
        do {
            if let priorMenu, priorMenu != targetMenu {
                phase = "close \(priorMenu.rawValue)"
                try setClientMenu(priorMenu, isOpen: false, in: session)
            }
            if let targetMenu, targetMenu != priorMenu {
                phase = "open \(targetMenu.rawValue)"
                targetOpenAttempted = true
                try setClientMenu(targetMenu, isOpen: true, in: session)
            }
            return GModPlayableClientMenuTransitionReport(
                boundary: GModPlayableInputBoundaryReport(
                    pointerEpoch: pointerEpoch,
                    inputEpoch: inputEpoch,
                    cancelledActivePointer: cancellation.cancelled,
                    cancellationFailure: cancellation.failure
                ),
                requestedPriorMenu: priorMenu,
                requestedTargetMenu: targetMenu,
                committedMenu: targetMenu,
                rollbackFailure: nil
            )
        } catch {
            let lifecycleFailure = "\(phase): \(GMLuaRuntime.describe(error))"
            var rollbackFailures: [String] = []
            if targetOpenAttempted, let targetMenu, targetMenu != priorMenu {
                do {
                    try setClientMenu(targetMenu, isOpen: false, in: session)
                } catch {
                    rollbackFailures.append(
                        "close \(targetMenu.rawValue): " +
                            GMLuaRuntime.describe(error)
                    )
                }
            }
            if let priorMenu, priorMenu != targetMenu {
                do {
                    try setClientMenu(priorMenu, isOpen: true, in: session)
                } catch {
                    rollbackFailures.append(
                        "reopen \(priorMenu.rawValue): " +
                            GMLuaRuntime.describe(error)
                    )
                }
            }
            let rollbackFailure = rollbackFailures.isEmpty
                ? nil
                : rollbackFailures.joined(separator: "; ")
            return GModPlayableClientMenuTransitionReport(
                boundary: GModPlayableInputBoundaryReport(
                    pointerEpoch: pointerEpoch,
                    inputEpoch: inputEpoch,
                    cancelledActivePointer: cancellation.cancelled,
                    cancellationFailure: cancellation.failure,
                    lifecycleFailure: lifecycleFailure
                ),
                requestedPriorMenu: priorMenu,
                requestedTargetMenu: targetMenu,
                committedMenu: rollbackFailure == nil ? priorMenu : nil,
                rollbackFailure: rollbackFailure
            )
        }
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
        dedicatedExecutor.preconditionIsCurrentWorker()
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

    /// Context-menu equivalent of `setSpawnMenuOpen`. The boundary is kept
    /// separate from the Lua callback so a throwing Addon hook cannot retain a
    /// host pointer capture or admit a pre-transition movement frame.
    @discardableResult
    public func setContextMenuOpen(
        _ isOpen: Bool,
        cancelActivePointer: Bool = false,
        cancellationTimestamp: TimeInterval = 0,
        expectedGeneration: UInt64? = nil,
        expectedPointerEpoch: UInt64? = nil,
        expectedInputEpoch: UInt64? = nil
    ) throws -> GModPlayableInputBoundaryReport {
        dedicatedExecutor.preconditionIsCurrentWorker()
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

        pointerGestureActive = false
        lastPointerLocation = nil
        pointerEpoch &+= 1
        inputEpoch &+= 1
        let lifecycleFailure: String?
        do {
            try session.setContextMenuOpen(isOpen)
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
        dedicatedExecutor.preconditionIsCurrentWorker()
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
        notifyPauseMenuWillShow: Bool = false,
        expectedGeneration: UInt64? = nil,
        expectedPointerEpoch: UInt64? = nil,
        expectedInputEpoch: UInt64? = nil
    ) throws -> GModPlayableInputBoundaryReport {
        dedicatedExecutor.preconditionIsCurrentWorker()
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
        let lifecycleFailure: String?
        if notifyPauseMenuWillShow {
            do {
                try session.notifyPauseMenuWillShow()
                lifecycleFailure = nil
            } catch {
                lifecycleFailure = GMLuaRuntime.describe(error)
            }
        } else {
            lifecycleFailure = nil
        }
        // A paused host has no frame drain. Retire any pre-pause UI sounds so
        // Resume never replays stale taps from the prior input epoch.
        _ = try session.drainClientSurfaceSoundRequests()
        return GModPlayableInputBoundaryReport(
            pointerEpoch: pointerEpoch,
            inputEpoch: inputEpoch,
            cancelledActivePointer: cancellation.cancelled,
            cancellationFailure: cancellation.failure,
            lifecycleFailure: lifecycleFailure
        )
    }

    public func insertClientVGUIText(
        _ text: String,
        expectedGeneration: UInt64? = nil
    ) throws -> Int? {
        dedicatedExecutor.preconditionIsCurrentWorker()
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
        dedicatedExecutor.preconditionIsCurrentWorker()
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
    public func close(
        expectedGeneration: UInt64? = nil
    ) throws -> GModPlayableSessionCloseReport {
        dedicatedExecutor.preconditionIsCurrentWorker()
        guard let prior = session else {
            return GModPlayableSessionCloseReport(
                clientFinalizerErrors: [],
                serverFinalizerErrors: []
            )
        }
        try validate(expectedGeneration: expectedGeneration)
        let report = try prior.close()
        dedicatedExecutor.clearShutdownCleanup()
        session = nil
        generation &+= 1
        pointerEpoch &+= 1
        inputEpoch &+= 1
        pointerGestureActive = false
        lastPointerLocation = nil
        return report
    }

    /// Internal deterministic seam proving that actor-isolated work entered
    /// the same dedicated engine thread. No Thread object crosses the actor.
    func executionThreadIdentityForTesting() -> String {
        dedicatedExecutor.preconditionIsCurrentWorker()
        return dedicatedExecutor.workerIdentity
    }

    private func retainForShutdown(_ session: GModPlayableSession) {
        let observer = shutdownCleanupObserverForTesting
        dedicatedExecutor.replaceShutdownCleanup { workerIdentity in
            let closeReport: GModPlayableSessionCloseReport?
            let closeFailure: String?
            do {
                closeReport = try session.close()
                closeFailure = nil
            } catch {
                closeReport = nil
                closeFailure = GMLuaRuntime.describe(error)
            }
            observer?(
                GModPlayableSessionLaneShutdownCleanupObservation(
                    workerIdentity: workerIdentity,
                    sessionIsClosed: session.isClosed,
                    closeReport: closeReport,
                    closeFailure: closeFailure
                )
            )
        }
    }

    private func setClientMenu(
        _ menu: GModPlayableClientMenu,
        isOpen: Bool,
        in session: GModPlayableSession
    ) throws {
        switch menu {
        case .spawn:
            try session.setSpawnMenuOpen(isOpen)
        case .context:
            try session.setContextMenuOpen(isOpen)
        }
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

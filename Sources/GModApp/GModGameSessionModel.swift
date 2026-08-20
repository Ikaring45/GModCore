import Combine
import Foundation
import GModEngine
import GModGameAssets
import GModGameSession
import GModMetal

private struct GModGameFrameBatch: Sendable {
    let token: GModGameFrameToken
    let fixedTickCount: Int
    let viewport: GMLuaViewportSize
    let movementInput: GModPlayableMovementInput
}

private struct GModSurfaceBuildResult: Sendable {
    let scene: GModMetalSurfaceScene?
    let failure: String?
}

struct GModGameMovementDiagnostic: Equatable, Sendable {
    let status: String
    let logMessage: String

    init(
        commandNumber: Int32,
        reason: SourceWorldWalkUnsupportedReason
    ) {
        status =
            "Movement blocked at command \(commandNumber): \(reason); " +
            "state preserved"
        logMessage =
            "[GAME][MOVEMENT] command \(commandNumber) rejected: " +
            "\(reason); state preserved"
    }
}

/// Lock-protected one-slot mailbox between MTKView's render callback and the
/// serialized game actor. Slow Lua frames coalesce rather than creating an
/// unbounded queue of MainActor tasks.
private final class GModGameFrameMailbox: @unchecked Sendable {
    private static let maximumCatchUpTicks = 8

    private let lock = NSLock()
    private var enabled = false
    private var token: GModGameFrameToken?
    private var drainScheduled = false
    private var pendingTicks = 0
    private var pendingViewport = GMLuaViewportSize.logicalDesktopDefault
    private var movementInput = GModPlayableMovementInput.idle
    private var hasPendingFrame = false

    func disable() {
        lock.lock()
        enabled = false
        pendingTicks = 0
        hasPendingFrame = false
        lock.unlock()
    }

    func enable(token replacement: GModGameFrameToken) {
        lock.lock()
        if token != replacement {
            // Never relabel a frame admitted under an older input boundary.
            pendingTicks = 0
            hasPendingFrame = false
        }
        token = replacement
        enabled = true
        lock.unlock()
    }

    func setMovementInput(_ replacement: GModPlayableMovementInput) {
        lock.lock()
        movementInput = replacement
        lock.unlock()
    }

    func submit(
        _ request: GModMetalFrameRequest,
        consume: @escaping @Sendable (GModGameFrameBatch) async -> Void
    ) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        let incomingTicks = Swift.max(0, request.fixedTickCount)
        pendingTicks = Swift.min(
            Self.maximumCatchUpTicks,
            pendingTicks + incomingTicks
        )
        if request.viewportWidth > 0, request.viewportHeight > 0 {
            pendingViewport = GMLuaViewportSize(
                width: request.viewportWidth,
                height: request.viewportHeight
            )
        }
        hasPendingFrame = true
        let shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        Task {
            while let batch = self.takePendingBatch() {
                await consume(batch)
            }
        }
    }

    private func takePendingBatch() -> GModGameFrameBatch? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, hasPendingFrame, let token else {
            drainScheduled = false
            return nil
        }
        let batch = GModGameFrameBatch(
            token: token,
            fixedTickCount: pendingTicks,
            viewport: pendingViewport,
            movementInput: movementInput
        )
        pendingTicks = 0
        hasPendingFrame = false
        return batch
    }
}

/// A bounded, single-drain input lane for SwiftUI pointer samples. Consecutive
/// moves are coalesced, while began/ended/cancelled samples retain ordering.
/// This keeps a 120 Hz touch stream from spawning an unbounded number of Tasks.
private final class GModGamePointerMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var drainScheduled = false
    private var queue = GModGamePointerPendingQueue()

    func setEnabled(_ replacement: Bool) {
        lock.lock()
        enabled = replacement
        if !replacement {
            queue = GModGamePointerPendingQueue(capacity: queue.capacity)
        }
        lock.unlock()
    }

    func submit(
        _ sample: GModGamePointerSample,
        consume: @escaping @Sendable (GModGamePointerSample) async -> Void
    ) -> GModGamePointerQueueSubmission {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return GModGamePointerQueueSubmission(
                acceptedSample: false,
                droppedSampleCount: 0,
                coalescedMoveCount: 0
            )
        }

        let submission = queue.enqueue(sample)

        let shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            Task {
                while let next = self.takePendingSample() {
                    await consume(next)
                }
            }
        }
        return submission
    }

    private func takePendingSample() -> GModGamePointerSample? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !queue.samples.isEmpty else {
            drainScheduled = false
            return nil
        }
        return queue.popFirst()
    }
}

@MainActor
final class GModGameSessionModel: ObservableObject {
    @Published private(set) var status = "Choose a bundled map to start Sandbox"
    @Published private(set) var activeMap: GModBundledMap?
    @Published private(set) var loadingMap: GModBundledMap?
    @Published private(set) var isStarting = false
    @Published private(set) var isReady = false
    @Published private(set) var fixedTickCount: UInt64 = 0
    @Published private(set) var lastDeliveredMessages = 0
    @Published private(set) var recentLogs: [String] = []
    @Published private(set) var playerOrigin = SourceVector3.zero
    @Published private(set) var movementStatus = "Movement idle"
    @Published private(set) var viewAngles = SourceQAngle.zero
    @Published private(set) var worldScene: GModMetalWorldScene?
    @Published private(set) var surfaceScene: GModMetalSurfaceScene?
    @Published private(set) var surfaceDiagnostics: GModMetalSurfaceDiagnostics?
    @Published private(set) var surfaceStatus = "VGUI surface idle"
    @Published private(set) var isSpawnMenuOpen = false
    @Published private(set) var isSpawnMenuTransitioning = false
    @Published private(set) var pointerStatus = "VGUI pointer idle"
    @Published private(set) var pointerQueueDropCount = 0
    @Published private(set) var pointerMoveCoalescedCount = 0
    @Published private(set) var isInputSuspended = false
    let pointerCapability =
        "UIKit single-touch with native cancellation; " +
        "stock DButton enabled/capture callbacks active; " +
        "hover/wheel/keyboard pending"

    private let lane: GModPlayableSessionLane
    private let logSink: (String) -> Void
    private nonisolated let frameMailbox = GModGameFrameMailbox()
    private nonisolated let pointerMailbox = GModGamePointerMailbox()
    private nonisolated let surfaceTextureResolver:
        GModMetalSurfaceSourceMaterialResolver
    private nonisolated let surfaceTextRasterizer:
        GModMetalCoreTextRasterizer
    private var forwardAxis: Float = 0
    private var sideAxis: Float = 0
    private var jumpPressed = false
    private var sessionGeneration: UInt64 = 0
    private var laneGeneration: UInt64?
    private var pointerEpoch: UInt64?
    private var inputEpoch: UInt64?
    private var surfaceRequestRevision: UInt64 = 0
    private var inputSuspensionInFlight = false
    private var lastSurfaceFailure: String?
    private var lastPointerFailure: String?
    private var lastMovementRejectionReason:
        SourceWorldWalkUnsupportedReason?

    init(
        runtimeFactory: GModAppRuntimeFactory,
        logSink: @escaping (String) -> Void = { _ in }
    ) {
        lane = runtimeFactory.makePlayableSessionLane()
        surfaceTextureResolver = runtimeFactory.surfaceTextureResolver
        surfaceTextRasterizer = runtimeFactory.surfaceTextRasterizer
        self.logSink = logSink
    }

    deinit {
        let lane = lane
        Task {
            _ = try? await lane.close()
        }
    }

    func start(map: GModBundledMap, contentPackURL: URL? = nil) {
        guard !isStarting else { return }
        invalidateSurfaceRequests()
        isStarting = true
        isReady = false
        activeMap = nil
        loadingMap = map
        worldScene = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        surfaceStatus = "VGUI surface loading…"
        isSpawnMenuOpen = false
        isSpawnMenuTransitioning = false
        pointerStatus = "VGUI pointer idle"
        pointerQueueDropCount = 0
        pointerMoveCoalescedCount = 0
        movementStatus = "Movement loading…"
        lastSurfaceFailure = nil
        lastPointerFailure = nil
        lastMovementRejectionReason = nil
        jumpPressed = false
        sessionGeneration &+= 1
        let requestedGeneration = sessionGeneration
        laneGeneration = nil
        pointerEpoch = nil
        inputEpoch = nil
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        status = "Loading \(map.rawValue) / Sandbox…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await lane.start(
                    configuration: GModPlayableSessionConfiguration(
                        map: map,
                        contentPackURL: contentPackURL
                    ),
                    logger: { [weak self] realm, message in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  requestedGeneration == self.sessionGeneration else {
                                return
                            }
                            self.appendLog("[\(realm.rawValue)] \(message)")
                        }
                    }
                )
                guard requestedGeneration == sessionGeneration else { return }
                activeMap = map
                laneGeneration = snapshot.generation
                pointerEpoch = snapshot.pointerEpoch
                inputEpoch = snapshot.inputEpoch
                isReady = true
                fixedTickCount = 0
                lastDeliveredMessages = snapshot.startup.deliveredMessages
                playerOrigin = snapshot.playerWalkState.origin
                movementStatus = "Movement ready"
                viewAngles = snapshot.playerWalkState.viewAngles
                forwardAxis = 0
                sideAxis = 0
                jumpPressed = false
                publishMovementInput()
                let textureResolver = surfaceTextureResolver
                let preparedWorldScene = try await Task.detached(
                    priority: .userInitiated
                ) {
                    defer { textureResolver.removeAllCachedTextures() }
                    return try Self.makeWorldScene(
                        map: map,
                        mesh: snapshot.worldMesh,
                        playerOrigin: snapshot.playerWalkState.origin,
                        viewAngles: snapshot.playerWalkState.viewAngles,
                        textureResolver: textureResolver
                    )
                }.value
                guard requestedGeneration == sessionGeneration else { return }
                worldScene = preparedWorldScene
                surfaceStatus = "VGUI surface awaiting first client frame"
                let spawn = snapshot.startup.spawnPoint.origin
                status = "READY \(map.rawValue) spawn=(\(spawn.x), \(spawn.y), \(spawn.z))"
                if isInputSuspended {
                    beginInputSuspensionIfPossible()
                } else {
                    activateInputIfPossible()
                }
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                activeMap = nil
                isReady = false
                movementStatus = "Movement unavailable"
                status = "START FAILED: \(GMLuaRuntime.describe(error))"
                appendLog(status)
            }
            loadingMap = nil
            isStarting = false
        }
    }

    nonisolated func submitFrame(_ request: GModMetalFrameRequest) {
        frameMailbox.submit(request) { [weak self] batch in
            await self?.consumeFrame(batch)
        }
    }

    func executeActiveServer(_ rawSource: String) {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let requestedGeneration = sessionGeneration
        guard let requestedLaneGeneration = laneGeneration else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard requestedGeneration == sessionGeneration, isReady else {
                    return
                }
                try await lane.execute(
                    source,
                    expectedGeneration: requestedLaneGeneration
                )
                guard requestedGeneration == sessionGeneration, isReady else {
                    return
                }
                appendLog("[GAME][OK]")
            } catch {
                if requestedGeneration == sessionGeneration {
                    appendLog("[GAME][ERROR] \(GMLuaRuntime.describe(error))")
                }
            }
        }
    }

    func setMovementAxes(forward: Float, side: Float) {
        guard !isInputSuspended else { return }
        forwardAxis = Swift.max(-1, Swift.min(1, forward))
        sideAxis = Swift.max(-1, Swift.min(1, side))
        publishMovementInput()
    }

    func setJumpPressed(_ pressed: Bool) {
        guard !isInputSuspended else { return }
        jumpPressed = pressed
        publishMovementInput()
    }

    func adjustLook(deltaX: Float, deltaY: Float) {
        guard !isInputSuspended else { return }
        let sensitivity: Float = 0.34
        var yaw = viewAngles.yaw + deltaX * sensitivity
        yaw.formTruncatingRemainder(dividingBy: 360)
        viewAngles = SourceQAngle(
            pitch: Swift.max(
                -89,
                Swift.min(89, viewAngles.pitch + deltaY * sensitivity)
            ),
            yaw: yaw,
            roll: 0
        )
        publishMovementInput()
        publishCameraScene()
    }

    /// Idempotently closes every host-input path before the app loses active
    /// execution. The lane boundary clears the realm-visible button word and
    /// advances its pointer and frame epochs after cancelling a gesture once.
    func suspendInput() {
        guard !isInputSuspended else { return }
        isInputSuspended = true
        forwardAxis = 0
        sideAxis = 0
        jumpPressed = false
        publishMovementInput()
        invalidateSurfaceRequests()
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        pointerStatus = "VGUI input suspended"
        beginInputSuspensionIfPossible()
    }

    /// Re-enables mailboxes only after an in-flight actor suspension has
    /// advanced both input epochs. This prevents a quick inactive/active bounce
    /// from admitting new pointer or frame work under an epoch being retired.
    func resumeInput() {
        guard isInputSuspended else { return }
        isInputSuspended = false
        activateInputIfPossible()
    }

    func toggleSpawnMenu() {
        setSpawnMenuOpen(!isSpawnMenuOpen)
    }

    func setSpawnMenuOpen(_ replacement: Bool) {
        guard isReady,
              !isInputSuspended,
              !isSpawnMenuTransitioning,
              replacement != isSpawnMenuOpen,
              let requestedLaneGeneration = laneGeneration,
              let requestedPointerEpoch = pointerEpoch,
              let requestedInputEpoch = inputEpoch else {
            return
        }
        let requestedGeneration = sessionGeneration
        invalidateSurfaceRequests()
        isSpawnMenuTransitioning = true
        frameMailbox.disable()
        if replacement {
            forwardAxis = 0
            sideAxis = 0
            jumpPressed = false
            publishMovementInput()
        } else {
            pointerMailbox.setEnabled(false)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let boundary = try await lane.setSpawnMenuOpen(
                    replacement,
                    cancelActivePointer: !replacement,
                    cancellationTimestamp: Date().timeIntervalSinceReferenceDate,
                    expectedGeneration: requestedLaneGeneration,
                    expectedPointerEpoch: requestedPointerEpoch,
                    expectedInputEpoch: requestedInputEpoch
                )
                guard requestedGeneration == sessionGeneration, isReady else {
                    return
                }
                pointerEpoch = boundary.pointerEpoch
                inputEpoch = boundary.inputEpoch
                reportPointerCancellationFailure(boundary.cancellationFailure)
                if let lifecycleFailure = boundary.lifecycleFailure {
                    appendLog(
                        "[CLIENT][VGUI] Spawn Menu transition failed: " +
                            lifecycleFailure
                    )
                } else {
                    isSpawnMenuOpen = replacement
                    pointerMailbox.setEnabled(
                        replacement && !isInputSuspended
                    )
                    pointerStatus = isInputSuspended
                        ? "VGUI input suspended"
                        : replacement
                        ? "Single-touch VGUI; native cancel active; " +
                            "hover/wheel/keyboard pending"
                        : "VGUI pointer idle"
                    surfaceStatus = replacement
                        ? "Spawn Menu open; awaiting VGUI frame"
                        : "Spawn Menu closed; awaiting VGUI frame"
                    if !replacement {
                        surfaceScene = nil
                        surfaceDiagnostics = nil
                    }
                }
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                if isSpawnMenuOpen && !isInputSuspended {
                    pointerMailbox.setEnabled(true)
                }
                appendLog(
                    "[CLIENT][VGUI] Spawn Menu transition failed: " +
                        GMLuaRuntime.describe(error)
                )
            }
            if requestedGeneration == sessionGeneration {
                isSpawnMenuTransitioning = false
                if isInputSuspended {
                    beginInputSuspensionIfPossible()
                } else {
                    activateInputIfPossible()
                }
            }
        }
    }

    /// Maps a value-only host touch location into the last rendered VGUI
    /// viewport. The bounded mailbox preserves press/release ordering and
    /// coalesces move samples before crossing the session actor boundary.
    func submitSpawnMenuPointer(
        x: Double,
        y: Double,
        viewWidth: Double,
        viewHeight: Double,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval
    ) {
        guard isReady, !isInputSuspended,
              isSpawnMenuOpen, !isSpawnMenuTransitioning,
              let laneGeneration,
              let pointerEpoch,
              let surfaceScene,
              timestamp.isFinite else {
            return
        }
        guard let mapped = GModGamePointerCoordinateMapper.map(
            x: x,
            y: y,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            viewportWidth: surfaceScene.viewportWidth,
            viewportHeight: surfaceScene.viewportHeight
        ) else { return }

        let submission = pointerMailbox.submit(
            GModGamePointerSample(
                generation: GModGameSessionGenerationToken(
                    application: sessionGeneration,
                    lane: laneGeneration
                ),
                pointerEpoch: pointerEpoch,
                x: mapped.x,
                y: mapped.y,
                phase: phase,
                timestamp: timestamp
            )
        ) { [weak self] sample in
            await self?.consumePointer(sample)
        }
        pointerQueueDropCount += submission.droppedSampleCount
        pointerMoveCoalescedCount += submission.coalescedMoveCount
    }

    private func consumeFrame(_ batch: GModGameFrameBatch) async {
        guard isReady, !isInputSuspended,
              !inputSuspensionInFlight, !isSpawnMenuTransitioning,
              batch.token.matches(
                  application: sessionGeneration,
                  lane: laneGeneration,
                  inputEpoch: inputEpoch
              ) else {
            return
        }
        let activeToken = batch.token
        do {
            let report = try await lane.runHostFrame(
                fixedTickCount: batch.fixedTickCount,
                // Keep this false until the strict Sandbox VGUI slice can
                // guarantee that Paint failures are represented in the host
                // report. Today VGUI is requested separately below so a Lua
                // UI failure cannot discard an already-advanced world frame.
                renderClientVGUIFrame: false,
                viewport: batch.viewport,
                movementInput: batch.movementInput,
                expectedGeneration: activeToken.generation.lane,
                expectedInputEpoch: activeToken.inputEpoch
            )
            guard isReady, !isInputSuspended,
                  !inputSuspensionInFlight, !isSpawnMenuTransitioning,
                  activeToken.matches(
                      application: sessionGeneration,
                      lane: laneGeneration,
                      inputEpoch: inputEpoch
                  ) else {
                return
            }
            fixedTickCount &+= UInt64(report.fixedTicks.count)
            lastDeliveredMessages = report.deliveredMessages
            playerOrigin = report.playerWalkState.origin
            reportMovementResults(report.fixedTicks)
            publishCameraScene()
            for tick in report.fixedTicks {
                reportFailures(tick.server)
                reportFailures(tick.client)
            }
            for failure in report.actionFailures {
                appendLog(
                    "[SERVER][console:\(failure.command)] Action failed: " +
                        failure.message
                )
            }
            if let clientFrame = report.clientFrame {
                reportFailures(clientFrame)
            }
            guard !isSpawnMenuTransitioning else { return }
            let surfaceToken = beginSurfaceRequest(
                applicationGeneration: activeToken.generation.application,
                laneGeneration: activeToken.generation.lane
            )
            do {
                let snapshot = try await lane.renderClientVGUIFrame(
                    expectedGeneration: activeToken.generation.lane
                )
                await buildAndPublishSurfaceScene(
                    snapshot,
                    token: surfaceToken
                )
            } catch {
                guard isReady, surfaceToken.matches(
                    application: sessionGeneration,
                    lane: laneGeneration,
                    requestRevision: surfaceRequestRevision,
                    spawnMenuOpen: isSpawnMenuOpen
                ) else {
                    return
                }
                publishSurfaceFailure(
                    "live VGUI render failed: \(GMLuaRuntime.describe(error))"
                )
            }
        } catch {
            if isReady, !isInputSuspended,
               !inputSuspensionInFlight, !isSpawnMenuTransitioning,
               activeToken.matches(
                   application: sessionGeneration,
                   lane: laneGeneration,
                   inputEpoch: inputEpoch
               ) {
                failRuntime(error)
            }
        }
    }

    private func buildAndPublishSurfaceScene(
        _ snapshot: GMLuaSurfaceFrameSnapshot,
        token: GModSurfacePublicationToken
    ) async {
        let resolver = surfaceTextureResolver
        let rasterizer = surfaceTextRasterizer
        let build = await Task.detached(priority: .userInitiated) {
            do {
                return GModSurfaceBuildResult(
                    scene: try GModMetalSurfaceScene(
                        snapshot: snapshot,
                        textureResolver: resolver,
                        textRasterizer: rasterizer
                    ),
                    failure: nil
                )
            } catch {
                return GModSurfaceBuildResult(
                    scene: nil,
                    failure: String(describing: error)
                )
            }
        }.value

        guard isReady,
              token.matches(
                application: sessionGeneration,
                lane: laneGeneration,
                requestRevision: surfaceRequestRevision,
                spawnMenuOpen: isSpawnMenuOpen
              ) else {
            return
        }
        if let scene = build.scene {
            surfaceScene = scene
            surfaceDiagnostics = scene.diagnostics
            let diagnostics = scene.diagnostics
            surfaceStatus =
                "VGUI \(diagnostics.resolvedCommandCount)/" +
                "\(diagnostics.snapshotCommandCount) resolved; " +
                "\(diagnostics.unresolvedCommands.count) unresolved; " +
                "dropped capture " +
                "\(diagnostics.captureDiagnostics.droppedCommandCount), " +
                "scene \(diagnostics.droppedSnapshotCommandCount)"
            lastSurfaceFailure = nil
        } else if let failure = build.failure {
            publishSurfaceFailure("surface build failed: \(failure)")
        }
    }

    /// Retains the last complete immutable scene on a transient UI failure.
    /// The world renderer therefore continues and diagnostics remain visible.
    private func publishSurfaceFailure(_ failure: String) {
        surfaceStatus = "VGUI unavailable: \(failure)"
        if lastSurfaceFailure != failure {
            lastSurfaceFailure = failure
            appendLog("[CLIENT][VGUI] \(failure)")
        }
    }

    private func beginSurfaceRequest(
        applicationGeneration: UInt64,
        laneGeneration: UInt64
    ) -> GModSurfacePublicationToken {
        surfaceRequestRevision &+= 1
        return GModSurfacePublicationToken(
            generation: GModGameSessionGenerationToken(
                application: applicationGeneration,
                lane: laneGeneration
            ),
            requestRevision: surfaceRequestRevision,
            spawnMenuOpen: isSpawnMenuOpen
        )
    }

    private func invalidateSurfaceRequests() {
        surfaceRequestRevision &+= 1
    }

    private func consumePointer(_ sample: GModGamePointerSample) async {
        guard isReady, !isInputSuspended,
              isSpawnMenuOpen, !isSpawnMenuTransitioning,
              sample.pointerEpoch == pointerEpoch,
              sample.generation.matches(
                application: sessionGeneration,
                lane: laneGeneration
              ) else {
            return
        }
        do {
            let result = try await lane.dispatchClientVGUIPointerEvent(
                x: sample.x,
                y: sample.y,
                phase: sample.phase,
                timestamp: sample.timestamp,
                expectedGeneration: sample.generation.lane,
                expectedPointerEpoch: sample.pointerEpoch
            )
            guard isReady, !isInputSuspended,
                  isSpawnMenuOpen, !isSpawnMenuTransitioning,
                  sample.pointerEpoch == pointerEpoch,
                  sample.generation.matches(
                    application: sessionGeneration,
                    lane: laneGeneration
                  ) else {
                return
            }
            let panel = result.hitPanelIdentifier.map(String.init) ?? "none"
            pointerStatus =
                "VGUI pointer panel=\(panel) callbacks=" +
                "\(result.callbackNames.count)"
            lastPointerFailure = nil
        } catch {
            guard sample.generation.application == sessionGeneration,
                  sample.pointerEpoch == pointerEpoch else {
                return
            }
            pointerStatus = "VGUI pointer dispatch failed"
            let failure = GMLuaRuntime.describe(error)
            if lastPointerFailure != failure {
                lastPointerFailure = failure
                appendLog(
                    "[CLIENT][VGUI] Pointer dispatch failed: \(failure)"
                )
            }
        }
    }

    private func reportFailures(_ report: GMLuaSourceRuntimeRunReport) {
        for failure in report.hookFailures {
            appendLog(
                "[\(failure.realm.rawValue)][\(failure.event)] \(failure.message)"
            )
        }
        for failure in report.timerFailures {
            appendLog(
                "[\(failure.realm.rawValue)][timer:\(failure.identifier)] " +
                    failure.message
            )
        }
    }

    /// Keeps an unsupported movement capability visible without turning the
    /// successfully advanced SERVER/CLIENT host frame into an app failure.
    func reportMovementResults(_ reports: [GModPlayableFixedTickReport]) {
        guard let last = reports.last else { return }
        for rejection in reports.compactMap({ $0.movement.rejection }) {
            let diagnostic = GModGameMovementDiagnostic(
                commandNumber: rejection.commandNumber,
                reason: rejection.reason
            )
            if rejection.reason != lastMovementRejectionReason {
                appendLog(diagnostic.logMessage)
            }
            lastMovementRejectionReason = rejection.reason
        }

        switch last.movement {
        case .advanced:
            movementStatus = "Movement active"
            lastMovementRejectionReason = nil
        case let .rejected(rejection):
            movementStatus = GModGameMovementDiagnostic(
                commandNumber: rejection.commandNumber,
                reason: rejection.reason
            ).status
        }
    }

    private func failRuntime(_ error: Error) {
        isReady = false
        invalidateSurfaceRequests()
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        pointerEpoch = nil
        inputEpoch = nil
        worldScene = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        isSpawnMenuOpen = false
        isSpawnMenuTransitioning = false
        lastPointerFailure = nil
        lastMovementRejectionReason = nil
        movementStatus = "Movement stopped"
        status = "RUNTIME FAILED: \(GMLuaRuntime.describe(error))"
        appendLog(status)
    }

    private func beginInputSuspensionIfPossible() {
        guard isInputSuspended,
              !inputSuspensionInFlight,
              isReady,
              !isSpawnMenuTransitioning,
              let requestedLaneGeneration = laneGeneration,
              let requestedPointerEpoch = pointerEpoch,
              let requestedInputEpoch = inputEpoch else {
            return
        }
        inputSuspensionInFlight = true
        let requestedGeneration = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let boundary = try await lane.suspendInput(
                    cancellationTimestamp: Date().timeIntervalSinceReferenceDate,
                    expectedGeneration: requestedLaneGeneration,
                    expectedPointerEpoch: requestedPointerEpoch,
                    expectedInputEpoch: requestedInputEpoch
                )
                if requestedGeneration == sessionGeneration,
                   requestedLaneGeneration == laneGeneration {
                    pointerEpoch = boundary.pointerEpoch
                    inputEpoch = boundary.inputEpoch
                    reportPointerCancellationFailure(
                        boundary.cancellationFailure
                    )
                }
            } catch {
                if requestedGeneration == sessionGeneration {
                    appendLog(
                        "[CLIENT][INPUT] Suspension failed: " +
                            GMLuaRuntime.describe(error)
                    )
                }
            }
            inputSuspensionInFlight = false
            if isInputSuspended {
                pointerMailbox.setEnabled(false)
                frameMailbox.disable()
            } else {
                activateInputIfPossible()
            }
        }
    }

    private func activateInputIfPossible() {
        guard isReady,
              !isInputSuspended,
              !inputSuspensionInFlight,
              !isSpawnMenuTransitioning,
              let laneGeneration,
              let inputEpoch else {
            return
        }
        frameMailbox.enable(
            token: GModGameFrameToken(
                generation: GModGameSessionGenerationToken(
                    application: sessionGeneration,
                    lane: laneGeneration
                ),
                inputEpoch: inputEpoch
            )
        )
        pointerMailbox.setEnabled(isSpawnMenuOpen)
        pointerStatus = isSpawnMenuOpen
            ? "Single-touch VGUI; native cancel active; " +
                "hover/wheel/keyboard pending"
            : "VGUI pointer idle"
    }

    private func reportPointerCancellationFailure(_ failure: String?) {
        guard let failure else { return }
        appendLog("[CLIENT][INPUT] Pointer cancellation callback failed: \(failure)")
    }

    private func publishMovementInput() {
        let speed: Float = 250
        var buttons: SourceInputButtons = []
        if forwardAxis > 0 { buttons.insert(.forward) }
        if forwardAxis < 0 { buttons.insert(.back) }
        if sideAxis > 0 { buttons.insert(.moveRight) }
        if sideAxis < 0 { buttons.insert(.moveLeft) }
        if jumpPressed { buttons.insert(.jump) }
        frameMailbox.setMovementInput(
            GModPlayableMovementInput(
                viewAngles: viewAngles,
                forwardMove: forwardAxis * speed,
                sideMove: sideAxis * speed,
                buttons: buttons
            )
        )
    }

    private func publishCameraScene() {
        guard let worldScene else { return }
        self.worldScene = worldScene.updatingCamera(
            eye: Self.cameraEye(for: playerOrigin),
            forward: Self.cameraForward(for: viewAngles)
        )
    }

    nonisolated private static func makeWorldScene(
        map: GModBundledMap,
        mesh: GModWorldRenderMesh,
        playerOrigin: SourceVector3,
        viewAngles: SourceQAngle,
        textureResolver: GModMetalSurfaceSourceMaterialResolver
    ) throws -> GModMetalWorldScene {
        let maximumRetainedTextureBytes = 128 * 1_024 * 1_024
        var retainedTextureBytes = 0
        let ranges: [GModMetalWorldMaterialRange] = mesh.materialRanges.map { range in
            let bitmap: GModMetalSurfaceBitmap?
            if let name = range.materialName,
               let resolved = try? textureResolver.resolveSurfaceTexture(
                   named: name
               ),
               resolved.premultipliedRGBA8.count <=
                    maximumRetainedTextureBytes - retainedTextureBytes {
                bitmap = resolved
                retainedTextureBytes += resolved.premultipliedRGBA8.count
            } else {
                bitmap = nil
            }
            return GModMetalWorldMaterialRange(
                materialName: range.materialName,
                firstIndex: range.firstIndex,
                indexCount: range.indexCount,
                bitmap: bitmap
            )
        }
        return GModMetalWorldScene(
            meshIdentifier: "\(map.rawValue):\(mesh.vertices.count):\(mesh.indices.count)",
            sourcePositions: mesh.vertices.map {
                SIMD3<Float>($0.position.x, $0.position.y, $0.position.z)
            },
            sourceNormals: mesh.vertices.map {
                SIMD3<Float>($0.normal.x, $0.normal.y, $0.normal.z)
            },
            sourceTextureCoordinates: mesh.vertices.map {
                SIMD2<Float>($0.textureCoordinate.u, $0.textureCoordinate.v)
            },
            indices: mesh.indices,
            materialRanges: ranges,
            cameraEye: cameraEye(for: playerOrigin),
            cameraForward: cameraForward(for: viewAngles)
        )
    }

    nonisolated private static func cameraEye(
        for origin: SourceVector3
    ) -> SIMD3<Float> {
        SIMD3<Float>(origin.x, origin.y, origin.z + 64)
    }

    nonisolated private static func cameraForward(
        for angles: SourceQAngle
    ) -> SIMD3<Float> {
        let degreesToRadians = Double.pi / 180
        let pitch = Double(angles.pitch) * degreesToRadians
        let yaw = Double(angles.yaw) * degreesToRadians
        let cosinePitch = Float(cos(pitch))
        return SIMD3<Float>(
            cosinePitch * Float(cos(yaw)),
            cosinePitch * Float(sin(yaw)),
            -Float(sin(pitch))
        )
    }

    private func appendLog(_ value: String) {
        recentLogs.append(value)
        if recentLogs.count > 80 {
            recentLogs.removeFirst(recentLogs.count - 80)
        }
        logSink(value)
    }
}

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

struct GModGameFirstWorldFrameGate: Equatable, Sendable {
    private(set) var expectedMeshIdentifier: String?

    mutating func arm(meshIdentifier: String) {
        expectedMeshIdentifier = meshIdentifier
    }

    mutating func reset() {
        expectedMeshIdentifier = nil
    }

    func matches(meshIdentifier: String) -> Bool {
        expectedMeshIdentifier == meshIdentifier
    }

    mutating func acknowledge(meshIdentifier: String) -> Bool {
        guard meshIdentifier == expectedMeshIdentifier else { return false }
        expectedMeshIdentifier = nil
        return true
    }
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
    @Published private(set) var loadingState =
        GModPlayableSessionLoadingState()
    @Published private(set) var startFailure: GModGameStartFailure?
    @Published private(set) var isStarting = false
    @Published private(set) var isDisconnecting = false
    @Published private(set) var isReady = false
    @Published private(set) var fixedTickCount: UInt64 = 0
    @Published private(set) var lastDeliveredMessages = 0
    @Published private(set) var recentLogs: [String] = []
    @Published private(set) var playerOrigin = SourceVector3.zero
    @Published private(set) var movementStatus = "Movement idle"
    @Published private(set) var viewAngles = SourceQAngle.zero
    @Published private(set) var worldScene: GModMetalWorldScene?
    @Published private(set) var lastRendererFailure:
        GModMetalWorldRendererFailure?
    @Published private(set) var surfaceScene: GModMetalSurfaceScene?
    @Published private(set) var surfaceDiagnostics: GModMetalSurfaceDiagnostics?
    @Published private(set) var surfaceStatus = "VGUI surface idle"
    @Published private(set) var activeClientMenu: GModGameClientMenu?
    @Published private(set) var transitioningClientMenu: GModGameClientMenu?
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
    private let diagnosticsStore: GModAppDiagnosticsStore
    private let inputVideoSettings: GModInputVideoSettingsStore
    let audioController: GModMenuAudioController
    private nonisolated let frameMailbox = GModGameFrameMailbox()
    private nonisolated let pointerMailbox = GModGamePointerMailbox()
    private nonisolated let surfaceTextureResolver:
        GModMetalSurfaceSourceMaterialResolver
    private nonisolated let surfaceTextRasterizer:
        GModMetalCoreTextRasterizer
    private var forwardAxis: Float = 0
    private var sideAxis: Float = 0
    private var jumpPressed = false
    private var heldActionButtons: SourceInputButtons = []
    private var isHostPopupPresented = false
    private var sessionGeneration: UInt64 = 0
    private var laneGeneration: UInt64?
    private var pointerEpoch: UInt64?
    private var inputEpoch: UInt64?
    private var surfaceRequestRevision: UInt64 = 0
    private var surfaceRefreshQueue = GModGameSurfaceRefreshPendingQueue()
    private var surfaceRefreshTask: Task<Void, Never>?
    private var inputSuspensionInFlight = false
    private var pauseMenuNotificationPending = false
    private var lastSurfaceFailure: String?
    private var lastPointerFailure: String?
    private var lastMovementRejectionReason:
        SourceWorldWalkUnsupportedReason?
    private var firstWorldFrameGate = GModGameFirstWorldFrameGate()
    private var worldSkyVisibility: GModWorldSkyVisibility?

    var loadingProgress: GModPlayableSessionLoadingProgress {
        loadingState.progress
    }

    var hasActiveSession: Bool {
        isReady && activeMap != nil
    }

    var isSpawnMenuOpen: Bool { activeClientMenu == .spawn }
    var isContextMenuOpen: Bool { activeClientMenu == .context }
    var isClientMenuOpen: Bool { activeClientMenu != nil }
    var isClientMenuTransitioning: Bool { transitioningClientMenu != nil }
    var isSpawnMenuTransitioning: Bool {
        transitioningClientMenu == .spawn
    }
    var isContextMenuTransitioning: Bool {
        transitioningClientMenu == .context
    }
    var acceptsWorldInput: Bool {
        GModGameWorldInputPolicy.accepts(
            isReady: isReady,
            isInputSuspended: isInputSuspended,
            activeMenu: activeClientMenu,
            transitioningMenu: transitioningClientMenu,
            isHostPopupPresented: isHostPopupPresented
        )
    }

    var continuitySnapshot: GModGameSessionContinuitySnapshot? {
        guard isReady, let activeMap else { return nil }
        return GModGameSessionContinuitySnapshot(
            map: activeMap,
            playerOrigin: playerOrigin,
            viewAngles: viewAngles,
            fixedTickCount: fixedTickCount
        )
    }

    init(
        runtimeFactory: GModAppRuntimeFactory,
        audioSettingsStore: GModMenuAudioSettingsStore = .shared,
        inputVideoSettings: GModInputVideoSettingsStore = .shared,
        diagnosticsStore: GModAppDiagnosticsStore = .shared,
        logSink: @escaping (String) -> Void = { _ in }
    ) {
        lane = runtimeFactory.makePlayableSessionLane()
        self.diagnosticsStore = diagnosticsStore
        self.inputVideoSettings = inputVideoSettings
        surfaceTextureResolver = runtimeFactory.surfaceTextureResolver
        surfaceTextRasterizer = runtimeFactory.surfaceTextRasterizer
        audioController = GModMenuAudioController(
            resolver: { logicalPath, maximumByteCount in
                try runtimeFactory.mountedContentData(
                    for: logicalPath,
                    maximumByteCount: maximumByteCount
                )
            },
            settingsStore: audioSettingsStore,
            diagnostic: { diagnostic in
                guard let record = GModAudioProblemMapper.record(
                    for: diagnostic
                ) else { return }
                diagnosticsStore.record(record)
                logSink(
                    "[AUDIO][\(diagnostic.code.rawValue)] " + record.detail
                )
            }
        )
        self.logSink = logSink
    }

    deinit {
        let lane = lane
        Task {
            _ = try? await lane.close()
        }
    }

    func start(
        map: GModBundledMap,
        contentPackURL: URL? = nil,
        languageCode: String = "en",
        languagePhrases: [String: String] = [:]
    ) {
        guard !isStarting, !isDisconnecting else { return }
        audioController.stop(bus: .gameplay)
        invalidateSurfaceRequests()
        isStarting = true
        loadingState = GModPlayableSessionLoadingState()
        startFailure = nil
        isReady = false
        activeMap = nil
        loadingMap = map
        worldScene = nil
        worldSkyVisibility = nil
        lastRendererFailure = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        surfaceStatus = "VGUI surface loading…"
        activeClientMenu = nil
        transitioningClientMenu = nil
        pointerStatus = "VGUI pointer idle"
        pointerQueueDropCount = 0
        pointerMoveCoalescedCount = 0
        movementStatus = "Movement loading…"
        lastSurfaceFailure = nil
        lastPointerFailure = nil
        lastMovementRejectionReason = nil
        firstWorldFrameGate.reset()
        pauseMenuNotificationPending = false
        clearHeldWorldInput()
        isHostPopupPresented = false
        sessionGeneration &+= 1
        let requestedGeneration = sessionGeneration
        laneGeneration = nil
        pointerEpoch = nil
        inputEpoch = nil
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        status = "loading.\(loadingProgress.taskIdentifier) — " +
            "\(loadingProgress.percentComplete)%"

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await lane.start(
                    configuration: GModPlayableSessionConfiguration(
                        map: map,
                        contentPackURL: contentPackURL,
                        languageCode: languageCode,
                        languagePhrases: languagePhrases
                    ),
                    logger: { [weak self] realm, message in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  requestedGeneration == self.sessionGeneration else {
                                return
                            }
                            self.appendLog("[\(realm.rawValue)] \(message)")
                        }
                    },
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.recordLoadingProgress(
                                progress,
                                requestedGeneration: requestedGeneration
                            )
                        }
                    }
                )
                guard requestedGeneration == sessionGeneration else {
                    _ = try? await lane.close(
                        expectedGeneration: snapshot.generation
                    )
                    return
                }
                recordLoadingProgress(
                    .init(stage: .preparingMaterials),
                    requestedGeneration: requestedGeneration
                )
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
                clearHeldWorldInput()
                publishMovementInput()
                let textureResolver = surfaceTextureResolver
                let preparedWorldScene = try await Task.detached(
                    priority: .userInitiated
                ) {
                    defer { textureResolver.removeAllCachedTextures() }
                    return try Self.makeWorldScene(
                        map: map,
                        sessionGeneration: requestedGeneration,
                        mesh: snapshot.worldMesh,
                        playerOrigin: snapshot.playerWalkState.origin,
                        viewAngles: snapshot.playerWalkState.viewAngles,
                        textureResolver: textureResolver
                    )
                }.value
                guard requestedGeneration == sessionGeneration else { return }
                firstWorldFrameGate.arm(
                    meshIdentifier: preparedWorldScene.meshIdentifier
                )
                recordLoadingProgress(
                    .init(stage: .awaitingFirstMetalFrame),
                    requestedGeneration: requestedGeneration
                )
                worldSkyVisibility = snapshot.worldMesh.skyVisibility
                worldScene = preparedWorldScene
                surfaceStatus = "VGUI surface awaiting first client frame"
                if isInputSuspended {
                    beginInputSuspensionIfPossible()
                } else {
                    activateInputIfPossible()
                }
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                let description = GMLuaRuntime.describe(error)
                var failedLoadingState = loadingState
                failedLoadingState.fail(description)
                loadingState = failedLoadingState
                activeMap = nil
                isReady = false
                isInputSuspended = true
                frameMailbox.disable()
                pointerMailbox.setEnabled(false)
                firstWorldFrameGate.reset()
                movementStatus = "Movement unavailable"
                status = "START FAILED: \(description)"
                appendLog(status)
                startFailure = GModGameStartFailure(
                    map: map,
                    origin: .cpu,
                    detail: description
                )
            }
        }
    }

    nonisolated func submitFrame(_ request: GModMetalFrameRequest) {
        frameMailbox.submit(request) { [weak self] batch in
            await self?.consumeFrame(batch)
        }
    }

    /// Metal calls this only after a command buffer containing the selected
    /// world scene completes. The mesh identifier embeds the app generation,
    /// so a delayed completion from an older start cannot dismiss the overlay.
    nonisolated func submitPresentedWorldFrame(meshIdentifier: String) {
        submitWorldFrameEvent(.presented(meshIdentifier: meshIdentifier))
    }

    nonisolated func submitWorldFrameEvent(
        _ event: GModMetalWorldFrameEvent
    ) {
        Task { @MainActor [weak self] in
            self?.handleWorldFrameEvent(event)
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
        guard acceptsWorldInput else {
            rejectLateWorldInput()
            return
        }
        forwardAxis = Swift.max(-1, Swift.min(1, forward))
        sideAxis = Swift.max(-1, Swift.min(1, side))
        publishMovementInput()
    }

    func setJumpPressed(_ pressed: Bool) {
        guard acceptsWorldInput else {
            rejectLateWorldInput()
            return
        }
        jumpPressed = pressed
        publishMovementInput()
    }

    func setWorldActionButton(
        _ action: GModGameWorldActionButton,
        pressed: Bool
    ) {
        guard acceptsWorldInput else {
            rejectLateWorldInput()
            return
        }
        if pressed {
            heldActionButtons.insert(action.sourceButton)
        } else {
            heldActionButtons.remove(action.sourceButton)
        }
        publishMovementInput()
    }

    func adjustLook(deltaX: Float, deltaY: Float) {
        guard acceptsWorldInput else {
            rejectLateWorldInput()
            return
        }
        viewAngles = GModTouchLookPolicy.adjustedAngles(
            current: viewAngles,
            deltaX: deltaX,
            deltaY: deltaY,
            sensitivity: inputVideoSettings.touchLookSensitivity,
            invertY: inputVideoSettings.invertTouchLookY
        )
        publishMovementInput()
        publishCameraScene()
    }

    /// Idempotently closes every host-input path before the app loses active
    /// execution. The lane boundary clears the realm-visible button word and
    /// advances its pointer and frame epochs after cancelling a gesture once.
    func suspendInput() {
        requestInputSuspension(notifyPauseMenuWillShow: false)
    }

    /// Presents the in-game Home boundary without replacing the playable
    /// session. In addition to suspending every host input path, this sends the
    /// stock CLIENT pause notification so Sandbox closes Q/C-owned panels.
    func presentPauseMenu() {
        activeClientMenu = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        requestInputSuspension(notifyPauseMenuWillShow: true)
    }

    /// Native Options/Problems windows own touch while visible. Home normally
    /// already has the session paused, but this gate also sanitizes a popup
    /// presented directly over a live world and rejects late UIKit callbacks.
    func setHostPopupPresented(_ presented: Bool) {
        guard presented != isHostPopupPresented else { return }
        isHostPopupPresented = presented
        if presented {
            clearHeldWorldInput()
            publishMovementInput()
        }
    }

    private func requestInputSuspension(
        notifyPauseMenuWillShow: Bool
    ) {
        if notifyPauseMenuWillShow {
            pauseMenuNotificationPending = true
        }
        if !isInputSuspended {
            isInputSuspended = true
        } else if !notifyPauseMenuWillShow {
            return
        }
        clearHeldWorldInput()
        audioController.stop(bus: .gameplay)
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
        pauseMenuNotificationPending = false
        activateInputIfPossible()
    }

    /// Leaves a failed CPU/renderer startup without waiting for a timeout. The
    /// failed loading state and typed failure remain available to Problems;
    /// only the unusable lane and its render/input references are retired.
    func returnToHomeAfterStartFailure() {
        guard isStarting, startFailure != nil, !isDisconnecting else { return }
        isDisconnecting = true
        audioController.stop(bus: .gameplay)
        sessionGeneration &+= 1
        let requestedGeneration = sessionGeneration
        let requestedLaneGeneration = laneGeneration

        isStarting = false
        isReady = false
        isInputSuspended = true
        pauseMenuNotificationPending = false
        clearHeldWorldInput()
        publishMovementInput()
        invalidateSurfaceRequests()
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        firstWorldFrameGate.reset()

        activeMap = nil
        loadingMap = nil
        fixedTickCount = 0
        lastDeliveredMessages = 0
        playerOrigin = .zero
        viewAngles = .zero
        worldScene = nil
        worldSkyVisibility = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        surfaceStatus = "VGUI surface idle"
        activeClientMenu = nil
        transitioningClientMenu = nil
        pointerStatus = "VGUI pointer idle"
        pointerQueueDropCount = 0
        pointerMoveCoalescedCount = 0
        movementStatus = "Movement unavailable"
        lastSurfaceFailure = nil
        lastPointerFailure = nil
        lastMovementRejectionReason = nil
        laneGeneration = nil
        pointerEpoch = nil
        inputEpoch = nil
        status = "Returning to Home…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await lane.close(
                    expectedGeneration: requestedLaneGeneration
                )
                guard requestedGeneration == sessionGeneration else { return }
                for failure in report.clientFinalizerErrors {
                    appendLog("[CLIENT][failed-start] \(failure)")
                }
                for failure in report.serverFinalizerErrors {
                    appendLog("[SERVER][failed-start] \(failure)")
                }
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                appendLog(
                    "[GAME][failed-start] " + GMLuaRuntime.describe(error)
                )
            }
            guard requestedGeneration == sessionGeneration else { return }
            isDisconnecting = false
            status = "Choose a bundled map to start Sandbox"
        }
    }

    /// Closes the playable lane and returns the model to a value-safe Home
    /// state. A new map is not admitted until teardown completes, preventing a
    /// delayed close from destroying the replacement session.
    func disconnect() {
        guard !isStarting, !isDisconnecting else { return }
        isDisconnecting = true
        audioController.stop(bus: .gameplay)
        sessionGeneration &+= 1
        let requestedGeneration = sessionGeneration
        let requestedLaneGeneration = laneGeneration

        isInputSuspended = true
        pauseMenuNotificationPending = false
        clearHeldWorldInput()
        publishMovementInput()
        invalidateSurfaceRequests()
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        firstWorldFrameGate.reset()

        isReady = false
        activeMap = nil
        loadingMap = nil
        loadingState = GModPlayableSessionLoadingState()
        fixedTickCount = 0
        lastDeliveredMessages = 0
        playerOrigin = .zero
        viewAngles = .zero
        worldScene = nil
        worldSkyVisibility = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        surfaceStatus = "VGUI surface idle"
        activeClientMenu = nil
        transitioningClientMenu = nil
        pointerStatus = "VGUI pointer idle"
        pointerQueueDropCount = 0
        pointerMoveCoalescedCount = 0
        movementStatus = "Movement idle"
        lastSurfaceFailure = nil
        lastPointerFailure = nil
        lastMovementRejectionReason = nil
        laneGeneration = nil
        pointerEpoch = nil
        inputEpoch = nil
        status = "Disconnecting…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await lane.close(
                    expectedGeneration: requestedLaneGeneration
                )
                guard requestedGeneration == sessionGeneration else { return }
                for failure in report.clientFinalizerErrors {
                    appendLog("[CLIENT][disconnect] \(failure)")
                }
                for failure in report.serverFinalizerErrors {
                    appendLog("[SERVER][disconnect] \(failure)")
                }
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                appendLog(
                    "[GAME][disconnect] " + GMLuaRuntime.describe(error)
                )
            }
            guard requestedGeneration == sessionGeneration else { return }
            isDisconnecting = false
            status = "Choose a bundled map to start Sandbox"
        }
    }

    func toggleSpawnMenu() {
        setSpawnMenuOpen(!isSpawnMenuOpen)
    }

    func toggleContextMenu() {
        setContextMenuOpen(!isContextMenuOpen)
    }

    func setSpawnMenuOpen(_ replacement: Bool) {
        setClientMenu(.spawn, open: replacement)
    }

    func setContextMenuOpen(_ replacement: Bool) {
        setClientMenu(.context, open: replacement)
    }

    private func setClientMenu(
        _ menu: GModGameClientMenu,
        open replacement: Bool
    ) {
        guard isReady,
              !isInputSuspended,
              !isClientMenuTransitioning,
              replacement
                ? activeClientMenu != menu
                : activeClientMenu == menu,
              let requestedLaneGeneration = laneGeneration,
              let requestedPointerEpoch = pointerEpoch,
              let requestedInputEpoch = inputEpoch else {
            return
        }
        let requestedGeneration = sessionGeneration
        let priorMenu = activeClientMenu
        invalidateSurfaceRequests()
        transitioningClientMenu = menu
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        if replacement {
            clearHeldWorldInput()
            publishMovementInput()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let transition = try await lane.transitionClientMenu(
                    from: priorMenu?.playableMenu,
                    to: replacement ? menu.playableMenu : nil,
                    cancelActivePointer: priorMenu != nil,
                    cancellationTimestamp: Date().timeIntervalSinceReferenceDate,
                    expectedGeneration: requestedLaneGeneration,
                    expectedPointerEpoch: requestedPointerEpoch,
                    expectedInputEpoch: requestedInputEpoch
                )
                guard requestedGeneration == sessionGeneration, isReady else {
                    return
                }
                pointerEpoch = transition.pointerEpoch
                inputEpoch = transition.inputEpoch
                reportPointerCancellationFailure(transition.cancellationFailure)
                activeClientMenu = transition.committedMenu.map(
                    GModGameClientMenu.init
                )
                pointerMailbox.setEnabled(
                    activeClientMenu != nil && !isInputSuspended
                )
                if let lifecycleFailure = transition.lifecycleFailure {
                    appendLog(
                        "[CLIENT][VGUI] \(menu.statusName) transition failed: " +
                            lifecycleFailure
                    )
                    if let rollbackFailure = transition.rollbackFailure {
                        appendLog(
                            "[CLIENT][VGUI] menu rollback failed: " +
                                rollbackFailure
                        )
                        surfaceScene = nil
                        surfaceDiagnostics = nil
                        surfaceStatus = "VGUI menu ownership uncertain"
                    } else {
                        surfaceStatus = activeClientMenu.map {
                            "\($0.statusName) restored after failed transition"
                        } ?? "VGUI menu transition rolled back"
                    }
                } else {
                    pointerStatus = isInputSuspended
                        ? "VGUI input suspended"
                        : activeClientMenu != nil
                        ? "Single-touch VGUI; native cancel active; " +
                            "hover/wheel/keyboard pending"
                        : "VGUI pointer idle"
                    surfaceStatus = activeClientMenu.map {
                        "\($0.statusName) open; awaiting VGUI frame"
                    } ?? "\(menu.statusName) closed; VGUI surface idle"
                    if activeClientMenu == nil {
                        surfaceScene = nil
                        surfaceDiagnostics = nil
                    }
                }
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                if priorMenu != nil && !isInputSuspended {
                    pointerMailbox.setEnabled(true)
                }
                appendLog(
                    "[CLIENT][VGUI] \(menu.statusName) transition failed: " +
                        GMLuaRuntime.describe(error)
                )
            }
            if requestedGeneration == sessionGeneration {
                transitioningClientMenu = nil
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
    func submitClientMenuPointer(
        x: Double,
        y: Double,
        viewWidth: Double,
        viewHeight: Double,
        phase: GMLuaPointerPhase,
        timestamp: TimeInterval
    ) {
        guard isReady, !isInputSuspended,
              isClientMenuOpen, !isClientMenuTransitioning,
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
              !inputSuspensionInFlight, !isClientMenuTransitioning,
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
                  !inputSuspensionInFlight, !isClientMenuTransitioning,
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
            playClientSurfaceSounds(report.clientSurfaceSounds)
            scheduleClientSurfaceRefresh(
                applicationGeneration: activeToken.generation.application,
                laneGeneration: activeToken.generation.lane
            )
        } catch {
            if isReady, !isInputSuspended,
               !inputSuspensionInFlight, !isClientMenuTransitioning,
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
                activeMenu: activeClientMenu
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
            activeMenu: activeClientMenu
        )
    }

    private func invalidateSurfaceRequests() {
        surfaceRequestRevision &+= 1
        surfaceRefreshQueue.removeAll()
    }

    private func scheduleClientSurfaceRefresh(
        applicationGeneration: UInt64,
        laneGeneration: UInt64
    ) {
        guard GModGameClientSurfaceCapturePolicy.shouldCapture(
            activeMenu: activeClientMenu,
            transitioningMenu: transitioningClientMenu
        ) else {
            surfaceRefreshQueue.removeAll()
            if surfaceScene != nil || surfaceDiagnostics != nil {
                surfaceRequestRevision &+= 1
                surfaceScene = nil
                surfaceDiagnostics = nil
                surfaceStatus = "VGUI surface idle"
            }
            return
        }
        let generation = GModGameSessionGenerationToken(
            application: applicationGeneration,
            lane: laneGeneration
        )
        surfaceRefreshQueue.submit(GModGameSurfaceRefreshRequest(
            generation: generation
        ))
        guard surfaceRefreshTask == nil else { return }
        surfaceRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.drainClientSurfaceRefreshes()
        }
    }

    private func drainClientSurfaceRefreshes() async {
        while let request = surfaceRefreshQueue.takeLatest() {
            await refreshClientSurface(
                request: request
            )
        }
        surfaceRefreshTask = nil
    }

    /// Captures one renderer-facing frame for the current foreground Q/C
    /// owner. Pointer callbacks mutate Lua synchronously and enqueue this work
    /// in the same host input cycle; the latest-only refresh queue keeps scene
    /// construction from blocking subsequent pointer delivery.
    private func refreshClientSurface(
        request: GModGameSurfaceRefreshRequest
    ) async {
        guard GModGameClientSurfaceCapturePolicy.shouldCapture(
            activeMenu: activeClientMenu,
            transitioningMenu: transitioningClientMenu
        ) else {
            if surfaceScene != nil || surfaceDiagnostics != nil {
                invalidateSurfaceRequests()
                surfaceScene = nil
                surfaceDiagnostics = nil
                surfaceStatus = "VGUI surface idle"
            }
            return
        }
        let surfaceToken = beginSurfaceRequest(
            applicationGeneration: request.generation.application,
            laneGeneration: request.generation.lane
        )
        do {
            let snapshot = try await lane.renderClientVGUIFrame(
                expectedGeneration: request.generation.lane
            )
            await buildAndPublishSurfaceScene(snapshot, token: surfaceToken)
        } catch {
            guard isReady, !isInputSuspended,
                  !isClientMenuTransitioning,
                  surfaceToken.matches(
                      application: sessionGeneration,
                      lane: self.laneGeneration,
                      requestRevision: surfaceRequestRevision,
                      activeMenu: activeClientMenu
                  ) else {
                return
            }
            publishSurfaceFailure(
                "live VGUI render failed: \(GMLuaRuntime.describe(error))"
            )
        }
    }

    private func consumePointer(_ sample: GModGamePointerSample) async {
        guard isReady, !isInputSuspended,
              isClientMenuOpen, !isClientMenuTransitioning,
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
                  isClientMenuOpen, !isClientMenuTransitioning,
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
            scheduleClientSurfaceRefresh(
                applicationGeneration: sample.generation.application,
                laneGeneration: sample.generation.lane
            )
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

    private func recordLoadingProgress(
        _ progress: GModPlayableSessionLoadingProgress,
        requestedGeneration: UInt64
    ) {
        guard requestedGeneration == sessionGeneration, isStarting else { return }
        var replacement = loadingState
        guard replacement.record(progress) else { return }
        loadingState = replacement
        status = "loading.\(progress.taskIdentifier) — " +
            "\(progress.percentComplete)%"
    }

    private func handleWorldFrameEvent(_ event: GModMetalWorldFrameEvent) {
        switch event {
        case let .textureUploadProgress(progress):
            guard isStarting, isReady,
                  firstWorldFrameGate.matches(
                      meshIdentifier: progress.meshIdentifier
                  ) else { return }
            recordLoadingProgress(
                .init(
                    stage: .awaitingFirstMetalFrame,
                    completedSubunitCount: progress.uploadedTextureCount,
                    totalSubunitCount: progress.requiredTextureCount
                ),
                requestedGeneration: sessionGeneration
            )

        case let .presented(meshIdentifier):
            acknowledgePresentedWorldFrame(meshIdentifier: meshIdentifier)

        case let .failed(failure):
            guard isStarting, isReady,
                  firstWorldFrameGate.matches(
                      meshIdentifier: failure.meshIdentifier
                  ), let map = loadingMap else { return }
            var failedLoadingState = loadingState
            failedLoadingState.fail(failure.reason.diagnosticDescription)
            loadingState = failedLoadingState
            lastRendererFailure = failure
            startFailure = GModGameStartFailure(
                map: map,
                origin: .renderer(meshIdentifier: failure.meshIdentifier),
                detail: failure.reason.diagnosticDescription
            )
            firstWorldFrameGate.reset()
            suspendInput()
            status = "RENDERER START FAILED: " +
                failure.reason.diagnosticDescription
            appendLog("[RENDERER][ERROR] \(failure.meshIdentifier) " +
                failure.reason.diagnosticDescription)
        }
    }

    private func acknowledgePresentedWorldFrame(meshIdentifier: String) {
        guard isStarting, isReady,
              loadingState.progress.stage == .awaitingFirstMetalFrame,
              let map = loadingMap else {
            return
        }
        guard firstWorldFrameGate.acknowledge(
            meshIdentifier: meshIdentifier
        ) else { return }
        var replacement = loadingState
        guard replacement.record(.init(stage: .complete)) else { return }
        loadingState = replacement
        loadingMap = nil
        isStarting = false
        status = "READY \(map.rawValue) spawn=(" +
            "\(playerOrigin.x), \(playerOrigin.y), \(playerOrigin.z))"
    }

    private func failRuntime(_ error: Error) {
        let description = GMLuaRuntime.describe(error)
        audioController.stop(bus: .gameplay)
        if isStarting {
            var failedLoadingState = loadingState
            failedLoadingState.fail(description)
            loadingState = failedLoadingState
            firstWorldFrameGate.reset()
            if startFailure == nil, let map = loadingMap {
                startFailure = GModGameStartFailure(
                    map: map,
                    origin: .cpu,
                    detail: description
                )
            }
        }
        isReady = false
        invalidateSurfaceRequests()
        frameMailbox.disable()
        pointerMailbox.setEnabled(false)
        pointerEpoch = nil
        inputEpoch = nil
        worldScene = nil
        worldSkyVisibility = nil
        surfaceScene = nil
        surfaceDiagnostics = nil
        activeClientMenu = nil
        transitioningClientMenu = nil
        pauseMenuNotificationPending = false
        lastPointerFailure = nil
        lastMovementRejectionReason = nil
        movementStatus = "Movement stopped"
        status = "RUNTIME FAILED: \(description)"
        appendLog(status)
    }

    /// Preserves the surface queue's total order and repeated paths. The lane
    /// already drained this report exactly once; this method never retries a
    /// rejected or failed playback event.
    private func playClientSurfaceSounds(
        _ report: GMLuaSurfaceSoundRequestReport
    ) {
        if report.diagnostics.overflowed {
            let detail = "CLIENT surface.PlaySound queue retained " +
                "\(report.diagnostics.retainedRequestCount)/" +
                "\(report.diagnostics.attemptedRequestCount); dropped " +
                "\(report.diagnostics.droppedRequestCount)"
            recordAudioDiagnostic(GModAudioDiagnostic(
                code: .requestQueueOverflow,
                severity: .error,
                bus: .gameplay,
                message: detail,
                logicalPath: nil
            ))
        }

        for request in report.requests {
            guard let path = String(
                bytes: request.soundPath.bytes,
                encoding: .utf8
            ) else {
                recordAudioDiagnostic(GModAudioDiagnostic(
                    code: .invalidRequestEncoding,
                    severity: .error,
                    bus: .gameplay,
                    message: "CLIENT surface.PlaySound path is not UTF-8",
                    logicalPath: nil
                ))
                continue
            }
            audioController.play(
                path,
                origin: .lua,
                bus: .gameplay
            )
        }
    }

    private func recordAudioDiagnostic(
        _ diagnostic: GModAudioDiagnostic
    ) {
        guard let record = GModAudioProblemMapper.record(
            for: diagnostic
        ) else { return }
        diagnosticsStore.record(record)
        appendLog(
            "[CLIENT][AUDIO][\(diagnostic.code.rawValue)] " + record.detail
        )
    }

    private func beginInputSuspensionIfPossible() {
        guard isInputSuspended,
              !inputSuspensionInFlight,
              isReady,
              !isClientMenuTransitioning,
              let requestedLaneGeneration = laneGeneration,
              let requestedPointerEpoch = pointerEpoch,
              let requestedInputEpoch = inputEpoch else {
            return
        }
        inputSuspensionInFlight = true
        let notifyPauseMenuWillShow = pauseMenuNotificationPending
        pauseMenuNotificationPending = false
        let requestedGeneration = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let boundary = try await lane.suspendInput(
                    cancellationTimestamp: Date().timeIntervalSinceReferenceDate,
                    notifyPauseMenuWillShow: notifyPauseMenuWillShow,
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
                    if let lifecycleFailure = boundary.lifecycleFailure {
                        appendLog(
                            "[CLIENT][VGUI] Pause Menu notification failed: " +
                                lifecycleFailure
                        )
                    }
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
                if pauseMenuNotificationPending {
                    beginInputSuspensionIfPossible()
                }
            } else {
                activateInputIfPossible()
            }
        }
    }

    private func activateInputIfPossible() {
        guard isReady,
              !isInputSuspended,
              !inputSuspensionInFlight,
              !isClientMenuTransitioning,
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
        pointerMailbox.setEnabled(isClientMenuOpen)
        pointerStatus = isClientMenuOpen
            ? "Single-touch VGUI; native cancel active; " +
                "hover/wheel/keyboard pending"
            : "VGUI pointer idle"
    }

    private func reportPointerCancellationFailure(_ failure: String?) {
        guard let failure else { return }
        appendLog("[CLIENT][INPUT] Pointer cancellation callback failed: \(failure)")
    }

    /// UIKit gesture closures may arrive after a menu/pause ownership boundary.
    /// Stored axes are cleared and the mailbox receives only an idle snapshot;
    /// a delayed positive sample is never relabelled into the new epoch.
    private func rejectLateWorldInput() {
        clearHeldWorldInput()
        publishMovementInput()
    }

    private func clearHeldWorldInput() {
        forwardAxis = 0
        sideAxis = 0
        jumpPressed = false
        heldActionButtons = []
    }

    private func publishMovementInput() {
        frameMailbox.setMovementInput(
            GModGameWorldInputPolicy.movementInput(
                acceptsWorldInput: acceptsWorldInput,
                viewAngles: viewAngles,
                forwardAxis: forwardAxis,
                sideAxis: sideAxis,
                jumpPressed: jumpPressed,
                heldActionButtons: heldActionButtons
            )
        )
    }

    private func publishCameraScene() {
        guard let worldScene else { return }
        let eye = Self.cameraEye(for: playerOrigin)
        let sourceEye = SourceVector3(eye.x, eye.y, eye.z)
        let skyboxVisibility = Self.metalSkyboxVisibility(
            worldSkyVisibility?.visibility(at: sourceEye) ?? .notVisible
        )
        self.worldScene = worldScene.updatingCamera(
            eye: eye,
            forward: Self.cameraForward(for: viewAngles),
            up: Self.cameraUp(for: viewAngles),
            skyboxVisibility: skyboxVisibility,
            sourceFixedTime: Float(fixedTickCount) *
                SourceGlobalVars.intervalPerTick
        )
    }

    nonisolated private static func makeWorldScene(
        map: GModBundledMap,
        sessionGeneration: UInt64,
        mesh: GModWorldRenderMesh,
        playerOrigin: SourceVector3,
        viewAngles: SourceQAngle,
        textureResolver: GModMetalSurfaceSourceMaterialResolver
    ) throws -> GModMetalWorldScene {
        var retentionBudget = GModMetalWorldBitmapRetentionBudget(
            maximumByteCount: 128 * 1_024 * 1_024
        )
        let meshIdentifier =
            "session-\(sessionGeneration):\(map.rawValue):" +
            "\(mesh.vertices.count):\(mesh.indices.count)"
        let ranges: [GModMetalWorldMaterialRange] = mesh.materialRanges.map { range in
            let waterSurface = range.waterSurface.map {
                GModMetalWorldWaterSurface(
                    surfaceZ: $0.surfaceZ,
                    minimumZ: $0.minimumZ
                )
            }
            let waterMaterial = waterSurface.flatMap { _ in
                range.materialName.flatMap {
                    try? textureResolver.resolveWaterMaterial(named: $0)
                }
            }
            let materialResolution: GModMetalWorldMaterialResolution
            if waterSurface != nil || range.materialName == nil {
                materialResolution = .notApplicable
            } else if let name = range.materialName {
                do {
                    if let resolved = try textureResolver.resolveWorldTexture(
                        named: name
                    ) {
                        let requiredByteCount = resolved.totalByteCount
                        if retentionBudget.retain(resolved) {
                            materialResolution = .resolved(resolved)
                        } else {
                            materialResolution = .retentionCapacityExceeded(
                                requiredByteCount: requiredByteCount,
                                retainedByteCount: retentionBudget.retainedByteCount,
                                maximumByteCount: retentionBudget.maximumByteCount
                            )
                        }
                    } else {
                        materialResolution = .sourceMissing
                    }
                } catch {
                    materialResolution = .decodeFailed(
                        GMLuaRuntime.describe(error)
                    )
                }
            } else {
                materialResolution = .notApplicable
            }
            return GModMetalWorldMaterialRange(
                materialName: range.materialName,
                firstIndex: range.firstIndex,
                indexCount: range.indexCount,
                materialResolution: materialResolution,
                waterSurface: waterSurface,
                waterMaterial: waterMaterial,
                renderLayer: switch range.renderLayer {
                case .world: .world
                case .sky3D: .sky3D
                case .sky2D: .sky2D
                }
            )
        }
        let lightmapAtlas = mesh.lightmapAtlas.map {
            GModMetalWorldLightmapAtlas(
                identifier: "\(meshIdentifier):lightmap",
                width: $0.width,
                height: $0.height,
                linearRGBA16Float: $0.linearRGBA16Float
            )
        }
        let lightmapAtlasStatus: GModMetalWorldLightmapAtlasStatus
        switch mesh.diagnostics.lightmapAtlasStatus {
        case .unavailableNoLightmaps:
            lightmapAtlasStatus = .unavailableNoLightmaps
        case let .built(width, height, byteCount):
            lightmapAtlasStatus = .built(
                width: width,
                height: height,
                byteCount: byteCount
            )
        case let .capacityExceeded(
            requiredWidth,
            requiredHeight,
            requiredByteCount,
            maximumWidth,
            maximumHeight,
            maximumByteCount
        ):
            lightmapAtlasStatus = .capacityExceeded(
                requiredWidth: requiredWidth,
                requiredHeight: requiredHeight,
                requiredByteCount: requiredByteCount,
                maximumWidth: maximumWidth,
                maximumHeight: maximumHeight,
                maximumByteCount: maximumByteCount
            )
        }
        let unlitLightmapCoordinate = mesh.lightmapAtlas?.unlitTextureCoordinate
        return GModMetalWorldScene(
            meshIdentifier: meshIdentifier,
            sourcePositions: mesh.vertices.map {
                SIMD3<Float>($0.position.x, $0.position.y, $0.position.z)
            },
            sourceNormals: mesh.vertices.map {
                SIMD3<Float>($0.normal.x, $0.normal.y, $0.normal.z)
            },
            sourceTextureCoordinates: mesh.vertices.map {
                SIMD2<Float>($0.textureCoordinate.u, $0.textureCoordinate.v)
            },
            sourceLightmapTextureCoordinates: mesh.vertices.map {
                let coordinate = $0.lightmapCoordinate ?? unlitLightmapCoordinate ?? .zero
                return SIMD2<Float>(coordinate.u, coordinate.v)
            },
            indices: mesh.indices,
            materialRanges: ranges,
            lightmapAtlas: lightmapAtlas,
            lightmapDiagnostics: GModMetalWorldLightmapDiagnostics(
                atlasStatus: lightmapAtlasStatus,
                ignoredAdditionalLightStyleFaceCount:
                    mesh.diagnostics.ignoredAdditionalLightStyleFaceCount,
                ignoredBumpLightFaceCount:
                    mesh.diagnostics.ignoredBumpLightFaceCount,
                clampedChannelCount: mesh.lightmapAtlas?.clampedChannelCount ?? 0
            ),
            sky3D: mesh.sky3D.map {
                GModMetalWorldSky3D(
                    sourceOrigin: SIMD3<Float>(
                        $0.origin.x,
                        $0.origin.y,
                        $0.origin.z
                    ),
                    scale: $0.scale
                )
            },
            skyboxVisibility: metalSkyboxVisibility(
                mesh.skyVisibility?.visibility(
                    at: SourceVector3(
                        playerOrigin.x,
                        playerOrigin.y,
                        playerOrigin.z + 64
                    )
                ) ?? .notVisible
            ),
            cameraEye: cameraEye(for: playerOrigin),
            cameraForward: cameraForward(for: viewAngles),
            cameraUp: cameraUp(for: viewAngles)
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
        let forward = angles.sourceBasis.forward
        return SIMD3<Float>(forward.x, forward.y, forward.z)
    }

    nonisolated private static func cameraUp(
        for angles: SourceQAngle
    ) -> SIMD3<Float> {
        let up = angles.sourceBasis.up
        return SIMD3<Float>(up.x, up.y, up.z)
    }

    nonisolated private static func metalSkyboxVisibility(
        _ visibility: GModWorldSkyboxVisibility
    ) -> GModMetalSkyboxVisibility {
        return switch visibility {
        case .notVisible: .notVisible
        case .sky3D: .sky3D
        case .sky2D: .sky2D
        }
    }

    private func appendLog(_ value: String) {
        recentLogs.append(value)
        if recentLogs.count > 80 {
            recentLogs.removeFirst(recentLogs.count - 80)
        }
        logSink(value)
    }
}

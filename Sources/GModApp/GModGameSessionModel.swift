import Combine
import Foundation
import GModEngine
import GModGameAssets
import GModGameSession
import GModMetal

private struct GModGameFrameBatch: Sendable {
    let generation: UInt64
    let fixedTickCount: Int
    let viewport: GMLuaViewportSize
    let movementInput: GModPlayableMovementInput
}

/// Lock-protected one-slot mailbox between MTKView's render callback and the
/// serialized game actor. Slow Lua frames coalesce rather than creating an
/// unbounded queue of MainActor tasks.
private final class GModGameFrameMailbox: @unchecked Sendable {
    private static let maximumCatchUpTicks = 8

    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var drainScheduled = false
    private var pendingTicks = 0
    private var pendingViewport = GMLuaViewportSize.logicalDesktopDefault
    private var movementInput = GModPlayableMovementInput.idle
    private var hasPendingFrame = false

    func setEnabled(_ replacement: Bool, generation: UInt64? = nil) {
        lock.lock()
        enabled = replacement
        if let generation {
            self.generation = generation
        }
        if !replacement {
            pendingTicks = 0
            hasPendingFrame = false
        }
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
        guard enabled, hasPendingFrame else {
            drainScheduled = false
            return nil
        }
        let batch = GModGameFrameBatch(
            generation: generation,
            fixedTickCount: pendingTicks,
            viewport: pendingViewport,
            movementInput: movementInput
        )
        pendingTicks = 0
        hasPendingFrame = false
        return batch
    }
}

@MainActor
final class GModGameSessionModel: ObservableObject {
    @Published private(set) var status = "Choose a bundled map to start Sandbox"
    @Published private(set) var activeMap: GModBundledMap?
    @Published private(set) var isStarting = false
    @Published private(set) var isReady = false
    @Published private(set) var fixedTickCount: UInt64 = 0
    @Published private(set) var lastDeliveredMessages = 0
    @Published private(set) var recentLogs: [String] = []
    @Published private(set) var playerOrigin = SourceVector3.zero
    @Published private(set) var viewAngles = SourceQAngle.zero
    @Published private(set) var worldScene: GModMetalWorldScene?

    private let lane: GModPlayableSessionLane
    private let logSink: (String) -> Void
    private nonisolated let frameMailbox = GModGameFrameMailbox()
    private var forwardAxis: Float = 0
    private var sideAxis: Float = 0
    private var sessionGeneration: UInt64 = 0
    private var laneGeneration: UInt64?

    init(
        runtimeFactory: GModAppRuntimeFactory,
        logSink: @escaping (String) -> Void = { _ in }
    ) {
        lane = runtimeFactory.makePlayableSessionLane()
        self.logSink = logSink
    }

    deinit {
        let lane = lane
        Task {
            _ = try? await lane.close()
        }
    }

    func start(map: GModBundledMap) {
        guard !isStarting else { return }
        isStarting = true
        isReady = false
        activeMap = nil
        worldScene = nil
        sessionGeneration &+= 1
        let requestedGeneration = sessionGeneration
        laneGeneration = nil
        frameMailbox.setEnabled(false)
        status = "Loading \(map.rawValue) / Sandbox…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await lane.start(
                    configuration: GModPlayableSessionConfiguration(map: map),
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
                isReady = true
                fixedTickCount = 0
                lastDeliveredMessages = snapshot.startup.deliveredMessages
                playerOrigin = snapshot.playerWalkState.origin
                viewAngles = snapshot.playerWalkState.viewAngles
                forwardAxis = 0
                sideAxis = 0
                publishMovementInput()
                worldScene = Self.makeWorldScene(
                    map: map,
                    mesh: snapshot.worldMesh,
                    playerOrigin: playerOrigin,
                    viewAngles: viewAngles
                )
                let spawn = snapshot.startup.spawnPoint.origin
                status = "READY \(map.rawValue) spawn=(\(spawn.x), \(spawn.y), \(spawn.z))"
                frameMailbox.setEnabled(
                    true,
                    generation: requestedGeneration
                )
            } catch {
                guard requestedGeneration == sessionGeneration else { return }
                activeMap = nil
                isReady = false
                status = "START FAILED: \(GMLuaRuntime.describe(error))"
                appendLog(status)
            }
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
        forwardAxis = Swift.max(-1, Swift.min(1, forward))
        sideAxis = Swift.max(-1, Swift.min(1, side))
        publishMovementInput()
    }

    func adjustLook(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.12
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

    private func consumeFrame(_ batch: GModGameFrameBatch) async {
        guard isReady,
              batch.generation == sessionGeneration,
              let activeLaneGeneration = laneGeneration else {
            return
        }
        let activeGeneration = batch.generation
        do {
            let report = try await lane.runHostFrame(
                fixedTickCount: batch.fixedTickCount,
                viewport: batch.viewport,
                movementInput: batch.movementInput,
                expectedGeneration: activeLaneGeneration
            )
            guard isReady, activeGeneration == sessionGeneration else { return }
            fixedTickCount &+= UInt64(report.fixedTicks.count)
            lastDeliveredMessages = report.deliveredMessages
            playerOrigin = report.playerWalkState.origin
            publishCameraScene()
            for tick in report.fixedTicks {
                reportFailures(tick.server)
                reportFailures(tick.client)
            }
            if let clientFrame = report.clientFrame {
                reportFailures(clientFrame)
            }
        } catch {
            if activeGeneration == sessionGeneration {
                failRuntime(error)
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

    private func failRuntime(_ error: Error) {
        isReady = false
        frameMailbox.setEnabled(false)
        worldScene = nil
        status = "RUNTIME FAILED: \(GMLuaRuntime.describe(error))"
        appendLog(status)
    }

    private func publishMovementInput() {
        let speed: Float = 250
        var buttons: SourceInputButtons = []
        if forwardAxis > 0 { buttons.insert(.forward) }
        if forwardAxis < 0 { buttons.insert(.back) }
        if sideAxis > 0 { buttons.insert(.moveRight) }
        if sideAxis < 0 { buttons.insert(.moveLeft) }
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

    private static func makeWorldScene(
        map: GModBundledMap,
        mesh: GModWorldRenderMesh,
        playerOrigin: SourceVector3,
        viewAngles: SourceQAngle
    ) -> GModMetalWorldScene {
        GModMetalWorldScene(
            meshIdentifier: "\(map.rawValue):\(mesh.vertices.count):\(mesh.indices.count)",
            sourcePositions: mesh.vertices.map {
                SIMD3<Float>($0.position.x, $0.position.y, $0.position.z)
            },
            sourceNormals: mesh.vertices.map {
                SIMD3<Float>($0.normal.x, $0.normal.y, $0.normal.z)
            },
            indices: mesh.indices,
            cameraEye: cameraEye(for: playerOrigin),
            cameraForward: cameraForward(for: viewAngles)
        )
    }

    private static func cameraEye(for origin: SourceVector3) -> SIMD3<Float> {
        SIMD3<Float>(origin.x, origin.y, origin.z + 64)
    }

    private static func cameraForward(for angles: SourceQAngle) -> SIMD3<Float> {
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

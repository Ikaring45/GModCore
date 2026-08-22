import Foundation
import XCTest
@testable import GModEngine

private enum CameraToolTestError: Error {
    case expectedSpawn
}

final class SourceCanonicalCameraToolTests: XCTestCase {
    func testBundledCameraLifecycleOwnershipTrackingInputAndImmutableProjection()
        throws
    {
        let entityList = SourceEntityList(initialSerialNumber: 90)
        let canonical = SourceCanonicalEntityStore(entityList: entityList)
        let world = try canonical.create(kind: .world, at: 0)
        let player = try canonical.create(kind: .player, at: 1)
        let otherPlayer = try canonical.create(kind: .player, at: 2)

        var limitAllowed = false
        var limitCalls = 0
        let coordinator = SourceCanonicalCameraToolCoordinator(
            entityList: entityList,
            limitGate: { owner in
                XCTAssertEqual(owner, player.identity)
                limitCalls += 1
                return limitAllowed
            }
        )
        let client = SourceCanonicalCameraClientProjection()
        let trace = SourceCanonicalCameraTrace(
            startPosition: SourceVector3(96, 0, 64),
            hitPosition: SourceVector3(128, 0, 48),
            target: SourceCanonicalCameraTrackingTargetSnapshot(world)
        )

        var canToolCalls = 0
        let denied = try coordinator.perform(
            SourceCanonicalCameraToolRequest(
                actor: player,
                action: .leftClick,
                trace: trace,
                settings: .bundledDefaults
            ),
            canTool: { request in
                canToolCalls += 1
                XCTAssertEqual(request.action.rawValue, 1)
                XCTAssertEqual(request.actor.identity, player.identity)
                return false
            }
        )
        XCTAssertEqual(denied, .rejected(.canToolDenied))
        XCTAssertEqual(canToolCalls, 1)
        XCTAssertEqual(limitCalls, 0)
        XCTAssertTrue(coordinator.snapshots.isEmpty)

        let disabled = try coordinator.perform(
            SourceCanonicalCameraToolRequest(
                actor: player,
                action: .leftClick,
                trace: trace,
                settings: SourceCanonicalCameraToolSettings(
                    controlKey: -1,
                    locked: 0,
                    toggle: 1
                )
            ),
            canTool: { _ in canToolCalls += 1; return true }
        )
        XCTAssertEqual(disabled, .rejected(.controlKeyDisabled))
        XCTAssertEqual(canToolCalls, 2, "stock CanTool precedes LeftClick")
        XCTAssertEqual(limitCalls, 0)

        let limited = try coordinator.perform(
            SourceCanonicalCameraToolRequest(
                actor: player,
                action: .leftClick,
                trace: trace,
                settings: .bundledDefaults
            ),
            canTool: { _ in true }
        )
        XCTAssertEqual(limited, .rejected(.cameraLimitReached))
        XCTAssertEqual(limitCalls, 1)

        limitAllowed = true
        let first = try spawned(coordinator.perform(
            SourceCanonicalCameraToolRequest(
                actor: player,
                action: .leftClick,
                trace: trace,
                settings: .bundledDefaults
            ),
            canTool: { _ in true }
        ))
        XCTAssertEqual(limitCalls, 2)
        XCTAssertEqual(first.camera.className, "gmod_cameraprop")
        XCTAssertEqual(
            first.camera.model.path,
            "models/dav0r/camera.mdl"
        )
        XCTAssertEqual(first.camera.lifecycle, .spawned)
        XCTAssertEqual(first.camera.revision, 1)
        XCTAssertEqual(first.camera.owner, player.identity)
        XCTAssertEqual(first.camera.controlKey, 37)
        XCTAssertEqual(first.camera.locked, 0)
        XCTAssertEqual(first.camera.toggle, 1)
        XCTAssertNil(first.camera.trackingEntity)
        XCTAssertEqual(first.camera.trackingLocalPosition, .zero)
        XCTAssertEqual(first.camera.moveType, .vPhysics)
        XCTAssertEqual(first.camera.solidType, .vPhysics)
        XCTAssertEqual(first.camera.collisionGroup, .weapon)
        XCTAssertFalse(first.camera.drawsShadow)
        XCTAssertTrue(first.camera.physicsObjectStartsAsleep)
        XCTAssertTrue(try coordinator.canUseTool(
            onCamera: first.camera.identity
        ))
        XCTAssertNil(first.camera.projectionOverrides.fieldOfViewDegrees)
        XCTAssertNil(first.camera.projectionOverrides.nearClip)
        XCTAssertNil(first.camera.projectionOverrides.farClip)
        XCTAssertNil(first.camera.projectionOverrides.orthographicBounds)
        XCTAssertNil(first.camera.projectionOverrides.drawsViewer)
        XCTAssertEqual(first.cleanupCategory, "cameras")
        XCTAssertEqual(first.undo.name, "gmod_cameraprop")
        XCTAssertEqual(first.undo.player, player.identity)
        XCTAssertEqual(first.undo.camera, first.camera.identity)
        XCTAssertEqual(
            coordinator.cleanupCameras(for: player.identity),
            [first.camera.identity]
        )

        let initialBatch = try XCTUnwrap(
            coordinator.drainReplicationBatch()
        )
        XCTAssertEqual(initialBatch.sequence, 1)
        XCTAssertEqual(initialBatch.operations.count, 2)
        try client.apply(initialBatch)
        XCTAssertEqual(
            client.snapshot(for: first.camera.identity),
            first.camera
        )

        XCTAssertEqual(
            try coordinator.inputActionForBinding(
                camera: first.camera.identity,
                pressed: true
            ),
            .toggle
        )
        XCTAssertNil(try coordinator.inputActionForBinding(
            camera: first.camera.identity,
            pressed: false
        ))
        XCTAssertNil(try coordinator.handleInput(
            SourceCanonicalCameraInput(
                player: otherPlayer.identity,
                camera: first.camera.identity,
                action: .toggle,
                source: .touch(actionIdentifier: 9)
            )
        ))
        let firstOn = try XCTUnwrap(coordinator.handleInput(
            SourceCanonicalCameraInput(
                player: player.identity,
                camera: first.camera.identity,
                action: .toggle,
                source: .touch(actionIdentifier: 9)
            )
        ))
        XCTAssertTrue(firstOn.isOn)
        XCTAssertEqual(firstOn.usingPlayer, player.identity)
        try client.apply(try XCTUnwrap(coordinator.drainReplicationBatch()))
        let firstView = try XCTUnwrap(client.activeView(
            for: player.identity,
            target: { _ in nil }
        ))
        XCTAssertEqual(firstView.camera, first.camera.identity)
        XCTAssertEqual(firstView.origin, trace.startPosition)
        XCTAssertEqual(firstView.angles, player.transform.angles)
        XCTAssertEqual(
            firstView.projectionOverrides,
            .bundledCameraTool
        )

        // Same owner/key replaces the previous camera without consulting the
        // count limit again, exactly as CheckLimit/MakeCamera do.
        limitAllowed = false
        let replacement = try spawned(coordinator.perform(
            SourceCanonicalCameraToolRequest(
                actor: player,
                action: .leftClick,
                trace: SourceCanonicalCameraTrace(
                    startPosition: SourceVector3(160, 0, 64),
                    hitPosition: .zero,
                    target: SourceCanonicalCameraTrackingTargetSnapshot(world)
                ),
                settings: .bundledDefaults
            ),
            canTool: { _ in true }
        ))
        XCTAssertEqual(limitCalls, 2)
        XCTAssertEqual(
            replacement.replacedCameras,
            [first.camera.identity]
        )
        XCTAssertEqual(
            coordinator.snapshot(for: first.camera.identity)?.lifecycle,
            .pendingRemoval
        )
        XCTAssertNotEqual(
            replacement.camera.identity,
            first.camera.identity
        )
        try client.apply(try XCTUnwrap(coordinator.drainReplicationBatch()))
        XCTAssertEqual(
            client.snapshot(for: first.camera.identity)?.lifecycle,
            .pendingRemoval
        )
        XCTAssertNotNil(client.snapshot(for: replacement.camera.identity))

        XCTAssertEqual(entityList.cleanupDeleteList(), 1)
        let removedFirst = try XCTUnwrap(
            coordinator.acknowledgeCleanup(first.camera.identity)
        )
        XCTAssertEqual(removedFirst.lifecycle, .removed)
        XCTAssertNil(coordinator.snapshot(for: first.camera.identity))

        // Right click first spawns a camera, then tracks world as the owner at
        // local zero. A locked camera uses the symbolic WORLD collision group
        // without guessing its SDK integer in this isolated slice.
        limitAllowed = true
        let right = try spawned(coordinator.perform(
            SourceCanonicalCameraToolRequest(
                actor: player,
                action: .rightClick,
                trace: SourceCanonicalCameraTrace(
                    startPosition: SourceVector3(100, 0, 64),
                    hitPosition: SourceVector3(999, 999, 999),
                    target: SourceCanonicalCameraTrackingTargetSnapshot(world)
                ),
                settings: SourceCanonicalCameraToolSettings(
                    controlKey: 38,
                    locked: 1,
                    toggle: 0
                )
            ),
            canTool: { request in
                XCTAssertEqual(request.action.rawValue, 2)
                XCTAssertEqual(request.trace.target?.identity, world.identity)
                return true
            }
        ))
        XCTAssertEqual(limitCalls, 3)
        XCTAssertEqual(
            right.camera.identity.entryIndex,
            first.camera.identity.entryIndex
        )
        XCTAssertNotEqual(
            right.camera.identity.handle,
            first.camera.identity.handle
        )
        XCTAssertEqual(right.camera.trackingEntity, player.identity)
        XCTAssertEqual(right.camera.trackingLocalPosition, .zero)
        XCTAssertEqual(right.camera.moveType, .none)
        XCTAssertEqual(right.camera.solidType, .boundingBox)
        XCTAssertEqual(right.camera.collisionGroup, .world)
        XCTAssertFalse(try coordinator.canUseTool(
            onCamera: right.camera.identity
        ))
        XCTAssertEqual(
            try coordinator.inputActionForBinding(
                camera: right.camera.identity,
                pressed: true
            ),
            .activate
        )
        XCTAssertEqual(
            try coordinator.inputActionForBinding(
                camera: right.camera.identity,
                pressed: false
            ),
            .deactivate
        )

        // One FIFO batch removes the old generation before creating the new
        // one in the same entry. The immutable CLIENT projection never aliases
        // the two handles.
        let reuseBatch = try XCTUnwrap(coordinator.drainReplicationBatch())
        try client.apply(reuseBatch)
        XCTAssertNil(client.snapshot(for: first.camera.identity))
        XCTAssertEqual(client.snapshot(for: right.camera.identity), right.camera)

        let rightOn = try XCTUnwrap(coordinator.handleInput(
            SourceCanonicalCameraInput(
                player: player.identity,
                camera: right.camera.identity,
                action: .activate,
                source: .controlKey(38)
            )
        ))
        XCTAssertTrue(rightOn.isOn)
        try client.apply(try XCTUnwrap(coordinator.drainReplicationBatch()))
        let trackingView = try XCTUnwrap(client.activeView(
            for: player.identity,
            target: { identity in
                identity == player.identity
                    ? SourceCanonicalCameraTrackingTargetSnapshot(player)
                    : nil
            }
        ))
        XCTAssertEqual(trackingView.camera, right.camera.identity)
        XCTAssertEqual(trackingView.origin, right.camera.transform.origin)
        XCTAssertNotEqual(trackingView.angles, right.camera.transform.angles)
        XCTAssertTrue(trackingView.angles.pitch.isFinite)
        XCTAssertTrue(trackingView.angles.yaw.isFinite)
        XCTAssertEqual(
            trackingView.projectionOverrides,
            .bundledCameraTool
        )

        XCTAssertEqual(
            try coordinator.undoLatestCamera(for: player.identity),
            right.camera.identity
        )
        let cleanup = try coordinator.markCleanupForRemoval(
            player: player.identity
        )
        XCTAssertEqual(
            cleanup.sorted { $0.handle.rawValue < $1.handle.rawValue },
            [replacement.camera.identity, right.camera.identity].sorted {
                $0.handle.rawValue < $1.handle.rawValue
            }
        )
        try client.apply(try XCTUnwrap(coordinator.drainReplicationBatch()))
        XCTAssertEqual(entityList.cleanupDeleteList(), 2)
        XCTAssertNotNil(try coordinator.acknowledgeCleanup(
            replacement.camera.identity
        ))
        XCTAssertNotNil(try coordinator.acknowledgeCleanup(
            right.camera.identity
        ))
        try client.apply(try XCTUnwrap(coordinator.drainReplicationBatch()))
        XCTAssertTrue(client.snapshots.isEmpty)
        XCTAssertTrue(coordinator.cleanupCameras(
            for: player.identity
        ).isEmpty)
        XCTAssertTrue(coordinator.undoRecords.allSatisfy { !$0.isLive })
    }

    private func spawned(
        _ result: SourceCanonicalCameraToolResult
    ) throws -> SourceCanonicalCameraSpawnResult {
        guard case let .spawned(spawn) = result else {
            XCTFail("expected camera spawn, got \(result)")
            throw CameraToolTestError.expectedSpawn
        }
        return spawn
    }
}

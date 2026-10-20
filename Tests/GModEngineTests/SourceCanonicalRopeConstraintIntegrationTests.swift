import Foundation
import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

private final class RopeWorldMissProvider:
    GMLuaTraceProvider, @unchecked Sendable
{
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class RopeDynamicProvider:
    GMLuaDynamicTraceCandidateProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [GMLuaDynamicTraceCandidate] = []

    var isDynamicTraceReady: Bool { true }

    var candidates: [GMLuaDynamicTraceCandidate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}

private final class AttestedRopeCommandQueue:
    SourceCanonicalRopeConstraintCommandQueue,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let sequenceSource:
        any SourceCanonicalPropPhysicsCommandSequenceSource
    private var storage: [SourceCanonicalQueuedRopeConstraintCommand] = []
    var rejection: SourceCanonicalRopeConstraintBackendError?

    init(
        sequenceSource: any SourceCanonicalPropPhysicsCommandSequenceSource
    ) {
        self.sequenceSource = sequenceSource
    }

    var commands: [SourceCanonicalQueuedRopeConstraintCommand] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func enqueueCanonicalRopeConstraintCommands(
        _ commands: [SourceCanonicalRopeConstraintCommand]
    ) throws -> [SourceCanonicalQueuedRopeConstraintCommand] {
        if let rejection { throw rejection }
        let sequences = try sequenceSource.reservePhysicsCommandSequences(
            count: commands.count
        )
        let queued = zip(sequences, commands).map {
            SourceCanonicalQueuedRopeConstraintCommand(
                sequence: $0.0,
                command: $0.1
            )
        }
        lock.lock()
        storage.append(contentsOf: queued)
        lock.unlock()
        return queued
    }

    func rollbackCanonicalRopeConstraintCommands(
        _ commands: [SourceCanonicalQueuedRopeConstraintCommand]
    ) {
        guard !commands.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        precondition(Array(storage.suffix(commands.count)) == commands)
        storage.removeLast(commands.count)
    }
}

final class SourceCanonicalRopeConstraintIntegrationTests: XCTestCase {
    func testStockRopeReachesAngularSolverAndCanonicalPhysObjState() throws {
        let model = SourceEntityModelReference("models/props/angular_rope_fixture.mdl")
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            // Keep this synthetic mechanical fixture outside the unrelated,
            // unattested BSP contact-material boundary.
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody, damping: .zero,
                isGravityEnabled: false, isCollisionEnabled: false, startsAwake: true
            ),
            massCenterLocal: SourceVector3(2, -3, 1)
        )
        let session = try GModPlayableSession(
            configuration: .init(map: .construct), textMeasurer: nil,
            logger: { _, _ in }, worldWalkCollisionProvider: nil,
            canonicalModelValidator: { requested, kind in
                requested == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting: makeAttestedPropPhysicsTestResolver(asset: asset)
        )
        defer { _ = try? session.close() }
        let first = try activeProp(in: session, model: model, origin: SourceVector3(0, 0, 100))
        let second = try activeProp(in: session, model: model, origin: SourceVector3(10, -2, 100))
        _ = try session.runFixedTick()
        try executeReportingLuaErrors(session.serverRuntime,
            """
            local first = Entity(\(first.identity.entryIndex))
            local second = Entity(\(second.identity.entryIndex))
            first:GetPhysicsObject():EnableMotion(false)
            second:GetPhysicsObject():SetVelocity(Vector(4, 0, 0))
            local rope
            ANGULAR_ROPE_CONSTRAINT, rope = constraint.Rope(
                first, second, 0, 0, Vector(2, -3, 1), Vector(2, -1, 1),
                10, 0, 0, 2, "cable/rope", false
            )
            assert(IsValid(ANGULAR_ROPE_CONSTRAINT))
            assert(rope == nil and ANGULAR_ROPE_CONSTRAINT.RopeRenderAvailable == false)
            """,
            sourceName: "=(stock rope to actual physics solver)"
        )
        let report = try session.runFixedTick()
        XCTAssertEqual(report.actionFailures, [])
        XCTAssertEqual(report.propPhysics.lengthConstraints.count, 1)
        let body = try XCTUnwrap(report.propPhysics.bodies.first { $0.bodyID.entityIdentity == second.identity })
        let impulse: Float = 4 / (1 / 12 + 4 / 4)
        XCTAssertEqual(body.linearVelocity.x, 4 - impulse / 12, accuracy: 0.0001)
        XCTAssertEqual(body.angularVelocity.z, 2 * impulse / 4 * 180 / .pi, accuracy: 0.0001)
        XCTAssertEqual(body.massProperties.massCenterLocal, SourceVector3(2, -3, 1))
        let server = try XCTUnwrap(session.sourceAdapter.canonicalSnapshot(for: second.identity))
        let client = try XCTUnwrap(session.clientCanonicalEntitySnapshots.first { $0.identity == second.identity })
        XCTAssertEqual(server.motion.linearVelocity, body.linearVelocity)
        XCTAssertEqual(server.motion.angularVelocity, body.angularVelocity)
        XCTAssertEqual(server.transform, body.transform)
        XCTAssertEqual(client.transform, body.transform)
        try executeReportingLuaErrors(session.serverRuntime,
            """
            local phys = Entity(\(second.identity.entryIndex)):GetPhysicsObject()
            assert(phys:GetAngleVelocity().z > 100, "rope angular velocity not published to PhysObj")
            local velocity = phys:GetVelocityAtPoint(phys:LocalToWorld(Vector(2, -1, 1)))
            assert(math.abs(velocity.x) < 0.001, "rope attachment still has outward speed")
            assert(constraint.RemoveConstraints(Entity(\(first.identity.entryIndex)), "Rope"), "rope removal failed")
            -- Entity removal is finalized at the next fixed-tick boundary.
            """,
            sourceName: "=(solved rope PhysObj reads and removal)"
        )
        let removed = try session.runFixedTick()
        XCTAssertEqual(removed.actionFailures, [])
        XCTAssertTrue(removed.propPhysics.lengthConstraints.isEmpty)
        XCTAssertFalse(session.serverToolActionBridge.constraintGraph.hasConstraints(involving: first.identity))
        try executeReportingLuaErrors(session.serverRuntime,
            "assert(not IsValid(ANGULAR_ROPE_CONSTRAINT), 'removed rope Entity still valid after fixed tick')",
            sourceName: "=(finalized rope removal)"
        )
    }

    private func executeReportingLuaErrors(_ runtime: GMLuaRuntime, _ source: String, sourceName: String) throws {
        do {
            try runtime.execute(source, sourceName: sourceName)
        } catch let raised as LuaRaisedError {
            throw LuaError.runtime(raised.value.printable)
        }
    }

    func testStockRopeTwoClickRoutePreservesExactFIFOAndWorldBoundary()
        throws
    {
        let model = SourceEntityModelReference(
            "models/props/canonical_rope_fixture.mdl"
        )
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { requested, kind in
                requested == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting:
                makeAttestedPropPhysicsTestResolver(asset: asset)
        )
        defer { _ = try? session.close() }

        let first = try activeProp(
            in: session,
            model: model,
            origin: SourceVector3(96, 0, 96)
        )
        let second = try activeProp(
            in: session,
            model: model,
            origin: SourceVector3(160, 0, 96)
        )
        _ = try session.runFixedTick()

        let world = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .world
            }
        )
        let worldBodyID = try SourcePhysicsBodyID(
            entityIdentity: world.identity,
            solidIndex: 0
        )
        let queue = AttestedRopeCommandQueue(
            sequenceSource: session.sharedSession.netTransport
        )
        let bridge = try SourceCanonicalRopeConstraintGLuaBridge.install(
            into: session.serverRuntime,
            entityHost: session.sourceAdapter,
            physicsHost: session.sourceAdapter,
            commandQueue: queue,
            constraintGraph:
                session.serverToolActionBridge.constraintGraph,
            worldPhysicsBodyID: worldBodyID
        )

        // A typed controller refusal performs a full Entity/graph/FIFO
        // rollback instead of returning a fake constraint.
        queue.rejection = .flexibleLengthConstraintUnavailable
        try session.serverRuntime.execute(
            """
            local first = Entity(\(first.identity.entryIndex))
            local second = Entity(\(second.identity.entryIndex))
            local constraintEntity, rope = constraint.Rope(
                first, second, 0, 0,
                Vector(0, 0, 0), Vector(0, 0, 0),
                64, 0, 0, 2, "cable/rope", false, Color(255, 255, 255)
            )
            assert(constraintEntity == false and rope == nil)
            """,
            sourceName: "=(typed rope backend rejection)"
        )
        XCTAssertEqual(
            bridge.store.lastFailure,
            .backend(.flexibleLengthConstraintUnavailable)
        )
        XCTAssertTrue(bridge.store.bindings.isEmpty)
        XCTAssertTrue(queue.commands.isEmpty)
        queue.rejection = nil

        let dynamic = RopeDynamicProvider()
        session.serverRuntime.traceBridge?.connect(provider:
            GMLuaCompositeTraceProvider(
                world: RopeWorldMissProvider(),
                dynamic: dynamic
            )
        )
        XCTAssertEqual(
            session.clientRuntime.conVarRegistry?.stringValue(
                for: "gmod_toolmode"
            ),
            "rope"
        )
        try session.clientRuntime.execute(
            """
            RunConsoleCommand("rope_forcelimit", "0")
            RunConsoleCommand("rope_addlength", "0")
            RunConsoleCommand("rope_material", "cable/rope")
            RunConsoleCommand("rope_width", "2")
            RunConsoleCommand("rope_rigid", "0")
            RunConsoleCommand("rope_color_r", "255")
            RunConsoleCommand("rope_color_g", "255")
            RunConsoleCommand("rope_color_b", "255")
            """,
            sourceName: "=(stock rope defaults)"
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give stock rope toolgun)"
        )
        _ = try session.runFixedTick()

        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        let shootPosition = player.transform.origin + player.viewOffset
        let forward = player.transform.angles.sourceBasis.forward
        dynamic.candidates = [try candidate(
            for: first,
            at: shootPosition + forward * 96
        )]
        let firstClick = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(firstClick.weaponGameplay.failures, [])
        XCTAssertEqual(firstClick.actionFailures, [])
        XCTAssertTrue(bridge.store.bindings.isEmpty)
        XCTAssertTrue(queue.commands.isEmpty)

        _ = try session.runFixedTick()
        dynamic.candidates = [try candidate(
            for: second,
            at: shootPosition + forward * 160
        )]
        let secondClick = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(secondClick.weaponGameplay.failures, [])
        XCTAssertEqual(secondClick.actionFailures, [])

        let binding = try XCTUnwrap(bridge.store.bindings.only)
        XCTAssertEqual(binding.request.first.entity, first.identity)
        XCTAssertEqual(binding.request.second.entity, second.identity)
        XCTAssertEqual(binding.request.first.kind, .dynamicBody)
        XCTAssertEqual(binding.request.second.kind, .dynamicBody)
        XCTAssertEqual(binding.request.additionalLength, 0)
        XCTAssertEqual(binding.request.forceLimit, 0)
        XCTAssertEqual(binding.request.width, 2)
        XCTAssertEqual(binding.request.material, LuaString("cable/rope"))
        XCTAssertFalse(binding.request.isRigid)
        XCTAssertEqual(
            binding.request.color,
            SourceCanonicalRopeColor(
                red: 255,
                green: 255,
                blue: 255,
                alpha: 255
            )
        )
        XCTAssertEqual(
            binding.renderingState,
            .unavailableKeyframeRopeEntity
        )
        XCTAssertEqual(
            binding.request.authoredLength,
            (binding.request.first.worldAnchor -
                binding.request.second.worldAnchor).length,
            accuracy: 0.001
        )
        XCTAssertEqual(queue.commands.map(\.command), [
            .create(binding.request),
            .wake(binding.request.first.bodyID),
            .wake(binding.request.second.bodyID),
        ])
        XCTAssertTrue(zip(
            queue.commands,
            queue.commands.dropFirst()
        ).allSatisfy { $0.sequence < $1.sequence })
        XCTAssertEqual(
            session.sourceAdapter.canonicalSnapshot(
                for: binding.constraintEntity
            )?.lifecycle,
            .active
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local rows = undo.GetTable()[ply:UniqueID()]
            assert(rows and rows[1], "stock rope tool did not create undo")
            assert(undo.Do_Undo(rows[1]) == 1)
            """,
            sourceName: "=(stock rope undo removal)"
        )
        XCTAssertTrue(bridge.store.bindings.isEmpty)
        XCTAssertEqual(queue.commands.last?.command,
            .delete(binding.request.constraintID))
        XCTAssertFalse(
            session.serverToolActionBridge.constraintGraph.hasConstraints(
                involving: first.identity
            )
        )

        // Worldspawn remains a real static-scene endpoint with its full
        // canonical identity; it is not replaced by a guessed dynamic body.
        try session.serverRuntime.execute(
            """
            local first = Entity(\(first.identity.entryIndex))
            local world = Entity(\(world.identity.entryIndex))
            local constraintEntity, rope = constraint.Rope(
                first, world, 0, 0,
                Vector(1, 2, 3), Vector(4, 5, 6),
                48, 5, 12, 3, "cable/cable2", true,
                Color(10, 20, 30, 40)
            )
            assert(IsValid(constraintEntity))
            assert(constraintEntity.Type == "Rope")
            assert(constraintEntity.RopeRenderAvailable == false)
            assert(rope == nil)
            assert(constraint.RemoveConstraints(first, "Rope"))
            """,
            sourceName: "=(canonical rope static world endpoint)"
        )
        XCTAssertTrue(bridge.store.bindings.isEmpty)
        guard queue.commands.count >= 3,
              case let .create(worldRequest) =
                queue.commands[queue.commands.count - 3].command else {
            return XCTFail("world rope create command is missing")
        }
        XCTAssertEqual(worldRequest.first.entity, first.identity)
        XCTAssertEqual(worldRequest.second.entity, world.identity)
        XCTAssertEqual(worldRequest.second.kind, .staticWorld)
        XCTAssertEqual(worldRequest.second.bodyID, worldBodyID)
        XCTAssertEqual(worldRequest.authoredLength, 48)
        XCTAssertEqual(worldRequest.additionalLength, 5)
        XCTAssertEqual(worldRequest.maximumLength, 53)
        XCTAssertEqual(worldRequest.forceLimit, 12)
        XCTAssertEqual(worldRequest.width, 3)
        XCTAssertEqual(worldRequest.material, LuaString("cable/cable2"))
        XCTAssertTrue(worldRequest.isRigid)
        XCTAssertEqual(
            queue.commands.last?.command,
            .delete(worldRequest.constraintID)
        )
    }

    private func activeProp(
        in session: GModPlayableSession,
        model: SourceEntityModelReference,
        origin: SourceVector3
    ) throws -> SourceCanonicalEntitySnapshot {
        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        state.model = model
        state.transform.origin = origin
        let created = try session.sourceAdapter.createCanonicalEntity(
            kind: .propPhysics,
            state: state
        )
        _ = try session.sourceAdapter.spawnCanonicalEntity(created.identity)
        return try session.sourceAdapter.activateCanonicalEntity(
            created.identity
        )
    }

    private func candidate(
        for entity: SourceCanonicalEntitySnapshot,
        at origin: SourceVector3
    ) throws -> GMLuaDynamicTraceCandidate {
        GMLuaDynamicTraceCandidate(
            identity: entity.identity,
            className: entity.className,
            collisionGroup: entity.collisionGroup,
            studioHitboxes: [try GMLuaDynamicStudioHitbox(
                minimum: SourceVector3(-10, -10, -10),
                maximum: SourceVector3(10, 10, 10),
                boneToWorld: SourceStudioMatrix3x4(
                    1, 0, 0, origin.x,
                    0, 1, 0, origin.y,
                    0, 0, 1, origin.z
                ),
                contents: .solid,
                surface: SourceTraceSurface(name: "canonical_rope_fixture"),
                hitBox: 0,
                hitGroup: 0,
                physicsBone: 0
            )]
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private extension SourceVector3 {
    var length: Float {
        (x * x + y * y + z * z).squareRoot()
    }
}

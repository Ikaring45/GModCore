import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

private final class ToolActionWorldMissProvider: GMLuaTraceProvider,
    @unchecked Sendable
{
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class ToolActionDynamicProvider:
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
        candidates
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}

final class SourceCanonicalToolActionBridgeTests: XCTestCase {
    func testConstraintStateCanonicalMutatorsAndGameplayEventsUseSharedFIFO()
        throws
    {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        defer {
            _ = client.close()
            _ = server.close()
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        defer { try? adapter.close() }
        try adapter.installCanonicalEntityLuaBridge()
        _ = try adapter.createCanonicalEntity(kind: .world, at: 0)
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 101
        )
        let firstProp = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 7
        )
        let secondProp = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 8
        )
        let weapon = try adapter.giveCanonicalWeapon(
            className: "gmod_tool",
            to: player.identity
        )
        let graph = SourceCanonicalConstraintGraph()
        _ = try graph.insert(entities: [firstProp.identity, secondProp.identity])

        let clientBridge = try SourceCanonicalToolActionBridge.install(
            into: client
        )
        _ = try SourceCanonicalToolActionBridge.install(
            into: server,
            host: adapter,
            constraintGraph: graph
        )

        try server.execute(
            """
            local a, b = Entity(7), Entity(8)
            assert(a:IsConstrained())
            local connected = constraint.GetAllConstrainedEntities(a)
            assert(connected[a] == a and connected[b] == b)
            local removed, count = constraint.RemoveAll(a)
            assert(removed and count == 1 and not a:IsConstrained())

            a:SetNotSolid(true)
            a:SetNoDraw(true)
            a:SetMoveType(MOVETYPE_NONE)
            assert(a:GetNotSolid() and a:GetNoDraw())

            local data = EffectData()
            data:SetOrigin(Vector(10, 20, 30))
            data:SetStart(Vector(1, 2, 3))
            data:SetNormal(Vector(0, 0, 1))
            data:SetEntity(a)
            data:SetAttachment(4)
            util.Effect("entity_remove", data, true, true)
            a:EmitSound("Toolgun.Single", 75, 100, 1, CHAN_WEAPON, 0, 0)
            assert(Entity(\(weapon.identity.entryIndex)):SendWeaponAnim(
                ACT_VM_PRIMARYATTACK
            ))
            Player(101):SetAnimation(PLAYER_ATTACK1)
            """,
            sourceName: "=(canonical tool action FIFO fixture)"
        )

        let mutated = try XCTUnwrap(
            adapter.canonicalSnapshot(for: firstProp.identity)
        )
        XCTAssertTrue(mutated.isNotSolid)
        XCTAssertTrue(mutated.isNoDraw)
        XCTAssertEqual(mutated.solidType, firstProp.solidType)
        XCTAssertEqual(mutated.moveType, .none)
        XCTAssertTrue(clientBridge.clientEventState?.capturedDeliveries.isEmpty == true)
        XCTAssertTrue(client.effects?.capturedRequests.isEmpty == true)
        XCTAssertTrue(client.sound?.capturedPlayEvents.isEmpty == true)

        XCTAssertEqual(try transport.pump(), 4)
        let deliveries = try XCTUnwrap(
            clientBridge.clientEventState
        ).capturedDeliveries
        XCTAssertEqual(deliveries.map(\.transportSequence), [1, 2, 3, 4])
        XCTAssertEqual(deliveries.map(\.payload), [
            .effect(try XCTUnwrap(server.effects?.capturedRequests.last)),
            .entitySound(GMLuaEntitySoundEvent(
                entityIdentity: firstProp.identity,
                sound: "Toolgun.Single",
                origin: firstProp.transform.origin,
                level: 75,
                pitch: 100,
                volume: 1,
                channel: 1,
                flags: 0,
                dsp: 0
            )),
            .weaponAnimation(GMLuaWeaponAnimationEvent(
                weaponIdentity: weapon.identity,
                activity: 181
            )),
            .playerAnimation(GMLuaPlayerAnimationEvent(
                playerIdentity: player.identity,
                animation: 5
            )),
        ])

        let effect = try XCTUnwrap(client.effects?.capturedRequests.last)
        XCTAssertEqual(effect.name, "entity_remove")
        XCTAssertEqual(effect.data.origin, GMLuaEffectVector(x: 10, y: 20, z: 30))
        XCTAssertEqual(effect.data.start, GMLuaEffectVector(x: 1, y: 2, z: 3))
        XCTAssertEqual(effect.data.normal, GMLuaEffectVector(x: 0, y: 0, z: 1))
        XCTAssertEqual(effect.data.entityIdentity, firstProp.identity)
        XCTAssertEqual(effect.data.attachment, 4)
        XCTAssertEqual(
            client.sound?.capturedPlayEvents.map(\.sound),
            ["Toolgun.Single"]
        )
        XCTAssertTrue(client.sound?.capturedPlayEvents.allSatisfy {
            !$0.hasAudioBacking
        } == true)
    }

    func testStockRemoverCompletesDynamicPropActionThroughSessionIntegration()
        throws
    {
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil
        )
        defer { _ = try? session.close() }
        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        // The dynamic collision fixture is positioned once from this Player's
        // eye. Freeze world movement with real MOVETYPE_NOCLIP semantics so a
        // preparatory tick cannot move the trace ray away from that hitbox.
        _ = try session.sourceAdapter.updateCanonicalEntity(
            player.identity
        ) { state in
            state.moveType = .noClip
            state.motion.linearVelocity = .zero
            state.motion.baseVelocity = .zero
            state.motion.outputWishVelocity = .zero
            state.motion.isOnGround = false
        }
        let dynamic = ToolActionDynamicProvider()
        session.serverRuntime.traceBridge?.connect(provider:
            GMLuaCompositeTraceProvider(
                world: ToolActionWorldMissProvider(),
                dynamic: dynamic
            )
        )

        try session.clientRuntime.execute(
            "RunConsoleCommand('gmod_toolmode', 'remover')",
            sourceName: "=(select stock remover for complete action)"
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give stock toolgun for complete action)"
        )

        let target = try createTargetProp(
            in: session,
            player: player,
            dynamic: dynamic
        )
        _ = try session.runFixedTick()
        do {
            try session.serverRuntime.execute(
                """
                local weapon = Player(\(session.configuration.playerUserID)):GetActiveWeapon()
                assert(weapon:GetMode() == "remover", "unexpected tool mode " .. tostring(weapon:GetMode()))
                local trace = weapon:DoToolTrace()
                assert(trace ~= nil, "stock DoToolTrace missed dynamic target")
                assert(trace.Entity:EntIndex() == \(target.identity.entryIndex), "stock DoToolTrace hit wrong entity " .. tostring(trace.Entity:EntIndex()))
                """,
                sourceName: "=(verify stock remover dynamic trace preflight)"
            )
        } catch let raised as LuaRaisedError {
            XCTFail("stock dynamic trace preflight: \(raised.value.printable)")
            return
        }
        let completed = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(completed.weaponGameplay.failures, [])
        XCTAssertEqual(completed.actionFailures, [])
        XCTAssertTrue(completed.weaponGameplay.invocations.contains {
            $0.className == "gmod_tool" && $0.invocation == .primaryAttack
        })

        let authoritative = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: target.identity)
        )
        XCTAssertTrue(authoritative.isNotSolid)
        XCTAssertTrue(authoritative.isNoDraw)
        XCTAssertEqual(authoritative.moveType, .none)
        let replicated = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == target.identity
            }
        )
        XCTAssertTrue(replicated.isNotSolid)
        XCTAssertTrue(replicated.isNoDraw)
        XCTAssertEqual(replicated.moveType, .none)

        let deliveries = try XCTUnwrap(
            session.clientToolActionBridge.clientEventState
        ).capturedDeliveries
        XCTAssertEqual(
            deliveries.map(\.transportSequence),
            deliveries.map(\.transportSequence).sorted()
        )
        XCTAssertTrue(deliveries.contains {
            if case let .effect(request) = $0.payload {
                return request.name == "entity_remove" &&
                    request.data.entityIdentity == target.identity
            }
            return false
        })
        XCTAssertTrue(deliveries.contains {
            if case let .entitySound(event) = $0.payload {
                return event.sound == "Toolgun.Single"
            }
            return false
        })
        XCTAssertTrue(deliveries.contains {
            if case .weaponAnimation = $0.payload { return true }
            return false
        })
        XCTAssertTrue(deliveries.contains {
            if case .playerAnimation = $0.payload { return true }
            return false
        })
        XCTAssertTrue(session.clientRuntime.effects?.capturedRequests.contains {
            $0.name == "entity_remove" &&
                $0.data.entityIdentity == target.identity
        } == true)
        XCTAssertTrue(session.clientRuntime.sound?.capturedPlayEvents.contains {
            $0.sound == "Toolgun.Single"
        } == true)
        XCTAssertTrue(session.clientRuntime.achievements?.capturedRequests.contains(
            .entityRemoved
        ) == true)

        var timerFailures: [GMLuaSourceTimerFailure] = []
        var removedEntities: [GMLuaSourceEntityIdentity] = []
        for _ in 0..<72 {
            let tick = try session.runFixedTick()
            timerFailures.append(contentsOf: tick.server.timerFailures)
            removedEntities.append(contentsOf: tick.server.removedEntities)
        }
        XCTAssertEqual(timerFailures, [])
        XCTAssertTrue(removedEntities.contains(target.identity))
        XCTAssertNil(session.sourceAdapter.canonicalSnapshot(for: target.identity))
        XCTAssertFalse(session.clientCanonicalEntitySnapshots.contains {
            $0.identity == target.identity
        })
    }

    private func createTargetProp(
        in session: GModPlayableSession,
        player: SourceCanonicalEntitySnapshot,
        dynamic: ToolActionDynamicProvider
    ) throws -> SourceCanonicalEntitySnapshot {
        let eye = player.transform.origin + player.viewOffset
        let forward = player.transform.angles.sourceBasis.forward
        let target = eye + forward * 128
        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        state.transform.origin = target
        let prop = try session.sourceAdapter.createCanonicalEntity(
            kind: .propPhysics,
            at: nil,
            state: state,
            playerUserID: nil
        )
        let hitbox = try GMLuaDynamicStudioHitbox(
            minimum: SourceVector3(-12, -12, -12),
            maximum: SourceVector3(12, 12, 12),
            boneToWorld: SourceStudioMatrix3x4(
                1, 0, 0, target.x,
                0, 1, 0, target.y,
                0, 0, 1, target.z
            ),
            contents: .solid,
            surface: SourceTraceSurface(name: "canonical_tool_target"),
            hitBox: 0,
            hitGroup: 0,
            physicsBone: 0
        )
        dynamic.candidates = [GMLuaDynamicTraceCandidate(
            identity: prop.identity,
            className: prop.className,
            collisionGroup: prop.collisionGroup,
            studioHitboxes: [hitbox]
        )]
        return prop
    }
}

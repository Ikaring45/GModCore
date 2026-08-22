import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession

private final class WeldWorldMissProvider:
    GMLuaTraceProvider,
    @unchecked Sendable
{
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class WeldDynamicProvider:
    GMLuaDynamicTraceCandidateProvider,
    @unchecked Sendable
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

final class SourceCanonicalWeldConstraintIntegrationTests: XCTestCase {
    func testPublicConstraintWeldUsesFullHandlesPhysicsFIFOAndOriginalUndoRemoval()
        throws
    {
        let fixture = try makeSessionAndProps()
        let session = fixture.session
        defer { _ = try? session.close() }

        try session.serverRuntime.execute(
            """
            local first = Entity(\(fixture.first.identity.entryIndex))
            local second = Entity(\(fixture.second.identity.entryIndex))
            assert(constraint.Weld(first, second, 0, 0, 1, false, false) == false)
            assert(constraint.Weld(first, second, 0, 0, 0, true, false) == false)
            assert(constraint.Weld(first, second, 0, 0, 0, false, true) == false)
            """,
            sourceName: "=(unsupported weld semantics fail closed)"
        )
        XCTAssertTrue(session.serverWeldConstraintBridge.store.bindings.isEmpty)
        XCTAssertEqual(session.sharedSession.netTransport.pendingPhysicsBodyCommandCount, 0)

        try session.serverRuntime.execute(
            """
            local first = Entity(\(fixture.first.identity.entryIndex))
            local second = Entity(\(fixture.second.identity.entryIndex))
            local weld = constraint.Weld(first, second, 0, 0, 0, false, false)
            assert(IsValid(weld), "constraint.Weld did not return an Entity")
            assert(weld:IsConstraint())
            assert(weld:GetClass() == "phys_constraint")
            assert(first:IsConstrained() and second:IsConstrained())
            assert(constraint.Find(first, second, "Weld", 0, 0) == weld)
            assert(constraint.Weld(first, second, 0, 0, 0, false, false) == false)

            undo.Create("Weld")
                undo.AddEntity(weld)
                undo.SetPlayer(Player(\(session.configuration.playerUserID)))
            assert(undo.Finish("#tool.weld.name"))
            """,
            sourceName: "=(canonical public constraint.Weld)"
        )

        let binding = try XCTUnwrap(
            session.serverWeldConstraintBridge.store.bindings.only
        )
        XCTAssertEqual(binding.firstEntity, fixture.first.identity)
        XCTAssertEqual(binding.secondEntity, fixture.second.identity)
        XCTAssertEqual(binding.firstBodyID.entityIdentity, fixture.first.identity)
        XCTAssertEqual(binding.secondBodyID.entityIdentity, fixture.second.identity)
        XCTAssertEqual(session.sharedSession.netTransport.pendingPhysicsBodyCommandCount, 3)

        let created = try session.runFixedTick()
        XCTAssertEqual(created.propPhysics.fixedConstraints.count, 1)
        XCTAssertEqual(
            created.propPhysics.fixedConstraints.first?.constraintID,
            binding.physicsConstraintID
        )
        XCTAssertTrue(session.clientCanonicalEntitySnapshots.contains {
            $0.identity == binding.constraintEntity &&
                $0.kind == .physicsConstraint &&
                $0.lifecycle == .active
        })

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local rows = undo.GetTable()[ply:UniqueID()]
            assert(rows and rows[1], "original undo row is missing")
            assert(undo.Do_Undo(rows[1]) == 1)
            """,
            sourceName: "=(original undo removes canonical weld Entity)"
        )
        XCTAssertTrue(session.serverWeldConstraintBridge.store.bindings.isEmpty)
        XCTAssertEqual(session.sharedSession.netTransport.pendingPhysicsBodyCommandCount, 1)

        let removed = try session.runFixedTick()
        XCTAssertTrue(removed.propPhysics.fixedConstraints.isEmpty)
        XCTAssertFalse(session.serverToolActionBridge.constraintGraph.hasConstraints(
            involving: fixture.first.identity
        ))
        XCTAssertFalse(session.clientCanonicalEntitySnapshots.contains {
            $0.identity == binding.constraintEntity
        })
    }

    func testBundledStockWeldToolCreatesFixedConstraintOnSecondPrimaryClick()
        throws
    {
        let fixture = try makeSessionAndProps(createPropsAfterInitialTick: true)
        let session = fixture.session
        defer { _ = try? session.close() }
        let dynamic = WeldDynamicProvider()
        session.serverRuntime.traceBridge?.connect(provider:
            GMLuaCompositeTraceProvider(
                world: WeldWorldMissProvider(),
                dynamic: dynamic
            )
        )

        try session.clientRuntime.execute(
            """
            RunConsoleCommand("gmod_toolmode", "weld")
            RunConsoleCommand("weld_forcelimit", "0")
            RunConsoleCommand("weld_nocollide", "0")
            """,
            sourceName: "=(select original weld stool)"
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give stock toolgun for weld)"
        )
        _ = try session.runFixedTick()

        try session.serverRuntime.execute(
            """
            local toolgun = Player(\(session.configuration.playerUserID)):GetActiveWeapon()
            assert(toolgun:GetMode() == "weld")
            assert(toolgun:GetToolObject("weld") ~= nil, "stock weld stool missing")
            """,
            sourceName: "=(stock weld stool preflight)"
        )

        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        let aimPoint = player.transform.origin + player.viewOffset +
            player.transform.angles.sourceBasis.forward * 128
        dynamic.candidates = [try candidate(
            for: fixture.first,
            at: aimPoint
        )]
        let firstClick = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(firstClick.weaponGameplay.failures, [])
        XCTAssertEqual(firstClick.actionFailures, [])
        XCTAssertTrue(session.serverWeldConstraintBridge.store.bindings.isEmpty)

        _ = try session.runFixedTick()
        dynamic.candidates = [try candidate(
            for: fixture.second,
            at: aimPoint
        )]
        let secondClick = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(secondClick.weaponGameplay.failures, [])
        XCTAssertEqual(secondClick.actionFailures, [])
        XCTAssertEqual(
            session.serverWeldConstraintBridge.store.bindings.count,
            1
        )
        XCTAssertEqual(secondClick.propPhysics.fixedConstraints.count, 1)

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local rows = undo.GetTable()[ply:UniqueID()]
            assert(rows and rows[1], "stock weld tool did not create undo")
            """,
            sourceName: "=(stock weld undo verification)"
        )
    }

    private func makeSessionAndProps(
        createPropsAfterInitialTick: Bool = false
    ) throws -> (
        session: GModPlayableSession,
        first: SourceCanonicalEntitySnapshot,
        second: SourceCanonicalEntitySnapshot
    ) {
        let model = SourceEntityModelReference(
            "models/props/canonical_weld_fixture.mdl"
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
        if createPropsAfterInitialTick {
            _ = try session.runFixedTick()
        }
        let first = try activeProp(
            in: session,
            model: model,
            origin: SourceVector3(96, 0, 96)
        )
        let second = try activeProp(
            in: session,
            model: model,
            origin: SourceVector3(128, 0, 96)
        )
        _ = try session.runFixedTick()
        return (session, first, second)
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
        return try session.sourceAdapter.activateCanonicalEntity(created.identity)
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
                minimum: SourceVector3(-12, -12, -12),
                maximum: SourceVector3(12, 12, 12),
                boneToWorld: SourceStudioMatrix3x4(
                    1, 0, 0, origin.x,
                    0, 1, 0, origin.y,
                    0, 0, 1, origin.z
                ),
                contents: .solid,
                surface: SourceTraceSurface(name: "canonical_weld_fixture"),
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

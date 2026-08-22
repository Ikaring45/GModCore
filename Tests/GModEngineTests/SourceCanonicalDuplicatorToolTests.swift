import Foundation
import XCTest
@testable import GModEngine
import GModLua

private enum DuplicatorTestFailure: Error, Equatable {
    case injectedSecondActivation
    case injectedSecondPhysicsMutation
}

private final class DuplicatorForwardingHost:
    SourceCanonicalDuplicatorHost,
    @unchecked Sendable
{
    let adapter: GMLuaSourceRuntimeAdapter
    var failActivationNumber: Int?
    var failPhysicsMutationNumber: Int?
    private var activationCount = 0
    private var physicsMutationCount = 0

    init(
        adapter: GMLuaSourceRuntimeAdapter,
        failActivationNumber: Int? = nil,
        failPhysicsMutationNumber: Int? = nil
    ) {
        self.adapter = adapter
        self.failActivationNumber = failActivationNumber
        self.failPhysicsMutationNumber = failPhysicsMutationNumber
    }

    func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        adapter.canonicalSnapshot(for: identity)
    }

    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        adapter.primaryCanonicalPhysicsObject(for: entity)
    }

    func createCanonicalEntity(
        kind: SourceCanonicalEntityKind,
        at entryIndex: Int?,
        state: SourceCanonicalEntityState?,
        playerUserID: Int?
    ) throws -> SourceCanonicalEntitySnapshot {
        try adapter.createCanonicalEntity(
            kind: kind,
            at: entryIndex,
            state: state,
            playerUserID: playerUserID
        )
    }

    func spawnCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try adapter.spawnCanonicalEntity(identity)
    }

    func activateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        activationCount += 1
        if activationCount == failActivationNumber {
            throw DuplicatorTestFailure.injectedSecondActivation
        }
        return try adapter.activateCanonicalEntity(identity)
    }

    func rollbackUnpublishedCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try adapter.rollbackUnpublishedCanonicalEntity(identity)
    }

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        physicsMutationCount += 1
        if physicsMutationCount == failPhysicsMutationNumber {
            throw DuplicatorTestFailure.injectedSecondPhysicsMutation
        }
        try adapter.enqueueCanonicalPhysicsObjectMutation(command)
    }

    func markCanonicalEntityForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try adapter.markCanonicalEntityForRemoval(identity)
    }

    func withCanonicalDuplicatorPasteTransaction(
        _ body: () throws -> [SourceCanonicalDuplicatorPastedEntity]
    ) throws -> [SourceCanonicalDuplicatorPastedEntity] {
        try adapter.withCanonicalDuplicatorPasteTransaction(body)
    }
}

final class SourceCanonicalDuplicatorToolTests: XCTestCase {
    func testStockCopyPasteBridgePreservesCanonicalAppearancePhysicsCreatorAndUndo()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }

        let graph = SourceCanonicalConstraintGraph()
        let world = try makeActiveWorld(adapter: fixture.adapter)
        let player = try makeActivePlayer(
            adapter: fixture.adapter,
            userID: 77
        )
        let source = try makeActiveProp(
            adapter: fixture.adapter,
            model: fixture.model,
            origin: SourceVector3(160, 240, 32),
            yaw: 70,
            creator: player.identity,
            color: SourceEntityRenderColor(
                red: 21, green: 42, blue: 63, alpha: 128
            ),
            skin: 2,
            bodyValue: 5,
            persistent: true,
            material: SourceEntityMaterialOverride(
                name: "models/debug/debugwhite",
                logicalMaterialPath:
                    "materials/models/debug/debugwhite.vmt"
            )
        )
        let copiedConstraint = try graph.insert(
            entities: [source.identity, world.identity]
        )

        let bridge = try SourceCanonicalDuplicatorGLuaBridge.install(
            into: fixture.runtime,
            host: fixture.adapter,
            constraintSource: graph
        )
        try fixture.runtime.execute(
            """
            duplicator.SetLocalPos(Vector(100, 200, 0))
            duplicator.SetLocalAng(Angle(0, 25, 0))
            local dupe = duplicator.Copy(Entity(\(source.identity.entryIndex)))
            assert(dupe ~= nil)
            assert(dupe.Entities[\(source.identity.entryIndex)].Class == "prop_physics")
            assert(dupe.Entities[\(source.identity.entryIndex)].Model == "\(fixture.model.path)")
            assert(dupe.Constraints[\(copiedConstraint.identifier)].UnsupportedType == "canonical_graph")
            assert(dupe.Mins.x < dupe.Maxs.x and dupe.Mins.y < dupe.Maxs.y and dupe.Mins.z < dupe.Maxs.z)

            duplicator.SetLocalPos(Vector(500, -80, 16))
            duplicator.SetLocalAng(Angle(0, 110, 0))
            local created, constraints = duplicator.Paste(
                Player(77), dupe.Entities, dupe.Constraints
            )
            assert(created[\(source.identity.entryIndex)] ~= nil)
            assert(constraints ~= nil)
            DUPLICATOR_TEST_PASTED = created[\(source.identity.entryIndex)]
            """,
            sourceName: "=(stock Duplicator Copy/Paste spellings)"
        )

        let paste = try XCTUnwrap(bridge.lastPasteResult)
        XCTAssertEqual(paste.entities.count, 1)
        XCTAssertEqual(
            paste.unsupportedConstraints,
            [SourceCanonicalDuplicatorUnsupportedConstraint(
                kind: .canonicalGraph,
                sourceRecord: copiedConstraint
            )]
        )
        XCTAssertEqual(paste.sleepingPhysicsObjectsNotApplied, [
            paste.entities[0].pasted.identity
        ])

        let pasted = try XCTUnwrap(fixture.adapter.canonicalSnapshot(
            for: paste.entities[0].pasted.identity
        ))
        XCTAssertEqual(pasted.lifecycle, .active)
        XCTAssertEqual(pasted.kind, .propPhysics)
        XCTAssertEqual(pasted.model, fixture.model)
        XCTAssertEqual(pasted.creator, player.identity)
        XCTAssertEqual(pasted.renderState.color, source.renderState.color)
        XCTAssertEqual(pasted.renderState.mode, source.renderState.mode)
        XCTAssertEqual(pasted.materialOverride, source.materialOverride)
        XCTAssertEqual(pasted.skin, 2)
        XCTAssertEqual(pasted.bodyValue, 5)
        XCTAssertTrue(pasted.isPersistent)
        XCTAssertNotEqual(pasted.identity, source.identity)
        XCTAssertEqual(
            fixture.transport.pendingPhysicsBodyCommandCount,
            2,
            "no-gravity restore queues one body create and one stock mutation"
        )

        let pastedLua = fixture.runtime.entityRegistry?.canonicalIdentity(
            for: fixture.runtime.state.getGlobal("DUPLICATOR_TEST_PASTED")
        )
        XCTAssertEqual(pastedLua, pasted.identity)

        let undo = try bridge.coordinator.undo(paste.undoToken)
        XCTAssertEqual(undo.scheduledForRemoval, [pasted.identity])
        XCTAssertEqual(
            fixture.adapter.canonicalSnapshot(for: pasted.identity)?.lifecycle,
            .pendingRemoval
        )
        XCTAssertEqual(
            fixture.adapter.canonicalSnapshot(for: source.identity)?.lifecycle,
            .active,
            "undo must remove the pasted full EHANDLE, never the source"
        )
    }

    func testPasteFailureRollsBackEveryFreshFullHandleAndStagedPhysicsSuffix()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }

        let player = try makeActivePlayer(
            adapter: fixture.adapter,
            userID: 88
        )
        let first = try makeActiveProp(
            adapter: fixture.adapter,
            model: fixture.model,
            origin: SourceVector3(20, 0, 0),
            yaw: 0,
            creator: player.identity
        )
        let second = try makeActiveProp(
            adapter: fixture.adapter,
            model: fixture.model,
            origin: SourceVector3(60, 0, 0),
            yaw: 15,
            creator: player.identity
        )
        let graph = SourceCanonicalConstraintGraph()
        _ = try graph.insert(entities: [first.identity, second.identity])
        let host = DuplicatorForwardingHost(
            adapter: fixture.adapter,
            failPhysicsMutationNumber: 2
        )
        let coordinator = SourceCanonicalDuplicatorCoordinator(
            host: host,
            constraintSource: graph
        )
        let copy = try XCTUnwrap(coordinator.copy(
            target: first.identity,
            anchor: .identity
        ).copy)
        XCTAssertEqual(copy.entities.count, 2)

        let snapshotsBefore = fixture.adapter.canonicalEntitySnapshots
        let journalBefore = fixture.adapter.pendingCanonicalEntityOperationCount
        let physicsBefore = fixture.transport.pendingPhysicsBodyCommandCount
        XCTAssertThrowsError(try coordinator.paste(
            actor: player.identity,
            copy: copy,
            anchor: SourceEntityTransform(
                origin: SourceVector3(1_000, 0, 0),
                angles: SourceQAngle(yaw: 90)
            )
        )) { error in
            XCTAssertEqual(error as? DuplicatorTestFailure,
                           .injectedSecondPhysicsMutation)
        }

        XCTAssertEqual(fixture.adapter.canonicalEntitySnapshots, snapshotsBefore)
        XCTAssertEqual(
            fixture.adapter.pendingCanonicalEntityOperationCount,
            journalBefore
        )
        XCTAssertEqual(
            fixture.transport.pendingPhysicsBodyCommandCount,
            physicsBefore,
            "failed transaction must not leak a physics FIFO suffix"
        )
        XCTAssertEqual(coordinator.pendingUndoCount, 0)
    }

    private struct Fixture {
        let runtime: GMLuaRuntime
        let transport: GMLuaNetTransport
        let adapter: GMLuaSourceRuntimeAdapter
        let model: SourceEntityModelReference

        func close() {
            try? adapter.close()
            _ = runtime.close()
        }
    }

    private func makeFixture() throws -> Fixture {
        let transport = GMLuaNetTransport()
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let model = SourceEntityModelReference(
            "models/props_c17/oildrum001.mdl"
        )
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                damping: .zero,
                isGravityEnabled: false,
                isCollisionEnabled: true,
                startsAwake: false
            )
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 9,
            canonicalModelValidator: { requested, kind in
                requested == model && kind == .propPhysics
                    ? .valid
                    : .invalid
            },
            canonicalPropPhysicsAssetResolver:
                makeAttestedPropPhysicsTestResolver(asset: asset)
        )
        try adapter.installCanonicalEntityLuaBridge()
        return Fixture(
            runtime: runtime,
            transport: transport,
            adapter: adapter,
            model: model
        )
    }

    private func makeActiveWorld(
        adapter: GMLuaSourceRuntimeAdapter
    ) throws -> SourceCanonicalEntitySnapshot {
        let created = try adapter.createCanonicalEntity(
            kind: .world,
            at: 0
        )
        _ = try adapter.spawnCanonicalEntity(created.identity)
        return try adapter.activateCanonicalEntity(created.identity)
    }

    private func makeActivePlayer(
        adapter: GMLuaSourceRuntimeAdapter,
        userID: Int
    ) throws -> SourceCanonicalEntitySnapshot {
        let created = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: userID
        )
        _ = try adapter.spawnCanonicalEntity(created.identity)
        return try adapter.activateCanonicalEntity(created.identity)
    }

    private func makeActiveProp(
        adapter: GMLuaSourceRuntimeAdapter,
        model: SourceEntityModelReference,
        origin: SourceVector3,
        yaw: Float,
        creator: SourceCanonicalEntityIdentity,
        color: SourceEntityRenderColor = .white,
        skin: Int = 0,
        bodyValue: Int = 0,
        persistent: Bool = false,
        material: SourceEntityMaterialOverride? = nil
    ) throws -> SourceCanonicalEntitySnapshot {
        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        state.transform = SourceEntityTransform(
            origin: origin,
            angles: SourceQAngle(yaw: yaw)
        )
        state.model = model
        state.creator = creator
        state.renderState = SourceEntityRenderState(
            color: color,
            mode: color.alpha < 255 ? .transColor : .normal,
            fx: .none
        )
        state.materialOverride = material
        state.skin = skin
        state.bodyValue = bodyValue
        state.isPersistent = persistent
        let created = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            state: state
        )
        _ = try adapter.spawnCanonicalEntity(created.identity)
        return try adapter.activateCanonicalEntity(created.identity)
    }
}

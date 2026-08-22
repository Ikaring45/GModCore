import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

private final class MaterialToolWorldMissProvider:
    GMLuaTraceProvider,
    @unchecked Sendable
{
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class MaterialToolDynamicProvider:
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

final class SourceCanonicalMaterialToolIntegrationTests: XCTestCase {
    func testSourceGameResolverNormalizesExistingVMTAndRejectsMissingOverride()
        throws
    {
        let resolver = GMLuaSourceMaterialResolver { logicalPath in
            logicalPath.lowercased() == "materials/models/test/override.vmt"
                ? Data(#""VertexLitGeneric" {}"#.utf8)
                : nil
        }

        let override = try XCTUnwrap(
            resolver.resolveEntityMaterialOverride(
                named: " MATERIALS\\Models/Test/Override.VMT "
            )
        )
        XCTAssertEqual(override.name, "models/test/override")
        XCTAssertEqual(
            override.logicalMaterialPath,
            "materials/models/test/override.vmt"
        )
        XCTAssertNil(try resolver.resolveEntityMaterialOverride(named: ""))
        XCTAssertThrowsError(
            try resolver.resolveEntityMaterialOverride(
                named: "models/test/missing"
            )
        ) { error in
            XCTAssertEqual(
                error as? GMLuaSourceMaterialError,
                .entityMaterialOverrideMissing(
                    "materials/models/test/missing.vmt"
                )
            )
        }
    }

    func testOriginalMaterialStoolUsesCanonicalOverrideFIFOAndRenderProjection()
        throws
    {
        let model = SourceEntityModelReference(
            "models/props/material_target.mdl"
        )
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 2,
                maximumGeometryByteCount: 1_024
            ),
            compile: { requested, bodyValue, skinFamilyIndex in
                let path = requested.path.lowercased()
                let checksum: Int32 = 0x004D_4154
                return .resolved(GModStudioRenderableModelResource(
                    id: GModStudioRenderableModelResourceID(
                        normalizedModelPath: path,
                        checksum: checksum,
                        bodyValue: bodyValue,
                        skinFamilyIndex: skinFamilyIndex
                    ),
                    model: GModStudioRenderableModelSnapshot(
                        checksum: checksum,
                        modelName: path,
                        lodIndex: 0,
                        bodyValue: bodyValue,
                        skinFamilyIndex: skinFamilyIndex,
                        vertices: [GModDynamicModelVertex(
                            position: .zero,
                            normal: SourceVector3(0, 0, 1),
                            textureCoordinate: .init(u: 0, v: 0)
                        )],
                        indices: [],
                        drawRanges: []
                    )
                ))
            }
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
                makeAttestedPropPhysicsTestResolver(asset: propAsset),
            studioRenderableModelCacheForTesting: cache
        )
        defer { _ = try? session.close() }

        let dynamic = MaterialToolDynamicProvider()
        session.serverRuntime.traceBridge?.connect(provider:
            GMLuaCompositeTraceProvider(
                world: MaterialToolWorldMissProvider(),
                dynamic: dynamic
            )
        )
        try session.clientRuntime.execute(
            """
            RunConsoleCommand("gmod_toolmode", "material")
            RunConsoleCommand("material_override", "models/debug/debugwhite")
            """,
            sourceName: "=(select original material stool)"
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give original toolgun for material stool)"
        )

        _ = try session.runFixedTick()
        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        let eye = player.transform.origin + player.viewOffset
        let targetOrigin = eye +
            player.transform.angles.sourceBasis.forward * 128
        var targetState = SourceCanonicalEntityState.defaults(
            for: .propPhysics
        )
        targetState.transform.origin = targetOrigin
        let target = try session.sourceAdapter.createCanonicalEntity(
            kind: .propPhysics,
            state: targetState
        )
        dynamic.candidates = [GMLuaDynamicTraceCandidate(
            identity: target.identity,
            className: target.className,
            collisionGroup: target.collisionGroup,
            studioHitboxes: [try GMLuaDynamicStudioHitbox(
                minimum: SourceVector3(-12, -12, -12),
                maximum: SourceVector3(12, 12, 12),
                boneToWorld: SourceStudioMatrix3x4(
                    1, 0, 0, targetOrigin.x,
                    0, 1, 0, targetOrigin.y,
                    0, 0, 1, targetOrigin.z
                ),
                contents: .solid,
                surface: SourceTraceSurface(
                    name: "canonical_material_target"
                ),
                hitBox: 0,
                hitGroup: 0,
                physicsBone: 0
            )]
        )]
        try session.serverRuntime.execute(
            """
            local weapon = Player(\(session.configuration.playerUserID)):GetActiveWeapon()
            assert(weapon:GetMode() == "material")
            assert(weapon:GetToolObject("material") ~= nil)
            local trace = weapon:DoToolTrace()
            assert(trace and trace.Entity:EntIndex() == \(target.identity.entryIndex))
            """,
            sourceName: "=(original material stool dynamic trace preflight)"
        )

        let left = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(left.weaponGameplay.failures, [])
        XCTAssertEqual(left.actionFailures, [])
        XCTAssertTrue(left.weaponGameplay.invocations.contains {
            $0.className == "gmod_tool" && $0.invocation == .primaryAttack
        })
        let expected = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(
                for: target.identity
            )?.materialOverride
        )
        XCTAssertEqual(expected.name, "models/debug/debugwhite")
        XCTAssertEqual(
            expected.logicalMaterialPath,
            "materials/models/debug/debugwhite.vmt"
        )
        try session.serverRuntime.execute(
            """
            local ent = Entity(\(target.identity.entryIndex))
            assert(ent:GetMaterial() == "models/debug/debugwhite")
            assert(ent.EntityMods.material.MaterialOverride == "models/debug/debugwhite")
            """,
            sourceName: "=(original material duplicator modifier)"
        )

        let beforeRejected = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: target.identity)
        )
        let journalBeforeRejected =
            session.sourceAdapter.pendingCanonicalEntityOperationCount
        try session.serverRuntime.execute(
            """
            local ent = Entity(\(target.identity.entryIndex))
            local ok, message = pcall(function()
                ent:SetMaterial("missing/not_in_game")
            end)
            assert(ok == false)
            assert(string.find(message, "missing from GAME", 1, true))
            """,
            sourceName: "=(reject missing material override)"
        )
        XCTAssertEqual(
            session.sourceAdapter.canonicalSnapshot(for: target.identity),
            beforeRejected
        )
        XCTAssertEqual(
            session.sourceAdapter.pendingCanonicalEntityOperationCount,
            journalBeforeRejected
        )

        try session.clientRuntime.execute(
            "RunConsoleCommand('material_override', 'models/wireframe')",
            sourceName: "=(change material selector before right click)"
        )
        try advanceReleased(session, ticks: 8)
        let right = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack2])
        )
        XCTAssertEqual(right.weaponGameplay.failures, [])
        XCTAssertTrue(right.weaponGameplay.invocations.contains {
            $0.className == "gmod_tool" && $0.invocation == .secondaryAttack
        })
        try advanceReleased(session, ticks: 2)
        XCTAssertEqual(
            session.clientRuntime.conVarRegistry?.stringValue(
                for: "material_override"
            ),
            "models/debug/debugwhite"
        )

        try advanceReleased(session, ticks: 8)
        let reload = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.reload])
        )
        XCTAssertEqual(reload.weaponGameplay.failures, [])
        XCTAssertTrue(reload.weaponGameplay.invocations.contains {
            $0.className == "gmod_tool" && $0.invocation == .reload
        })
        XCTAssertNil(
            session.sourceAdapter.canonicalSnapshot(
                for: target.identity
            )?.materialOverride
        )
        try session.serverRuntime.execute(
            """
            local ent = Entity(\(target.identity.entryIndex))
            assert(ent:GetMaterial() == "")
            assert(ent.EntityMods.material.MaterialOverride == "")
            """,
            sourceName: "=(original material reload modifier)"
        )

        try advanceReleased(session, ticks: 8)
        let reapplied = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(reapplied.weaponGameplay.failures, [])
        XCTAssertEqual(
            session.sourceAdapter.canonicalSnapshot(
                for: target.identity
            )?.materialOverride,
            expected
        )

        _ = try session.sourceAdapter.updateCanonicalEntity(target.identity) {
            $0.model = model
        }
        _ = try session.sourceAdapter.spawnCanonicalEntity(target.identity)
        _ = try session.sourceAdapter.activateCanonicalEntity(target.identity)
        let enqueued = try session.sourceAdapter
            .publishPendingCanonicalEntityOperations {
                try session.sharedSession.publishCanonicalEntityUpdates($0)
            }
        XCTAssertGreaterThan(enqueued, 0)
        XCTAssertGreaterThan(try session.sharedSession.pump(), 0)

        let replicated = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == target.identity
            }
        )
        XCTAssertEqual(replicated.materialOverride, expected)
        try session.clientRuntime.execute(
            """
            assert(Entity(\(target.identity.entryIndex)):GetMaterial() ==
                "models/debug/debugwhite")
            """,
            sourceName: "=(replicated material getter)"
        )
        let scene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(ifChangedFrom: nil)
        )
        XCTAssertEqual(
            scene.instances.first {
                $0.identity == target.identity
            }?.materialOverride,
            expected
        )
    }

    private func advanceReleased(
        _ session: GModPlayableSession,
        ticks: Int
    ) throws {
        for _ in 0..<ticks {
            _ = try session.runFixedTick()
        }
    }
}

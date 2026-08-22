import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

private final class ColourToolWorldMissProvider:
    GMLuaTraceProvider,
    @unchecked Sendable
{
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class ColourToolDynamicProvider:
    GMLuaDynamicTraceCandidateProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [GMLuaDynamicTraceCandidate] = []
    private var requestStorage: GMLuaTraceRequest?

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

    var lastRequest: GMLuaTraceRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        requestStorage = request
        let result = storage
        lock.unlock()
        return result
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}

private final class ColourToolRenderableProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCountStorage = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution {
        lock.lock()
        callCountStorage += 1
        lock.unlock()

        let normalizedPath = model.path.lowercased()
        let checksum: Int32 = 0x0055_66AA
        let snapshot = GModStudioRenderableModelSnapshot(
            checksum: checksum,
            modelName: normalizedPath,
            lodIndex: 0,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            vertices: [GModDynamicModelVertex(
                position: .zero,
                normal: SourceVector3(0, 0, 1),
                textureCoordinate: SourceStudioTextureCoordinate(u: 0, v: 0)
            )],
            indices: [],
            drawRanges: []
        )
        return .resolved(GModStudioRenderableModelResource(
            id: GModStudioRenderableModelResourceID(
                normalizedModelPath: normalizedPath,
                checksum: checksum,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex
            ),
            model: snapshot
        ))
    }
}

final class SourceCanonicalColourToolIntegrationTests: XCTestCase {
    /// Metal tint/blend consumption is intentionally outside this slice. This
    /// verifies the renderer-facing immutable instance that the later Metal
    /// bridge will consume, in addition to the complete original Lua route.
    func testStockColourPrimaryAttackReplicatesAndProjectsRendererFacingStateWithoutMetalConsumption()
        throws
    {
        let model = SourceEntityModelReference(
            "models/props/colour_target.mdl"
        )
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let renderProbe = ColourToolRenderableProbe()
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 4,
                maximumGeometryByteCount: 1_024
            ),
            compile: { [renderProbe] model, bodyValue, skinFamilyIndex in
                renderProbe.resolve(
                    model: model,
                    bodyValue: bodyValue,
                    skinFamilyIndex: skinFamilyIndex
                )
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

        let dynamic = ColourToolDynamicProvider()
        session.serverRuntime.traceBridge?.connect(provider:
            GMLuaCompositeTraceProvider(
                world: ColourToolWorldMissProvider(),
                dynamic: dynamic
            )
        )

        try session.clientRuntime.execute(
            """
            RunConsoleCommand("gmod_toolmode", "colour")
            RunConsoleCommand("colour_r", "17")
            RunConsoleCommand("colour_g", "34")
            RunConsoleCommand("colour_b", "51")
            RunConsoleCommand("colour_a", "96")
            RunConsoleCommand("colour_mode", "0")
            RunConsoleCommand("colour_fx", "16")
            """,
            sourceName: "=(select and configure original colour stool)"
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give original toolgun for colour stool)"
        )

        // The first fixed tick applies the map's authoritative player spawn
        // transform and initializes the real SWEP/tool object. Build dynamic
        // trace geometry from that post-tick canonical transform.
        _ = try session.runFixedTick()
        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        let eye = player.transform.origin + player.viewOffset
        let targetOrigin = eye + player.transform.angles.sourceBasis.forward * 128
        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        state.transform.origin = targetOrigin
        let target = try session.sourceAdapter.createCanonicalEntity(
            kind: .propPhysics,
            state: state
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
                surface: SourceTraceSurface(name: "canonical_colour_target"),
                hitBox: 0,
                hitGroup: 0,
                physicsBone: 0
            )]
        )]

        do {
            try session.serverRuntime.execute(
                """
                local weapon = Player(\(session.configuration.playerUserID)):GetActiveWeapon()
                assert(weapon:GetMode() == "colour", "unexpected tool mode " .. tostring(weapon:GetMode()))
                assert(weapon:GetToolObject("colour") ~= nil, "original colour stool was not loaded")
                local trace = weapon:DoToolTrace()
                assert(trace ~= nil, "colour tool trace missed canonical prop")
                assert(trace.Entity:EntIndex() == \(target.identity.entryIndex), "colour trace hit wrong entity")
                """,
                sourceName: "=(original colour tool preflight)"
            )
        } catch let raised as LuaRaisedError {
            let requestDescription: String
            if let request = dynamic.lastRequest {
                requestDescription =
                    " start=\(request.ray.actualStart)" +
                    " end=\(request.ray.actualEnd)" +
                    " mask=\(request.mask.rawValue)" +
                    " excluded=\(request.excludedEntityHandles)" +
                    " included=\(request.includedEntityHandles)" +
                    " target=\(targetOrigin)"
            } else {
                requestDescription = " no dynamic trace request captured"
            }
            XCTFail(
                "original colour tool preflight: \(raised.value.printable)" +
                    requestDescription
            )
            return
        }
        let attack = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(attack.weaponGameplay.failures, [])
        XCTAssertEqual(attack.actionFailures, [])
        XCTAssertTrue(attack.weaponGameplay.invocations.contains {
            $0.className == "gmod_tool" && $0.invocation == .primaryAttack
        })

        let expectedColor = SourceEntityRenderColor(
            red: 17,
            green: 34,
            blue: 51,
            alpha: 96
        )
        let authoritative = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: target.identity)
        )
        XCTAssertEqual(authoritative.renderState.color, expectedColor)
        XCTAssertEqual(
            authoritative.renderState.mode,
            .transColor,
            "unmodified colour.lua must change NORMAL to TRANSCOLOR for alpha < 255"
        )
        XCTAssertEqual(authoritative.renderState.fx, .hologram)

        // Keep the trace target free of physics motion until the original Lua
        // route has completed, then prove that the engine-owned render state
        // survives the real prop lifecycle and its full-EHANDLE journal.
        _ = try session.sourceAdapter.updateCanonicalEntity(target.identity) {
            $0.model = model
        }
        _ = try session.sourceAdapter.spawnCanonicalEntity(target.identity)
        _ = try session.sourceAdapter.activateCanonicalEntity(target.identity)

        // Publish through the real entity journal/shared FIFO directly. A
        // physics step is orthogonal to colour and would make this test depend
        // on the session's independently attested material table fixture.
        let enqueued = try session.sourceAdapter
            .publishPendingCanonicalEntityOperations {
                try session.sharedSession.publishCanonicalEntityUpdates($0)
            }
        XCTAssertGreaterThan(enqueued, 0)
        XCTAssertGreaterThan(try session.sharedSession.pump(), 0)

        let activeAuthoritative = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: target.identity)
        )
        XCTAssertEqual(activeAuthoritative.lifecycle, .active)
        XCTAssertEqual(activeAuthoritative.renderState, authoritative.renderState)

        let replicated = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == target.identity
            }
        )
        XCTAssertEqual(replicated.renderState, activeAuthoritative.renderState)
        try session.clientRuntime.execute(
            """
            local ent = Entity(\(target.identity.entryIndex))
            local color = ent:GetColor()
            assert(IsColor(color), "GetColor must return the bundled Color type")
            assert(color.r == 17 and color.g == 34 and color.b == 51 and color.a == 96)
            assert(ent:GetRenderMode() == RENDERMODE_TRANSCOLOR)
            assert(ent:GetRenderFX() == 16)
            """,
            sourceName: "=(replicated original Color and render getters)"
        )

        let scene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(ifChangedFrom: nil)
        )
        let instance = try XCTUnwrap(scene.instances.first {
            $0.identity == target.identity
        })
        XCTAssertEqual(instance.colorModulation, expectedColor)
        XCTAssertEqual(instance.renderMode, .transColor)
        XCTAssertEqual(instance.renderFX, .hologram)
        XCTAssertEqual(renderProbe.callCount, 1)
    }
}

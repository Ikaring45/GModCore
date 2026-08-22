import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class GModPlayableDynamicEntitySceneIntegrationTests: XCTestCase {
    func testLanePublishesOnlyChangedReplicatedPropSceneAndReusesAppearance()
        async throws
    {
        let model = SourceEntityModelReference("models/props/scene_test.mdl")
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let probe = PlayableSceneCompileProbe()
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 4,
                maximumGeometryByteCount: 1_024
            ),
            compile: { [probe] model, bodyValue, skinFamilyIndex in
                probe.resolve(
                    model: model,
                    bodyValue: bodyValue,
                    skinFamilyIndex: skinFamilyIndex
                )
            }
        )
        let repository = GModStudioModelRepository(
            reader: MissingPlayableSceneStudioReader()
        )
        let lane = GModPlayableSessionLane(
            worldWalkCollisionProvider: nil,
            canonicalModelValidatorForTesting: { requested, kind in
                requested == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting:
                makeAttestedPropPhysicsTestResolver(asset: propAsset),
            studioModelRepositoryForTesting: repository,
            studioRenderableModelCacheForTesting: cache
        )
        let started = try await lane.start(configuration: .init(map: .construct))

        let baselineCandidate = try await lane.clientDynamicEntityRenderScene(
            ifChangedFrom: nil,
            expectedGeneration: started.generation
        )
        let baseline = try XCTUnwrap(baselineCandidate)
        XCTAssertEqual(baseline.revision, 1)
        XCTAssertTrue(baseline.resources.isEmpty)
        XCTAssertTrue(baseline.instances.isEmpty)
        XCTAssertTrue(baseline.issues.isEmpty)

        do {
            _ = try await lane.clientDynamicEntityRenderScene(
                ifChangedFrom: baseline.revision,
                expectedGeneration: started.generation + 1
            )
            XCTFail("a stale scene consumer crossed the lane generation")
        } catch {
            XCTAssertEqual(
                error as? GModPlayableSessionLaneError,
                .staleGeneration(
                    expected: started.generation + 1,
                    actual: started.generation
                )
            )
        }

        let playerTick = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            movementInput: GModPlayableMovementInput(forwardMove: 200),
            expectedGeneration: started.generation,
            expectedInputEpoch: started.inputEpoch
        )
        XCTAssertNotNil(playerTick.canonicalEntityCursor)
        let afterPlayerTick = try await lane.clientDynamicEntityRenderScene(
            ifChangedFrom: baseline.revision,
            expectedGeneration: started.generation
        )
        XCTAssertNil(
            afterPlayerTick,
            "Player movement must not rebuild the prop projection"
        )

        try await lane.execute(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/scene_test.mdl")
            prop:SetPos(Vector(10, 20, 30))
            prop:SetAngles(Angle(1, 2, 3))
            prop:Spawn()
            prop:Activate()
            TEST_DYNAMIC_SCENE_PROP = prop
            """,
            realm: .server,
            sourceName: "=(dynamic scene prop creation)",
            expectedGeneration: started.generation
        )
        let beforeReplication = try await lane.clientDynamicEntityRenderScene(
            ifChangedFrom: baseline.revision,
            expectedGeneration: started.generation
        )
        XCTAssertNil(
            beforeReplication,
            "SERVER mutation must wait for the shared replication FIFO"
        )

        _ = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            expectedGeneration: started.generation,
            expectedInputEpoch: started.inputEpoch
        )
        let createdCandidate = try await lane.clientDynamicEntityRenderScene(
            ifChangedFrom: baseline.revision,
            expectedGeneration: started.generation
        )
        let created = try XCTUnwrap(createdCandidate)
        XCTAssertGreaterThan(created.revision, baseline.revision)
        XCTAssertEqual(created.resources.count, 1)
        XCTAssertEqual(created.instances.count, 1)
        XCTAssertTrue(created.issues.isEmpty)
        XCTAssertEqual(created.instances[0].transform.origin.x, 10)
        XCTAssertEqual(created.instances[0].transform.origin.y, 20)
        XCTAssertEqual(
            created.instances[0].transform.origin.z,
            29.82,
            accuracy: 0.000_1,
            "the rendered CLIENT transform must include the authoritative gravity step"
        )
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(cache.cachedEntryCount, 1)

        try await lane.execute(
            "TEST_DYNAMIC_SCENE_PROP:SetPos(Vector(40, 50, 60))",
            realm: .server,
            sourceName: "=(dynamic scene prop transform)",
            expectedGeneration: started.generation
        )
        let beforeMovedReplication = try await lane
            .clientDynamicEntityRenderScene(
                ifChangedFrom: created.revision,
                expectedGeneration: started.generation
            )
        XCTAssertNil(
            beforeMovedReplication
        )
        _ = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            expectedGeneration: started.generation,
            expectedInputEpoch: started.inputEpoch
        )
        let movedCandidate = try await lane.clientDynamicEntityRenderScene(
            ifChangedFrom: created.revision,
            expectedGeneration: started.generation
        )
        let moved = try XCTUnwrap(movedCandidate)
        XCTAssertGreaterThan(moved.revision, created.revision)
        XCTAssertEqual(moved.resources, created.resources)
        XCTAssertEqual(moved.instances.count, 1)
        XCTAssertEqual(moved.instances[0].transform.origin.x, 40)
        XCTAssertEqual(moved.instances[0].transform.origin.y, 50)
        XCTAssertEqual(
            moved.instances[0].transform.origin.z,
            59.64,
            accuracy: 0.000_1,
            "SetPos preserves velocity, so the next fixed physics tick must still advance the body"
        )
        XCTAssertEqual(
            probe.callCount,
            1,
            "a transform-only update must reuse the compiled appearance"
        )
        let unchangedMovedScene = try await lane.clientDynamicEntityRenderScene(
            ifChangedFrom: moved.revision,
            expectedGeneration: started.generation
        )
        XCTAssertNil(unchangedMovedScene)

        _ = try await lane.close(expectedGeneration: started.generation)
        XCTAssertEqual(cache.cachedEntryCount, 0)
    }
}

private struct MissingPlayableSceneStudioReader:
    SourceStudioBoundedAssetReading
{
    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        .missing
    }
}

private final class PlayableSceneCompileProbe: @unchecked Sendable {
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

        let checksum: Int32 = 0x1020_3040
        let normalizedPath = model.path.lowercased()
        let snapshot = GModStudioRenderableModelSnapshot(
            checksum: checksum,
            modelName: normalizedPath,
            lodIndex: 0,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            vertices: [
                GModDynamicModelVertex(
                    position: SourceVector3(0, 0, 0),
                    normal: SourceVector3(0, 0, 1),
                    textureCoordinate: SourceStudioTextureCoordinate(u: 0, v: 0)
                ),
            ],
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

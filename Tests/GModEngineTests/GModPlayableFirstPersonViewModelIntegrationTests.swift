import Foundation
@testable import GModEngine
@testable import GModGameSession
import XCTest

final class GModPlayableFirstPersonViewModelIntegrationTests:
    XCTestCase
{
    func testLaneProjectsReplicatedActiveToolgunThroughClientSWEPAndStudioCache()
        async throws
    {
        let probe = PlayableViewModelCompileProbe()
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 4,
                maximumGeometryByteCount: 4_096
            ),
            compile: { [probe] model, body, skin in
                probe.resolve(model: model, bodyValue: body, skinFamilyIndex: skin)
            }
        )
        let lane = GModPlayableSessionLane(
            worldWalkCollisionProvider: nil,
            canonicalModelValidatorForTesting: { model, kind in
                model.path == "models/weapons/w_toolgun.mdl" && kind == .weapon
                    ? .valid
                    : .invalid
            },
            studioModelRepositoryForTesting: GModStudioModelRepository(
                reader: MissingPlayableViewModelStudioReader()
            ),
            studioRenderableModelCacheForTesting: cache
        )
        let started = try await lane.start(configuration: .init(map: .construct))

        let baselineCandidate = try await lane
            .clientFirstPersonViewModelScene(
                ifChangedFrom: nil,
                expectedGeneration: started.generation
            )
        let baseline = try XCTUnwrap(baselineCandidate)
        XCTAssertNil(baseline.projection)

        try await lane.execute(
            """
            local ply = Player(1)
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            realm: .server,
            sourceName: "=(first-person canonical gmod_tool fixture)",
            expectedGeneration: started.generation
        )
        _ = try await lane.runHostFrame(
            fixedTickCount: 1,
            renderClientFrame: false,
            expectedGeneration: started.generation,
            expectedInputEpoch: started.inputEpoch
        )

        let publishedCandidate = try await lane
            .clientFirstPersonViewModelScene(
                ifChangedFrom: baseline.revision,
                expectedGeneration: started.generation
            )
        let published = try XCTUnwrap(publishedCandidate)
        let projection = try XCTUnwrap(published.projection)
        XCTAssertEqual(published.status, .available)
        XCTAssertEqual(projection.weaponClassName, "gmod_tool")
        XCTAssertEqual(
            projection.viewModel.path,
            "models/weapons/c_toolgun.mdl"
        )
        XCTAssertEqual(
            projection.worldModel?.path,
            "models/weapons/w_toolgun.mdl"
        )
        XCTAssertEqual(projection.viewModelFieldOfViewDegrees, 62)
        XCTAssertEqual(probe.requests, [PlayableViewModelCompileProbe.Request(
            path: "models/weapons/c_toolgun.mdl",
            body: 0,
            skin: 0
        )])
        let unchanged = try await lane.clientFirstPersonViewModelScene(
            ifChangedFrom: published.revision,
            expectedGeneration: started.generation
        )
        XCTAssertNil(unchanged)

        _ = try await lane.close(expectedGeneration: started.generation)
    }
}

private struct MissingPlayableViewModelStudioReader:
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

private final class PlayableViewModelCompileProbe: @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        let body: Int
        let skin: Int
    }

    private let lock = NSLock()
    private var requestsStorage: [Request] = []

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution {
        lock.lock()
        requestsStorage.append(Request(
            path: model.path,
            body: bodyValue,
            skin: skinFamilyIndex
        ))
        lock.unlock()
        let path = model.path.lowercased()
        let checksum: Int32 = 91
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
                    textureCoordinate: SourceStudioTextureCoordinate(u: 0, v: 0)
                )],
                indices: [],
                drawRanges: []
            )
        ))
    }
}

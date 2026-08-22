import Foundation
@testable import GModEngine
@testable import GModGameSession
import XCTest

final class GModPlayableFirstPersonHandsIntegrationTests: XCTestCase {
    func testStockSetupHandsPublishesAndReplacesThroughClientFIFO() throws {
        let playerModel = SourceEntityModelReference(
            "models/player/kleiner.mdl"
        )
        let handsModel = SourceEntityModelReference(
            "models/weapons/c_arms_citizen.mdl"
        )
        let playerLayout = try SourceStudioBodyGroupLayout(
            bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 2),
                .init(modelSelectionBase: 2, modelCount: 3),
            ]
        )
        let handsLayout = try SourceStudioBodyGroupLayout(
            bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 2),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
            ]
        )
        let compileProbe = PlayableHandsCompileProbe()
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 4,
                maximumGeometryByteCount: 4_096
            ),
            compile: { [compileProbe] model, body, skin in
                compileProbe.resolve(
                    model: model,
                    bodyValue: body,
                    skinFamilyIndex: skin
                )
            }
        )
        let configuration = GModPlayableSessionConfiguration(
            map: .construct,
            playerEntityIndex: 7,
            playerUserID: 70
        )
        let session = try GModPlayableSession(
            configuration: configuration,
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalBodyGroupLayoutResolverForTesting: { model in
                if model == playerModel { return playerLayout }
                if model == handsModel { return handsLayout }
                return nil
            },
            studioRenderableModelCacheForTesting: cache
        )
        defer { _ = try? session.close() }

        let baseline = try XCTUnwrap(
            session.clientFirstPersonHandsScene(ifChangedFrom: nil)
        )
        let clientPlayer = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first(where: {
                $0.identity.entryIndex == configuration.playerEntityIndex &&
                    $0.kind == .player
            })
        )
        XCTAssertNil(baseline.projection)
        XCTAssertEqual(
            baseline.status,
            .unavailableNoHands(clientPlayer.identity)
        )

        let spawn = try session.serverRuntime.executeReturningValues(
            """
            local ok, message = pcall(
                hook.Call,
                "PlayerSpawn",
                GAMEMODE,
                Player(70),
                false
            )
            return ok, message
            """,
            sourceName: "=(first-person Hands stock PlayerSpawn)"
        )
        guard case .boolean(true)? = spawn.first else {
            return XCTFail(
                "stock PlayerSpawn failed: " +
                    (spawn.dropFirst().first.map(String.init(describing:)) ??
                        "missing result")
            )
        }

        XCTAssertNil(
            try session.clientFirstPersonHandsScene(
                ifChangedFrom: baseline.revision
            ),
            "SERVER hands must wait for the canonical replication FIFO"
        )
        _ = try session.runFixedTick()

        let first = try XCTUnwrap(
            session.clientFirstPersonHandsScene(
                ifChangedFrom: baseline.revision
            )
        )
        XCTAssertEqual(first.status, .available)
        XCTAssertEqual(
            first.sourceProjectionCursor,
            session.clientCanonicalEntityReplicationCursor
        )
        let firstProjection = try XCTUnwrap(first.projection)
        XCTAssertEqual(firstProjection.playerIdentity.entryIndex, 7)
        XCTAssertEqual(firstProjection.model, handsModel)
        XCTAssertEqual(firstProjection.viewModelSlot, 0)
        XCTAssertEqual(firstProjection.skinFamilyIndex, 0)
        XCTAssertEqual(firstProjection.bodyValue, 0)

        try session.serverRuntime.execute(
            "Player(70):SetupHands()",
            sourceName: "=(first-person Hands replacement)"
        )
        XCTAssertNil(
            try session.clientFirstPersonHandsScene(
                ifChangedFrom: first.revision
            ),
            "replacement must remain SERVER-only until the next FIFO drain"
        )
        _ = try session.runFixedTick()

        let replaced = try XCTUnwrap(
            session.clientFirstPersonHandsScene(
                ifChangedFrom: first.revision
            )
        )
        XCTAssertEqual(replaced.status, .available)
        let replacementProjection = try XCTUnwrap(replaced.projection)
        XCTAssertNotEqual(
            replacementProjection.handsIdentity,
            firstProjection.handsIdentity
        )
        XCTAssertEqual(replacementProjection.model, handsModel)
        XCTAssertEqual(
            replaced.sourceProjectionCursor,
            session.clientCanonicalEntityReplicationCursor
        )
        XCTAssertEqual(compileProbe.requests, [
            PlayableHandsCompileProbe.Request(
                path: handsModel.path,
                body: 0,
                skin: 0
            ),
        ])
    }

}

private final class PlayableHandsCompileProbe: @unchecked Sendable {
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
        let checksum: Int32 = 0x2718_2818
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
                    textureCoordinate: SourceStudioTextureCoordinate(
                        u: 0,
                        v: 0
                    )
                )],
                indices: [],
                drawRanges: []
            )
        ))
    }
}

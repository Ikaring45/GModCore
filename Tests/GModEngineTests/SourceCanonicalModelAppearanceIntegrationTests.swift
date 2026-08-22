import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class SourceCanonicalModelAppearanceIntegrationTests: XCTestCase {
    func testStudioAppearanceMutatesThroughFIFOAndSelectsExactRenderResource()
        throws
    {
        let model = SourceEntityModelReference(
            "models/props/appearance_test.mdl"
        )
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let appearance = try SourceStudioModelAppearanceLayout(
            checksum: propAsset.studioChecksum,
            modelName: "appearance_test",
            skinFamilyCount: 2,
            bodyGroups: [
                SourceStudioBodyGroupAppearance(
                    id: 0,
                    name: "equipment",
                    modelSelectionBase: 1,
                    submodelNames: ["blank", "helmet"]
                ),
            ]
        )
        let layout = try SourceStudioBodyGroupLayout(
            bodyParts: appearance.bodyGroups.map(\.selectionDescriptor),
            appearance: appearance
        )
        let cache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 8,
                maximumGeometryByteCount: 1_024
            ),
            compile: { model, bodyValue, skinFamilyIndex in
                .resolved(Self.resource(
                    model: model,
                    bodyValue: bodyValue,
                    skinFamilyIndex: skinFamilyIndex
                ))
            }
        )
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting:
                makeAttestedPropPhysicsTestResolver(asset: propAsset),
            canonicalBodyGroupLayoutResolverForTesting: { candidate in
                candidate == model ? layout : nil
            },
            studioRenderableModelCacheForTesting: cache
        )
        defer { _ = try? session.close() }

        let values = try session.serverRuntime.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/appearance_test.mdl")
            assert(prop:SkinCount() == 2)
            assert(prop:GetNumBodyGroups() == 1)
            assert(prop:GetBodygroupName(0) == "equipment")
            assert(prop:GetBodygroupCount(0) == 2)
            local groups = prop:GetBodyGroups()
            assert(#groups == 1)
            assert(groups[1].id == 0)
            assert(groups[1].name == "equipment")
            assert(groups[1].num == 2)
            assert(groups[1].submodels[0] == "blank")
            assert(groups[1].submodels[1] == "helmet")
            prop:SetSkin(1)
            prop:SetBodygroup(0, 1)
            prop:Spawn()
            prop:Activate()
            TEST_APPEARANCE_PROP = prop
            return prop:EntIndex()
            """,
            sourceName: "=(canonical Studio appearance create)"
        )
        guard case let .number(indexValue)? = values.first else {
            return XCTFail("appearance prop did not return an entity index")
        }
        let index = Int(indexValue)
        XCTAssertNil(
            session.clientRuntime.entityRegistry?.canonicalSnapshot(at: index),
            "SERVER appearance must wait for the shared entity FIFO"
        )

        _ = try session.runFixedTick()
        let client = try XCTUnwrap(
            session.clientRuntime.entityRegistry?.canonicalSnapshot(at: index)
        )
        XCTAssertEqual(client.skin, 1)
        XCTAssertEqual(client.bodyValue, 1)
        let firstScene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(ifChangedFrom: nil)
        )
        let firstInstance = try XCTUnwrap(firstScene.instances.first)
        XCTAssertEqual(firstInstance.resourceID.skinFamilyIndex, 1)
        XCTAssertEqual(firstInstance.resourceID.bodyValue, 1)

        let beforeReject = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: client.identity)
        )
        let journalBeforeReject = session.sourceAdapter
            .pendingCanonicalEntityOperationCount
        try session.serverRuntime.execute(
            """
            local ok = pcall(function() TEST_APPEARANCE_PROP:SetSkin(2) end)
            assert(ok == false)
            """,
            sourceName: "=(reject out-of-range Studio skin family)"
        )
        XCTAssertEqual(
            session.sourceAdapter.canonicalSnapshot(for: client.identity),
            beforeReject
        )
        XCTAssertEqual(
            session.sourceAdapter.pendingCanonicalEntityOperationCount,
            journalBeforeReject
        )

        try session.serverRuntime.execute(
            """
            TEST_APPEARANCE_PROP:SetSkin(0)
            TEST_APPEARANCE_PROP:SetBodygroup(0, 0)
            """,
            sourceName: "=(canonical Studio appearance update)"
        )
        XCTAssertNil(
            try session.clientDynamicEntityRenderScene(
                ifChangedFrom: firstScene.revision
            ),
            "renderer must not observe SERVER appearance before FIFO delivery"
        )
        _ = try session.runFixedTick()
        let secondScene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(
                ifChangedFrom: firstScene.revision
            )
        )
        let secondInstance = try XCTUnwrap(secondScene.instances.first)
        XCTAssertEqual(secondInstance.resourceID.skinFamilyIndex, 0)
        XCTAssertEqual(secondInstance.resourceID.bodyValue, 0)
        XCTAssertNotEqual(secondInstance.resourceID, firstInstance.resourceID)

        let originalIdentity = client.identity
        try session.serverRuntime.execute(
            "TEST_APPEARANCE_PROP:Remove()",
            sourceName: "=(remove canonical appearance prop)"
        )
        _ = try session.runFixedTick()
        let replacementValues = try session.serverRuntime.executeReturningValues(
            """
            local replacement = assert(ents.Create("prop_physics"))
            replacement:SetModel("models/props/appearance_test.mdl")
            local staleOK = pcall(function()
                TEST_APPEARANCE_PROP:SetSkin(1)
            end)
            assert(staleOK == false)
            TEST_APPEARANCE_REPLACEMENT = replacement
            return replacement
            """,
            sourceName: "=(appearance EHANDLE generation reuse)"
        )
        let replacementValue = try XCTUnwrap(replacementValues.first)
        let replacement = try XCTUnwrap(
            session.serverRuntime.entityRegistry?.canonicalSnapshot(
                for: replacementValue
            )
        )
        XCTAssertEqual(replacement.identity.entryIndex, originalIdentity.entryIndex)
        XCTAssertNotEqual(replacement.identity, originalIdentity)
        XCTAssertEqual(replacement.skin, 0)
    }

    private static func resource(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResource {
        let normalized = model.path.lowercased()
        let checksum: Int32 = 0x1122_3344
        let snapshot = GModStudioRenderableModelSnapshot(
            checksum: checksum,
            modelName: normalized,
            lodIndex: 0,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            vertices: [
                GModDynamicModelVertex(
                    position: .zero,
                    normal: SourceVector3(0, 0, 1),
                    textureCoordinate: SourceStudioTextureCoordinate(u: 0, v: 0)
                ),
            ],
            indices: [],
            drawRanges: []
        )
        return GModStudioRenderableModelResource(
            id: GModStudioRenderableModelResourceID(
                normalizedModelPath: normalized,
                checksum: checksum,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex
            ),
            model: snapshot
        )
    }
}

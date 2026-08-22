import Foundation
import XCTest
@testable import GModEngine
import GModGameAssets
@testable import GModGameSession

final class GModStockPropVerticalIntegrationTests: XCTestCase {
    private let model = SourceEntityModelReference(
        "models/maxofs2d/button_06.mdl"
    )

    func testOriginalSpawnIconCreatesReplicatesAndUndoesButtonProp()
        throws
    {
        let mdlData = Data("exact button_06 mdl fixture".utf8)
        let phyData = Data("exact button_06 phy fixture".utf8)
        let studioChecksum: Int32 = -1_817_891_700
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            mdlSHA256: digest(mdlData),
            phySHA256: digest(phyData),
            studioChecksum: studioChecksum,
            // This vertical verifies the stock SpawnIcon, replication,
            // rendering, and undo route. The bundled BSP intentionally keeps
            // world surface-material indices nil until independent Source
            // material-pair evidence is available, so this synthetic asset
            // must not enter that unrelated fail-closed contact boundary.
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                damping: .zero,
                isGravityEnabled: false,
                isCollisionEnabled: false,
                startsAwake: true
            )
        )
        let resolver = try GModAttestedPropPhysicsAssetResolver(
            attestedAssets: [asset],
            loadObservedAsset: { requested in
                .loaded(GModObservedPropPhysicsAsset(
                    normalizedModelPath: requested.path,
                    mdlData: mdlData,
                    phyData: phyData,
                    studioChecksum: studioChecksum
                ))
            }
        )
        let bodyGroupMetadata = try SourceAttestedStudioBodyGroupMetadata(
            normalizedModelPath: model.path,
            mdlSHA256: asset.mdlSHA256,
            studioChecksum: studioChecksum,
            bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 1),
            ],
            attestationReference: "synthetic-stock-route-mechanics"
        )
        let renderCache = try GModStudioRenderableModelCache(
            policy: GModStudioRenderableModelCachePolicy(
                maximumEntryCount: 1,
                maximumGeometryByteCount: 1_024
            ),
            compile: { [model] requested, bodyValue, skinFamilyIndex in
                precondition(requested == model)
                let normalizedPath = requested.path.lowercased()
                let renderable = GModStudioRenderableModelSnapshot(
                    checksum: studioChecksum,
                    modelName: normalizedPath,
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
                return .resolved(GModStudioRenderableModelResource(
                    id: GModStudioRenderableModelResourceID(
                        normalizedModelPath: normalizedPath,
                        checksum: studioChecksum,
                        bodyValue: bodyValue,
                        skinFamilyIndex: skinFamilyIndex
                    ),
                    model: renderable
                ))
            }
        )
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { [model] candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            attestedPropPhysicsAssetResolverForTesting: resolver,
            attestedStudioBodyGroupMetadataForTesting: [bodyGroupMetadata],
            studioRenderableModelCacheForTesting: renderCache
        )
        defer { _ = try? session.close() }

        try session.serverRuntime.execute(
            """
            assert(game.SinglePlayer())
            assert(util.IsValidModel("models/maxofs2d/button_06.mdl"))
            assert(util.IsValidProp("models/maxofs2d/button_06.mdl"))
            """,
            sourceName: "=(stock button_06 eligibility)"
        )
        try session.clientRuntime.execute(
            """
            local effectDataA = EffectData()
            local effectDataB = EffectData()
            assert(effectDataA == effectDataB)
            assert(TypeID(effectDataA) == TYPE_EFFECTDATA)
            local dockProbe = vgui.Create("Panel")
            dockProbe:DockPadding(1, 2, 3, 4)
            dockProbe:DockMargin(5, 6, 7, 8)
            local pl, pt, pr, pb = dockProbe:GetDockPadding()
            local ml, mt, mr, mb = dockProbe:GetDockMargin()
            assert(pl == 1 and pt == 2 and pr == 3 and pb == 4)
            assert(ml == 5 and mt == 6 and mr == 7 and mb == 8)
            STOCK_NETWORK_CREATED = {}
            hook.Add("NetworkEntityCreated", "StockPropVertical", function(ent)
                if ent:GetClass() == "prop_physics" then
                    STOCK_NETWORK_CREATED[#STOCK_NETWORK_CREATED + 1] = ent
                end
            end)
            """,
            sourceName: "=(stock prop dock geometry ABI)"
        )
        try session.clientRuntime.execute(
            """
            STOCK_BUTTON_ICON = assert(spawnmenu.CreateContentIcon(
                "model",
                nil,
                { model = "models/maxofs2d/button_06.mdl", skin = 0 }
            ))
            assert(STOCK_BUTTON_ICON:GetBodyGroup() == "000000000")
            STOCK_BUTTON_ICON:DoClick()
            """,
            sourceName: "=(original stock button_06 SpawnIcon click)"
        )

        let spawned = try session.runFixedTick()
        if let failure = spawned.actionFailures.first {
            XCTFail("first stock prop boundary: \(failure.message)")
        }
        XCTAssertEqual(spawned.actionFailures, [])
        let serverProp = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .propPhysics
            }
        )
        let clientProp = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.kind == .propPhysics
            }
        )
        XCTAssertEqual(clientProp.identity, serverProp.identity)
        XCTAssertEqual(clientProp.model, model)
        XCTAssertEqual(serverProp.bodyValue, 0)
        XCTAssertEqual(clientProp.lifecycle, .active)
        XCTAssertTrue(serverProp.spawnEffect)
        XCTAssertEqual(clientProp.spawnEffect, serverProp.spawnEffect)
        XCTAssertEqual(clientProp.creationTime, serverProp.creationTime)
        let effect = try XCTUnwrap(
            session.clientRuntime.effects?.capturedRequests.last
        )
        XCTAssertEqual(effect.name, "propspawn")
        XCTAssertEqual(effect.data.entityIdentity, serverProp.identity)
        XCTAssertEqual(effect.data.origin.x, Double(clientProp.transform.origin.x))
        XCTAssertEqual(effect.data.origin.y, Double(clientProp.transform.origin.y))
        XCTAssertEqual(effect.data.origin.z, Double(clientProp.transform.origin.z))
        XCTAssertTrue(effect.allowOverride)
        XCTAssertEqual(effect.ignorePrediction, true)
        XCTAssertTrue(
            try XCTUnwrap(session.clientRuntime.achievements)
                .capturedRequests.contains(.propSpawned)
        )
        let createdScene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(ifChangedFrom: nil)
        )
        XCTAssertEqual(createdScene.resources.count, 1)
        XCTAssertEqual(createdScene.instances.count, 1)
        XCTAssertEqual(createdScene.instances[0].identity, serverProp.identity)
        XCTAssertEqual(createdScene.instances[0].transform, clientProp.transform)
        XCTAssertTrue(createdScene.issues.isEmpty)
        try session.clientRuntime.execute(
            """
            assert(#STOCK_NETWORK_CREATED == 1)
            assert(STOCK_NETWORK_CREATED[1]:GetSpawnEffect())
            assert(STOCK_NETWORK_CREATED[1]:GetCreationTime() <= CurTime())
            """,
            sourceName: "=(stock prop network creation semantics)"
        )

        try session.serverRuntime.execute(
            """
            STOCK_SERVER_REMOVE_CALLBACKS = 0
            STOCK_SERVER_REMOVED_HOOKS = 0
            local prop = Entity(\(serverProp.identity.entryIndex))
            prop:CallOnRemove("stock-removal", function(ent, marker)
                assert(IsValid(ent))
                assert(Entity(\(serverProp.identity.entryIndex)) == ent)
                assert(marker == "server-extra")
                STOCK_SERVER_REMOVE_CALLBACKS = STOCK_SERVER_REMOVE_CALLBACKS + 1
            end, "server-extra")
            prop:CallOnRemove("stock-cancelled", function()
                error("removed stock SERVER callback ran")
            end)
            prop:RemoveCallOnRemove("stock-cancelled")
            hook.Add("EntityRemoved", "StockServerRemoval", function(ent, fullUpdate)
                if ent ~= prop then return end
                assert(IsValid(ent))
                assert(fullUpdate == false)
                STOCK_SERVER_REMOVED_HOOKS = STOCK_SERVER_REMOVED_HOOKS + 1
            end)
            """,
            sourceName: "=(stock prop SERVER removal callbacks)"
        )
        try session.clientRuntime.execute(
            """
            STOCK_CLIENT_REMOVE_CALLBACKS = 0
            STOCK_CLIENT_REMOVED_HOOKS = 0
            local prop = Entity(\(clientProp.identity.entryIndex))
            prop:CallOnRemove("stock-removal", function(ent, marker)
                assert(IsValid(ent))
                assert(Entity(\(clientProp.identity.entryIndex)) == ent)
                assert(marker == "client-extra")
                STOCK_CLIENT_REMOVE_CALLBACKS = STOCK_CLIENT_REMOVE_CALLBACKS + 1
            end, "client-extra")
            prop:CallOnRemove("stock-cancelled", function()
                error("removed stock CLIENT callback ran")
            end)
            prop:RemoveCallOnRemove("stock-cancelled")
            hook.Add("EntityRemoved", "StockClientRemoval", function(ent, fullUpdate)
                if ent ~= prop then return end
                assert(IsValid(ent))
                assert(fullUpdate == false)
                STOCK_CLIENT_REMOVED_HOOKS = STOCK_CLIENT_REMOVED_HOOKS + 1
            end)
            """,
            sourceName: "=(stock prop CLIENT removal callbacks)"
        )

        try session.serverRuntime.execute(
            """
            local undos = undo.GetTable()
            assert(undos[1] ~= nil)
            assert(undos[1][1] ~= nil)
            assert(undos[1][1].Name == "prop_physics")
            assert(undos[1][1].Entities[1] == Entity(\(serverProp.identity.index)))
            """,
            sourceName: "=(stock prop original SERVER undo stack)"
        )
        try session.clientRuntime.execute(
            """
            local undos = undo.GetTable()
            assert(#undos == 1)
            assert(undos[1].Key == 1)
            STOCK_CLIENT_UNDO_HOOKS = 0
            hook.Add("OnUndo", "StockPropUndo", function(name, customText)
                assert(name == "prop_physics")
                assert(customText == nil)
                STOCK_CLIENT_UNDO_HOOKS = STOCK_CLIENT_UNDO_HOOKS + 1
            end)
            RunConsoleCommand("undo")
            """,
            sourceName: "=(original stock undo console action)"
        )

        // The CLIENT command reaches SERVER after this tick's cleanup phase.
        // Stock undo therefore marks the exact EHANDLE for deferred removal,
        // sends its original net notices, and lets the following Source tick
        // perform EntityRemoved/CallOnRemove before invalidating the userdata.
        let undoAction = try session.runFixedTick()
        XCTAssertEqual(undoAction.actionFailures, [])
        XCTAssertEqual(undoAction.server.hookFailures, [])
        XCTAssertEqual(undoAction.client.hookFailures, [])
        XCTAssertEqual(
            session.sourceAdapter.canonicalSnapshot(for: serverProp.identity)?.lifecycle,
            .pendingRemoval
        )
        try session.clientRuntime.execute(
            """
            assert(STOCK_CLIENT_UNDO_HOOKS == 1)
            assert(#undo.GetTable() == 0)
            local foundNotice = false
            for _, panel in ipairs(vgui.GetAll()) do
                if panel:GetClassName() == "NoticePanel" then
                    foundNotice = true
                    break
                end
            end
            assert(foundNotice)
            """,
            sourceName: "=(stock undo CLIENT notifications)"
        )
        XCTAssertTrue(
            try XCTUnwrap(session.clientRuntime.surfaceCommandState)
                .pendingSoundRequestReport.requests.contains {
                    $0.soundPath == "buttons/button15.wav"
                }
        )

        let removal = try session.runFixedTick()
        XCTAssertEqual(removal.server.hookFailures, [])
        XCTAssertEqual(removal.client.hookFailures, [])
        try session.serverRuntime.execute(
            """
            assert(STOCK_SERVER_REMOVE_CALLBACKS == 1)
            assert(STOCK_SERVER_REMOVED_HOOKS == 1)
            """,
            sourceName: "=(stock prop SERVER removal results)"
        )
        try session.clientRuntime.execute(
            """
            assert(STOCK_CLIENT_REMOVE_CALLBACKS == 1)
            assert(STOCK_CLIENT_REMOVED_HOOKS == 1)
            """,
            sourceName: "=(stock prop CLIENT removal results)"
        )
        XCTAssertFalse(session.sourceAdapter.canonicalEntitySnapshots.contains {
            $0.identity == serverProp.identity
        })
        XCTAssertFalse(session.clientCanonicalEntitySnapshots.contains {
            $0.identity == serverProp.identity
        })
        let removedScene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(
                ifChangedFrom: createdScene.revision
            )
        )
        XCTAssertTrue(removedScene.resources.isEmpty)
        XCTAssertTrue(removedScene.instances.isEmpty)
        XCTAssertTrue(removedScene.issues.isEmpty)
    }

    private func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }
}

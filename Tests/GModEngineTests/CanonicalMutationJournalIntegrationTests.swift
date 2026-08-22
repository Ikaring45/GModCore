import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class CanonicalMutationJournalIntegrationTests: XCTestCase {
    private enum IntentionalPublishFailure: Error {
        case stopBeforeFIFOCommit
    }

    func testStockLikePropMutationsWaitForTickAndKeepGlobalFIFOOrder() throws {
        let acceptedModel = SourceEntityModelReference(
            "models/props_c17/oildrum001.mdl"
        )
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: acceptedModel.path
        )
        let appearance = try SourceStudioModelAppearanceLayout(
            checksum: propAsset.studioChecksum,
            modelName: acceptedModel.path,
            skinFamilyCount: 3,
            bodyGroups: []
        )
        let appearanceLayout = try SourceStudioBodyGroupLayout(
            bodyParts: [],
            appearance: appearance
        )
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { model, kind in
                model == acceptedModel && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting:
                makeAttestedPropPhysicsTestResolver(asset: propAsset),
            canonicalBodyGroupLayoutResolverForTesting: { model in
                model == acceptedModel ? appearanceLayout : nil
            }
        )
        defer { _ = try? session.close() }

        XCTAssertEqual(session.sourceAdapter.pendingCanonicalEntityOperationCount, 0)
        let values = try session.serverRuntime.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props_c17/oildrum001.mdl")
            prop:SetSkin(2)
            prop:SetPos(Vector(100, 200, 300))
            prop:SetAngles(Angle(15, 25, 35))
            prop:Spawn()
            prop:Activate()
            TEST_JOURNAL_PROP = prop
            return prop:EntIndex()
            """,
            sourceName: "=(canonical journal stock-like prop creation)"
        )
        guard case let .number(indexNumber)? = values.first else {
            return XCTFail("prop creation did not return an entity index")
        }
        let propIndex = Int(indexNumber)
        let authoritativeProp = try XCTUnwrap(
            session.serverRuntime.entityRegistry?.canonicalSnapshot(at: propIndex)
        )
        XCTAssertEqual(authoritativeProp.lifecycle, .active)
        XCTAssertNil(
            session.clientRuntime.entityRegistry?.canonicalSnapshot(at: propIndex),
            "direct SERVER Lua must remain invisible to CLIENT before a fixed tick"
        )

        let pendingBeforeFailure = session.sourceAdapter
            .pendingCanonicalEntityOperationCount
        var rejectedOperations: [SourceEntityReplicationOperation] = []
        XCTAssertThrowsError(
            try session.sourceAdapter.publishPendingCanonicalEntityOperations {
                rejectedOperations = $0
                throw IntentionalPublishFailure.stopBeforeFIFOCommit
            }
        ) { error in
            XCTAssertTrue(error is IntentionalPublishFailure)
        }
        XCTAssertFalse(rejectedOperations.isEmpty)
        XCTAssertEqual(
            session.sourceAdapter.pendingCanonicalEntityOperationCount,
            pendingBeforeFailure,
            "a failed enqueue transaction must retain the exact journal prefix"
        )
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)

        _ = try session.runFixedTick()
        XCTAssertEqual(
            session.clientRuntime.entityRegistry?.canonicalSnapshot(at: propIndex),
            session.serverRuntime.entityRegistry?.canonicalSnapshot(at: propIndex)
        )
        XCTAssertEqual(session.sourceAdapter.pendingCanonicalEntityOperationCount, 0)

        try session.serverRuntime.execute(
            "TEST_JOURNAL_PROP:Remove()",
            sourceName: "=(canonical journal deferred remove)"
        )
        XCTAssertEqual(
            session.serverRuntime.entityRegistry?.canonicalSnapshot(at: propIndex)?.lifecycle,
            .pendingRemoval
        )
        XCTAssertEqual(
            session.clientRuntime.entityRegistry?.canonicalSnapshot(at: propIndex)?.lifecycle,
            .active,
            "pending removal must not bypass the entity FIFO"
        )
        _ = try session.runFixedTick()
        XCTAssertNil(session.serverRuntime.entityRegistry?.canonicalSnapshot(at: propIndex))
        XCTAssertNil(session.clientRuntime.entityRegistry?.canonicalSnapshot(at: propIndex))

        try session.serverRuntime.execute(
            """
            local prior = concommand.Run
            function concommand.Run(sender, command, arguments, argumentString)
                if command == "journal_spawn_prop" then
                    local prop = assert(ents.Create("prop_physics"))
                    prop:SetModel("models/props_c17/oildrum001.mdl")
                    prop:Spawn()
                    prop:Activate()
                    TEST_CALLBACK_PROP = prop
                    return
                end
                return prior(sender, command, arguments, argumentString)
            end
            AddConsoleCommand("journal_spawn_prop")
            util.AddNetworkString("journal_observe_before_entity_delta")
            """,
            sourceName: "=(canonical journal callback mutation route)"
        )
        try session.clientRuntime.execute(
            """
            JOURNAL_PROP_VISIBLE_DURING_NET = nil
            net.Receive("journal_observe_before_entity_delta", function()
                JOURNAL_PROP_VISIBLE_DURING_NET = Entity(\(propIndex)):IsValid()
            end)
            RunConsoleCommand("journal_spawn_prop")
            """,
            sourceName: "=(canonical journal queue callback command)"
        )
        try session.serverRuntime.execute(
            """
            net.Start("journal_observe_before_entity_delta")
            net.Broadcast()
            """,
            sourceName: "=(canonical journal queue prior net packet)"
        )

        let callbackTick = try session.runFixedTick()
        XCTAssertGreaterThanOrEqual(callbackTick.deliveredMessages, 3)
        try session.clientRuntime.execute(
            """
            assert(JOURNAL_PROP_VISIBLE_DURING_NET == false)
            assert(Entity(\(propIndex)):IsValid())
            """,
            sourceName: "=(canonical journal FIFO ordering assertion)"
        )
        let callbackServerProp = try XCTUnwrap(
            session.serverRuntime.entityRegistry?.canonicalSnapshot(at: propIndex)
        )
        let callbackClientProp = try XCTUnwrap(
            session.clientRuntime.entityRegistry?.canonicalSnapshot(at: propIndex)
        )
        XCTAssertEqual(callbackClientProp, callbackServerProp)
        XCTAssertNotEqual(callbackClientProp.identity, authoritativeProp.identity)

        let rollbackValues = try session.serverRuntime.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            local index = prop:EntIndex()
            prop:SetModel("models/props_c17/not_present.mdl")
            assert(pcall(function() prop:Spawn() end) == false)
            assert(prop:IsValid() == false)
            return index
            """,
            sourceName: "=(canonical journal failed spawn rollback)"
        )
        guard case let .number(rollbackIndexNumber)? = rollbackValues.first else {
            return XCTFail("rollback did not return its transient entity index")
        }
        let rollbackIndex = Int(rollbackIndexNumber)
        XCTAssertNil(session.serverRuntime.entityRegistry?.canonicalSnapshot(at: rollbackIndex))
        XCTAssertNil(session.clientRuntime.entityRegistry?.canonicalSnapshot(at: rollbackIndex))
        XCTAssertEqual(
            session.sourceAdapter.pendingCanonicalEntityOperationCount,
            0,
            "an unpublished ents.Create transaction must vanish with its exact rollback"
        )
    }

    func testJournalCapacityRejectsBeforeCanonicalStateCommit() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 2,
            canonicalMutationJournalCapacity: 1
        )
        defer {
            try? adapter.close()
            _ = server.close()
        }

        let player = try adapter.createCanonicalEntity(kind: .player, at: 11)
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 1)
        XCTAssertThrowsError(
            try adapter.updateCanonicalEntity(player.identity) { state in
                state.transform.origin = SourceVector3(9, 8, 7)
            }
        ) { error in
            guard case let GMLuaSourceRuntimeAdapterError
                    .canonicalMutationJournalCapacityExceeded(maximum) = error else {
                return XCTFail("unexpected journal error: \(error)")
            }
            XCTAssertEqual(maximum, 1)
        }
        XCTAssertEqual(adapter.canonicalSnapshot(for: player.identity), player)
        XCTAssertEqual(
            server.entityRegistry?.canonicalSnapshot(at: player.identity.entryIndex),
            player
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 1)
    }

    func testTwoClientEntityFanoutIsAllOrNothingBeforeFIFOAppend() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let firstClient = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        let secondClient = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        defer {
            _ = secondClient.close()
            _ = firstClient.close()
            _ = server.close()
        }
        let serverEndpoint = try XCTUnwrap(server.netEndpoint)
        let firstEndpoint = try XCTUnwrap(firstClient.netEndpoint)
        let secondEndpoint = try XCTUnwrap(secondClient.netEndpoint)
        try transport.connectClientEndpoint(
            firstEndpoint,
            playerIndex: 1,
            generation: 11,
            onDisconnect: {}
        )
        try transport.connectClientEndpoint(
            secondEndpoint,
            playerIndex: 2,
            generation: 22,
            onDisconnect: {}
        )
        let generation11 = SourceEntityReplicationConnectionGeneration(rawValue: 11)
        let generation22 = SourceEntityReplicationConnectionGeneration(rawValue: 22)
        let wrongGeneration = SourceEntityReplicationConnectionGeneration(rawValue: 23)

        XCTAssertThrowsError(
            try transport.enqueueEntityReplications(
                [
                    GMLuaEntityReplicationEnqueueRequest(
                        packet: SourceEntityReplicationPacket(
                            connectionGeneration: generation11,
                            sequence: 1,
                            payload: .snapshot([])
                        ),
                        destination: firstEndpoint
                    ),
                    GMLuaEntityReplicationEnqueueRequest(
                        packet: SourceEntityReplicationPacket(
                            connectionGeneration: wrongGeneration,
                            sequence: 1,
                            payload: .snapshot([])
                        ),
                        destination: secondEndpoint
                    ),
                ],
                from: serverEndpoint
            )
        ) { error in
            XCTAssertEqual(
                error as? GMLuaEntityReplicationTransportError,
                .connectionGenerationMismatch(
                    expected: generation22,
                    received: wrongGeneration
                )
            )
        }
        XCTAssertEqual(
            transport.pendingDeliveryCount,
            0,
            "the valid first destination must not be partially enqueued"
        )

        try transport.enqueueEntityReplications(
            [
                GMLuaEntityReplicationEnqueueRequest(
                    packet: SourceEntityReplicationPacket(
                        connectionGeneration: generation11,
                        sequence: 1,
                        payload: .snapshot([])
                    ),
                    destination: firstEndpoint
                ),
                GMLuaEntityReplicationEnqueueRequest(
                    packet: SourceEntityReplicationPacket(
                        connectionGeneration: generation22,
                        sequence: 1,
                        payload: .snapshot([])
                    ),
                    destination: secondEndpoint
                ),
            ],
            from: serverEndpoint
        )
        XCTAssertEqual(transport.pendingDeliveryCount, 2)
    }
}

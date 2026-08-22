import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class SourceCanonicalEntityGLuaBridgeTests: XCTestCase {
    func testPlayerQueriesAndPropMutationsUseCanonicalSnapshots() throws {
        let runtime = makeRuntime()
        let acceptedModel = SourceEntityModelReference(
            "models/props_c17/oildrum001.mdl"
        )
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: acceptedModel.path
        )
        let bodyGroupMesh = makeBodyGroupMesh()
        let appearance = try SourceStudioModelAppearanceLayout(
            checksum: bodyGroupMesh.checksum,
            modelName: bodyGroupMesh.modelName,
            skinFamilyCount: 4,
            bodyGroups: bodyGroupMesh.bodyParts.map { bodyPart in
                SourceStudioBodyGroupAppearance(
                    id: bodyPart.index,
                    name: bodyPart.name,
                    modelSelectionBase: bodyPart.modelSelectionBase,
                    submodelNames: bodyPart.models.map(\.name)
                )
            }
        )
        let bodyGroupLayout = try SourceStudioBodyGroupLayout(
            bodyParts: bodyGroupMesh.bodyParts.map {
                SourceStudioBodyGroupSelectionDescriptor(
                    modelSelectionBase: $0.modelSelectionBase,
                    modelCount: $0.models.count
                )
            },
            appearance: appearance
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 4,
            canonicalModelValidator: { model, kind in
                model == acceptedModel && kind == .propPhysics ? .valid : .invalid
            },
            canonicalBodyGroupResolver: { model, subModelIDs, currentBodyValue in
                guard model == acceptedModel else {
                    throw SourceCanonicalEntityError.modelRejected(model)
                }
                return try bodyGroupMesh.bodyValue(
                    applyingBodyGroups: subModelIDs,
                    to: currentBodyValue
                )
            },
            canonicalBodyGroupLayoutResolver: { model in
                model == acceptedModel ? bodyGroupLayout : nil
            },
            canonicalPropPhysicsAssetResolver:
                makeAttestedPropPhysicsTestResolver(asset: propAsset)
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        var playerState = SourceCanonicalEntityState.defaults(for: .player)
        playerState.transform = SourceEntityTransform(
            origin: SourceVector3(10, 20, 30),
            angles: SourceQAngle(pitch: 11, yaw: 22, roll: 3)
        )
        playerState.motion.linearVelocity = SourceVector3(4, 5, 6)
        playerState.motion.isAlive = true
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 7,
            state: playerState,
            playerUserID: 41
        )

        let values = try runtime.executeReturningValues(
            """
            local ply = Player(41)
            assert(ply:Alive() == true)
            local pos = ply:GetPos()
            assert(pos.x == 10 and pos.y == 20 and pos.z == 30)
            local velocity = ply:GetVelocity()
            assert(velocity.x == 4 and velocity.y == 5 and velocity.z == 6)
            assert(ply:GetMoveType() == 2)
            local shoot = ply:GetShootPos()
            assert(shoot.x == 10 and shoot.y == 20 and shoot.z == 94)
            local eye = ply:EyeAngles()
            assert(eye.p == 11 and eye.y == 22 and eye.r == 3)
            assert(ply:GetVehicle() == NULL)

            assert(util.IsValidModel("models/props_c17/oildrum001.mdl") == true)
            assert(util.IsValidProp("models/props_c17/oildrum001.mdl") == true)
            assert(util.IsValidModel("models/props_c17/not_present.mdl") == false)
            assert(util.IsValidProp("models/props_c17/not_present.mdl") == false)
            assert(util.IsValidModel("../outside.mdl") == false)
            assert(ents.Create("unsupported_class") == NULL)

            local prop = ents.Create("prop_physics")
            assert(prop:GetClass() == "prop_physics")
            prop:SetModel("models/props_c17/oildrum001.mdl")
            prop:SetSkin(3)
            assert(prop:GetSkin() == 3)
            assert(prop:SkinCount() == 4)
            prop:SetBodyGroups("12")
            assert(prop:GetNumBodyGroups() == 2)
            assert(prop:GetBodygroupName(0) == "body_0")
            assert(prop:GetBodygroupCount(1) == 3)
            local bodygroups = prop:GetBodyGroups()
            assert(#bodygroups == 2)
            assert(bodygroups[1].id == 0)
            assert(bodygroups[1].name == "body_0")
            assert(bodygroups[1].num == 2)
            assert(bodygroups[1].submodels[0] == "model_0")
            assert(prop:GetBodygroup(0) == 1)
            assert(prop:GetBodygroup(1) == 2)
            assert(prop:GetBodygroup(-1) == 0)
            assert(prop:GetBodygroup(12) == 0)
            prop:SetBodygroup(1, 1)
            assert(prop:GetBodygroup(1) == 1)
            prop:SetBodygroup(-1, 1)
            prop:SetBodygroup(1, 3)
            assert(prop:GetBodygroup(1) == 1)
            assert(pcall(function() prop:SetBodygroup(1, -1) end) == false)
            prop:SetPos(Vector(100, 200, 300))
            prop:SetAngles(Angle(15, 25, 35))
            local localPoint = Vector(7, -11, 13)
            local worldPoint = prop:LocalToWorld(localPoint)
            local roundTrip = prop:WorldToLocal(worldPoint)
            assert(math.abs(roundTrip.x - localPoint.x) < 0.0001)
            assert(math.abs(roundTrip.y - localPoint.y) < 0.0001)
            assert(math.abs(roundTrip.z - localPoint.z) < 0.0001)
            prop:SetCreator(ply)
            prop:Spawn()
            prop:Activate()
            TEST_CANONICAL_PROP = prop
            return prop
            """,
            sourceName: "=(canonical Entity GLua ABI)"
        )
        let propValue = try XCTUnwrap(values.first)
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let prop = try XCTUnwrap(registry.canonicalSnapshot(for: propValue))

        XCTAssertEqual(prop.lifecycle, .active)
        XCTAssertEqual(prop.model, acceptedModel)
        XCTAssertEqual(prop.skin, 3)
        XCTAssertEqual(prop.bodyValue, 3)
        XCTAssertEqual(prop.transform.origin, SourceVector3(100, 200, 300))
        XCTAssertEqual(
            prop.transform.angles,
            SourceQAngle(pitch: 15, yaw: 25, roll: 35)
        )
        XCTAssertEqual(prop.creator, player.identity)
        XCTAssertEqual(adapter.canonicalSnapshot(for: prop.identity), prop)

        try runtime.execute(
            "TEST_CANONICAL_PROP:Remove()",
            sourceName: "=(canonical Entity Remove)"
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: prop.identity)?.lifecycle,
            .pendingRemoval
        )
    }

    func testUnavailableModelValidationIsExplicitAndSpawnRollsBackExactHandle() throws {
        let runtime = makeRuntime()
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 12,
            canonicalModelValidator: nil
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let first = try runtime.executeReturningValues(
            """
            local validationOK, validationMessage = pcall(
                util.IsValidModel,
                "models/props_c17/oildrum001.mdl"
            )
            assert(validationOK == false)
            assert(string.find(
                validationMessage,
                "IsValidModel validation is unavailable",
                1,
                true
            ))
            local prop = ents.Create("prop_physics")
            local index = prop:EntIndex()
            prop:SetModel("models/props_c17/oildrum001.mdl")
            local ok, message = pcall(function() prop:Spawn() end)
            assert(ok == false)
            assert(string.find(message, "model validation is unavailable", 1, true))
            assert(prop:IsValid() == false)
            return index
            """,
            sourceName: "=(canonical unavailable model rollback)"
        )
        guard case let .number(firstIndex)? = first.first else {
            return XCTFail("rollback probe did not return the first entity index")
        }
        XCTAssertEqual(adapter.canonicalEntitySnapshots, [])
        XCTAssertNil(runtime.entityRegistry?.canonicalSnapshot(at: Int(firstIndex)))

        let replacementValues = try runtime.executeReturningValues(
            "return ents.Create('prop_physics')",
            sourceName: "=(canonical replacement after rollback)"
        )
        let replacementValue = try XCTUnwrap(replacementValues.first)
        let replacement = try XCTUnwrap(
            runtime.entityRegistry?.canonicalSnapshot(for: replacementValue)
        )
        XCTAssertEqual(replacement.identity.entryIndex, Int(firstIndex))
        XCTAssertEqual(replacement.identity.serialNumber, 13)
    }

    func testRejectedMutationAndInvalidLifecycleLeavePriorSnapshotExact() throws {
        let runtime = makeRuntime()
        let acceptedModel = SourceEntityModelReference("models/props/test.mdl")
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 2,
            canonicalModelValidator: { model, kind in
                model == acceptedModel && kind == .propPhysics ? .valid : .invalid
            }
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let values = try runtime.executeReturningValues(
            """
            local prop = ents.Create("prop_physics")
            prop:SetModel("models/props/test.mdl")
            prop:SetPos(Vector(1, 2, 3))
            local badPos = pcall(function()
                prop:SetPos(Vector(0 / 0, 20, 30))
            end)
            assert(badPos == false)
            local pos = prop:GetPos()
            assert(pos.x == 1 and pos.y == 2 and pos.z == 3)

            local badOrder = pcall(function() prop:Activate() end)
            assert(badOrder == false)
            assert(prop:IsValid() == true)
            return prop
            """,
            sourceName: "=(canonical transaction rejection)"
        )
        let propValue = try XCTUnwrap(values.first)
        let snapshot = try XCTUnwrap(
            runtime.entityRegistry?.canonicalSnapshot(for: propValue)
        )
        XCTAssertEqual(snapshot.lifecycle, .created)
        XCTAssertEqual(snapshot.transform.origin, SourceVector3(1, 2, 3))
        XCTAssertEqual(snapshot.revision, 2)
    }

    func testBodyGroupFailuresLeaveCanonicalStateRevisionAndJournalExact() throws {
        let acceptedModel = SourceEntityModelReference("models/props/test.mdl")
        let mesh = makeBodyGroupMesh()
        let runtime = makeRuntime()
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 20,
            canonicalModelValidator: { _, _ in .valid },
            canonicalBodyGroupResolver: { model, subModelIDs, currentBodyValue in
                guard model == acceptedModel else {
                    throw SourceCanonicalEntityError.modelRejected(model)
                }
                return try mesh.bodyValue(
                    applyingBodyGroups: subModelIDs,
                    to: currentBodyValue
                )
            }
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let values = try runtime.executeReturningValues(
            """
            local prop = ents.Create("prop_physics")
            local missingModel, missingMessage = pcall(function()
                prop:SetBodyGroups("10")
            end)
            assert(missingModel == false)
            assert(string.find(missingMessage, "has no Studio model", 1, true))

            prop:SetModel("models/props/test.mdl")
            local malformed, malformedMessage = pcall(function()
                prop:SetBodyGroups("20")
            end)
            assert(malformed == false)
            assert(string.find(malformedMessage, "invalidSelection", 1, true))
            return prop
            """,
            sourceName: "=(canonical body-group rejection)"
        )
        let propValue = try XCTUnwrap(values.first)
        let snapshot = try XCTUnwrap(
            runtime.entityRegistry?.canonicalSnapshot(for: propValue)
        )
        XCTAssertEqual(snapshot.model, acceptedModel)
        XCTAssertEqual(snapshot.bodyValue, 0)
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 2)

        let unavailableRuntime = makeRuntime()
        let unavailableAdapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: unavailableRuntime,
            initialEntitySerialNumber: 30,
            canonicalModelValidator: { _, _ in .valid }
        )
        defer {
            try? unavailableAdapter.close()
            _ = unavailableRuntime.close()
        }
        try unavailableAdapter.installCanonicalEntityLuaBridge()
        let unavailableValues = try unavailableRuntime.executeReturningValues(
            """
            local prop = ents.Create("prop_physics")
            assert(prop:GetNumBodyGroups() == 0)
            assert(prop:GetBodygroup(0) == 0)
            prop:SetModel("models/props/test.mdl")
            local ok, message = pcall(function() prop:SetBodyGroups("10") end)
            assert(ok == false)
            assert(string.find(message, "resolver is unavailable", 1, true))
            local queryOK, queryMessage = pcall(function()
                return prop:GetNumBodyGroups()
            end)
            assert(queryOK == false)
            assert(string.find(
                queryMessage,
                "layout resolver is unavailable",
                1,
                true
            ))
            local singleOK, singleMessage = pcall(function()
                prop:SetBodygroup(0, 1)
            end)
            assert(singleOK == false)
            assert(string.find(
                singleMessage,
                "layout resolver is unavailable",
                1,
                true
            ))
            return prop
            """,
            sourceName: "=(canonical body-group resolver unavailable)"
        )
        let unavailableValue = try XCTUnwrap(unavailableValues.first)
        let unavailableSnapshot = try XCTUnwrap(
            unavailableRuntime.entityRegistry?.canonicalSnapshot(
                for: unavailableValue
            )
        )
        XCTAssertEqual(unavailableSnapshot.bodyValue, 0)
        XCTAssertEqual(unavailableSnapshot.revision, 1)
        XCTAssertEqual(unavailableAdapter.pendingCanonicalEntityOperationCount, 2)
    }

    func testRepositoryBackedResolverUsesValidatedStudioBodyPartMetadata() throws {
        let asset = try makeValidatedStudioAsset()
        let model = SourceEntityModelReference("models/props/test.mdl")
        let mesh = makeBodyGroupMesh(
            checksum: asset.validation.checksum,
            modelName: asset.renderPayload.model.header.name
        )
        let repository = GModStudioModelRepository(
            decodeRootMesh: { _, _ in mesh },
            loadAsset: { _, _ in .loaded(asset) }
        )
        let runtime = makeRuntime()
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 40,
            canonicalModelValidator: { candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalBodyGroupResolver: {
                candidate,
                subModelIDs,
                currentBodyValue in
                try repository.bodyValue(
                    for: candidate,
                    applyingBodyGroups: subModelIDs,
                    to: currentBodyValue
                )
            }
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let values = try runtime.executeReturningValues(
            """
            local prop = ents.Create("prop_physics")
            prop:SetModel("models/props/test.mdl")
            prop:SetBodyGroups("12")
            return prop
            """,
            sourceName: "=(repository-backed canonical body groups)"
        )
        let value = try XCTUnwrap(values.first)
        let snapshot = try XCTUnwrap(
            runtime.entityRegistry?.canonicalSnapshot(for: value)
        )
        XCTAssertEqual(snapshot.bodyValue, 5)
        XCTAssertEqual(snapshot.revision, 2)

        let unsupported = SourceStudioMeshUnsupportedFeature.eyeballs(
            bodyPart: 0,
            model: 0,
            count: 1
        )
        let unsupportedRepository = GModStudioModelRepository(
            decodeRootMesh: { _, _ in
                throw SourceStudioModelMeshDecodeError.unsupported(unsupported)
            },
            loadAsset: { _, _ in .loaded(asset) }
        )
        XCTAssertThrowsError(
            try unsupportedRepository.bodyValue(
                for: model,
                applyingBodyGroups: "1",
                to: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? GModStudioBodyGroupResolutionError,
                .unsupportedMetadata(unsupported)
            )
        }
    }

    private func makeBodyGroupMesh(
        checksum: Int32 = 17,
        modelName: String = "bodygroup_test"
    ) -> SourceStudioModelMeshSnapshot {
        SourceStudioModelMeshSnapshot(
            checksum: checksum,
            modelName: modelName,
            lodIndex: 0,
            bodyParts: [2, 3].enumerated().map { bodyGroupID, modelCount in
                SourceStudioBodyPartMeshSnapshot(
                    index: bodyGroupID,
                    name: "body_\(bodyGroupID)",
                    modelSelectionBase: bodyGroupID == 0 ? 1 : 2,
                    models: (0..<modelCount).map { modelID in
                        SourceStudioSubmodelSnapshot(
                            index: modelID,
                            name: "model_\(modelID)",
                            type: 0,
                            boundingRadius: 1,
                            rootLODVertexCount: 0,
                            meshes: []
                        )
                    }
                )
            }
        )
    }

    private func makeValidatedStudioAsset() throws -> SourceStudioModelAsset {
        let checksum: Int32 = 71
        let paths = SourceStudioModelAssetPaths(
            mdl: "models/props/test.mdl",
            vvd: "models/props/test.vvd",
            vtx: "models/props/test.dx90.vtx"
        )
        let loader = SourceStudioModelAssetLoader(
            reader: BodyGroupStudioAssetReader(files: [
                paths.mdl: makeStudioMDL(checksum: checksum),
                paths.vvd: makeStudioVVD(checksum: checksum),
                paths.vtx: makeStudioVTX(checksum: checksum),
            ]),
            budget: SourceStudioModelAssetBudget(
                maximumBytesByKind: [
                    .mdl: 4_096,
                    .vvd: 4_096,
                    .vtx: 4_096,
                ],
                maximumTotalBytes: 12_288,
                maximumVVDVertices: 128,
                maximumVVDFixups: 128,
                maximumVTXBodyParts: 128
            )
        )
        return try XCTUnwrap(
            loader.load(paths: paths, requirement: .render).asset
        )
    }

    private func makeStudioMDL(checksum: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 408)
        putStudioUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putStudioInt32(48, at: 4, into: &bytes)
        putStudioInt32(checksum, at: 8, into: &bytes)
        putStudioCString(
            "models/props/test.mdl",
            at: 12,
            capacity: 64,
            into: &bytes
        )
        putStudioInt32(Int32(bytes.count), at: 76, into: &bytes)
        return Data(bytes)
    }

    private func makeStudioVVD(checksum: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        putStudioUInt32(0x5653_4449, at: 0, into: &bytes)
        putStudioInt32(4, at: 4, into: &bytes)
        putStudioInt32(checksum, at: 8, into: &bytes)
        putStudioInt32(1, at: 12, into: &bytes)
        putStudioInt32(1, at: 16, into: &bytes)
        putStudioInt32(64, at: 56, into: &bytes)
        putStudioInt32(112, at: 60, into: &bytes)
        return Data(bytes)
    }

    private func makeStudioVTX(checksum: Int32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 44)
        putStudioInt32(7, at: 0, into: &bytes)
        putStudioInt32(32, at: 4, into: &bytes)
        putStudioUInt16(3, at: 8, into: &bytes)
        putStudioUInt16(3, at: 10, into: &bytes)
        putStudioInt32(3, at: 12, into: &bytes)
        putStudioInt32(checksum, at: 16, into: &bytes)
        putStudioInt32(1, at: 20, into: &bytes)
        putStudioInt32(36, at: 24, into: &bytes)
        return Data(bytes)
    }

    private func putStudioCString(
        _ value: String,
        at offset: Int,
        capacity: Int,
        into bytes: inout [UInt8]
    ) {
        let encoded = Array(value.utf8.prefix(capacity - 1))
        bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
        bytes[offset + encoded.count] = 0
    }

    private func putStudioUInt16(
        _ value: UInt16,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func putStudioInt32(
        _ value: Int32,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        putStudioUInt32(UInt32(bitPattern: value), at: offset, into: &bytes)
    }

    private func putStudioUInt32(
        _ value: UInt32,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func makeRuntime() -> GMLuaRuntime {
        GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
    }
}

private struct BodyGroupStudioAssetReader: SourceStudioBoundedAssetReading {
    let files: [String: Data]

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        guard let data = files[path.lowercased()] else { return .missing }
        guard data.count <= maximumBytes else {
            return .exceeded(actual: data.count)
        }
        return .data(data)
    }
}

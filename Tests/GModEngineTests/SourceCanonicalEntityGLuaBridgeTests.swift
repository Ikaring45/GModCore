import XCTest
@testable import GModEngine
import GModLua

final class SourceCanonicalEntityGLuaBridgeTests: XCTestCase {
    func testPlayerQueriesAndPropMutationsUseCanonicalSnapshots() throws {
        let runtime = makeRuntime()
        let acceptedModel = SourceEntityModelReference(
            "models/props_c17/oildrum001.mdl"
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 4,
            canonicalModelValidator: { model, kind in
                model == acceptedModel && kind == .propPhysics ? .valid : .invalid
            }
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
            assert(util.IsValidModel("models/props_c17/not_present.mdl") == false)
            assert(util.IsValidModel("../outside.mdl") == false)
            assert(ents.Create("unsupported_class") == NULL)

            local prop = ents.Create("prop_physics")
            assert(prop:GetClass() == "prop_physics")
            prop:SetModel("models/props_c17/oildrum001.mdl")
            prop:SetSkin(3)
            assert(prop:GetSkin() == 3)
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

    func testUnavailableModelValidationReturnsFalseAndSpawnRollsBackExactHandle() throws {
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
            assert(util.IsValidModel("models/props_c17/oildrum001.mdl") == false)
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

    private func makeRuntime() -> GMLuaRuntime {
        GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
    }
}

import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModGameAssets
import GModLua

final class GModAttestedPropRuntimeBridgeIntegrationTests: XCTestCase {
    private let model = SourceEntityModelReference(
        "models/props/attested_runtime.mdl"
    )
    private let mdlData = Data("exact runtime mdl".utf8)
    private let phyData = Data("exact runtime phy".utf8)
    private let studioChecksum: Int32 = 76_543

    func testExactBytesDriveIsValidPropAtomicSpawnAndPendingPhysObj()
        throws
    {
        let asset = try makeExactAsset()
        let resolver = try makeResolver(asset: asset) { [self] model in
            .loaded(GModObservedPropPhysicsAsset(
                normalizedModelPath: model.path,
                mdlData: mdlData,
                phyData: phyData,
                studioChecksum: studioChecksum
            ))
        }
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let adapter = try makeAdapter(server: server, resolver: resolver)
        defer { close(adapter: adapter, runtimes: [server]) }
        try adapter.installCanonicalEntityLuaBridge()
        try adapter.installCanonicalPhysicsObjectLuaBridge()

        let values = try server.executeReturningValues(
            """
            assert(util.IsValidModel("models/props/attested_runtime.mdl"))
            assert(util.IsValidProp("models/props/attested_runtime.mdl"))
            assert(util.IsValidProp("models/props/not_attested.mdl") == false)

            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/attested_runtime.mdl")
            prop:SetPos(Vector(10, 20, 30))
            prop:Spawn()

            local phys = prop:GetPhysicsObject()
            assert(IsValid(phys))
            assert(phys == prop:GetPhysicsObject())
            assert(phys:GetMass() == 19)
            local inertia = phys:GetInertia()
            assert(inertia.x == 2 and inertia.y == 3 and inertia.z == 4)
            local mins, maxs = phys:GetAABB()
            assert(mins.x == -4 and mins.y == -6 and mins.z == -8)
            assert(maxs.x == 12 and maxs.y == 10 and maxs.z == 14)
            assert(phys:IsGravityEnabled() and phys:IsCollisionEnabled())
            assert(phys:IsAsleep() == false)
            return prop
            """,
            sourceName: "=(exact attested prop runtime)"
        )
        let propValue = try XCTUnwrap(values.first)
        let snapshot = try XCTUnwrap(
            server.entityRegistry?.canonicalSnapshot(for: propValue)
        )
        XCTAssertEqual(snapshot.lifecycle, .spawned)
        XCTAssertEqual(snapshot.collisionProperty, asset.collisionProperty)
        XCTAssertEqual(snapshot.solidType, .vPhysics)
        XCTAssertEqual(snapshot.moveType, .vPhysics)
        XCTAssertNotNil(
            adapter.primaryCanonicalPhysicsObject(for: snapshot.identity)
        )
    }

    func testMismatchAndUnavailableLeaveCreatedStateAndJournalExact()
        throws
    {
        let asset = try makeExactAsset()
        let unavailableReason = SourceStudioModelAssetUnavailable.readFailed(
            kind: .phy,
            path: "models/props/attested_runtime.phy",
            reason: "bounded content source unavailable"
        )
        let outcomes: [GModObservedPropPhysicsAssetOutcome] = [
            .loaded(GModObservedPropPhysicsAsset(
                normalizedModelPath: model.path,
                mdlData: Data("drifted mdl".utf8),
                phyData: phyData,
                studioChecksum: studioChecksum
            )),
            .unavailable(unavailableReason),
        ]

        for (offset, outcome) in outcomes.enumerated() {
            let resolver = try makeResolver(asset: asset) { _ in outcome }
            let transport = GMLuaNetTransport()
            let server = makeRuntime(.server, transport: transport)
            let adapter = try makeAdapter(
                server: server,
                resolver: resolver,
                initialSerialNumber: 30 + offset
            )
            defer { close(adapter: adapter, runtimes: [server]) }
            try adapter.installCanonicalEntityLuaBridge()
            try adapter.installCanonicalPhysicsObjectLuaBridge()

            let validationScript: String
            if offset == 0 {
                validationScript =
                    "assert(util.IsValidProp(" +
                    "\"models/props/attested_runtime.mdl\") == false)"
            } else {
                validationScript = """
                local ok, message = pcall(
                    util.IsValidProp,
                    "models/props/attested_runtime.mdl"
                )
                assert(ok == false)
                assert(string.find(message, "IsValidProp validation is unavailable", 1, true))
                """
            }
            let values = try server.executeReturningValues(
                """
                assert(util.IsValidModel("models/props/attested_runtime.mdl"))
                \(validationScript)
                local prop = assert(ents.Create("prop_physics"))
                prop:SetModel("models/props/attested_runtime.mdl")
                return prop
                """,
                sourceName: "=(rejected attested prop setup)"
            )
            let propValue = try XCTUnwrap(values.first)
            let before = try XCTUnwrap(
                server.entityRegistry?.canonicalSnapshot(for: propValue)
            )
            let pendingBefore = adapter.pendingCanonicalEntityOperationCount

            XCTAssertThrowsError(
                try adapter.spawnCanonicalEntity(before.identity)
            )
            XCTAssertEqual(
                adapter.canonicalSnapshot(for: before.identity),
                before
            )
            XCTAssertEqual(
                adapter.pendingCanonicalEntityOperationCount,
                pendingBefore
            )
            XCTAssertNil(
                adapter.primaryCanonicalPhysicsObject(for: before.identity)
            )
        }
    }

    func testForwardedRollbackInvalidatesOldPhysObjAndOneRetrySucceeds()
        throws
    {
        let asset = try makeExactAsset()
        let resolver = try makeResolver(asset: asset) { [self] model in
            .loaded(GModObservedPropPhysicsAsset(
                normalizedModelPath: model.path,
                mdlData: mdlData,
                phyData: phyData,
                studioChecksum: studioChecksum
            ))
        }
        let session = GMLuaSharedSession()
        let server = makeRuntime(.server, transport: session.netTransport)
        let client = makeRuntime(.client, transport: session.netTransport)
        let adapter = try makeAdapter(server: server, resolver: resolver)
        defer { close(adapter: adapter, runtimes: [client, server]) }
        try adapter.installCanonicalEntityLuaBridge()
        try adapter.installCanonicalPhysicsObjectLuaBridge()

        let world = try adapter.createCanonicalEntity(kind: .world, at: 0)
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 101
        )
        try session.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 101,
            authoritativeSnapshots: [world, player]
        )
        XCTAssertEqual(try adapter.discardPendingCanonicalEntityOperations(), 2)
        XCTAssertEqual(try session.pump(), 1)

        try server.execute(
            """
            ATTEMPT = 0
            SHOULD_FAIL = true
            concommand = {}
            function concommand.Run(sender, command, arguments, argumentString)
                assert(sender == Player(101))
                assert(command == "attested_retry")
                ATTEMPT = ATTEMPT + 1
                local prop = assert(ents.Create("prop_physics"))
                prop:SetModel("models/props/attested_runtime.mdl")
                prop:Spawn()
                prop:Activate()
                local phys = prop:GetPhysicsObject()
                assert(IsValid(phys))
                if SHOULD_FAIL then
                    ROLLED_BACK_PHYS = phys
                    error("intentional attested rollback")
                end
                RETRY_PHYS = phys
                RETRY_PROP = prop
            end
            AddConsoleCommand("attested_retry")
            """,
            sourceName: "=(attested retry command)"
        )

        try client.execute("RunConsoleCommand('attested_retry')")
        let failure = try session
            .pumpReportingForwardedConsoleFailures(maxDeliveries: 1)
        XCTAssertEqual(failure.forwardedConsoleFailures.count, 1)
        XCTAssertEqual(
            adapter.canonicalEntitySnapshots.filter { $0.kind == .propPhysics },
            []
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)
        try server.execute(
            "assert(IsValid(ROLLED_BACK_PHYS) == false)"
        )

        try server.execute("SHOULD_FAIL = false")
        try client.execute("RunConsoleCommand('attested_retry')")
        let retry = try session
            .pumpReportingForwardedConsoleFailures(maxDeliveries: 1)
        XCTAssertEqual(retry.forwardedConsoleFailures, [])
        try server.execute(
            """
            assert(ATTEMPT == 2)
            assert(IsValid(ROLLED_BACK_PHYS) == false)
            assert(IsValid(RETRY_PHYS))
            assert(RETRY_PHYS ~= ROLLED_BACK_PHYS)
            assert(RETRY_PROP:GetPhysicsObject() == RETRY_PHYS)
            """
        )
        XCTAssertEqual(
            adapter.canonicalEntitySnapshots.filter { $0.kind == .propPhysics }
                .count,
            1
        )
    }
}

private extension GModAttestedPropRuntimeBridgeIntegrationTests {
    func makeExactAsset() throws -> SourceAttestedPropPhysicsAsset {
        try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            massKilograms: 19,
            mdlSHA256: digest(mdlData),
            phySHA256: digest(phyData),
            studioChecksum: studioChecksum
        )
    }

    func makeResolver(
        asset: SourceAttestedPropPhysicsAsset,
        outcome: @escaping @Sendable (
            SourceEntityModelReference
        ) -> GModObservedPropPhysicsAssetOutcome
    ) throws -> GModAttestedPropPhysicsAssetResolver {
        try GModAttestedPropPhysicsAssetResolver(
            attestedAssets: [asset],
            loadObservedAsset: outcome
        )
    }

    func makeAdapter(
        server: GMLuaRuntime,
        resolver: GModAttestedPropPhysicsAssetResolver,
        initialSerialNumber: Int = 20
    ) throws -> GMLuaSourceRuntimeAdapter {
        try XCTUnwrap(server.typeSystem).installFallbackUtilities()
        return try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: initialSerialNumber,
            canonicalModelValidator: { [model] candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolver: { candidate in
                resolver.resolve(candidate).canonicalResolution
            }
        )
    }

    func makeRuntime(
        _ realm: GMLuaRealm,
        transport: GMLuaNetTransport
    ) -> GMLuaRuntime {
        GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            netTransport: transport
        )
    }

    func close(
        adapter: GMLuaSourceRuntimeAdapter,
        runtimes: [GMLuaRuntime]
    ) {
        try? adapter.close()
        for runtime in runtimes {
            _ = runtime.close()
        }
    }

    func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }
}

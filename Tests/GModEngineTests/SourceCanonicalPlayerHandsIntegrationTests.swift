import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class SourceCanonicalPlayerHandsIntegrationTests: XCTestCase {
    func testOriginalSetupHandsReplacesFullHandleThroughReplicationFIFO()
        throws
    {
        let configuration = GModPlayableSessionConfiguration(
            map: .construct,
            playerEntityIndex: 7,
            playerUserID: 70
        )
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
        // A test-owned decoded Studio layout. Production resolves the same
        // descriptors from mounted MDL/VVD/VTX or exact owned attestation.
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
        let session = try GModPlayableSession(
            configuration: configuration,
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalBodyGroupLayoutResolverForTesting: { model in
                if model == playerModel { return playerLayout }
                if model == handsModel { return handsLayout }
                return nil
            }
        )
        defer { _ = try? session.close() }
        let serverRegistry = try XCTUnwrap(session.serverRuntime.entityRegistry)
        let clientRegistry = try XCTUnwrap(session.clientRuntime.entityRegistry)

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
            sourceName: "=(original PlayerSpawn hands route)"
        )
        guard case .boolean(true)? = spawn.first else {
            return XCTFail(
                "original PlayerSpawn failed: " +
                    (spawn.dropFirst().first.map(String.init(describing:)) ??
                        "missing result")
            )
        }
        let firstPlayer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let firstHandsIdentity = try XCTUnwrap(firstPlayer.playerHands)
        let firstHands = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: firstHandsIdentity.entryIndex)
        )
        XCTAssertEqual(firstHands.identity, firstHandsIdentity)
        XCTAssertEqual(firstHands.kind, .playerHands)
        XCTAssertEqual(firstHands.className, "gmod_hands")
        XCTAssertEqual(firstHands.handsOwner, firstPlayer.identity)
        XCTAssertEqual(firstHands.handsViewModelIndex, 0)
        XCTAssertEqual(firstHands.model, handsModel)
        XCTAssertEqual(firstHands.skin, 0)
        XCTAssertEqual(firstHands.bodyValue, 0)
        XCTAssertEqual(firstHands.lifecycle, .spawned)

        _ = try session.runFixedTick()
        let replicatedFirstPlayer = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(replicatedFirstPlayer.playerHands, firstHandsIdentity)

        try session.serverRuntime.execute(
            "Player(70):SetupHands()",
            sourceName: "=(original SetupHands replacement)"
        )
        let secondPlayer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let secondHandsIdentity = try XCTUnwrap(secondPlayer.playerHands)
        XCTAssertNotEqual(secondHandsIdentity, firstHandsIdentity)
        XCTAssertEqual(
            serverRegistry.canonicalSnapshot(
                at: firstHandsIdentity.entryIndex
            )?.lifecycle,
            .pendingRemoval
        )
        let secondHands = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: secondHandsIdentity.entryIndex)
        )
        XCTAssertEqual(secondHands.identity, secondHandsIdentity)
        XCTAssertEqual(secondHands.handsOwner, secondPlayer.identity)
        XCTAssertEqual(secondHands.model, handsModel)
        XCTAssertEqual(secondHands.lifecycle, .spawned)
        XCTAssertEqual(
            clientRegistry.canonicalSnapshot(
                at: configuration.playerEntityIndex
            )?.playerHands,
            firstHandsIdentity,
            "CLIENT must not observe replacement before the fixed FIFO drain"
        )

        _ = try session.runFixedTick()
        let replicatedSecondPlayer = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(replicatedSecondPlayer.playerHands, secondHandsIdentity)
        XCTAssertNil(
            clientRegistry.canonicalSnapshot(at: firstHandsIdentity.entryIndex)
        )
        XCTAssertEqual(
            clientRegistry.canonicalSnapshot(
                at: secondHandsIdentity.entryIndex
            )?.identity,
            secondHandsIdentity
        )
        try session.clientRuntime.execute(
            """
            local ply = Player(70)
            local hands = ply:GetHands()
            assert(IsValid(hands))
            assert(hands:GetClass() == "gmod_hands")
            assert(hands:GetOwner() == ply)
            assert(hands:GetModel() == "models/weapons/c_arms_citizen.mdl")
            assert(hands:GetSkin() == 0)
            assert(IsValid(hands:GetParent()))
            assert(ply.SetHands == nil)
            """,
            sourceName: "=(replicated canonical hands ABI)"
        )
    }
}

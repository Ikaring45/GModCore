import Foundation
import GModEngine
@testable import GModGameSession
import XCTest

final class GModFirstPersonHandsSceneTests: XCTestCase {
    func testProjectsCanonicalHandsWithoutAnActiveWeapon() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity,
            skin: 2,
            bodyValue: 5,
            revision: 9
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity,
            revision: 3
        )

        XCTAssertTrue(try projector.update(
            clientEntities: [player, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 11)
        ))

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertEqual(scene.status, .available)
        XCTAssertEqual(scene.sourceProjectionCursor, cursor(sequence: 11))
        let projection = try XCTUnwrap(scene.projection)
        XCTAssertEqual(projection.playerIdentity, player.identity)
        XCTAssertEqual(projection.handsIdentity, hands.identity)
        XCTAssertEqual(projection.sourcePlayerRevision, 3)
        XCTAssertEqual(projection.sourceHandsRevision, 9)
        XCTAssertEqual(projection.viewModelSlot, 0)
        XCTAssertEqual(
            projection.model,
            SourceEntityModelReference(
                "models/weapons/c_arms_citizen.mdl"
            )
        )
        XCTAssertEqual(projection.skinFamilyIndex, 2)
        XCTAssertEqual(projection.bodyValue, 5)
        XCTAssertEqual(
            projection.resource.id.normalizedModelPath,
            "models/weapons/c_arms_citizen.mdl"
        )
        XCTAssertEqual(resolver.requests, [
            HandsStudioResolverProbe.Request(
                model: "models/weapons/c_arms_citizen.mdl",
                bodyValue: 5,
                skinFamilyIndex: 2
            ),
        ])
        XCTAssertTrue(player.weaponInventory.weapons.isEmpty)
        XCTAssertNil(player.weaponInventory.activeWeapon)
    }

    func testHandsGenerationMismatchDoesNotReuseAnEntryIndex() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let expected = identity(index: 18, serial: 5)
        let recycled = handsSnapshot(
            index: 18,
            serial: 6,
            owner: playerIdentity
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: expected
        )

        XCTAssertTrue(try projector.update(
            clientEntities: [player, recycled],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        ))

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableHandsGenerationMismatch(
                expected: expected,
                received: recycled.identity
            )
        )
        XCTAssertTrue(resolver.requests.isEmpty)
    }

    func testOwnerGenerationMismatchIsUnavailable() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let staleOwner = identity(index: 1, serial: 6)
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: staleOwner
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity
        )

        _ = try projector.update(
            clientEntities: [player, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableOwnerGenerationMismatch(
                expected: playerIdentity,
                received: staleOwner
            )
        )
        XCTAssertTrue(resolver.requests.isEmpty)
    }

    func testDifferentHandsOwnerIsUnavailable() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let otherPlayerIdentity = identity(index: 2, serial: 1)
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: otherPlayerIdentity
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity
        )

        _ = try projector.update(
            clientEntities: [player, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableOwnerMismatch(
                expected: playerIdentity,
                received: otherPlayerIdentity
            )
        )
        XCTAssertTrue(resolver.requests.isEmpty)
    }

    func testNonStockViewModelSlotIsUnavailable() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity,
            viewModelSlot: 1
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity
        )

        _ = try projector.update(
            clientEntities: [player, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableViewModelSlot(
                hands: hands.identity,
                received: 1
            )
        )
        XCTAssertTrue(resolver.requests.isEmpty)
    }

    func testStudioFailureNeverCreatesAPlaceholderProjection() throws {
        let failure = GModStudioRenderableModelResolutionFailure.cache(
            .invalidModelPath("models/weapons/c_arms_missing.mdl")
        )
        let resolver = HandsStudioResolverProbe(failure: failure)
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let missingModel = SourceEntityModelReference(
            "models/weapons/c_arms_missing.mdl"
        )
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity,
            model: missingModel
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity
        )

        _ = try projector.update(
            clientEntities: [player, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableStudio(model: missingModel, failure: failure)
        )
    }

    func testHandsRemovalClearsSceneWithoutDependingOnWeaponViewModel() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity
        )
        let attached = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity
        )
        _ = try projector.update(
            clientEntities: [attached, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )
        let first = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))

        let detached = playerSnapshot(
            identity: playerIdentity,
            hands: nil,
            revision: 2
        )
        XCTAssertTrue(try projector.update(
            clientEntities: [detached],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 2)
        ))

        let cleared = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: first.revision
        ))
        XCTAssertNil(cleared.projection)
        XCTAssertEqual(
            cleared.status,
            .unavailableNoHands(playerIdentity)
        )
        XCTAssertEqual(cleared.sourceProjectionCursor, cursor(sequence: 2))
        XCTAssertEqual(resolver.requests.count, 1)
        XCTAssertTrue(detached.weaponInventory.weapons.isEmpty)
        XCTAssertNil(detached.weaponInventory.activeWeapon)
    }

    func testPendingRemovalLifecycleClearsAnAvailableHandsProjection() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let playerIdentity = identity(index: 1, serial: 7)
        let hands = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity
        )
        let player = playerSnapshot(
            identity: playerIdentity,
            hands: hands.identity
        )
        _ = try projector.update(
            clientEntities: [player, hands],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )
        let first = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        let removing = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity,
            lifecycle: .pendingRemoval,
            revision: 2
        )

        XCTAssertTrue(try projector.update(
            clientEntities: [player, removing],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 2)
        ))

        let cleared = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: first.revision
        ))
        XCTAssertNil(cleared.projection)
        XCTAssertEqual(
            cleared.status,
            .unavailableHandsLifecycle(hands.identity)
        )
        XCTAssertEqual(resolver.requests.count, 1)
    }

    func testInvalidSkinAndBodyNeverReachStudioResolver() throws {
        let playerIdentity = identity(index: 1, serial: 7)

        let skinResolver = HandsStudioResolverProbe()
        let skinProjector = GModFirstPersonHandsSceneProjector(
            resolver: skinResolver
        )
        let invalidSkin = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity,
            skin: -1
        )
        _ = try skinProjector.update(
            clientEntities: [
                playerSnapshot(
                    identity: playerIdentity,
                    hands: invalidSkin.identity
                ),
                invalidSkin,
            ],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )
        XCTAssertEqual(
            skinProjector.snapshot(ifChangedFrom: nil)?.status,
            .unavailableInvalidSkin(
                hands: invalidSkin.identity,
                received: -1
            )
        )
        XCTAssertTrue(skinResolver.requests.isEmpty)

        let bodyResolver = HandsStudioResolverProbe()
        let bodyProjector = GModFirstPersonHandsSceneProjector(
            resolver: bodyResolver
        )
        let invalidBody = handsSnapshot(
            index: 18,
            serial: 4,
            owner: playerIdentity,
            bodyValue: -1
        )
        _ = try bodyProjector.update(
            clientEntities: [
                playerSnapshot(
                    identity: playerIdentity,
                    hands: invalidBody.identity
                ),
                invalidBody,
            ],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1)
        )
        XCTAssertEqual(
            bodyProjector.snapshot(ifChangedFrom: nil)?.status,
            .unavailableInvalidBodyValue(
                hands: invalidBody.identity,
                received: -1
            )
        )
        XCTAssertTrue(bodyResolver.requests.isEmpty)
    }

    func testRejectsOutOfOrderReplicationCursor() throws {
        let resolver = HandsStudioResolverProbe()
        let projector = GModFirstPersonHandsSceneProjector(
            resolver: resolver
        )
        let player = playerSnapshot(
            identity: identity(index: 1, serial: 7),
            hands: nil
        )
        _ = try projector.update(
            clientEntities: [player],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 4)
        )

        XCTAssertThrowsError(try projector.update(
            clientEntities: [player],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 3)
        )) { error in
            XCTAssertEqual(
                error as? GModFirstPersonHandsSceneError,
                .sourceCursorNotIncreasing(
                    previous: self.cursor(sequence: 4),
                    received: self.cursor(sequence: 3)
                )
            )
        }
    }

    private func playerSnapshot(
        identity: SourceCanonicalEntityIdentity,
        hands: SourceCanonicalEntityIdentity?,
        revision: UInt64 = 1
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: identity,
            kind: .player,
            className: SourceCanonicalEntityKind.player.className,
            transform: .identity,
            motion: SourceEntityMotionState(),
            model: nil,
            solidType: .boundingBox,
            moveType: .walk,
            lifecycle: .active,
            isNetworkable: true,
            revision: revision,
            playerHands: hands
        )
    }

    private func handsSnapshot(
        index: Int,
        serial: Int,
        owner: SourceCanonicalEntityIdentity?,
        viewModelSlot: Int32? = 0,
        model: SourceEntityModelReference = SourceEntityModelReference(
            "models/weapons/c_arms_citizen.mdl"
        ),
        skin: Int = 0,
        bodyValue: Int = 0,
        lifecycle: SourceCanonicalEntityLifecycle = .spawned,
        revision: UInt64 = 1
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: identity(index: index, serial: serial),
            kind: .playerHands,
            className: SourceCanonicalEntityKind.playerHands.className,
            transform: .identity,
            motion: SourceEntityMotionState(),
            model: model,
            solidType: .none,
            moveType: .none,
            lifecycle: lifecycle,
            isNetworkable: true,
            revision: revision,
            skin: skin,
            bodyValue: bodyValue,
            handsOwner: owner,
            handsViewModelIndex: viewModelSlot
        )
    }

    private func cursor(sequence: UInt64) -> SourceEntityReplicationCursor {
        SourceEntityReplicationCursor(
            connectionGeneration: SourceEntityReplicationConnectionGeneration(
                rawValue: 1
            ),
            sequence: sequence
        )
    }

    private func identity(
        index: Int,
        serial: Int
    ) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: index,
            serialNumber: serial
        ))
    }
}

private final class HandsStudioResolverProbe:
    GModStudioRenderableModelResolving,
    @unchecked Sendable
{
    struct Request: Equatable {
        let model: String
        let bodyValue: Int
        let skinFamilyIndex: Int
    }

    private let lock = NSLock()
    private let failure: GModStudioRenderableModelResolutionFailure?
    private var requestsStorage: [Request] = []

    init(failure: GModStudioRenderableModelResolutionFailure? = nil) {
        self.failure = failure
    }

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
            model: model.path,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex
        ))
        lock.unlock()
        if let failure { return .failed(failure) }
        let normalized = model.path.lowercased()
        let checksum: Int32 = 0x3141_5926
        return .resolved(GModStudioRenderableModelResource(
            id: GModStudioRenderableModelResourceID(
                normalizedModelPath: normalized,
                checksum: checksum,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex
            ),
            model: GModStudioRenderableModelSnapshot(
                checksum: checksum,
                modelName: normalized,
                lodIndex: 0,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex,
                vertices: [
                    GModDynamicModelVertex(
                        position: SourceVector3(0, 0, 0),
                        normal: SourceVector3(0, 0, 1),
                        textureCoordinate: SourceStudioTextureCoordinate(
                            u: 0,
                            v: 0
                        )
                    ),
                ],
                indices: [],
                drawRanges: []
            )
        ))
    }
}

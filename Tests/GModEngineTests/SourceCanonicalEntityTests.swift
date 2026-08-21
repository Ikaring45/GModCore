import XCTest
@testable import GModEngine

private enum SourceCanonicalEntityTestFailure: Error {
    case intentional
}

final class SourceCanonicalEntityTests: XCTestCase {
    func testWorldPlayerAndPropShareOneCanonicalTypeListAndEHANDLEContract() throws {
        let list = SourceEntityList(initialSerialNumber: 41)
        let store = SourceCanonicalEntityStore(
            entityList: list,
            modelValidator: { _, _ in .valid }
        )

        let world = try store.create(kind: .world)
        let player = try store.create(kind: .player, at: 1)
        let prop = try store.create(
            kind: .propPhysics,
            at: 2,
            state: SourceCanonicalEntityState(
                model: SourceEntityModelReference("models/props_c17/oildrum001.mdl"),
                solidType: .vPhysics,
                moveType: .vPhysics
            )
        )

        XCTAssertEqual(world.identity.entryIndex, 0)
        XCTAssertEqual(player.identity.entryIndex, 1)
        XCTAssertEqual(prop.identity.entryIndex, 2)
        XCTAssertEqual(world.identity.serialNumber, 41)
        XCTAssertEqual(player.identity.serialNumber, 41)
        XCTAssertEqual(prop.identity.serialNumber, 41)
        XCTAssertTrue(list.entity(for: world.identity.handle) is SourceCanonicalEntity)
        XCTAssertTrue(list.entity(for: player.identity.handle) is SourceCanonicalEntity)
        XCTAssertTrue(list.entity(for: prop.identity.handle) is SourceCanonicalEntity)
        XCTAssertTrue(store.entity(for: world.identity)?.kind == .world)
        XCTAssertTrue(store.entity(for: player.identity)?.kind == .player)
        XCTAssertTrue(store.entity(for: prop.identity)?.kind == .propPhysics)
        XCTAssertEqual(store.orderedSnapshots.map(\.identity), [world.identity, player.identity, prop.identity])
    }

    func testPropSpawnAndActivateRequireRealInjectedModelValidation() throws {
        let model = SourceEntityModelReference("models/props_c17/oildrum001.mdl")
        let state = SourceCanonicalEntityState(
            model: model,
            solidType: .vPhysics,
            moveType: .vPhysics
        )

        let unavailable = SourceCanonicalEntityStore(
            entityList: SourceEntityList(initialSerialNumber: 0)
        )
        let unavailableProp = try unavailable.create(kind: .propPhysics, at: 10, state: state)
        XCTAssertThrowsError(try unavailable.spawn(unavailableProp.identity)) { error in
            XCTAssertEqual(
                error as? SourceCanonicalEntityError,
                .modelValidationUnavailable(model)
            )
        }
        XCTAssertEqual(unavailable.snapshot(for: unavailableProp.identity)?.lifecycle, .created)
        XCTAssertEqual(unavailable.snapshot(for: unavailableProp.identity)?.revision, 0)

        let rejected = SourceCanonicalEntityStore(
            entityList: SourceEntityList(initialSerialNumber: 0),
            modelValidator: { _, _ in .invalid }
        )
        let rejectedProp = try rejected.create(kind: .propPhysics, at: 11, state: state)
        XCTAssertThrowsError(try rejected.spawn(rejectedProp.identity)) { error in
            XCTAssertEqual(error as? SourceCanonicalEntityError, .modelRejected(model))
        }
        XCTAssertEqual(rejected.snapshot(for: rejectedProp.identity)?.lifecycle, .created)

        var validated: [(SourceEntityModelReference, SourceCanonicalEntityKind)] = []
        let accepted = SourceCanonicalEntityStore(
            entityList: SourceEntityList(initialSerialNumber: 0),
            modelValidator: { model, kind in
                validated.append((model, kind))
                return .valid
            }
        )
        let acceptedProp = try accepted.create(kind: .propPhysics, at: 12, state: state)
        let spawned = try accepted.spawn(acceptedProp.identity)
        let active = try accepted.activate(acceptedProp.identity)

        XCTAssertEqual(validated.map(\.0), [model])
        XCTAssertEqual(validated.map(\.1), [.propPhysics])
        XCTAssertEqual(spawned.lifecycle, .spawned)
        XCTAssertEqual(spawned.revision, 1)
        XCTAssertEqual(active.lifecycle, .active)
        XCTAssertEqual(active.revision, 2)
    }

    func testCreateValidationFailsBeforeOccupyingAListSlot() throws {
        let list = SourceEntityList(initialSerialNumber: 5)
        let store = SourceCanonicalEntityStore(entityList: list)
        var invalidState = SourceCanonicalEntityState.defaults(for: .player)
        invalidState.transform.origin.x = .nan

        XCTAssertThrowsError(
            try store.create(kind: .player, at: 20, state: invalidState)
        ) { error in
            XCTAssertEqual(error as? SourceCanonicalEntityError, .invalidTransform)
        }
        XCTAssertNil(list.entity(at: 20))
        XCTAssertEqual(store.count, 0)

        var invalidModel = SourceCanonicalEntityState.defaults(for: .propPhysics)
        invalidModel.model = SourceEntityModelReference("../outside.mdl")
        XCTAssertThrowsError(
            try store.create(kind: .propPhysics, at: 20, state: invalidModel)
        ) { error in
            XCTAssertEqual(
                error as? SourceCanonicalEntityError,
                .invalidModelPath("../outside.mdl")
            )
        }
        XCTAssertNil(list.entity(at: 20))
        XCTAssertEqual(store.count, 0)
    }

    func testUpdateIsCopyValidateCommitAndPreservesStateOnEveryFailure() throws {
        let store = SourceCanonicalEntityStore(
            entityList: SourceEntityList(initialSerialNumber: 0)
        )
        let player = try store.create(kind: .player, at: 30)

        XCTAssertThrowsError(
            try store.update(player.identity) { state in
                state.transform.origin = SourceVector3(1, 2, 3)
                throw SourceCanonicalEntityTestFailure.intentional
            }
        )
        XCTAssertEqual(store.snapshot(for: player.identity), player)

        XCTAssertThrowsError(
            try store.update(player.identity) { state in
                state.transform.angles.roll = .infinity
            }
        ) { error in
            XCTAssertEqual(error as? SourceCanonicalEntityError, .invalidTransform)
        }
        XCTAssertEqual(store.snapshot(for: player.identity), player)

        let updated = try store.update(player.identity) { state in
            state.transform.origin = SourceVector3(1, 2, 3)
            state.moveType = .noClip
        }
        XCTAssertEqual(updated.transform.origin, SourceVector3(1, 2, 3))
        XCTAssertEqual(updated.moveType, .noClip)
        XCTAssertEqual(updated.revision, 1)
    }

    func testRemovalIsDeferredAndCleanupReturnsExactRemovedGeneration() throws {
        let list = SourceEntityList(initialSerialNumber: 7)
        let store = SourceCanonicalEntityStore(
            entityList: list,
            modelValidator: { _, _ in .valid }
        )
        let model = SourceEntityModelReference("models/props_c17/oildrum001.mdl")
        let created = try store.create(
            kind: .propPhysics,
            at: 42,
            state: SourceCanonicalEntityState(
                model: model,
                solidType: .vPhysics,
                moveType: .vPhysics
            )
        )
        _ = try store.spawn(created.identity)
        _ = try store.activate(created.identity)

        let pending = try store.markForRemoval(created.identity)
        XCTAssertEqual(pending.lifecycle, .pendingRemoval)
        XCTAssertNotNil(store.snapshot(for: created.identity))
        XCTAssertTrue(list.entity(for: created.identity.handle) is SourceCanonicalEntity)

        let removed = store.cleanupDeferredRemovals()
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].identity, created.identity)
        XCTAssertEqual(removed[0].lifecycle, .removed)
        XCTAssertEqual(removed[0].revision, pending.revision + 1)
        XCTAssertNil(store.snapshot(for: created.identity))
        XCTAssertNil(list.entity(for: created.identity.handle))

        let replacement = try store.create(
            kind: .propPhysics,
            at: 42,
            state: SourceCanonicalEntityState(
                model: model,
                solidType: .vPhysics,
                moveType: .vPhysics
            )
        )
        XCTAssertEqual(replacement.identity.entryIndex, created.identity.entryIndex)
        XCTAssertEqual(replacement.identity.serialNumber, created.identity.serialNumber + 1)
        XCTAssertNil(store.snapshot(for: created.identity))
        XCTAssertNotNil(store.snapshot(for: replacement.identity))
    }

    func testOccupiedSlotFailureDoesNotRegisterASecondCanonicalRecord() throws {
        let list = SourceEntityList(initialSerialNumber: 3)
        _ = try list.addNetworkableEntity(SourceEntity(className: "preexisting"), at: 50)
        let store = SourceCanonicalEntityStore(entityList: list)

        XCTAssertThrowsError(try store.create(kind: .player, at: 50)) { error in
            XCTAssertEqual(
                error as? SourceCanonicalEntityError,
                .entityList(.occupiedEntryIndex(50))
            )
        }
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(list.entity(at: 50)?.className, "preexisting")
    }

    func testWorldUsesOnlySlotZeroAndInlineWorldModel() throws {
        let store = SourceCanonicalEntityStore(
            entityList: SourceEntityList(initialSerialNumber: 2)
        )
        XCTAssertThrowsError(try store.create(kind: .world, at: 1)) { error in
            XCTAssertEqual(
                error as? SourceCanonicalEntityError,
                .invalidWorldEntryIndex(1)
            )
        }

        let world = try store.create(kind: .world)
        XCTAssertEqual(world.identity.entryIndex, 0)
        XCTAssertEqual(world.model, SourceEntityModelReference("*0"))
        XCTAssertEqual(world.solidType, .bsp)
        XCTAssertEqual(world.moveType, .none)
        XCTAssertEqual(try store.spawn(world.identity).lifecycle, .spawned)
        XCTAssertEqual(try store.activate(world.identity).lifecycle, .active)
    }
}

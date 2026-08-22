import XCTest
@testable import GModEngine

final class SourceCanonicalPhysgunClientDisplayStateTests: XCTestCase {
    func testGameplayFIFOAndFullEHANDLEGuardClientHoldLifecycle() throws {
        let player = identity(entry: 1, serial: 11)
        let weapon = identity(entry: 2, serial: 5)
        let firstTarget = identity(entry: 65, serial: 7)
        let reusedTarget = identity(entry: 65, serial: 8)
        let first = SourceCanonicalPhysgunDisplayEvent(
            phase: .active,
            player: player,
            weapon: weapon,
            entity: firstTarget,
            bodyID: try SourcePhysicsBodyID(
                entityIdentity: firstTarget,
                solidIndex: 0
            ),
            localHitPosition: SourceVector3(1, 2, 3)
        )
        let reused = SourceCanonicalPhysgunDisplayEvent(
            phase: .active,
            player: player,
            weapon: weapon,
            entity: reusedTarget,
            bodyID: try SourcePhysicsBodyID(
                entityIdentity: reusedTarget,
                solidIndex: 0
            ),
            localHitPosition: SourceVector3(4, 5, 6)
        )
        let state = GMLuaGameplayEventClientState()

        state.capture(.init(
            transportSequence: 10,
            payload: .physgunDisplay(first)
        ))
        XCTAssertEqual(state.physgunDisplayState.activeHolds, [first])
        XCTAssertEqual(state.physgunDisplayState.lastTransportSequence, 10)

        let inactiveFirst = SourceCanonicalPhysgunDisplayEvent(
            phase: .inactive,
            player: first.player,
            weapon: first.weapon,
            entity: first.entity,
            bodyID: first.bodyID,
            localHitPosition: first.localHitPosition
        )
        state.capture(.init(
            transportSequence: 9,
            payload: .physgunDisplay(inactiveFirst)
        ))
        XCTAssertEqual(
            state.physgunDisplayState.activeHolds,
            [first],
            "an older FIFO sequence must not clear the current hold"
        )

        state.capture(.init(
            transportSequence: 11,
            payload: .physgunDisplay(reused)
        ))
        XCTAssertEqual(state.physgunDisplayState.activeHolds, [reused])

        state.capture(.init(
            transportSequence: 12,
            payload: .physgunDisplay(inactiveFirst)
        ))
        XCTAssertEqual(
            state.physgunDisplayState.activeHolds,
            [reused],
            "an inactive event for an old serial must not clear the reused slot"
        )

        let inactiveReused = SourceCanonicalPhysgunDisplayEvent(
            phase: .inactive,
            player: reused.player,
            weapon: reused.weapon,
            entity: reused.entity,
            bodyID: reused.bodyID,
            localHitPosition: reused.localHitPosition
        )
        state.capture(.init(
            transportSequence: 13,
            payload: .physgunDisplay(inactiveReused)
        ))
        XCTAssertTrue(state.physgunDisplayState.activeHolds.isEmpty)
        XCTAssertEqual(state.physgunDisplayState.lastTransportSequence, 13)
    }

    private func identity(
        entry: Int,
        serial: Int
    ) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: entry,
            serialNumber: serial
        ))
    }
}

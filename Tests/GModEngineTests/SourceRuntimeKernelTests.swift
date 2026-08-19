import XCTest
@testable import GModEngine

private final class KernelRecordingEntity: SourceEntity {
    let label: String
    let log: (String) -> Void
    var onSimulation: (() -> Void)?
    var onThink: (() -> Void)?

    init(
        label: String,
        simulates: Bool,
        nextThinkTick: Int32 = sourceTickNeverThink,
        log: @escaping (String) -> Void
    ) {
        self.label = label
        self.log = log
        super.init(
            className: "test_\(label)",
            isGamePhysicsSimulationEnabled: simulates,
            nextThinkTick: nextThinkTick
        )
    }

    override func physicsSimulate(globals: inout SourceGlobalVars) {
        if isGamePhysicsSimulationEnabled {
            log("simulate:\(label):\(globals.tickCount)")
            onSimulation?()
        } else {
            super.physicsSimulate(globals: &globals)
        }
    }

    override func think(globals: inout SourceGlobalVars) {
        log("think:\(label):\(globals.tickCount)")
        onThink?()
    }
}

final class SourceRuntimeKernelTests: XCTestCase {
    func testBaseHandlePackingAndInvalidEntryCompatibilityQuirk() {
        let handle = SourceBaseHandle(entryIndex: 0x1234, serialNumber: 0x4567)

        XCTAssertTrue(handle.isValid)
        XCTAssertEqual(handle.rawValue, 0x4567_1234)
        XCTAssertEqual(handle.entryIndex, 0x1234)
        XCTAssertEqual(handle.serialNumber, 0x4567)
        XCTAssertEqual(handle.intValue, Int32(bitPattern: 0x4567_1234))

        let invalid = SourceBaseHandle.invalid
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.rawValue, UInt32.max)
        XCTAssertEqual(invalid.intValue, -1)
        XCTAssertEqual(
            invalid.entryIndex,
            SourceEntityConstants.numEntEntries - 1,
            "invalid GetEntryIndex must preserve Source's final-slot compatibility hack"
        )
        XCTAssertEqual(invalid.serialNumber, 0xffff)
        XCTAssertEqual(
            SourceBaseHandle.unsafeFromIndex(handle.rawValue),
            handle
        )
    }

    func testSlotReuseAdvancesSerialAndRejectsStaleHandle() throws {
        let list = SourceEntityList(initialSerialNumber: 7)
        let first = SourceEntity(className: "first")
        let firstHandle = try list.addNetworkableEntity(first, at: 42)

        XCTAssertTrue(list.entity(for: firstHandle) === first)
        list.markForDeletion(firstHandle)
        XCTAssertTrue(
            list.entity(for: firstHandle) === first,
            "UTIL_Remove-style deletion remains deferred until cleanup"
        )
        XCTAssertEqual(list.cleanupDeleteList(), 1)
        XCTAssertNil(list.entity(for: firstHandle))
        XCTAssertFalse(first.refHandle.isValid)

        let second = SourceEntity(className: "second")
        let secondHandle = try list.addNetworkableEntity(second, at: 42)

        XCTAssertEqual(secondHandle.entryIndex, firstHandle.entryIndex)
        XCTAssertEqual(secondHandle.serialNumber, firstHandle.serialNumber + 1)
        XCTAssertNotEqual(secondHandle, firstHandle)
        XCTAssertNil(list.entity(for: firstHandle))
        XCTAssertTrue(list.entity(for: secondHandle) === second)
    }

    func testServerPhaseOrderAndDeleteCleanupBeforeAndAfterThink() throws {
        var calls: [String] = []
        let list = SourceEntityList()
        let deletedBeforeFrame = SourceEntity(className: "delete_before")
        let deletedBeforeHandle = try list.addNetworkableEntity(deletedBeforeFrame, at: 1)
        list.markForDeletion(deletedBeforeHandle)

        let deletesDuringSimulation = KernelRecordingEntity(
            label: "delete_during",
            simulates: true,
            log: { calls.append($0) }
        )
        let deleteDuringHandle = try list.addNetworkableEntity(deletesDuringSimulation, at: 2)
        deletesDuringSimulation.onSimulation = { [unowned list, unowned deletesDuringSimulation] in
            list.markForDeletion(deletesDuringSimulation)
        }

        let kernel = SourceRuntimeKernel(entityList: list)
        var phases: [SourceServerPhase] = []
        var addonHooks: [SourceAddonHookPhase] = []
        kernel.runServerTick(
            onAddonHook: { addonHooks.append($0) },
            onPhase: { phases.append($0) }
        )

        XCTAssertEqual(phases, SourceServerPhase.allCases)
        XCTAssertEqual(addonHooks, [.think, .tick])
        XCTAssertEqual(kernel.lastAddonHookTrace, [.think, .tick])
        XCTAssertEqual(kernel.lastPhaseTrace, SourceServerPhase.allCases)
        XCTAssertEqual(kernel.globals.tickCount, 1)
        XCTAssertEqual(kernel.globals.frameCount, 1)
        XCTAssertEqual(kernel.globals.currentTime, SourceGlobalVars.intervalPerTick)
        XCTAssertEqual(
            Double(kernel.globals.frameTime),
            0.014_999_999_664_723_873,
            "the fixed interval must retain Source/GMod's 0.015f representation"
        )
        XCTAssertEqual(calls, ["simulate:delete_during:1"])
        XCTAssertNil(list.entity(for: deletedBeforeHandle))
        XCTAssertNil(list.entity(for: deleteDuringHandle))
        XCTAssertEqual(list.pendingDeletionCount, 0)
    }

    func testSimulationUsesStableSnapshotAndScheduledThinkChoice() throws {
        var calls: [String] = []
        let list = SourceEntityList()
        let simulator = KernelRecordingEntity(
            label: "existing",
            simulates: true,
            log: { calls.append($0) }
        )
        let thinker = KernelRecordingEntity(
            label: "thinker",
            simulates: false,
            nextThinkTick: 1,
            log: { calls.append($0) }
        )
        let addedDuringSimulation = KernelRecordingEntity(
            label: "late",
            simulates: true,
            log: { calls.append($0) }
        )

        _ = try list.addNetworkableEntity(simulator, at: 1)
        _ = try list.addNetworkableEntity(thinker, at: 2)
        simulator.onSimulation = { [unowned list, unowned addedDuringSimulation] in
            if !addedDuringSimulation.refHandle.isValid {
                _ = try! list.addNetworkableEntity(addedDuringSimulation, at: 3)
            }
        }

        let kernel = SourceRuntimeKernel(entityList: list)
        kernel.runServerTick()
        XCTAssertEqual(calls, ["simulate:existing:1", "think:thinker:1"])
        XCTAssertEqual(thinker.nextThinkTick, sourceTickNeverThink)

        kernel.runServerTick()
        XCTAssertEqual(
            calls,
            [
                "simulate:existing:1",
                "think:thinker:1",
                "simulate:existing:2",
                "simulate:late:2",
            ]
        )
    }

    func testSimThinkUsesAddToTailAndFastRemoveOrder() throws {
        var calls: [String] = []
        let list = SourceEntityList()
        let first = KernelRecordingEntity(label: "first", simulates: true) {
            calls.append($0)
        }
        let second = KernelRecordingEntity(label: "second", simulates: true) {
            calls.append($0)
        }
        let third = KernelRecordingEntity(label: "third", simulates: true) {
            calls.append($0)
        }
        _ = try list.addNetworkableEntity(first, at: 10)
        _ = try list.addNetworkableEntity(second, at: 11)
        _ = try list.addNetworkableEntity(third, at: 12)

        // Removing the first entry moves the vector tail (third) into its slot.
        // Reactivating first then uses AddToTail: [third, second, first].
        first.isGamePhysicsSimulationEnabled = false
        first.isGamePhysicsSimulationEnabled = true

        SourceRuntimeKernel(entityList: list).runServerTick()
        XCTAssertEqual(
            calls,
            ["simulate:third:1", "simulate:second:1", "simulate:first:1"]
        )
    }

    func testPhysicsDispatchUsesEdictIdentityAndThinkTickZeroIsInactive() throws {
        var calls: [String] = []
        let list = SourceEntityList(initialSerialNumber: 0)
        let networkedThink = KernelRecordingEntity(
            label: "networked_think",
            simulates: false,
            nextThinkTick: 1,
            log: { calls.append($0) }
        )
        let nonNetworkedSimulationFlag = KernelRecordingEntity(
            label: "nonnetworked",
            simulates: true,
            log: { calls.append($0) }
        )
        let zeroTick = KernelRecordingEntity(
            label: "zero",
            simulates: false,
            nextThinkTick: 0,
            log: { calls.append($0) }
        )
        _ = try list.addNetworkableEntity(networkedThink, at: 20)
        _ = try list.addNonNetworkableEntity(nonNetworkedSimulationFlag)
        _ = try list.addNetworkableEntity(zeroTick, at: 21)

        XCTAssertTrue(networkedThink.isNetworkable)
        XCTAssertFalse(nonNetworkedSimulationFlag.isNetworkable)
        SourceRuntimeKernel(entityList: list).runServerTick()

        XCTAssertEqual(calls, ["think:networked_think:1"])
        XCTAssertEqual(zeroTick.nextThinkTick, 0)
    }

    func testContextThinksRunAfterBaseInAddToTailOrderAndSeeClearedTicks() throws {
        var calls: [String] = []
        let list = SourceEntityList(initialSerialNumber: 0)
        let entity = KernelRecordingEntity(
            label: "context_order",
            simulates: false,
            nextThinkTick: 1,
            log: { calls.append($0) }
        )
        entity.onThink = { [unowned entity] in
            XCTAssertEqual(entity.nextThinkTick, sourceTickNeverThink)
        }
        entity.setContextThink(
            { entity, globals in
                calls.append("context:first:\(globals.tickCount)")
                XCTAssertEqual(
                    entity.nextThinkTick(context: "first"),
                    sourceTickNeverThink
                )
                entity.setContextThink(
                    { _, globals in calls.append("context:appended:\(globals.tickCount)") },
                    nextThinkTick: globals.tickCount,
                    context: "appended"
                )
            },
            nextThinkTick: 1,
            context: "first"
        )
        entity.setContextThink(
            { _, globals in calls.append("context:second:\(globals.tickCount)") },
            nextThinkTick: 1,
            context: "second"
        )
        _ = try list.addNetworkableEntity(entity, at: 30)

        SourceRuntimeKernel(entityList: list).runServerTick()

        XCTAssertEqual(
            calls,
            [
                "think:context_order:1",
                "context:first:1",
                "context:second:1",
                "context:appended:1",
            ]
        )
        XCTAssertEqual(entity.lastThinkTick, 1)
        XCTAssertEqual(entity.lastThinkTick(context: "first"), 1)
        XCTAssertEqual(entity.lastThinkTick(context: "second"), 1)
        XCTAssertEqual(entity.lastThinkTick(context: "appended"), 1)
        XCTAssertEqual(entity.firstThinkTick, sourceTickNeverThink)
    }

    func testContextRegistrationPrefixThinkSetZeroAndServerInactiveSentinels() throws {
        var calls: [String] = []
        let prefix = String(repeating: "x", count: 32)
        let firstName = prefix + "_first"
        let aliasedName = prefix + "_aliased"
        let entity = SourceEntity(className: "context_quirks")

        let firstIndex = entity.setContextThink(
            { _, _ in calls.append("old") },
            nextThinkTick: 4,
            context: firstName
        )
        let aliasIndex = entity.setContextThink(
            { _, _ in calls.append("replacement") },
            nextThinkTick: 0,
            context: aliasedName
        )

        XCTAssertEqual(firstIndex, aliasIndex)
        XCTAssertEqual(entity.thinkContextCount, 1)
        XCTAssertEqual(entity.thinkContextName(at: firstIndex), firstName)
        XCTAssertEqual(
            entity.nextThinkTick(context: aliasedName),
            4,
            "ThinkSet with time/tick zero replaces the function but preserves the schedule"
        )

        entity.setNextThinkTick(0, context: firstName)
        entity.setContextThink(nil, context: "registered_zero")
        entity.setNextThinkTick(sourceClientThinkAlways, context: "client_always")

        XCTAssertFalse(entity.willThink)
        XCTAssertEqual(entity.firstThinkTick, sourceTickNeverThink)
        XCTAssertEqual(entity.nextThinkTick(context: "registered_zero"), 0)
        XCTAssertEqual(
            entity.nextThinkTick(context: "client_always"),
            sourceClientThinkAlways
        )

        let list = SourceEntityList(initialSerialNumber: 0)
        _ = try list.addNetworkableEntity(entity, at: 31)
        let kernel = SourceRuntimeKernel(entityList: list)
        for _ in 0..<5 { kernel.runServerTick() }
        XCTAssertTrue(calls.isEmpty)

        entity.setNextThinkTick(6, context: firstName)
        kernel.runServerTick()
        XCTAssertEqual(calls, ["replacement"])
        XCTAssertEqual(entity.nextThinkTick(context: firstName), sourceTickNeverThink)
        XCTAssertEqual(entity.lastThinkTick(context: firstName), 6)
    }

    func testContextOnlyScheduleUsesSimThinkFastRemoveAndReactivationOrder() throws {
        var calls: [String] = []
        let list = SourceEntityList(initialSerialNumber: 0)
        let contextOnly = SourceEntity(className: "context_only")
        contextOnly.setContextThink(
            { _, globals in calls.append("context:first:\(globals.tickCount)") },
            nextThinkTick: 1,
            context: "first"
        )
        let second = KernelRecordingEntity(label: "second", simulates: true) {
            calls.append($0)
        }
        let third = KernelRecordingEntity(label: "third", simulates: true) {
            calls.append($0)
        }

        _ = try list.addNetworkableEntity(contextOnly, at: 40)
        _ = try list.addNetworkableEntity(second, at: 41)
        _ = try list.addNetworkableEntity(third, at: 42)

        // Removing the context-only head FastRemoves the vector tail (third)
        // into its slot. Reactivation AddToTail-appends contextOnly.
        contextOnly.setNextThinkTick(sourceTickNeverThink, context: "first")
        contextOnly.setNextThinkTick(1, context: "first")

        SourceRuntimeKernel(entityList: list).runServerTick()
        XCTAssertEqual(
            calls,
            ["simulate:third:1", "simulate:second:1", "context:first:1"]
        )
    }

    func testBaseAndContextDeletionStopRemainingContextsButNotSnapshotPeers() throws {
        var calls: [String] = []
        let list = SourceEntityList(initialSerialNumber: 0)

        let baseDeletes = KernelRecordingEntity(
            label: "base_deletes",
            simulates: false,
            nextThinkTick: 1,
            log: { calls.append($0) }
        )
        baseDeletes.setContextThink(
            { _, _ in calls.append("base_deletes:context_should_not_run") },
            nextThinkTick: 1,
            context: "after_base"
        )
        let baseHandle = try list.addNetworkableEntity(baseDeletes, at: 50)
        baseDeletes.onThink = { [unowned list, unowned baseDeletes] in
            list.markForDeletion(baseDeletes)
        }

        let contextDeletes = SourceEntity(className: "context_deletes")
        contextDeletes.setContextThink(
            { entity, globals in
                calls.append("context_deletes:first:\(globals.tickCount)")
                list.markForDeletion(entity)
            },
            nextThinkTick: 1,
            context: "first"
        )
        contextDeletes.setContextThink(
            { _, _ in calls.append("context_deletes:second_should_not_run") },
            nextThinkTick: 1,
            context: "second"
        )
        let contextHandle = try list.addNetworkableEntity(contextDeletes, at: 51)

        SourceRuntimeKernel(entityList: list).runServerTick()

        XCTAssertEqual(
            calls,
            ["think:base_deletes:1", "context_deletes:first:1"]
        )
        XCTAssertEqual(baseDeletes.lastThinkTick, 1)
        XCTAssertEqual(baseDeletes.lastThinkTick(context: "after_base"), 0)
        XCTAssertEqual(contextDeletes.lastThinkTick(context: "first"), 1)
        XCTAssertEqual(contextDeletes.lastThinkTick(context: "second"), 0)
        XCTAssertNil(list.entity(for: baseHandle))
        XCTAssertNil(list.entity(for: contextHandle))
        XCTAssertEqual(list.pendingDeletionCount, 0)
    }

    func testPhysicsRunThinkBaseOnlyAndAllButBaseModes() {
        var calls: [String] = []
        let entity = KernelRecordingEntity(
            label: "modes",
            simulates: false,
            nextThinkTick: 1,
            log: { calls.append($0) }
        )
        entity.setContextThink(
            { _, globals in calls.append("context:modes:\(globals.tickCount)") },
            nextThinkTick: 1,
            context: "mode_context"
        )
        var globals = SourceGlobalVars(tickCount: 1)

        XCTAssertTrue(entity.physicsRunThink(globals: &globals, method: .baseOnly))
        XCTAssertEqual(calls, ["think:modes:1"])
        XCTAssertEqual(entity.nextThinkTick(context: "mode_context"), 1)

        XCTAssertTrue(entity.physicsRunThink(globals: &globals, method: .allButBase))
        XCTAssertEqual(calls, ["think:modes:1", "context:modes:1"])
        XCTAssertEqual(entity.firstThinkTick, sourceTickNeverThink)
    }
}

import Dispatch
import Foundation
import XCTest
@testable import GModEngine
import GModLua

private final class AdapterConcurrencyObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var runErrorStorage: String?
    private var runCompletedStorage = false
    private var closeCompletedStorage = false

    func finishRun(error: Error?) {
        lock.lock()
        runErrorStorage = error.map(GMLuaRuntime.describe)
        runCompletedStorage = true
        lock.unlock()
    }

    func finishClose() {
        lock.lock()
        closeCompletedStorage = true
        lock.unlock()
    }

    var snapshot: (runError: String?, runCompleted: Bool, closeCompleted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (runErrorStorage, runCompletedStorage, closeCompletedStorage)
    }
}

private final class AdapterRuntimeBox: @unchecked Sendable {
    let runtime: GMLuaRuntime

    init(_ runtime: GMLuaRuntime) {
        self.runtime = runtime
    }
}

private final class WeakAdapterReference {
    weak var value: GMLuaSourceRuntimeAdapter?

    init(_ value: GMLuaSourceRuntimeAdapter?) {
        self.value = value
    }
}

final class GMLuaSourceRuntimeAdapterTests: XCTestCase {
    func testInitializationRejectsAdvancedServerClockBeforeAnyKernelTick() throws {
        let server = makeRuntime(.server)
        defer { _ = server.close() }
        let scheduler = try XCTUnwrap(server.timerScheduler)
        try server.execute(
            """
            SOURCE_INIT_HOOK_CALLS = 0
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm)
                SOURCE_INIT_HOOK_CALLS = SOURCE_INIT_HOOK_CALLS + 1
            end
            """
        )
        XCTAssertTrue(try scheduler.advance(by: 0.25).isEmpty)

        XCTAssertThrowsError(try GMLuaSourceRuntimeAdapter(serverRuntime: server)) { error in
            guard case let GMLuaSourceRuntimeAdapterError.timerClockMismatch(
                realm,
                expected,
                actual
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(realm, .server)
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(actual, 0.25)
        }
        XCTAssertEqual(scheduler.currentTime, 0.25)
        XCTAssertFalse(server.isClosed)
        try server.execute("assert(SOURCE_INIT_HOOK_CALLS == 0)")
    }

    func testServerRunRejectsPostInitializationClockDriftBeforeKernelTick() throws {
        let server = makeRuntime(.server)
        defer { _ = server.close() }
        try server.execute(
            """
            SOURCE_DRIFT_HOOK_CALLS = 0
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm)
                SOURCE_DRIFT_HOOK_CALLS = SOURCE_DRIFT_HOOK_CALLS + 1
            end
            """
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let scheduler = try XCTUnwrap(server.timerScheduler)
        XCTAssertTrue(try scheduler.advance(by: 0.25).isEmpty)

        XCTAssertThrowsError(try adapter.runServerFixedTick()) { error in
            guard case let GMLuaSourceRuntimeAdapterError.timerClockMismatch(
                realm,
                expected,
                actual
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(realm, .server)
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(actual, 0.25)
        }
        XCTAssertEqual(adapter.serverGlobals.tickCount, 0)
        XCTAssertEqual(adapter.serverGlobals.currentTime, 0)
        XCTAssertEqual(scheduler.currentTime, 0.25)
        try server.execute("assert(SOURCE_DRIFT_HOOK_CALLS == 0)")
    }

    func testSpawnMirrorsHandleGenerationWorldValiditySidecarsAndStaleCleanup() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        try installNoopHooks(in: server)
        try installNoopHooks(in: client)
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)

        let worldIdentity = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "worldspawn"),
            at: 0
        )
        let firstIdentity = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "prop_physics"),
            at: 12
        )
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let world = serverRegistry.entity(at: 0)
        let first = serverRegistry.entity(at: 12)
        server.state.setGlobal("SOURCE_WORLD", value: world)
        server.state.setGlobal("SOURCE_FIRST", value: first)
        try server.execute(
            """
            assert(Entity(0) == SOURCE_WORLD and SOURCE_WORLD ~= NULL)
            assert(SOURCE_WORLD:EntIndex() == 0)
            assert(SOURCE_WORLD:GetClass() == "worldspawn")
            assert(not SOURCE_WORLD:IsValid())
            SOURCE_WORLD.serverSide = "only"
            SOURCE_FIRST.persisted = 71
            assert(SOURCE_FIRST:IsValid() and SOURCE_FIRST.persisted == 71)
            """
        )
        XCTAssertTrue(GMLuaTypeSystem.typedObject(from: world)?.isValid == true)
        XCTAssertEqual(serverRegistry.sourceMirrorIdentity(for: world), worldIdentity)
        XCTAssertEqual(serverRegistry.sourceMirrorIdentity(for: first), firstIdentity)

        try adapter.attach(client: client)
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        client.state.setGlobal("CLIENT_WORLD", value: clientRegistry.entity(at: 0))
        client.state.setGlobal("CLIENT_FIRST", value: clientRegistry.entity(at: 12))
        try client.execute(
            """
            assert(Entity(0) == CLIENT_WORLD and CLIENT_WORLD ~= NULL)
            assert(not CLIENT_WORLD:IsValid() and CLIENT_WORLD:GetClass() == "worldspawn")
            assert(CLIENT_WORLD.serverSide == nil)
            assert(CLIENT_FIRST:IsValid() and CLIENT_FIRST.persisted == nil)
            CLIENT_FIRST.clientSide = 9
            """
        )
        try server.execute("assert(SOURCE_FIRST.clientSide == nil)")

        XCTAssertTrue(try adapter.markForDeletion(firstIdentity))
        try server.execute(
            "assert(Entity(12) == SOURCE_FIRST and SOURCE_FIRST:IsValid() and SOURCE_FIRST.persisted == 71)"
        )
        let report = try adapter.runServerFixedTick()
        XCTAssertEqual(report.removedEntities, [firstIdentity])
        try server.execute(
            "assert(Entity(12) == NULL and SOURCE_FIRST == NULL and not SOURCE_FIRST:IsValid())"
        )
        try client.execute(
            "assert(Entity(12) == NULL and CLIENT_FIRST == NULL and not CLIENT_FIRST:IsValid())"
        )

        let replacementIdentity = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "prop_dynamic"),
            at: 12
        )
        XCTAssertNotEqual(replacementIdentity, firstIdentity)
        serverRegistry.unregisterSourceMirror(
            owner: adapter.mirrorOwner,
            identity: firstIdentity
        )
        XCTAssertEqual(
            serverRegistry.sourceMirrorIdentity(at: 12),
            replacementIdentity,
            "stale cleanup must not invalidate a reused Source slot"
        )
        XCTAssertTrue(adapter.contains(worldIdentity))
        XCTAssertTrue(adapter.contains(replacementIdentity))
    }

    func testTransactionalSpawnAndClientAttachPreserveLegacyRegistryOwners() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let legacyServer = try serverRegistry.register(
            index: 8,
            className: "legacy_server"
        )

        let failedEntity = SourceEntity(className: "source_collision")
        XCTAssertThrowsError(
            try adapter.spawnNetworkableEntity(failedEntity, at: 8)
        )
        XCTAssertFalse(failedEntity.refHandle.isValid)
        XCTAssertTrue(GMLuaTypeSystem.typedObject(from: legacyServer)?.isValid == true)
        XCTAssertTrue(GMLuaTypeSystem.typedObject(from: serverRegistry.entity(at: 8)) ===
            GMLuaTypeSystem.typedObject(from: legacyServer))

        serverRegistry.unregister(index: 8)
        let sourceIdentity = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "source_after_rollback"),
            at: 8
        )
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        let legacyClient = try clientRegistry.register(
            index: 8,
            className: "legacy_client"
        )
        XCTAssertThrowsError(try adapter.attach(client: client))
        XCTAssertEqual(adapter.attachedClientCount, 0)
        XCTAssertEqual(serverRegistry.sourceMirrorIdentity(at: 8), sourceIdentity)
        XCTAssertTrue(GMLuaTypeSystem.typedObject(from: legacyClient)?.isValid == true)
        XCTAssertTrue(GMLuaTypeSystem.typedObject(from: clientRegistry.entity(at: 8)) ===
            GMLuaTypeSystem.typedObject(from: legacyClient))
    }

    func testExplicitCloseInvalidatesAllMirrorsAndHandlesAndIsIdempotent() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let sourceEntity = SourceEntity(className: "prop_physics")
        let identity = try adapter.spawnNetworkableEntity(sourceEntity, at: 21)
        try adapter.attach(client: client)
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        server.state.setGlobal("SOURCE_CLOSE_SERVER_ENTITY", value: serverRegistry.entity(at: 21))
        client.state.setGlobal("SOURCE_CLOSE_CLIENT_ENTITY", value: clientRegistry.entity(at: 21))

        try adapter.close()

        XCTAssertTrue(adapter.isClosed)
        XCTAssertEqual(adapter.attachedClientCount, 0)
        XCTAssertFalse(adapter.contains(identity))
        XCTAssertFalse(sourceEntity.refHandle.isValid)
        XCTAssertNil(serverRegistry.sourceMirrorIdentity(at: 21))
        XCTAssertNil(clientRegistry.sourceMirrorIdentity(at: 21))
        try server.execute(
            "assert(Entity(21) == NULL and SOURCE_CLOSE_SERVER_ENTITY == NULL)"
        )
        try client.execute(
            "assert(Entity(21) == NULL and SOURCE_CLOSE_CLIENT_ENTITY == NULL)"
        )

        try adapter.close()
        XCTAssertTrue(adapter.isClosed)
        XCTAssertFalse(sourceEntity.refHandle.isValid)
        XCTAssertThrowsError(
            try adapter.spawnNetworkableEntity(
                SourceEntity(className: "closed_spawn"),
                at: 22
            )
        ) { XCTAssertEqual(String(describing: $0), "Source runtime adapter is closed") }
        XCTAssertThrowsError(try adapter.attach(client: client)) {
            XCTAssertEqual(String(describing: $0), "Source runtime adapter is closed")
        }
        XCTAssertThrowsError(try adapter.runServerFixedTick()) {
            XCTAssertEqual(String(describing: $0), "Source runtime adapter is closed")
        }
        XCTAssertThrowsError(try adapter.withEntityMutation(identity) { _ in }) {
            XCTAssertEqual(String(describing: $0), "Source runtime adapter is closed")
        }
    }

    func testAdapterDeinitPerformsBestEffortMirrorAndHandleTeardown() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        let sourceEntity = SourceEntity(className: "prop_dynamic")
        var adapter: GMLuaSourceRuntimeAdapter? = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server
        )
        let identity = try XCTUnwrap(adapter).spawnNetworkableEntity(sourceEntity, at: 24)
        try XCTUnwrap(adapter).attach(client: client)
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        XCTAssertEqual(serverRegistry.sourceMirrorIdentity(at: 24), identity)
        XCTAssertEqual(clientRegistry.sourceMirrorIdentity(at: 24), identity)
        let releasedAdapter = WeakAdapterReference(adapter)

        adapter = nil

        XCTAssertNil(releasedAdapter.value)
        XCTAssertFalse(sourceEntity.refHandle.isValid)
        XCTAssertNil(serverRegistry.sourceMirrorIdentity(at: 24))
        XCTAssertNil(clientRegistry.sourceMirrorIdentity(at: 24))
        try server.execute("assert(Entity(24) == NULL)")
        try client.execute("assert(Entity(24) == NULL)")
    }

    func testCloseAfterServerRuntimeCloseStillCleansClientMirrorAndSourceHandle() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer { _ = client.close() }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let sourceEntity = SourceEntity(className: "prop_physics")
        let identity = try adapter.spawnNetworkableEntity(sourceEntity, at: 26)
        try adapter.attach(client: client)
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        let closedServerMirror = serverRegistry.entity(at: 26)
        client.state.setGlobal("SOURCE_SERVER_CLOSED_ENTITY", value: clientRegistry.entity(at: 26))

        _ = server.close()
        XCTAssertTrue(server.isClosed)
        XCTAssertThrowsError(try adapter.runServerFixedTick()) { error in
            guard case GMLuaSourceRuntimeAdapterError.closedRuntime(.server) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try adapter.runClientFrame()) { error in
            guard case GMLuaSourceRuntimeAdapterError.closedRuntime(.server) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(adapter.serverGlobals.tickCount, 0)
        XCTAssertEqual(clientRegistry.sourceMirrorIdentity(at: 26), identity)

        try adapter.close()

        XCTAssertTrue(adapter.isClosed)
        XCTAssertFalse(sourceEntity.refHandle.isValid)
        XCTAssertNil(serverRegistry.sourceMirrorIdentity(at: 26))
        XCTAssertNil(clientRegistry.sourceMirrorIdentity(at: 26))
        XCTAssertFalse(GMLuaTypeSystem.typedObject(from: closedServerMirror)?.isValid == true)
        try client.execute(
            "assert(Entity(26) == NULL and SOURCE_SERVER_CLOSED_ENTITY == NULL)"
        )
    }

    func testCloseAfterClientRuntimeCloseStillCleansClosedClientRegistry() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer { _ = server.close() }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let sourceEntity = SourceEntity(className: "prop_dynamic")
        let identity = try adapter.spawnNetworkableEntity(sourceEntity, at: 27)
        try adapter.attach(client: client)
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        let closedClientMirror = clientRegistry.entity(at: 27)

        _ = client.close()
        XCTAssertTrue(client.isClosed)
        XCTAssertEqual(clientRegistry.sourceMirrorIdentity(at: 27), identity)

        try adapter.close()

        XCTAssertTrue(adapter.isClosed)
        XCTAssertFalse(sourceEntity.refHandle.isValid)
        XCTAssertNil(serverRegistry.sourceMirrorIdentity(at: 27))
        XCTAssertNil(clientRegistry.sourceMirrorIdentity(at: 27))
        XCTAssertFalse(GMLuaTypeSystem.typedObject(from: closedClientMirror)?.isValid == true)
    }

    func testIndependentAdaptersCannotShareOrCleanupAnotherAdaptersMirrorOwner() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        try installNoopHooks(in: server)
        try installNoopHooks(in: client)
        let firstAdapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 17
        )
        let secondAdapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 17
        )
        let firstIdentity = try firstAdapter.spawnNetworkableEntity(
            SourceEntity(className: "prop_physics"),
            at: 30
        )
        try firstAdapter.attach(client: client)

        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let clientRegistry = try XCTUnwrap(client.entityRegistry)
        let firstClientMirror = clientRegistry.entity(at: 30)
        client.state.setGlobal("FIRST_ADAPTER_MIRROR", value: firstClientMirror)
        try client.execute("FIRST_ADAPTER_MIRROR.ownerSidecar = 41")

        // Free only the first adapter's SERVER mirror so the independent
        // kernel can allocate the same packed Source handle. The CLIENT mirror
        // deliberately remains owned by the first adapter.
        serverRegistry.unregisterSourceMirror(
            owner: firstAdapter.mirrorOwner,
            identity: firstIdentity
        )
        let secondIdentity = try secondAdapter.spawnNetworkableEntity(
            SourceEntity(className: "prop_physics"),
            at: 30
        )
        XCTAssertEqual(secondIdentity, firstIdentity)

        XCTAssertThrowsError(try secondAdapter.attach(client: client))
        XCTAssertEqual(secondAdapter.attachedClientCount, 0)
        XCTAssertEqual(clientRegistry.sourceMirrorIdentity(at: 30), firstIdentity)
        XCTAssertTrue(
            GMLuaTypeSystem.typedObject(from: clientRegistry.entity(at: 30)) ===
                GMLuaTypeSystem.typedObject(from: firstClientMirror)
        )
        try client.execute(
            "assert(Entity(30) == FIRST_ADAPTER_MIRROR and FIRST_ADAPTER_MIRROR.ownerSidecar == 41)"
        )

        XCTAssertThrowsError(try secondAdapter.detach(client: client))
        XCTAssertEqual(clientRegistry.sourceMirrorIdentity(at: 30), firstIdentity)
        XCTAssertTrue(try secondAdapter.markForDeletion(secondIdentity))
        XCTAssertEqual(
            try secondAdapter.runServerFixedTick().removedEntities,
            [secondIdentity]
        )
        XCTAssertEqual(clientRegistry.sourceMirrorIdentity(at: 30), firstIdentity)
        try client.execute(
            "assert(Entity(30) == FIRST_ADAPTER_MIRROR and FIRST_ADAPTER_MIRROR.ownerSidecar == 41)"
        )

        try firstAdapter.detach(client: client)
        try client.execute("assert(Entity(30) == NULL and FIRST_ADAPTER_MIRROR == NULL)")
    }

    func testServerTickAdvancesTimerOnceResolvesEachHookAndFinishesAfterThinkError() throws {
        let server = makeRuntime(.server)
        defer { _ = server.close() }
        try server.execute(
            """
            SOURCE_ORDER = {}
            GAMEMODE = { version = "first" }
            hook = {}
            function hook.Call(event, gm)
                assert(event == "Think" and gm.version == "first")
                THINK_TIME = CurTime()
                table.insert(SOURCE_ORDER, "Think")
                GAMEMODE = { version = "second" }
                hook.Call = function(nextEvent, nextGM)
                    assert((nextEvent == "Think" or nextEvent == "Tick")
                        and nextGM.version == "second")
                    SOURCE_REPLACEMENT_CALLS = (SOURCE_REPLACEMENT_CALLS or 0) + 1
                    LAST_HOOK_TIME = CurTime()
                    if FIRST_TICK_TIME == nil and nextEvent == "Tick" then
                        FIRST_TICK_TIME = CurTime()
                    end
                    if SOURCE_REPLACEMENT_CALLS <= 3 then
                        table.insert(SOURCE_ORDER, nextEvent)
                    end
                end
                error("intentional Think failure")
            end
            timer.Create("source_due", 0.015, 1, function()
                TIMER_TIME = CurTime()
                TIMER_COUNT = (TIMER_COUNT or 0) + 1
                table.insert(SOURCE_ORDER, "timer")
            end)
            """
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let scheduler = try XCTUnwrap(server.timerScheduler)
        let firstSourceTime = Double(Float(1) * SourceGlobalVars.intervalPerTick)
        let secondSourceTime = Double(Float(2) * SourceGlobalVars.intervalPerTick)

        let firstReport = try adapter.runServerFixedTick()

        XCTAssertEqual(firstReport.kind, .serverFixedTick)
        XCTAssertEqual(firstReport.serverPhases, SourceServerPhase.allCases)
        XCTAssertEqual(firstReport.addonHooks, [.think, .tick])
        XCTAssertEqual(firstReport.hookFailures.count, 1)
        XCTAssertEqual(firstReport.hookFailures.first?.event, "Think")
        XCTAssertTrue(
            firstReport.hookFailures.first?.message.contains("intentional Think failure") == true
        )
        XCTAssertTrue(firstReport.timerFailures.isEmpty)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 1)
        XCTAssertEqual(adapter.serverGlobals.currentTime, Float(1) * SourceGlobalVars.intervalPerTick)
        XCTAssertEqual(scheduler.currentTime, firstSourceTime)
        XCTAssertEqual(numberGlobal("THINK_TIME", in: server), firstSourceTime)
        XCTAssertEqual(numberGlobal("FIRST_TICK_TIME", in: server), firstSourceTime)
        try server.execute(
            """
            assert(#SOURCE_ORDER == 2)
            assert(SOURCE_ORDER[1] == "Think" and SOURCE_ORDER[2] == "Tick")
            assert(TIMER_TIME == nil and TIMER_COUNT == nil)
            """
        )

        let secondReport = try adapter.runServerFixedTick()
        XCTAssertTrue(secondReport.hookFailures.isEmpty)
        XCTAssertTrue(secondReport.timerFailures.isEmpty)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 2)
        XCTAssertEqual(scheduler.currentTime, secondSourceTime)
        XCTAssertEqual(numberGlobal("TIMER_TIME", in: server), secondSourceTime)
        XCTAssertEqual(numberGlobal("LAST_HOOK_TIME", in: server), secondSourceTime)
        try server.execute(
            """
            assert(#SOURCE_ORDER == 5)
            assert(SOURCE_ORDER[3] == "timer")
            assert(SOURCE_ORDER[4] == "Think" and SOURCE_ORDER[5] == "Tick")
            assert(TIMER_COUNT == 1)
            """
        )

        for _ in 3...257 {
            let report = try adapter.runServerFixedTick()
            XCTAssertTrue(report.hookFailures.isEmpty)
            XCTAssertTrue(report.timerFailures.isEmpty)
        }
        let finalSourceTime = Double(Float(257) * SourceGlobalVars.intervalPerTick)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 257)
        XCTAssertEqual(scheduler.currentTime, finalSourceTime)
        XCTAssertEqual(scheduler.currentTime, Double(adapter.serverGlobals.currentTime))
        XCTAssertEqual(numberGlobal("LAST_HOOK_TIME", in: server), finalSourceTime)
        try server.execute("assert(TIMER_COUNT == 1)")
    }

    func testClientFrameAndFixedTickHaveSeparateHooksAndClock() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let first = makeRuntime(.client, transport: transport)
        let second = makeRuntime(.client, transport: transport)
        defer {
            _ = second.close()
            _ = first.close()
            _ = server.close()
        }
        try installNoopHooks(in: server)
        let firstScheduler = try XCTUnwrap(first.timerScheduler)
        let secondScheduler = try XCTUnwrap(second.timerScheduler)
        XCTAssertTrue(try firstScheduler.advance(by: 2).isEmpty)
        var clientHookOrder: [String] = []
        for (runtime, label) in [(first, "first"), (second, "second")] {
            runtime.state.register("HOST_RECORD_CLIENT_SOURCE_HOOK") { arguments in
                clientHookOrder.append("\(label):\(arguments.first?.printable ?? "missing")")
                return []
            }
            try runtime.execute(
                """
                CLIENT_LABEL = "\(label)"
                CLIENT_THINKS = 0
                CLIENT_TICKS = 0
                CLIENT_TIMER = 0
                GAMEMODE = {}
                hook = {}
                function hook.Call(event, gm)
                    assert(gm == GAMEMODE)
                    HOST_RECORD_CLIENT_SOURCE_HOOK(event)
                    if event == "Think" then CLIENT_THINKS = CLIENT_THINKS + 1 end
                    if event == "Tick" then CLIENT_TICKS = CLIENT_TICKS + 1 end
                end
                timer.Create("client_due", 0.015, 1, function()
                    CLIENT_TIMER = CLIENT_TIMER + 1
                end)
                """
            )
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        try adapter.attach(client: first)
        try adapter.attach(client: second)

        XCTAssertEqual(try adapter.runClientFrame().addonHooks, [.think])
        _ = try adapter.runClientFrame()
        XCTAssertEqual(firstScheduler.currentTime, 2)
        XCTAssertEqual(secondScheduler.currentTime, 0)
        try first.execute("assert(CLIENT_THINKS == 2 and CLIENT_TICKS == 0 and CLIENT_TIMER == 0)")
        try second.execute("assert(CLIENT_THINKS == 2 and CLIENT_TICKS == 0 and CLIENT_TIMER == 0)")

        let firstSourceTime = Double(Float(1) * SourceGlobalVars.intervalPerTick)
        let fixedReport = try adapter.runClientFixedTick()
        XCTAssertEqual(fixedReport.addonHooks, [.tick])
        XCTAssertTrue(fixedReport.hookFailures.isEmpty)
        XCTAssertTrue(fixedReport.timerFailures.isEmpty)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 0)
        XCTAssertEqual(firstScheduler.currentTime, 2 + firstSourceTime)
        XCTAssertEqual(secondScheduler.currentTime, firstSourceTime)
        try first.execute("assert(CLIENT_THINKS == 2 and CLIENT_TICKS == 1 and CLIENT_TIMER == 0)")
        try second.execute("assert(CLIENT_THINKS == 2 and CLIENT_TICKS == 1 and CLIENT_TIMER == 0)")

        let secondFixedReport = try adapter.runClientFixedTick()
        XCTAssertTrue(secondFixedReport.hookFailures.isEmpty)
        XCTAssertTrue(secondFixedReport.timerFailures.isEmpty)
        let secondSourceTime = Double(Float(2) * SourceGlobalVars.intervalPerTick)
        XCTAssertEqual(firstScheduler.currentTime, 2 + secondSourceTime)
        XCTAssertEqual(secondScheduler.currentTime, secondSourceTime)
        try first.execute("assert(CLIENT_TICKS == 2 and CLIENT_TIMER == 1)")
        try second.execute("assert(CLIENT_TICKS == 2 and CLIENT_TIMER == 1)")

        try adapter.detach(client: first)
        _ = try adapter.runClientFixedTick()
        XCTAssertEqual(firstScheduler.currentTime, 2 + secondSourceTime)
        XCTAssertEqual(
            secondScheduler.currentTime,
            Double(Float(3) * SourceGlobalVars.intervalPerTick)
        )
        try adapter.attach(client: first)
        _ = try adapter.runClientFixedTick()
        XCTAssertEqual(firstScheduler.currentTime, 2 + secondSourceTime + firstSourceTime)
        XCTAssertEqual(
            secondScheduler.currentTime,
            Double(Float(4) * SourceGlobalVars.intervalPerTick)
        )
        try first.execute("assert(CLIENT_TICKS == 3 and CLIENT_TIMER == 1)")
        try second.execute("assert(CLIENT_TICKS == 4 and CLIENT_TIMER == 1)")
        XCTAssertEqual(
            clientHookOrder,
            [
                "first:Think", "second:Think",
                "first:Think", "second:Think",
                "first:Tick", "second:Tick",
                "first:Tick", "second:Tick",
                "second:Tick",
                "second:Tick", "first:Tick",
            ]
        )
    }

    func testClientClockDriftPreflightIsAtomicAcrossAllAttachments() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let first = makeRuntime(.client, transport: transport)
        let second = makeRuntime(.client, transport: transport)
        defer {
            _ = second.close()
            _ = first.close()
            _ = server.close()
        }
        try installNoopHooks(in: server)
        for runtime in [first, second] {
            try runtime.execute(
                """
                CLIENT_DRIFT_TICKS = 0
                CLIENT_DRIFT_TIMER = 0
                GAMEMODE = {}
                hook = {}
                function hook.Call(event, gm)
                    assert(gm == GAMEMODE)
                    if event == "Tick" then
                        CLIENT_DRIFT_TICKS = CLIENT_DRIFT_TICKS + 1
                    end
                end
                timer.Create("client_drift", 1, 1, function()
                    CLIENT_DRIFT_TIMER = CLIENT_DRIFT_TIMER + 1
                end)
                """
            )
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        try adapter.attach(client: first)
        try adapter.attach(client: second)
        let firstScheduler = try XCTUnwrap(first.timerScheduler)
        let secondScheduler = try XCTUnwrap(second.timerScheduler)
        XCTAssertTrue(try secondScheduler.advance(by: 0.25).isEmpty)

        XCTAssertThrowsError(try adapter.runClientFixedTick()) { error in
            guard case let GMLuaSourceRuntimeAdapterError.timerClockMismatch(
                realm,
                expected,
                actual
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(realm, .client)
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(actual, 0.25)
        }
        XCTAssertEqual(firstScheduler.currentTime, 0)
        XCTAssertEqual(secondScheduler.currentTime, 0.25)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 0)
        try first.execute("assert(CLIENT_DRIFT_TICKS == 0 and CLIENT_DRIFT_TIMER == 0)")
        try second.execute("assert(CLIENT_DRIFT_TICKS == 0 and CLIENT_DRIFT_TIMER == 0)")

        try adapter.detach(client: second)
        _ = try adapter.runClientFixedTick()
        XCTAssertEqual(
            firstScheduler.currentTime,
            Double(Float(1) * SourceGlobalVars.intervalPerTick)
        )
        try first.execute("assert(CLIENT_DRIFT_TICKS == 1 and CLIENT_DRIFT_TIMER == 0)")
        try second.execute("assert(CLIENT_DRIFT_TICKS == 0 and CLIENT_DRIFT_TIMER == 0)")
    }

    func testSameThreadReentrantTickIsRejectedAndNetQueueIsNeverAutoPumped() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        try adapter.attach(client: client)
        var reentryDescription: String?
        server.state.register("HOST_REENTER_SOURCE_TICK") { _ in
            do {
                _ = try adapter.runServerFixedTick()
                reentryDescription = "unexpected success"
            } catch {
                reentryDescription = String(describing: error)
            }
            return []
        }
        try server.execute(
            """
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm)
                if event == "Think" then HOST_REENTER_SOURCE_TICK() end
            end
            util.AddNetworkString("source_no_auto_pump")
            net.Start("source_no_auto_pump")
            net.WriteUInt(3, 2)
            net.Broadcast()
            """
        )
        try installNoopHooks(in: client)
        XCTAssertEqual(transport.pendingDeliveryCount, 1)

        _ = try adapter.runServerFixedTick()
        _ = try adapter.runClientFrame()
        _ = try adapter.runClientFixedTick()

        XCTAssertTrue(reentryDescription?.contains("cannot re-enter") == true)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 1)
        XCTAssertEqual(transport.pendingDeliveryCount, 1)
    }

    func testHookAndTimerCallbacksCannotCloseParticipatingRuntime() throws {
        let server = makeRuntime(.server)
        defer { _ = server.close() }
        var callbackCloseReports: [LuaCloseReport] = []
        server.state.register("HOST_CLOSE_DURING_SOURCE_RUN") { _ in
            callbackCloseReports.append(server.close())
            return []
        }
        try server.execute(
            """
            SOURCE_CLOSE_HOOKS = 0
            SOURCE_CLOSE_TIMERS = 0
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm)
                assert(gm == GAMEMODE)
                if event == "Think" then
                    SOURCE_CLOSE_HOOKS = SOURCE_CLOSE_HOOKS + 1
                    HOST_CLOSE_DURING_SOURCE_RUN()
                end
            end
            timer.Create("source_close", 0.015, 1, function()
                SOURCE_CLOSE_TIMERS = SOURCE_CLOSE_TIMERS + 1
                HOST_CLOSE_DURING_SOURCE_RUN()
            end)
            """
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)

        let firstReport = try adapter.runServerFixedTick()
        XCTAssertTrue(firstReport.hookFailures.isEmpty)
        XCTAssertTrue(firstReport.timerFailures.isEmpty)
        XCTAssertEqual(callbackCloseReports.count, 1)
        XCTAssertFalse(server.isClosed)

        let secondReport = try adapter.runServerFixedTick()
        XCTAssertTrue(secondReport.hookFailures.isEmpty)
        XCTAssertTrue(secondReport.timerFailures.isEmpty)
        XCTAssertEqual(callbackCloseReports.count, 3)
        for closeReport in callbackCloseReports {
            XCTAssertEqual(closeReport.finalizedUserdataCount, 0)
            XCTAssertEqual(closeReport.additionalPasses, 0)
            XCTAssertEqual(closeReport.deferredNewFinalizerCount, 0)
            XCTAssertEqual(closeReport.errorMessages.count, 1)
            XCTAssertTrue(
                closeReport.errorMessages[0].contains(
                    "rejected during Source adapter execution"
                )
            )
        }
        XCTAssertFalse(server.isClosed)
        XCTAssertEqual(adapter.serverGlobals.tickCount, 2)
        try server.execute(
            "assert(SOURCE_CLOSE_HOOKS == 2 and SOURCE_CLOSE_TIMERS == 1)"
        )

        _ = server.close()
        XCTAssertTrue(server.isClosed)
    }

    func testEntityMutationRejectsRuntimeAndAdapterCloseReentry() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        defer {
            _ = client.close()
            _ = server.close()
        }
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let identity = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "prop_physics"),
            at: 28
        )
        try adapter.attach(client: client)

        let closeReports = try adapter.withEntityMutation(identity) { _ in
            [server.close(), client.close()]
        }
        XCTAssertEqual(closeReports.count, 2)
        for closeReport in closeReports {
            XCTAssertEqual(closeReport.finalizedUserdataCount, 0)
            XCTAssertEqual(closeReport.errorMessages.count, 1)
            XCTAssertTrue(
                closeReport.errorMessages[0].contains(
                    "rejected during Source adapter execution"
                )
            )
        }
        XCTAssertFalse(server.isClosed)
        XCTAssertFalse(client.isClosed)
        XCTAssertTrue(adapter.contains(identity))
        XCTAssertEqual(server.entityRegistry?.sourceMirrorIdentity(at: 28), identity)
        XCTAssertEqual(client.entityRegistry?.sourceMirrorIdentity(at: 28), identity)

        XCTAssertThrowsError(
            try adapter.withEntityMutation(identity) { _ in
                try adapter.close()
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("cannot re-enter adapter close"))
        }
        XCTAssertFalse(adapter.isClosed)
        XCTAssertTrue(adapter.contains(identity))
        try adapter.close()
    }

    func testConcurrentRuntimeCloseWaitsForAdapterLifecycleBoundary() throws {
        let server = makeRuntime(.server)
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closeDone = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let observations = AdapterConcurrencyObservations()
        let runtimeBox = AdapterRuntimeBox(server)
        server.state.register("HOST_SOURCE_TICK_GATE") { _ in
            entered.signal()
            release.wait()
            return []
        }
        try server.execute(
            """
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm)
                if event == "Think" then HOST_SOURCE_TICK_GATE() end
            end
            """
        )

        workers.enter()
        DispatchQueue.global().async {
            do {
                _ = try adapter.runServerFixedTick()
                observations.finishRun(error: nil)
            } catch {
                observations.finishRun(error: error)
            }
            workers.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        workers.enter()
        DispatchQueue.global().async {
            _ = runtimeBox.runtime.close()
            observations.finishClose()
            closeDone.signal()
            workers.leave()
        }
        XCTAssertEqual(
            closeDone.wait(timeout: .now() + 0.1),
            .timedOut,
            "runtime close must wait for the complete adapter tick boundary"
        )
        release.signal()
        XCTAssertEqual(workers.wait(timeout: .now() + 2), .success)
        let snapshot = observations.snapshot
        XCTAssertNil(snapshot.runError)
        XCTAssertTrue(snapshot.runCompleted)
        XCTAssertTrue(snapshot.closeCompleted)
        XCTAssertTrue(server.isClosed)
    }

    private func makeRuntime(
        _ realm: GMLuaRealm,
        transport: GMLuaNetTransport? = nil
    ) -> GMLuaRuntime {
        GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            netTransport: transport
        )
    }

    private func installNoopHooks(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm) assert(gm == GAMEMODE) end
            """
        )
    }

    private func numberGlobal(_ name: String, in runtime: GMLuaRuntime) -> Double? {
        guard case let .number(value) = runtime.state.getGlobal(name) else { return nil }
        return value
    }
}

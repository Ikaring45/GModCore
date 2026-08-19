import Foundation
import Dispatch
import XCTest
@testable import GModEngine
import GModLua

private final class LockedNetPumpResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<Int, Error>] = []

    func append(_ result: Result<Int, Error>) {
        lock.lock()
        storage.append(result)
        lock.unlock()
    }

    var values: [Result<Int, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedNetInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func incrementAndReturn() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }
}

final class GMLuaNetTransportTests: XCTestCase {
    func testTTTRoundStateBroadcastIsQueuedAndDispatchedThroughLuaIncoming() throws {
        let sharedGlobals = GMLuaNetworkedGlobalTransport()
        let transport = GMLuaNetTransport(
            networkedGlobalTransport: sharedGlobals
        )
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
        try installFixture(in: firstClient)
        try installFixture(in: secondClient)

        try server.execute(
            """
            local id = util.AddNetworkString("TTT_RoundState")
            assert(id == util.NetworkStringToID("TTT_RoundState"))
            net.Start("TTT_RoundState")
            net.WriteUInt(5, 3)
            local bytes, bits = net.BytesWritten()
            assert(bytes == 4 and bits == 27)
            net.Broadcast()
            """,
            sourceName: "=(TTT RoundState server broadcast)"
        )

        XCTAssertEqual(transport.connectedClientCount, 2)
        XCTAssertEqual(transport.pendingDeliveryCount, 2)
        XCTAssertEqual(transport.completedMessageCount, 1)
        guard case .nilValue = firstClient.state.getGlobal("ROUND_STATE_RECEIVED") else {
            return XCTFail("Broadcast re-entered client Lua before host pump")
        }

        XCTAssertEqual(try transport.pump(), 2)
        XCTAssertEqual(transport.pendingDeliveryCount, 0)
        try assertRoundState(on: firstClient)
        try assertRoundState(on: secondClient)
        XCTAssertTrue(
            try XCTUnwrap(server.networkedGlobals).transport === sharedGlobals
        )
        XCTAssertTrue(
            try XCTUnwrap(firstClient.networkedGlobals).transport === sharedGlobals
        )
        XCTAssertEqual(server.networkStrings, ["TTT_RoundState"])
        XCTAssertEqual(firstClient.networkStrings, ["TTT_RoundState"])
    }

    func testNewStartDiscardsPriorMessageAndUnalignedBitsRoundTripExactly() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)

        try server.execute(
            """
            util.AddNetworkString("discarded_message")
            util.AddNetworkString("bit_mix")
            net.Start("discarded_message")
            net.WriteUInt(7, 3)
            net.Start("bit_mix")
            net.WriteBit(true)
            net.WriteBit(false)
            net.WriteUInt(5, 3)
            net.WriteUInt(165, 8)
            net.Broadcast()
            """
        )

        XCTAssertEqual(try transport.pump(), 1)
        guard case .number(0) = client.state.getGlobal("DISCARDED_RECEIVER_COUNT"),
              case .number(13) = client.state.getGlobal("MIX_LENGTH"),
              case .number(1) = client.state.getGlobal("MIX_A"),
              case .number(0) = client.state.getGlobal("MIX_B"),
              case .number(5) = client.state.getGlobal("MIX_C"),
              case .number(165) = client.state.getGlobal("MIX_D") else {
            return XCTFail("unaligned bit payload did not round-trip exactly")
        }
    }

    func testStandaloneServerBroadcastsHonestlyToZeroClients() throws {
        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        let transport = try XCTUnwrap(server.netTransport)

        try server.execute(
            """
            util.AddNetworkString("headless")
            net.Start("headless")
            net.WriteUInt(6, 3)
            net.Broadcast()
            """
        )

        XCTAssertEqual(transport.connectedClientCount, 0)
        XCTAssertEqual(transport.completedMessageCount, 1)
        XCTAssertEqual(transport.pendingDeliveryCount, 0)
        XCTAssertEqual(try transport.pump(), 0)
    }

    func testBoundaryErrorsAndDisconnectedClientRemainExplicit() throws {
        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        try server.execute(
            """
            assert(util.NetworkIDToString(0) == nil)
            assert(util.NetworkIDToString(-1) == nil)
            assert(util.NetworkIDToString(math.huge) == nil)
            assert(util.NetworkIDToString(-math.huge) == nil)
            assert(util.NetworkIDToString(0 / 0) == nil)
            assert(util.NetworkIDToString(1.5) == util.NetworkIDToString(1))
            """
        )
        XCTAssertThrowsError(try server.execute("net.Start('not_pooled')")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("unpooled"))
        }
        XCTAssertThrowsError(try server.execute("net.WriteUInt(1, 1)")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("without net.Start"))
        }
        XCTAssertThrowsError(try server.execute("net.ReadUInt(1)")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("outside an incoming"))
        }
        XCTAssertThrowsError(try server.execute("net.WriteBit(1)")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("boolean expected"))
        }
        try server.execute(
            """
            util.AddNetworkString("aborted")
            net.Start("aborted")
            net.WriteBit(true)
            net.Abort()
            """
        )
        XCTAssertThrowsError(try server.execute("net.Broadcast()")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("without net.Start"))
        }

        let pool = GMLuaNetworkedGlobalTransport()
        let poolOwner = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            networkedGlobalTransport: pool
        )
        try poolOwner.execute("util.AddNetworkString('client_attempt')")
        let disconnectedTransport = GMLuaNetTransport(
            networkedGlobalTransport: pool
        )
        let disconnectedClient = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: disconnectedTransport
        )
        try disconnectedClient.execute("assert(util.AddNetworkString == nil)")
        XCTAssertThrowsError(
            try disconnectedClient.execute(
                "net.Start('client_attempt'); net.WriteBit(true); net.SendToServer()"
            )
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("disconnected"))
        }
    }

    func testReceiverErrorAlwaysClearsReaderAndLeavesLaterDeliveryQueued() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)
        try server.execute(
            """
            util.AddNetworkString("receiver_error")
            util.AddNetworkString("after_error")
            net.Start("receiver_error")
            net.WriteUInt(6, 3)
            net.Broadcast()
            net.Start("after_error")
            net.WriteUInt(4, 3)
            net.Broadcast()
            """
        )

        XCTAssertThrowsError(try transport.pump()) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("intentional receiver failure"))
        }
        XCTAssertEqual(transport.pendingDeliveryCount, 1)
        XCTAssertThrowsError(try client.execute("net.ReadBit()")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("outside an incoming"))
        }
        XCTAssertEqual(try transport.pump(), 1)
        guard case .number(4) = client.state.getGlobal("AFTER_ERROR_VALUE") else {
            return XCTFail("delivery following receiver error was lost")
        }
    }

    func testMaximumPayloadLimitAndUIntRangesAreEnforced() throws {
        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        try server.execute("util.AddNetworkString('limit')")
        try server.execute(
            """
            net.Start("limit")
            for i = 1, 16383 do net.WriteUInt(0, 32) end
            net.WriteUInt(0, 8)
            local bytes, bits = net.BytesWritten()
            assert(bits == 524288 and bytes == 65536)
            net.Broadcast()
            """,
            sourceName: "=(exact 65533-byte net payload)"
        )
        XCTAssertThrowsError(
            try server.execute(
                """
                net.Start("limit")
                for i = 1, 16383 do net.WriteUInt(0, 32) end
                net.WriteUInt(0, 8)
                net.WriteBit(false)
                """,
                sourceName: "=(one bit beyond net payload limit)"
            )
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("65,533-byte"))
        }
        XCTAssertThrowsError(try server.execute("net.Start('limit'); net.WriteUInt(8, 3)"))
        XCTAssertThrowsError(try server.execute("net.Start('limit'); net.WriteUInt(0, 0)"))
        XCTAssertThrowsError(try server.execute("net.Start('limit'); net.WriteUInt(0, 33)"))
    }

    func testP1CodecsRoundTripBinaryValuesAtUnalignedOffsets() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)

        try server.execute(
            """
            util.AddNetworkString("codec_mix")
            net.Start("codec_mix")
            net.WriteBit(true)
            net.WriteInt(-3, 4)
            net.WriteUInt(13, 4)
            net.WriteFloat(0.1)
            net.WriteUInt(1036831949, 32)
            net.WriteFloat(-0.0)
            net.WriteFloat(math.huge)
            net.WriteFloat(0 / 0)
            net.WriteString(string.char(65, 255, 66, 0, 67))
            net.WriteData(string.char(0, 255, 128, 65, 66), 4)
            net.WriteBit(false)
            net.Broadcast()
            """,
            sourceName: "=(unaligned P1 net codecs)"
        )

        XCTAssertEqual(transport.pendingDeliveryCount, 1)
        guard case .nilValue = client.state.getGlobal("CODEC_LENGTH") else {
            return XCTFail("P1 codec delivery re-entered Lua before pump")
        }
        XCTAssertEqual(try transport.pump(), 1)

        guard case .number(234) = client.state.getGlobal("CODEC_LENGTH"),
              case .number(1) = client.state.getGlobal("CODEC_PREFIX_BIT"),
              case .number(13) = client.state.getGlobal("CODEC_INT_ENCODED"),
              case .number(-3) = client.state.getGlobal("CODEC_INT_DECODED"),
              case let .number(floatBits) = client.state.getGlobal("CODEC_FLOAT_BITS"),
              case let .number(floatValue) = client.state.getGlobal("CODEC_FLOAT_VALUE"),
              case let .number(negativeZero) = client.state.getGlobal("CODEC_NEGATIVE_ZERO"),
              case let .number(infinity) = client.state.getGlobal("CODEC_INFINITY"),
              case let .number(notANumber) = client.state.getGlobal("CODEC_NAN"),
              case let .string(stringValue) = client.state.getGlobal("CODEC_STRING"),
              case let .string(dataValue) = client.state.getGlobal("CODEC_DATA"),
              case .number(0) = client.state.getGlobal("CODEC_FINAL_BIT"),
              case .number(0) = client.state.getGlobal("CODEC_FINAL_BYTES"),
              case .number(0) = client.state.getGlobal("CODEC_FINAL_BITS") else {
            return XCTFail("unaligned P1 codec payload did not round-trip exactly")
        }
        XCTAssertEqual(floatBits, Double(Float(0.1).bitPattern))
        XCTAssertEqual(floatValue, Double(Float(bitPattern: 1_036_831_949)))
        XCTAssertEqual(negativeZero, 0)
        XCTAssertEqual(negativeZero.sign, .minus)
        XCTAssertEqual(infinity, .infinity)
        XCTAssertTrue(notANumber.isNaN)
        XCTAssertEqual(stringValue.bytes, [65, 255, 66])
        XCTAssertEqual(dataValue.bytes, [0, 255, 128, 65])
    }

    func testP1SignedWidthsAndDefaultDataLengthRoundTrip() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)

        try server.execute(
            """
            util.AddNetworkString("signed_widths")
            util.AddNetworkString("data_default_length")
            net.Start("signed_widths")
            for bits = 1, 32 do
                local magnitude = 2 ^ (bits - 1)
                net.WriteInt(-magnitude, bits)
                net.WriteInt(magnitude - 1, bits)
            end
            net.Broadcast()
            """
        )
        XCTAssertEqual(try transport.pump(maxDeliveries: 1), 1)
        guard case .boolean(true) = client.state.getGlobal("SIGNED_WIDTHS_RECEIVED") else {
            return XCTFail("signed two's-complement extrema did not round-trip for 1...32 bits")
        }

        try server.execute(
            """
            net.Start("data_default_length")
            net.WriteBit(true)
            net.WriteData(string.char(0, 255, 65))
            net.Broadcast()
            """
        )
        XCTAssertEqual(try transport.pump(maxDeliveries: 1), 1)
        guard case .number(1) = client.state.getGlobal("DATA_DEFAULT_PREFIX"),
              case let .string(defaultData) = client.state.getGlobal("DATA_DEFAULT") else {
            return XCTFail("net.WriteData omitted length did not preserve binary LuaString")
        }
        XCTAssertEqual(defaultData.bytes, [0, 255, 65])
    }

    func testP1CodecContextRangesAndReadBoundsAreExplicit() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)

        for source in [
            "net.WriteInt(0, 1)",
            "net.WriteFloat(0)",
            "net.WriteString('x')",
            "net.WriteData('x', 1)",
        ] {
            XCTAssertThrowsError(try server.execute(source)) { error in
                XCTAssertTrue(GMLuaRuntime.describe(error).contains("without net.Start"))
            }
        }
        for source in [
            "net.ReadInt(1)",
            "net.ReadFloat()",
            "net.ReadString()",
            "net.ReadData(0)",
        ] {
            XCTAssertThrowsError(try client.execute(source)) { error in
                XCTAssertTrue(GMLuaRuntime.describe(error).contains("outside an incoming"))
            }
        }

        try server.execute(
            """
            util.AddNetworkString("codec_limits")
            util.AddNetworkString("read_int_underflow")
            util.AddNetworkString("read_float_underflow")
            util.AddNetworkString("read_data_underflow")
            util.AddNetworkString("read_string_unterminated")
            """
        )
        for source in [
            "net.Start('codec_limits'); net.WriteInt(0, 0)",
            "net.Start('codec_limits'); net.WriteInt(0, 33)",
            "net.Start('codec_limits'); net.WriteInt(0.5, 4)",
            "net.Start('codec_limits'); net.WriteInt(-2, 1)",
            "net.Start('codec_limits'); net.WriteInt(1, 1)",
            "net.Start('codec_limits'); net.WriteInt(-2147483649, 32)",
            "net.Start('codec_limits'); net.WriteInt(2147483648, 32)",
            "net.Start('codec_limits'); net.WriteData('x', -1)",
            "net.Start('codec_limits'); net.WriteData('x', 0.5)",
            "net.Start('codec_limits'); net.WriteData('x', 2)",
            "net.Start('codec_limits'); net.WriteData('x', 65534)",
        ] {
            XCTAssertThrowsError(try server.execute(source))
        }

        try server.execute(
            """
            net.Start("read_int_underflow")
            net.WriteBit(true)
            net.Broadcast()
            net.Start("read_float_underflow")
            net.WriteUInt(0, 31)
            net.Broadcast()
            net.Start("read_data_underflow")
            net.WriteData("x", 1)
            net.Broadcast()
            net.Start("read_string_unterminated")
            net.WriteData("x", 1)
            net.Broadcast()
            """
        )

        let expectedFragments = [
            "read 2 bits with only 1 remaining",
            "read 32 bits with only 31 remaining",
            "read 2 bytes with only 8 bits remaining",
            "before its NUL terminator",
        ]
        for fragment in expectedFragments {
            XCTAssertThrowsError(try transport.pump()) { error in
                XCTAssertTrue(GMLuaRuntime.describe(error).contains(fragment))
            }
        }
        XCTAssertEqual(transport.pendingDeliveryCount, 0)
        XCTAssertThrowsError(try client.execute("net.ReadBit()")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("outside an incoming"))
        }
    }

    func testP1StringNULTerminationAndMessageLimitAreEnforced() throws {
        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        try server.execute("util.AddNetworkString('string_limit')")
        try server.execute(
            """
            net.Start("string_limit")
            net.WriteString(string.rep("a", 65532))
            local bytes, bits = net.BytesWritten()
            assert(bytes == 65536 and bits == 524288)
            net.Broadcast()
            """
        )
        XCTAssertThrowsError(
            try server.execute(
                "net.Start('string_limit'); net.WriteString(string.rep('a', 65533))"
            )
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("65,533-byte"))
        }
    }

    func testConcurrentPumpsSerializeBeforeDequeuingForTheSameRealm() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)

        let firstCallbackEntered = DispatchSemaphore(value: 0)
        let releaseFirstCallback = DispatchSemaphore(value: 0)
        let callbackCount = LockedNetInvocationCount()
        client.state.register("TEST_CONCURRENT_PUMP_GATE") { _ in
            if callbackCount.incrementAndReturn() == 1 {
                firstCallbackEntered.signal()
                releaseFirstCallback.wait()
            }
            return []
        }

        try server.execute(
            """
            util.AddNetworkString("concurrent_pump")
            net.Start("concurrent_pump")
            net.Broadcast()
            net.Start("concurrent_pump")
            net.Broadcast()
            """
        )
        XCTAssertEqual(transport.pendingDeliveryCount, 2)

        let queue = DispatchQueue(
            label: "GMLuaNetTransportTests.concurrentPump",
            attributes: .concurrent
        )
        let workers = DispatchGroup()
        let results = LockedNetPumpResults()
        let secondPumpStarted = DispatchSemaphore(value: 0)
        let secondPumpFinished = DispatchSemaphore(value: 0)

        workers.enter()
        queue.async {
            results.append(Result { try transport.pump(maxDeliveries: 1) })
            workers.leave()
        }
        guard firstCallbackEntered.wait(timeout: .now() + 2) == .success else {
            releaseFirstCallback.signal()
            _ = workers.wait(timeout: .now() + 2)
            return XCTFail("first pump did not enter its receiver")
        }

        workers.enter()
        queue.async {
            secondPumpStarted.signal()
            results.append(Result { try transport.pump(maxDeliveries: 1) })
            secondPumpFinished.signal()
            workers.leave()
        }
        XCTAssertEqual(secondPumpStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            secondPumpFinished.wait(timeout: .now() + 0.2),
            .timedOut,
            "second pump must wait without dequeuing while the first callback is active"
        )

        releaseFirstCallback.signal()
        XCTAssertEqual(workers.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondPumpFinished.wait(timeout: .now()), .success)
        XCTAssertEqual(results.values.count, 2)
        for result in results.values {
            XCTAssertEqual(try result.get(), 1)
        }
        XCTAssertEqual(transport.pendingDeliveryCount, 0)
        guard case .number(2) = client.state.getGlobal("CONCURRENT_PUMP_COUNT") else {
            return XCTFail("a concurrently pumped packet was lost")
        }
    }

    func testRuntimeCloseDetachesClientAndAllowsServerReplacement() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: client)

        try server.execute(
            """
            util.AddNetworkString("TTT_RoundState")
            net.Start("TTT_RoundState")
            net.WriteUInt(1, 3)
            net.Broadcast()
            """
        )
        XCTAssertEqual(transport.connectedClientCount, 1)
        XCTAssertEqual(transport.pendingDeliveryCount, 1)

        _ = client.close()
        XCTAssertEqual(transport.connectedClientCount, 0)
        XCTAssertEqual(transport.pendingDeliveryCount, 0)
        XCTAssertEqual(try transport.pump(), 0)

        try server.execute(
            """
            net.Start("TTT_RoundState")
            net.WriteUInt(2, 3)
            net.Broadcast()
            """
        )
        XCTAssertEqual(transport.pendingDeliveryCount, 0)

        _ = server.close()
        let replacementServer = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let replacementClient = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        try installFixture(in: replacementClient)
        try replacementServer.execute(
            """
            assert(util.AddNetworkString("TTT_RoundState") ==
                util.NetworkStringToID("TTT_RoundState"))
            net.Start("TTT_RoundState")
            net.WriteUInt(6, 3)
            net.Broadcast()
            """
        )

        XCTAssertEqual(transport.connectedClientCount, 1)
        XCTAssertEqual(try transport.pump(), 1)
        guard case .number(6) = replacementClient.state.getGlobal("ROUND_STATE_RECEIVED") else {
            return XCTFail("replacement server did not deliver through the reused session")
        }
    }

    func testSessionRejectsASecondServerAndMismatchedPool() throws {
        let transport = GMLuaNetTransport()
        let firstServer = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        try firstServer.execute("return true")
        let secondServer = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        XCTAssertThrowsError(try secondServer.execute("return true")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("exactly one SERVER"))
        }

        let mismatch = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            networkedGlobalTransport: GMLuaNetworkedGlobalTransport(),
            netTransport: GMLuaNetTransport()
        )
        XCTAssertThrowsError(try mismatch.execute("return true")) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("same NetworkString pool"))
        }
    }

    private func assertRoundState(on runtime: GMLuaRuntime) throws {
        guard case .number(3) = runtime.state.getGlobal("ROUND_STATE_LENGTH"),
              case .nilValue = runtime.state.getGlobal("ROUND_STATE_SENDER"),
              case .number(1) = runtime.state.getGlobal("ROUND_STATE_BYTES_LEFT"),
              case .number(3) = runtime.state.getGlobal("ROUND_STATE_BITS_LEFT"),
              case .number(5) = runtime.state.getGlobal("ROUND_STATE_RECEIVED"),
              case .number(0) = runtime.state.getGlobal("ROUND_STATE_FINAL_BYTES"),
              case .number(0) = runtime.state.getGlobal("ROUND_STATE_FINAL_BITS") else {
            return XCTFail("TTT_RoundState receiver observed the wrong header or payload")
        }
    }

    private func installFixture(in runtime: GMLuaRuntime) throws {
        let values = try runtime.executeReturningValues(
            try fixtureSource(),
            sourceName: "@GLuaNetTransportRegression.lua"
        )
        guard case .boolean(true) = values.first else {
            return XCTFail("net transport fixture did not install")
        }
    }

    private func fixtureSource() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaNetTransportRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaNetTransportRegression",
                withExtension: "lua"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

import XCTest
@testable import GModEngine

final class SourceNetworkTests: XCTestCase {
    func testLSBFirstGoldenBytesAndSignedWidths() {
        var writer = SourceBitWriter(byteCapacity: 2)
        writer.writeUnsigned(0b101, bitCount: 3)
        writer.writeUnsigned(0b11010, bitCount: 5)
        writer.writeSigned(-2, bitCount: 4)

        XCTAssertEqual(writer.bitsWritten, 12)
        XCTAssertEqual(writer.writtenBytes, [0xd5, 0x0e])
        XCTAssertFalse(writer.isOverflowed)

        var reader = SourceBitReader(bytes: writer.writtenBytes, bitCount: writer.bitsWritten)
        XCTAssertEqual(reader.readUnsigned(bitCount: 3), 0b101)
        XCTAssertEqual(reader.readUnsigned(bitCount: 5), 0b11010)
        XCTAssertEqual(reader.readSigned(bitCount: 4), -2)
        XCTAssertEqual(reader.bitsLeft, 0)
        XCTAssertFalse(reader.isOverflowed)

        var fullWidth = SourceBitWriter(byteCapacity: 4)
        fullWidth.writeSigned(Int32.min, bitCount: 32)
        XCTAssertEqual(fullWidth.writtenBytes, [0, 0, 0, 0x80])
        var fullWidthReader = SourceBitReader(bytes: fullWidth.writtenBytes)
        XCTAssertEqual(fullWidthReader.readSigned(bitCount: 32), Int32.min)
    }

    func testAtomicFieldOverflowPinsCursorAndPreservesEarlierBits() {
        var writer = SourceBitWriter(byteCapacity: 1)
        writer.writeUnsigned(0x2a, bitCount: 6)
        writer.writeUnsigned(0xf, bitCount: 4)

        XCTAssertTrue(writer.isOverflowed)
        XCTAssertEqual(writer.bitsWritten, 8)
        XCTAssertEqual(writer.bytes, [0x2a], "the overlong four-bit field must write nothing")

        var reader = SourceBitReader(bytes: [0xff], bitCount: 6)
        XCTAssertEqual(reader.readUnsigned(bitCount: 4), 0xf)
        XCTAssertEqual(reader.readUnsigned(bitCount: 4), 0)
        XCTAssertTrue(reader.isOverflowed)
        XCTAssertEqual(reader.bitsRead, 6)
        XCTAssertEqual(reader.readBit(), false)
        XCTAssertEqual(reader.bitsRead, 6)
    }

    func testVarIntGoldenBytesSignedRoundTripAndPartialOverflow() {
        var writer = SourceBitWriter(byteCapacity: 32)
        writer.writeVarUInt32(0)
        writer.writeVarUInt32(127)
        writer.writeVarUInt32(128)
        writer.writeVarUInt32(300)
        writer.writeVarUInt32(UInt32.max)

        XCTAssertEqual(
            writer.writtenBytes,
            [0x00, 0x7f, 0x80, 0x01, 0xac, 0x02, 0xff, 0xff, 0xff, 0xff, 0x0f]
        )

        var reader = SourceBitReader(bytes: writer.writtenBytes)
        XCTAssertEqual(reader.readVarUInt32(), 0)
        XCTAssertEqual(reader.readVarUInt32(), 127)
        XCTAssertEqual(reader.readVarUInt32(), 128)
        XCTAssertEqual(reader.readVarUInt32(), 300)
        XCTAssertEqual(reader.readVarUInt32(), UInt32.max)

        let signedValues: [Int32] = [0, -1, 1, Int32.min, Int32.max]
        var signedWriter = SourceBitWriter(byteCapacity: 32)
        for value in signedValues { signedWriter.writeVarInt32(value) }
        var signedReader = SourceBitReader(
            bytes: signedWriter.writtenBytes,
            bitCount: signedWriter.bitsWritten
        )
        XCTAssertEqual(signedValues.map { _ in signedReader.readVarInt32() }, signedValues)

        var partial = SourceBitWriter(byteCapacity: 1)
        partial.writeVarUInt32(300)
        XCTAssertTrue(partial.isOverflowed)
        XCTAssertEqual(partial.bytes, [0xac], "the first complete varint byte remains committed")

        var malformed = SourceBitReader(bytes: [0x80, 0x80, 0x80, 0x80, 0x80, 0x7f])
        XCTAssertEqual(malformed.readVarUInt32(), 0)
        XCTAssertEqual(malformed.bitsRead, 40, "Source stops before consuming a sixth varint32 byte")
        XCTAssertFalse(malformed.isOverflowed)
        XCTAssertEqual(malformed.readUnsigned(bitCount: 8), 0x7f)
    }

    func testCStringNULTerminationTruncationAndMissingTerminator() {
        var writer = SourceBitWriter(byteCapacity: 16)
        writer.writeCString("A")
        writer.writeCString(nil)
        XCTAssertEqual(Array(writer.writtenBytes.prefix(3)), [0x41, 0x00, 0x00])

        var reader = SourceBitReader(bytes: writer.writtenBytes, bitCount: writer.bitsWritten)
        let first = reader.readCString(maxLength: 8)
        XCTAssertEqual(first.bytes, [0x41])
        XCTAssertEqual(first.string, "A")
        XCTAssertTrue(first.isSuccessful)
        XCTAssertTrue(reader.readCString(maxLength: 8).isSuccessful)

        var longWriter = SourceBitWriter(byteCapacity: 8)
        longWriter.writeCString("abcdef")
        var longReader = SourceBitReader(
            bytes: longWriter.writtenBytes,
            bitCount: longWriter.bitsWritten
        )
        let truncated = longReader.readCString(maxLength: 4)
        XCTAssertEqual(truncated.string, "abc")
        XCTAssertTrue(truncated.wasTerminated)
        XCTAssertTrue(truncated.wasTruncated)
        XCTAssertFalse(truncated.isSuccessful)
        XCTAssertEqual(longReader.bitsLeft, 0, "truncation still consumes through the NUL")

        var unterminatedReader = SourceBitReader(bytes: [0x41])
        let unterminated = unterminatedReader.readCString(maxLength: 8)
        XCTAssertEqual(unterminated.string, "A")
        XCTAssertFalse(unterminated.wasTerminated)
        XCTAssertTrue(unterminatedReader.isOverflowed)
    }

    func testCoordinateNormalAndAngleGoldenBitPatterns() {
        var zeroCoordinate = SourceBitWriter(byteCapacity: 1)
        zeroCoordinate.writeCoordinate(0)
        XCTAssertEqual(zeroCoordinate.bitsWritten, 2)
        XCTAssertEqual(zeroCoordinate.writtenBytes, [0x00])

        var positiveCoordinate = SourceBitWriter(byteCapacity: 4)
        positiveCoordinate.writeCoordinate(1.5)
        XCTAssertEqual(positiveCoordinate.bitsWritten, 22)
        XCTAssertEqual(positiveCoordinate.writtenBytes, [0x03, 0x00, 0x20])

        var negativeCoordinate = SourceBitWriter(byteCapacity: 4)
        negativeCoordinate.writeCoordinate(-2.25)
        XCTAssertEqual(negativeCoordinate.bitsWritten, 22)
        XCTAssertEqual(negativeCoordinate.writtenBytes, [0x0f, 0x00, 0x10])

        var normal = SourceBitWriter(byteCapacity: 2)
        normal.writeNormal(-1)
        XCTAssertEqual(normal.bitsWritten, 12)
        XCTAssertEqual(normal.writtenBytes, [0xff, 0x0f])

        var angle = SourceBitWriter(byteCapacity: 1)
        angle.writeAngle(90, bitCount: 8)
        XCTAssertEqual(angle.writtenBytes, [0x40])

        var wrappedAngle = SourceBitWriter(byteCapacity: 1)
        wrappedAngle.writeAngle(-90, bitCount: 8)
        XCTAssertEqual(wrappedAngle.writtenBytes, [0xc0])
    }

    func testCoordinateAndNormalVectorRoundTripsAtSourceQuantization() {
        let coordinate = SourceVector3(1.5, -2.25, 0)
        var coordinateWriter = SourceBitWriter(byteCapacity: 16)
        coordinateWriter.writeVectorCoordinate(coordinate)
        var coordinateReader = SourceBitReader(
            bytes: coordinateWriter.writtenBytes,
            bitCount: coordinateWriter.bitsWritten
        )
        XCTAssertEqual(coordinateReader.readVectorCoordinate(), coordinate)
        XCTAssertFalse(coordinateReader.isOverflowed)

        let normal = SourceVector3(0.6, 0, -0.8)
        var normalWriter = SourceBitWriter(byteCapacity: 8)
        normalWriter.writeVectorNormal(normal)
        var normalReader = SourceBitReader(
            bytes: normalWriter.writtenBytes,
            bitCount: normalWriter.bitsWritten
        )
        let decoded = normalReader.readVectorNormal()
        XCTAssertEqual(
            decoded.x,
            Float(Int(0.6 * Float(SourceNetworkEncodingConstants.normalDenominator))) /
                Float(SourceNetworkEncodingConstants.normalDenominator),
            accuracy: 0.000_001
        )
        XCTAssertEqual(decoded.y, 0)
        XCTAssertEqual(decoded.z, -0.8, accuracy: 0.001)

        var angleWriter = SourceBitWriter(byteCapacity: 2)
        angleWriter.writeAngle(359, bitCount: 9)
        var angleReader = SourceBitReader(
            bytes: angleWriter.writtenBytes,
            bitCount: angleWriter.bitsWritten
        )
        XCTAssertEqual(
            angleReader.readAngle(bitCount: 9),
            Float(Int((359.0 / 360.0) * 512.0)) * (360.0 / 512.0),
            accuracy: 0.000_001
        )
    }

    func testNetChannelChokeTransmitReceiveAndStaleOrdering() {
        var state = SourceNetChannelSequenceState()
        state.setChoked()
        state.setChoked()

        XCTAssertEqual(state.outgoingSequenceNumber, 3)
        XCTAssertEqual(state.chokedPacketCount, 2)

        let sent = state.beginTransmit()
        XCTAssertEqual(
            sent,
            SourceOutgoingSequenceStamp(
                sequenceNumber: 3,
                acknowledgedIncomingSequence: 0,
                chokedPacketCount: 2
            )
        )
        XCTAssertEqual(state.outgoingSequenceNumber, 4)
        XCTAssertEqual(state.chokedPacketCount, 0)

        XCTAssertEqual(
            state.receive(sequenceNumber: 5, acknowledgesOutgoing: 3, chokedPacketCount: 2),
            SourceIncomingSequenceResult(accepted: true, droppedPacketCount: 2)
        )
        XCTAssertEqual(state.incomingSequenceNumber, 5)
        XCTAssertEqual(state.outgoingSequenceAcknowledged, 3)

        XCTAssertEqual(
            state.receive(sequenceNumber: 4, acknowledgesOutgoing: 99, chokedPacketCount: 0),
            SourceIncomingSequenceResult(accepted: false, droppedPacketCount: 0)
        )
        XCTAssertEqual(state.incomingSequenceNumber, 5)
        XCTAssertEqual(state.outgoingSequenceAcknowledged, 3)

        state.setSequenceData(outgoing: 12, incoming: 11, outgoingAcknowledged: 10)
        XCTAssertEqual(state.outgoingSequenceNumber, 12)
        XCTAssertEqual(state.incomingSequenceNumber, 11)
        XCTAssertEqual(state.outgoingSequenceAcknowledged, 10)
    }

    func testUserCommandNumberTickDeltaGoldenAndImplicitIncrement() {
        let baseline = SourceUserCommand(commandNumber: 10, tickCount: 20)

        var implicitWriter = SourceBitWriter(byteCapacity: 1)
        SourceUserCommandNumberCodec.write(
            SourceUserCommand(commandNumber: 11, tickCount: 21),
            from: baseline,
            to: &implicitWriter
        )
        XCTAssertEqual(implicitWriter.bitsWritten, 2)
        XCTAssertEqual(implicitWriter.writtenBytes, [0x00])
        var implicitReader = SourceBitReader(
            bytes: implicitWriter.writtenBytes,
            bitCount: implicitWriter.bitsWritten
        )
        XCTAssertEqual(
            SourceUserCommandNumberCodec.read(from: &implicitReader, baseline: baseline),
            SourceUserCommand(commandNumber: 11, tickCount: 21)
        )

        let richBaseline = SourceUserCommand(
            commandNumber: 20,
            tickCount: 30,
            forwardMove: 125,
            buttons: [.attack, .jump],
            hasBeenPredicted: true
        )
        var richReader = SourceBitReader(bytes: [0], bitCount: 2)
        var richExpected = richBaseline
        richExpected.commandNumber = 21
        richExpected.tickCount = 31
        XCTAssertEqual(
            SourceUserCommandNumberCodec.read(from: &richReader, baseline: richBaseline),
            richExpected,
            "ReadUsercmd begins from a field-for-field copy of its baseline"
        )

        var explicitWriter = SourceBitWriter(byteCapacity: 12)
        SourceUserCommandNumberCodec.write(
            SourceUserCommand(commandNumber: 12, tickCount: 25),
            from: baseline,
            to: &explicitWriter
        )
        XCTAssertEqual(explicitWriter.bitsWritten, 66)
        XCTAssertEqual(
            explicitWriter.writtenBytes,
            [0x19, 0, 0, 0, 0x66, 0, 0, 0, 0]
        )
        var explicitReader = SourceBitReader(
            bytes: explicitWriter.writtenBytes,
            bitCount: explicitWriter.bitsWritten
        )
        XCTAssertEqual(
            SourceUserCommandNumberCodec.read(from: &explicitReader, baseline: baseline),
            SourceUserCommand(commandNumber: 12, tickCount: 25)
        )
    }

    func testNinetySlotUserCommandRingRejectsOverwrittenSequence() {
        var history = SourceUserCommandHistory()
        history.store(SourceUserCommand(commandNumber: 0, tickCount: 100))
        XCTAssertEqual(history.command(number: 0)?.tickCount, 100)

        history.store(SourceUserCommand(commandNumber: 90, tickCount: 190))
        XCTAssertNil(history.command(number: 0))
        XCTAssertEqual(history.command(number: 90)?.tickCount, 190)
        XCTAssertNil(history.command(number: -1))
    }

    func testPredictionAcknowledgementRollsBackAndReplaysInCommandOrder() {
        var kernel = SourcePredictionKernel<Int>(initialState: 0)
        for number in Int32(1)...Int32(3) {
            kernel.submit(SourceUserCommand(commandNumber: number, tickCount: 100 + number))
        }

        let first = kernel.acknowledgeAndReplay(
            acknowledged: 0,
            authoritativeState: 0,
            outgoingCommandNumber: 3
        ) { state, command, isFirstTime in
            XCTAssertTrue(isFirstTime)
            state += Int(command.commandNumber)
        }
        XCTAssertEqual(first.executedCommandNumbers, [1, 2, 3])
        XCTAssertEqual(first.firstTimePredictionFlags, [true, true, true])
        XCTAssertEqual(first.state, 6)
        XCTAssertEqual(kernel.predictedFrame(commandNumber: 2)?.state, 3)

        var replayOrder: [Int32] = []
        let corrected = kernel.acknowledgeAndReplay(
            acknowledged: 1,
            authoritativeState: 10,
            outgoingCommandNumber: 3
        ) { state, command, isFirstTime in
            XCTAssertFalse(isFirstTime)
            replayOrder.append(command.commandNumber)
            state += Int(command.commandNumber)
        }
        XCTAssertEqual(replayOrder, [2, 3])
        XCTAssertEqual(corrected.firstTimePredictionFlags, [false, false])
        XCTAssertEqual(corrected.state, 15)
        XCTAssertNil(kernel.predictedFrame(commandNumber: 1))
        XCTAssertEqual(kernel.predictedFrame(commandNumber: 3)?.state, 15)

        let missing = kernel.acknowledgeAndReplay(
            acknowledged: 2,
            authoritativeState: 20,
            outgoingCommandNumber: 4
        ) { state, command, _ in
            state += Int(command.commandNumber)
        }
        XCTAssertEqual(missing.executedCommandNumbers, [3])
        XCTAssertEqual(missing.stoppedAtMissingCommand, 4)
        XCTAssertEqual(missing.state, 23)
    }

    func testPredictionStopsAtSDKBackupBoundary() {
        var kernel = SourcePredictionKernel<Int>(initialState: 0)
        for number in Int32(1)...Int32(90) {
            kernel.submit(SourceUserCommand(commandNumber: number, tickCount: number))
        }

        let replay = kernel.acknowledgeAndReplay(
            acknowledged: 0,
            authoritativeState: 0,
            outgoingCommandNumber: 90
        ) { state, _, _ in
            state += 1
        }

        XCTAssertEqual(replay.executedCommandNumbers.first, 1)
        XCTAssertEqual(replay.executedCommandNumbers.last, 89)
        XCTAssertEqual(replay.executedCommandNumbers.count, 89)
        XCTAssertTrue(replay.reachedBackupLimit)
        XCTAssertNil(replay.stoppedAtMissingCommand)
    }

    func testPredictionPlannerPreservesSourceOptimizationBranches() {
        XCTAssertEqual(
            SourcePredictionPlanner.computeFirstCommandToExecute(
                receivedNewWorldUpdate: false,
                incomingAcknowledged: 10,
                outgoingCommand: 15,
                commandsPredicted: 3,
                serverCommandsAcknowledged: 0,
                previousAcknowledgementHadErrors: false,
                optimizationLevel: 2
            ),
            SourcePredictionStartDecision(
                destinationSlot: 4,
                skipAhead: 3,
                restorePredictedFrame: 2,
                shiftedAcknowledgedSlots: 0,
                mode: .reuseWithoutNewAcknowledgement
            )
        )

        XCTAssertEqual(
            SourcePredictionPlanner.computeFirstCommandToExecute(
                receivedNewWorldUpdate: true,
                incomingAcknowledged: 10,
                outgoingCommand: 15,
                commandsPredicted: 5,
                serverCommandsAcknowledged: 2,
                previousAcknowledgementHadErrors: false,
                optimizationLevel: 2
            ),
            SourcePredictionStartDecision(
                destinationSlot: 4,
                skipAhead: 3,
                restorePredictedFrame: 4,
                shiftedAcknowledgedSlots: 2,
                mode: .shiftAcknowledgedPredictions
            )
        )

        XCTAssertEqual(
            SourcePredictionPlanner.computeFirstCommandToExecute(
                receivedNewWorldUpdate: true,
                incomingAcknowledged: 10,
                outgoingCommand: 15,
                commandsPredicted: 5,
                serverCommandsAcknowledged: 2,
                previousAcknowledgementHadErrors: true,
                optimizationLevel: 2
            ).mode,
            .replayFromAuthoritativeState
        )
    }
}

import Foundation

/// Network scalar sizes used by Source 1's legacy `bf_write`/`bf_read`
/// codecs. Values are cross-checked against Source SDK 2013
/// `public/coordsize.h` at commit c8f4c6351162fbff83bfa5a428d45d1e6eed3824.
public enum SourceNetworkEncodingConstants {
    public static let coordinateIntegerBits = 14
    public static let coordinateFractionalBits = 5
    public static let coordinateDenominator = 1 << coordinateFractionalBits
    public static let coordinateResolution = Float(1) / Float(coordinateDenominator)

    public static let normalFractionalBits = 11
    public static let normalDenominator = (1 << normalFractionalBits) - 1
    public static let normalResolution = Float(1) / Float(normalDenominator)

    /// `MULTIPLAYER_BACKUP` from `game/client/c_baseentity.h`.
    public static let multiplayerBackup = 90
}

/// LSB-first bit writer matching the externally relevant behavior of Source
/// 1's `bf_write`.
///
/// Multi-bit fields are atomic: when a field does not fit, Source advances the
/// cursor to the end, sets the overflow flag, and writes none of that field.
/// Composite routines such as varints still can contain earlier complete
/// fields when a later byte overflows.
public struct SourceBitWriter: Sendable {
    private var storage: [UInt8]

    public let bitCapacity: Int
    public private(set) var bitPosition: Int
    public private(set) var isOverflowed: Bool

    public init(byteCapacity: Int, bitCapacity: Int? = nil) {
        precondition(byteCapacity >= 0, "bf_write byte capacity cannot be negative")
        let requestedBits = bitCapacity ?? byteCapacity * 8
        precondition(
            requestedBits >= 0 && requestedBits <= byteCapacity * 8,
            "bf_write bit capacity must fit inside its byte storage"
        )

        storage = Array(repeating: 0, count: byteCapacity)
        self.bitCapacity = requestedBits
        bitPosition = 0
        isOverflowed = false
    }

    /// The whole backing buffer, including unused zero padding.
    public var bytes: [UInt8] { storage }

    /// The byte prefix touched by the current bit cursor.
    public var writtenBytes: [UInt8] {
        Array(storage.prefix((bitPosition + 7) / 8))
    }

    public var bitsWritten: Int { bitPosition }
    public var bitsLeft: Int { bitCapacity - bitPosition }

    public mutating func reset() {
        bitPosition = 0
        isOverflowed = false
    }

    public mutating func writeBit(_ value: Bool) {
        guard bitPosition < bitCapacity else {
            isOverflowed = true
            return
        }

        let byteIndex = bitPosition >> 3
        let bitMask = UInt8(1 << (bitPosition & 7))
        if value {
            storage[byteIndex] |= bitMask
        } else {
            storage[byteIndex] &= ~bitMask
        }
        bitPosition += 1
    }

    /// Appends the `bitCount` least-significant bits, least-significant bit
    /// first, as `bf_write::WriteUBitLong` does on Source's wire format.
    public mutating func writeUnsigned(_ value: UInt32, bitCount: Int) {
        precondition((1...32).contains(bitCount), "Source unsigned fields use 1...32 bits")
        guard reserveAtomicField(bitCount) else { return }

        for bit in 0..<bitCount {
            writeBitUnchecked(((value >> UInt32(bit)) & 1) != 0)
        }
    }

    /// Writes the low two's-complement bits used by
    /// `bf_write::WriteSBitLong`. Source's debug build diagnoses values that
    /// do not fit, but its release wire operation still writes these low bits.
    public mutating func writeSigned(_ value: Int32, bitCount: Int) {
        precondition((1...32).contains(bitCount), "Source signed fields use 1...32 bits")
        writeUnsigned(UInt32(bitPattern: value), bitCount: bitCount)
    }

    public mutating func writeFloat(_ value: Float) {
        writeUnsigned(value.bitPattern, bitCount: 32)
    }

    public mutating func writeBytes<S: Sequence>(_ values: S) where S.Element == UInt8 {
        for byte in values {
            writeUnsigned(UInt32(byte), bitCount: 8)
        }
    }

    public mutating func writeVarUInt32(_ value: UInt32) {
        var remainder = value
        while remainder > 0x7f {
            writeUnsigned((remainder & 0x7f) | 0x80, bitCount: 8)
            remainder >>= 7
        }
        writeUnsigned(remainder & 0x7f, bitCount: 8)
    }

    public mutating func writeVarUInt64(_ value: UInt64) {
        var remainder = value
        while remainder > 0x7f {
            writeUnsigned(UInt32((remainder & 0x7f) | 0x80), bitCount: 8)
            remainder >>= 7
        }
        writeUnsigned(UInt32(remainder & 0x7f), bitCount: 8)
    }

    public mutating func writeVarInt32(_ value: Int32) {
        let sign = UInt32(bitPattern: value >> 31)
        writeVarUInt32((UInt32(bitPattern: value) << 1) ^ sign)
    }

    public mutating func writeVarInt64(_ value: Int64) {
        let sign = UInt64(bitPattern: value >> 63)
        writeVarUInt64((UInt64(bitPattern: value) << 1) ^ sign)
    }

    /// Writes UTF-8 bytes followed by Source's required NUL terminator.
    /// An embedded NUL has C-string semantics and ends the value immediately.
    public mutating func writeCString(_ value: String?) {
        guard let value else {
            writeUnsigned(0, bitCount: 8)
            return
        }

        for byte in value.utf8 {
            writeUnsigned(UInt32(byte), bitCount: 8)
            if byte == 0 { return }
        }
        writeUnsigned(0, bitCount: 8)
    }

    /// Source's `WriteBitAngle`: quantize by truncating toward zero, then mask
    /// so negative and greater-than-360 angles wrap on the encoded circle.
    public mutating func writeAngle(_ angle: Float, bitCount: Int) {
        precondition((1...31).contains(bitCount), "Source angle fields use 1...31 bits")
        precondition(angle.isFinite, "Source angle codec requires a finite value")

        let shift = UInt32(1) << UInt32(bitCount)
        let quantized = Int64((Double(angle) / 360.0) * Double(shift))
        let encoded = UInt32(truncatingIfNeeded: quantized) & (shift - 1)
        writeUnsigned(encoded, bitCount: bitCount)
    }

    /// Source's non-MP `WriteBitCoord` representation (14 integer bits and
    /// 5 fractional bits, each presence-gated).
    public mutating func writeCoordinate(_ value: Float) {
        precondition(value.isFinite, "Source coordinate codec requires a finite value")

        var integer = Int(abs(value))
        let fraction = abs(Int(value * Float(SourceNetworkEncodingConstants.coordinateDenominator))) &
            (SourceNetworkEncodingConstants.coordinateDenominator - 1)
        let hasInteger = integer != 0
        let hasFraction = fraction != 0

        writeBit(hasInteger)
        writeBit(hasFraction)
        guard hasInteger || hasFraction else { return }

        writeBit(value <= -SourceNetworkEncodingConstants.coordinateResolution)
        if hasInteger {
            integer -= 1
            writeUnsigned(
                UInt32(truncatingIfNeeded: integer),
                bitCount: SourceNetworkEncodingConstants.coordinateIntegerBits
            )
        }
        if hasFraction {
            writeUnsigned(
                UInt32(fraction),
                bitCount: SourceNetworkEncodingConstants.coordinateFractionalBits
            )
        }
    }

    public mutating func writeVectorCoordinate(_ value: SourceVector3) {
        let threshold = SourceNetworkEncodingConstants.coordinateResolution
        let hasX = value.x >= threshold || value.x <= -threshold
        let hasY = value.y >= threshold || value.y <= -threshold
        let hasZ = value.z >= threshold || value.z <= -threshold

        writeBit(hasX)
        writeBit(hasY)
        writeBit(hasZ)
        if hasX { writeCoordinate(value.x) }
        if hasY { writeCoordinate(value.y) }
        if hasZ { writeCoordinate(value.z) }
    }

    public mutating func writeNormal(_ value: Float) {
        precondition(value.isFinite, "Source normal codec requires a finite value")

        writeBit(value <= -SourceNetworkEncodingConstants.normalResolution)
        let scaled = abs(Int(value * Float(SourceNetworkEncodingConstants.normalDenominator)))
        let clamped = min(scaled, SourceNetworkEncodingConstants.normalDenominator)
        writeUnsigned(
            UInt32(clamped),
            bitCount: SourceNetworkEncodingConstants.normalFractionalBits
        )
    }

    public mutating func writeVectorNormal(_ value: SourceVector3) {
        let threshold = SourceNetworkEncodingConstants.normalResolution
        let hasX = value.x >= threshold || value.x <= -threshold
        let hasY = value.y >= threshold || value.y <= -threshold

        writeBit(hasX)
        writeBit(hasY)
        if hasX { writeNormal(value.x) }
        if hasY { writeNormal(value.y) }
        writeBit(value.z <= -threshold)
    }

    private mutating func reserveAtomicField(_ count: Int) -> Bool {
        guard bitPosition + count <= bitCapacity else {
            bitPosition = bitCapacity
            isOverflowed = true
            return false
        }
        return true
    }

    private mutating func writeBitUnchecked(_ value: Bool) {
        let byteIndex = bitPosition >> 3
        let bitMask = UInt8(1 << (bitPosition & 7))
        if value {
            storage[byteIndex] |= bitMask
        } else {
            storage[byteIndex] &= ~bitMask
        }
        bitPosition += 1
    }
}

public struct SourceCStringReadResult: Equatable, Sendable {
    public let bytes: [UInt8]
    public let wasTerminated: Bool
    public let wasTruncated: Bool

    public var string: String { String(decoding: bytes, as: UTF8.self) }
    public var isSuccessful: Bool { wasTerminated && !wasTruncated }
}

/// LSB-first reader with Source `bf_read` overrun behavior: an overlong field
/// returns zero, moves the cursor to the end, and leaves overflow sticky.
public struct SourceBitReader: Sendable {
    private let storage: [UInt8]

    public let bitCount: Int
    public private(set) var bitPosition: Int
    public private(set) var isOverflowed: Bool

    public init(bytes: [UInt8], bitCount: Int? = nil) {
        let readableBits = bitCount ?? bytes.count * 8
        precondition(
            readableBits >= 0 && readableBits <= bytes.count * 8,
            "bf_read bit count must fit inside its byte storage"
        )

        storage = bytes
        self.bitCount = readableBits
        bitPosition = 0
        isOverflowed = false
    }

    public var bitsRead: Int { bitPosition }
    public var bitsLeft: Int { bitCount - bitPosition }

    public mutating func reset() {
        bitPosition = 0
        isOverflowed = false
    }

    public mutating func seek(toBit position: Int) -> Bool {
        guard position >= 0 && position <= bitCount else {
            bitPosition = bitCount
            isOverflowed = true
            return false
        }
        bitPosition = position
        return true
    }

    public mutating func readBit() -> Bool {
        guard bitPosition < bitCount else {
            isOverflowed = true
            return false
        }

        let value = ((storage[bitPosition >> 3] >> UInt8(bitPosition & 7)) & 1) != 0
        bitPosition += 1
        return value
    }

    public mutating func readUnsigned(bitCount fieldBits: Int) -> UInt32 {
        precondition((1...32).contains(fieldBits), "Source unsigned fields use 1...32 bits")
        guard bitPosition + fieldBits <= bitCount else {
            bitPosition = bitCount
            isOverflowed = true
            return 0
        }

        var value: UInt32 = 0
        for bit in 0..<fieldBits {
            let sourcePosition = bitPosition + bit
            let sourceBit = (storage[sourcePosition >> 3] >> UInt8(sourcePosition & 7)) & 1
            value |= UInt32(sourceBit) << UInt32(bit)
        }
        bitPosition += fieldBits
        return value
    }

    public mutating func readSigned(bitCount fieldBits: Int) -> Int32 {
        precondition((1...32).contains(fieldBits), "Source signed fields use 1...32 bits")
        let raw = readUnsigned(bitCount: fieldBits)
        guard fieldBits < 32 else { return Int32(bitPattern: raw) }

        let signBit = UInt32(1) << UInt32(fieldBits - 1)
        guard (raw & signBit) != 0 else { return Int32(raw) }
        let fieldMask = (UInt32(1) << UInt32(fieldBits)) - 1
        return Int32(bitPattern: raw | ~fieldMask)
    }

    public mutating func readFloat() -> Float {
        Float(bitPattern: readUnsigned(bitCount: 32))
    }

    public mutating func readBytes(count: Int) -> [UInt8] {
        precondition(count >= 0, "Source byte read count cannot be negative")
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(UInt8(truncatingIfNeeded: readUnsigned(bitCount: 8)))
        }
        return result
    }

    public mutating func readVarUInt32() -> UInt32 {
        var result: UInt32 = 0
        var count = 0
        while true {
            // This check occurs before a sixth byte in Source. A five-byte
            // continuation therefore returns the accumulated low 32 bits
            // without consuming another byte.
            if count == 5 { return result }
            let byte = readUnsigned(bitCount: 8)
            result |= (byte & 0x7f) &<< UInt32(7 * count)
            count += 1
            if (byte & 0x80) == 0 { return result }
        }
    }

    public mutating func readVarUInt64() -> UInt64 {
        var result: UInt64 = 0
        var count = 0
        while true {
            if count == 10 { return result }
            let byte = UInt64(readUnsigned(bitCount: 8))
            result |= (byte & 0x7f) &<< UInt64(7 * count)
            count += 1
            if (byte & 0x80) == 0 { return result }
        }
    }

    public mutating func readVarInt32() -> Int32 {
        let encoded = readVarUInt32()
        let signMask = UInt32(0) &- (encoded & 1)
        return Int32(bitPattern: (encoded >> 1) ^ signMask)
    }

    public mutating func readVarInt64() -> Int64 {
        let encoded = readVarUInt64()
        let signMask = UInt64(0) &- (encoded & 1)
        return Int64(bitPattern: (encoded >> 1) ^ signMask)
    }

    /// Reads and consumes a full NUL-terminated byte string. As in Source,
    /// `maxLength` includes the terminator: excess bytes are discarded until
    /// NUL and reported as truncation rather than left in the bit stream.
    public mutating func readCString(maxLength: Int) -> SourceCStringReadResult {
        precondition(maxLength > 0, "Source ReadString requires nonzero output capacity")

        var result: [UInt8] = []
        result.reserveCapacity(maxLength - 1)
        var truncated = false

        while true {
            let byte = UInt8(truncatingIfNeeded: readUnsigned(bitCount: 8))
            if byte == 0 {
                return SourceCStringReadResult(
                    bytes: result,
                    wasTerminated: !isOverflowed,
                    wasTruncated: truncated
                )
            }
            if result.count < maxLength - 1 {
                result.append(byte)
            } else {
                truncated = true
            }
        }
    }

    public mutating func readAngle(bitCount angleBits: Int) -> Float {
        precondition((1...31).contains(angleBits), "Source angle fields use 1...31 bits")
        let shift = UInt32(1) << UInt32(angleBits)
        return Float(readUnsigned(bitCount: angleBits)) * (360 / Float(shift))
    }

    public mutating func readCoordinate() -> Float {
        let hasInteger = readBit()
        let hasFraction = readBit()
        guard hasInteger || hasFraction else { return 0 }

        let isNegative = readBit()
        let integer = hasInteger
            ? Int(readUnsigned(bitCount: SourceNetworkEncodingConstants.coordinateIntegerBits)) + 1
            : 0
        let fraction = hasFraction
            ? Int(readUnsigned(bitCount: SourceNetworkEncodingConstants.coordinateFractionalBits))
            : 0
        var value = Float(integer) +
            Float(fraction) * SourceNetworkEncodingConstants.coordinateResolution
        if isNegative { value = -value }
        return value
    }

    public mutating func readVectorCoordinate() -> SourceVector3 {
        let hasX = readBit()
        let hasY = readBit()
        let hasZ = readBit()
        return SourceVector3(
            hasX ? readCoordinate() : 0,
            hasY ? readCoordinate() : 0,
            hasZ ? readCoordinate() : 0
        )
    }

    public mutating func readNormal() -> Float {
        let isNegative = readBit()
        let fraction = readUnsigned(bitCount: SourceNetworkEncodingConstants.normalFractionalBits)
        var value = Float(fraction) * SourceNetworkEncodingConstants.normalResolution
        if isNegative { value = -value }
        return value
    }

    public mutating func readVectorNormal() -> SourceVector3 {
        let hasX = readBit()
        let hasY = readBit()
        let x = hasX ? readNormal() : 0
        let y = hasY ? readNormal() : 0
        let negativeZ = readBit()

        let xyLengthSquared = x * x + y * y
        var z = xyLengthSquared < 1 ? (1 - xyLengthSquared).squareRoot() : 0
        if negativeZ { z = -z }
        return SourceVector3(x, y, z)
    }
}

/// Sequence values exposed by `INetChannel::GetSequenceData` plus the pending
/// choke count maintained by `net_chan`. This deliberately does not invent a
/// GMod packet payload or reliability layer.
public struct SourceNetChannelSequenceState: Equatable, Sendable {
    public private(set) var outgoingSequenceNumber: Int32
    public private(set) var incomingSequenceNumber: Int32
    public private(set) var outgoingSequenceAcknowledged: Int32
    public private(set) var chokedPacketCount: Int

    public init(
        outgoingSequenceNumber: Int32 = 1,
        incomingSequenceNumber: Int32 = 0,
        outgoingSequenceAcknowledged: Int32 = 0,
        chokedPacketCount: Int = 0
    ) {
        precondition(chokedPacketCount >= 0, "choked packet count cannot be negative")
        self.outgoingSequenceNumber = outgoingSequenceNumber
        self.incomingSequenceNumber = incomingSequenceNumber
        self.outgoingSequenceAcknowledged = outgoingSequenceAcknowledged
        self.chokedPacketCount = chokedPacketCount
    }

    /// Mirrors `CNetChan::SetChoked`: a deliberately unsent datagram consumes
    /// an outgoing sequence number and is reported by the next transmission.
    public mutating func setChoked() {
        outgoingSequenceNumber &+= 1
        chokedPacketCount += 1
    }

    /// Reserves the sequence stamp for the datagram being transmitted, then
    /// advances the outgoing sequence and clears the accumulated choke count.
    public mutating func beginTransmit() -> SourceOutgoingSequenceStamp {
        let stamp = SourceOutgoingSequenceStamp(
            sequenceNumber: outgoingSequenceNumber,
            acknowledgedIncomingSequence: incomingSequenceNumber,
            chokedPacketCount: chokedPacketCount
        )
        outgoingSequenceNumber &+= 1
        chokedPacketCount = 0
        return stamp
    }

    /// Applies only the sequence/ack/choke header state. Duplicate or stale
    /// incoming sequences are rejected without mutating acknowledgement state.
    @discardableResult
    public mutating func receive(
        sequenceNumber: Int32,
        acknowledgesOutgoing sequenceAcknowledgement: Int32,
        chokedPacketCount remoteChokedPackets: Int
    ) -> SourceIncomingSequenceResult {
        precondition(remoteChokedPackets >= 0, "remote choke count cannot be negative")

        guard sequenceNumber > incomingSequenceNumber else {
            return SourceIncomingSequenceResult(accepted: false, droppedPacketCount: 0)
        }

        let expected = Int64(incomingSequenceNumber) + Int64(remoteChokedPackets) + 1
        let dropped = max(Int64(0), Int64(sequenceNumber) - expected)
        incomingSequenceNumber = sequenceNumber
        outgoingSequenceAcknowledged = sequenceAcknowledgement
        return SourceIncomingSequenceResult(
            accepted: true,
            droppedPacketCount: Int(clamping: dropped)
        )
    }

    /// `INetChannel::SetSequenceData` compatibility boundary.
    public mutating func setSequenceData(
        outgoing: Int32,
        incoming: Int32,
        outgoingAcknowledged: Int32
    ) {
        outgoingSequenceNumber = outgoing
        incomingSequenceNumber = incoming
        outgoingSequenceAcknowledged = outgoingAcknowledged
    }
}

public struct SourceOutgoingSequenceStamp: Equatable, Sendable {
    public let sequenceNumber: Int32
    public let acknowledgedIncomingSequence: Int32
    public let chokedPacketCount: Int
}

public struct SourceIncomingSequenceResult: Equatable, Sendable {
    public let accepted: Bool
    public let droppedPacketCount: Int
}

/// The first two fields of SDK `WriteUsercmd`/`ReadUsercmd`. The zero flag
/// means implicit `from + 1`; a one flag is followed by the full 32-bit value.
public enum SourceUserCommandNumberCodec {
    public static func write(
        _ command: SourceUserCommand,
        from baseline: SourceUserCommand,
        to writer: inout SourceBitWriter
    ) {
        let commandIsExplicit = command.commandNumber != baseline.commandNumber &+ 1
        writer.writeBit(commandIsExplicit)
        if commandIsExplicit {
            writer.writeUnsigned(UInt32(bitPattern: command.commandNumber), bitCount: 32)
        }

        let tickIsExplicit = command.tickCount != baseline.tickCount &+ 1
        writer.writeBit(tickIsExplicit)
        if tickIsExplicit {
            writer.writeUnsigned(UInt32(bitPattern: command.tickCount), bitCount: 32)
        }
    }

    public static func read(
        from reader: inout SourceBitReader,
        baseline: SourceUserCommand
    ) -> SourceUserCommand {
        var command = baseline
        command.commandNumber = reader.readBit()
            ? Int32(bitPattern: reader.readUnsigned(bitCount: 32))
            : baseline.commandNumber &+ 1
        command.tickCount = reader.readBit()
            ? Int32(bitPattern: reader.readUnsigned(bitCount: 32))
            : baseline.tickCount &+ 1
        return command
    }
}

/// Exact 90-slot command ring used by `CInput`. Lookup validates the stored
/// command number so an overwritten slot is reported missing rather than
/// returning a newer command at the same modulo index.
public struct SourceUserCommandHistory: Sendable {
    private var slots: [SourceUserCommand?]

    public init() {
        slots = Array(repeating: nil, count: SourceNetworkEncodingConstants.multiplayerBackup)
    }

    public mutating func store(_ command: SourceUserCommand) {
        precondition(command.commandNumber >= 0, "Source command ring requires a nonnegative sequence")
        slots[slotIndex(for: command.commandNumber)] = command
    }

    public func command(number: Int32) -> SourceUserCommand? {
        guard number >= 0 else { return nil }
        let command = slots[slotIndex(for: number)]
        return command?.commandNumber == number ? command : nil
    }

    private func slotIndex(for number: Int32) -> Int {
        Int(number) % SourceNetworkEncodingConstants.multiplayerBackup
    }
}

public struct SourcePredictionFrame<State> {
    public let command: SourceUserCommand
    public let state: State
    public let wasFirstTimePredicted: Bool
}

public struct SourcePredictionReplay<State> {
    public let state: State
    public let executedCommandNumbers: [Int32]
    public let firstTimePredictionFlags: [Bool]
    public let stoppedAtMissingCommand: Int32?
    public let reachedBackupLimit: Bool
}

/// A deterministic first prediction kernel around the SDK's command ring and
/// acknowledgement boundary. A server acknowledgement rolls state back to the
/// supplied authoritative snapshot, then replays still-unacknowledged commands
/// in ascending command-number order. Previously executed commands retain
/// `hasbeenpredicted`, making replay callbacks non-first-time like Source.
public struct SourcePredictionKernel<State> {
    public private(set) var commands: SourceUserCommandHistory
    public private(set) var acknowledgedCommandNumber: Int32
    public private(set) var predictedState: State

    private var frames: [SourcePredictionFrame<State>?]

    public init(initialState: State, acknowledgedCommandNumber: Int32 = 0) {
        commands = SourceUserCommandHistory()
        self.acknowledgedCommandNumber = acknowledgedCommandNumber
        predictedState = initialState
        frames = Array(repeating: nil, count: SourceNetworkEncodingConstants.multiplayerBackup)
    }

    public mutating func submit(_ command: SourceUserCommand) {
        commands.store(command)
    }

    public func predictedFrame(commandNumber: Int32) -> SourcePredictionFrame<State>? {
        guard commandNumber >= 0 else { return nil }
        let frame = frames[Int(commandNumber) % SourceNetworkEncodingConstants.multiplayerBackup]
        return frame?.command.commandNumber == commandNumber ? frame : nil
    }

    /// Reconciles one authoritative update and replays at most the command
    /// indices Source's `PerformPrediction` permits (`i` 1 through 89).
    @discardableResult
    public mutating func acknowledgeAndReplay(
        acknowledged newAcknowledgement: Int32,
        authoritativeState: State,
        outgoingCommandNumber: Int32,
        simulate: (inout State, SourceUserCommand, Bool) -> Void
    ) -> SourcePredictionReplay<State> {
        acknowledgedCommandNumber = newAcknowledgement
        invalidateFrames(through: newAcknowledgement)

        var replayState = authoritativeState
        var executed: [Int32] = []
        var firstTimeFlags: [Bool] = []
        var missing: Int32?
        var reachedLimit = false
        var predictionIndex = 1
        var commandNumber = newAcknowledgement &+ 1

        while commandNumber <= outgoingCommandNumber {
            if predictionIndex >= SourceNetworkEncodingConstants.multiplayerBackup {
                reachedLimit = true
                break
            }
            guard var command = commands.command(number: commandNumber) else {
                missing = commandNumber
                break
            }

            let isFirstTime = !command.hasBeenPredicted
            simulate(&replayState, command, isFirstTime)
            command.hasBeenPredicted = true
            commands.store(command)

            frames[Int(commandNumber) % SourceNetworkEncodingConstants.multiplayerBackup] =
                SourcePredictionFrame(
                    command: command,
                    state: replayState,
                    wasFirstTimePredicted: isFirstTime
                )
            executed.append(commandNumber)
            firstTimeFlags.append(isFirstTime)
            predictionIndex += 1
            commandNumber &+= 1
        }

        predictedState = replayState
        return SourcePredictionReplay(
            state: replayState,
            executedCommandNumbers: executed,
            firstTimePredictionFlags: firstTimeFlags,
            stoppedAtMissingCommand: missing,
            reachedBackupLimit: reachedLimit
        )
    }

    private mutating func invalidateFrames(through acknowledgement: Int32) {
        for index in frames.indices {
            if let frame = frames[index], frame.command.commandNumber <= acknowledgement {
                frames[index] = nil
            }
        }
    }
}

public enum SourcePredictionStartMode: Equatable, Sendable {
    case reuseWithoutNewAcknowledgement
    case shiftAcknowledgedPredictions
    case replayFromAuthoritativeState
}

public struct SourcePredictionStartDecision: Equatable, Sendable {
    public let destinationSlot: Int
    public let skipAhead: Int
    public let restorePredictedFrame: Int?
    public let shiftedAcknowledgedSlots: Int
    public let mode: SourcePredictionStartMode
}

/// Pure form of SDK `CPrediction::ComputeFirstCommandToExecute`, kept separate
/// from state replay so its optimization ordering is directly testable.
public enum SourcePredictionPlanner {
    public static func computeFirstCommandToExecute(
        receivedNewWorldUpdate: Bool,
        incomingAcknowledged: Int,
        outgoingCommand: Int,
        commandsPredicted: Int,
        serverCommandsAcknowledged: Int,
        previousAcknowledgementHadErrors: Bool,
        optimizationLevel: Int
    ) -> SourcePredictionStartDecision {
        if !receivedNewWorldUpdate || serverCommandsAcknowledged == 0 {
            let normalStart = incomingAcknowledged + 1
            let desiredSkip = max(0, outgoingCommand - normalStart)
            let skipAhead = min(desiredSkip, commandsPredicted)
            return SourcePredictionStartDecision(
                destinationSlot: 1 + skipAhead,
                skipAhead: skipAhead,
                restorePredictedFrame: skipAhead - 1,
                shiftedAcknowledgedSlots: 0,
                mode: .reuseWithoutNewAcknowledgement
            )
        }

        if optimizationLevel >= 2,
           !previousAcknowledgementHadErrors,
           commandsPredicted > 0,
           serverCommandsAcknowledged <= commandsPredicted {
            let skipAhead = commandsPredicted - serverCommandsAcknowledged
            return SourcePredictionStartDecision(
                destinationSlot: 1 + skipAhead,
                skipAhead: skipAhead,
                restorePredictedFrame: commandsPredicted - 1,
                shiftedAcknowledgedSlots: serverCommandsAcknowledged,
                mode: .shiftAcknowledgedPredictions
            )
        }

        return SourcePredictionStartDecision(
            destinationSlot: 1,
            skipAhead: 0,
            restorePredictedFrame: nil,
            shiftedAcknowledgedSlots: 0,
            mode: .replayFromAuthoritativeState
        )
    }
}

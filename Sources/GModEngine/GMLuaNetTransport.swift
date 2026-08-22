import Foundation
import GModLua

private struct GMLuaNetBitBuffer: Sendable {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    mutating func appendBit(_ value: Bool) {
        let byteIndex = bitCount / 8
        let bitIndex = bitCount % 8
        if byteIndex == bytes.count { bytes.append(0) }
        if value { bytes[byteIndex] |= UInt8(1 << bitIndex) }
        bitCount += 1
    }

    mutating func appendUInt(_ value: UInt64, bitCount requestedBits: Int) {
        for bitIndex in 0..<requestedBits {
            appendBit(((value >> UInt64(bitIndex)) & 1) == 1)
        }
    }

    mutating func append(_ other: GMLuaNetBitBuffer) {
        for bitIndex in 0..<other.bitCount {
            appendBit(other.bit(at: bitIndex))
        }
    }

    func bit(at index: Int) -> Bool {
        let byteIndex = index / 8
        let bitIndex = index % 8
        return ((bytes[byteIndex] >> UInt8(bitIndex)) & 1) == 1
    }
}

private struct GMLuaNetBitReader {
    let buffer: GMLuaNetBitBuffer
    private(set) var position = 0

    var bitsLeft: Int { buffer.bitCount - position }

    mutating func readUInt(bitCount requestedBits: Int, function: String) throws -> UInt64 {
        guard requestedBits <= bitsLeft else {
            throw LuaError.runtime(
                "\(function) tried to read \(requestedBits) bits with only \(bitsLeft) remaining"
            )
        }
        var value: UInt64 = 0
        for bitIndex in 0..<requestedBits {
            if buffer.bit(at: position + bitIndex) {
                value |= UInt64(1) << UInt64(bitIndex)
            }
        }
        position += requestedBits
        return value
    }
}

private struct GMLuaNetWriter {
    let messageID: Int
    let unreliable: Bool
    var payload = GMLuaNetBitBuffer()
}

private struct GMLuaNetPacket: Sendable {
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let senderPlayerIndex: Int?
    let connectionGeneration: UInt64?
    let unreliable: Bool
    let bits: GMLuaNetBitBuffer
}

private struct GMLuaConsolePacket: Sendable {
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let senderPlayerIndex: Int
    let connectionGeneration: UInt64
    let command: String
    let arguments: [String]
}

private struct GMLuaTargetedClientConsolePacket: Sendable {
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let targetPlayerIndex: Int
    let connectionGeneration: UInt64
    let command: String
    let arguments: [String]
}

/// One SERVER `MsgAll` console write for one exact connected CLIENT. The
/// message is already converted with the same GLua printable rules as `Msg`;
/// the destination enters its ordinary local `Msg` surface only at pump time.
private struct GMLuaBroadcastConsoleMessagePacket: Sendable {
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let connectionGeneration: UInt64?
    let message: LuaString
}

private struct GMLuaClientLuaPacket: Sendable {
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let connectionGeneration: UInt64
    let code: LuaString
}

private struct GMLuaEntityReplicationDelivery: Sendable {
    /// Sequence in the transport-wide net/console/entity FIFO. The nested
    /// packet retains its independent per-connection replication sequence.
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let connectionGeneration: UInt64
    let packet: SourceEntityReplicationPacket
}

/// One SERVER engine gameplay event for one exact CLIENT connection. It uses
/// the same outer sequence and generation checks as net, console, SendLua, and
/// canonical Entity replication.
private struct GMLuaGameplayEventPacket: Sendable {
    let sequence: UInt64
    let sourceEndpointID: Int
    let destinationEndpointID: Int
    let connectionGeneration: UInt64?
    let payload: GMLuaGameplayEventPayload
}

/// One member of an atomic SERVER entity-replication fan-out. SharedSession
/// builds the complete batch before any destination receives a FIFO entry.
struct GMLuaEntityReplicationEnqueueRequest: Sendable {
    let packet: SourceEntityReplicationPacket
    let destination: GMLuaNetEndpoint
}

private enum GMLuaTransportDelivery: Sendable {
    case net(GMLuaNetPacket)
    case console(GMLuaConsolePacket)
    case targetedClientConsole(GMLuaTargetedClientConsolePacket)
    case broadcastConsoleMessage(GMLuaBroadcastConsoleMessagePacket)
    case clientLua(GMLuaClientLuaPacket)
    case entity(GMLuaEntityReplicationDelivery)
    case gameplayEvent(GMLuaGameplayEventPacket)

    var sequence: UInt64 {
        switch self {
        case let .net(packet): return packet.sequence
        case let .console(packet): return packet.sequence
        case let .targetedClientConsole(packet): return packet.sequence
        case let .broadcastConsoleMessage(packet): return packet.sequence
        case let .clientLua(packet): return packet.sequence
        case let .entity(delivery): return delivery.sequence
        case let .gameplayEvent(packet): return packet.sequence
        }
    }

    var sourceEndpointID: Int {
        switch self {
        case let .net(packet): return packet.sourceEndpointID
        case let .console(packet): return packet.sourceEndpointID
        case let .targetedClientConsole(packet): return packet.sourceEndpointID
        case let .broadcastConsoleMessage(packet): return packet.sourceEndpointID
        case let .clientLua(packet): return packet.sourceEndpointID
        case let .entity(delivery): return delivery.sourceEndpointID
        case let .gameplayEvent(packet): return packet.sourceEndpointID
        }
    }

    var destinationEndpointID: Int {
        switch self {
        case let .net(packet): return packet.destinationEndpointID
        case let .console(packet): return packet.destinationEndpointID
        case let .targetedClientConsole(packet): return packet.destinationEndpointID
        case let .broadcastConsoleMessage(packet): return packet.destinationEndpointID
        case let .clientLua(packet): return packet.destinationEndpointID
        case let .entity(delivery): return delivery.destinationEndpointID
        case let .gameplayEvent(packet): return packet.destinationEndpointID
        }
    }
}

enum GMLuaNetTransportDeliveryTransactionError: Error, Equatable, Sendable {
    case nestedTransaction
}

/// Current-thread staging owned by one outer forwarded console action. A
/// delivery receives its transport sequence at the original enqueue point but
/// cannot enter the globally visible FIFO until the scope commits.
private final class GMLuaTransportDeliveryTransactionContext: @unchecked Sendable {
    var deliveries: [GMLuaTransportDelivery] = []
    var physicsBodyCommands: [SourcePhysicsCommand] = []
    var completedMessageCount: UInt64 = 0
}

/// Typed failures specific to canonical entity replication transport. Packet
/// validation failures remain values until the CLIENT handler has completed
/// its transactional apply, then cross the pump boundary as this error.
public enum GMLuaEntityReplicationTransportError: Error, Equatable, Sendable {
    case serverSourceRequired
    case clientDestinationRequired
    case sourceEndpointDetached
    case destinationEndpointDetached
    case destinationNotConnected
    case connectionGenerationMismatch(
        expected: SourceEntityReplicationConnectionGeneration,
        received: SourceEntityReplicationConnectionGeneration
    )
    case transportSequenceExhausted
    case clientHandlerUnavailable
    case packetRejected(
        transportSequence: UInt64,
        packetSequence: UInt64,
        rejection: SourceEntityReplicationRejection
    )
}

public typealias GMLuaEntityReplicationHandler = @Sendable (
    SourceEntityReplicationPacket
) throws -> SourceEntityReplicationApplyResult

/// One CLIENT-originated console command that reached the SERVER command
/// surface but had an expected user-action failure: a Lua concommand body
/// failed, the host explicitly rejected it, or no command owner existed.
/// Transport/lifecycle validation, throwing host handlers, and net receiver
/// failures are deliberately not represented by this value.
public struct GMLuaForwardedConsoleCommandFailure: Sendable, Equatable {
    public let sequence: UInt64
    public let command: String
    public let arguments: [String]
    public let message: String

    public init(
        sequence: UInt64,
        command: String,
        arguments: [String],
        message: String
    ) {
        self.sequence = sequence
        self.command = command
        self.arguments = arguments
        self.message = message
    }
}

/// Result of the opt-in pump path used by an interactive host. A failed
/// forwarded command counts as processed (and therefore against the delivery
/// budget) but not as a successful delivery.
public struct GMLuaNetPumpReport: Sendable, Equatable {
    public let processedDeliveries: Int
    public let successfulDeliveries: Int
    public let forwardedConsoleFailures: [GMLuaForwardedConsoleCommandFailure]

    public init(
        processedDeliveries: Int,
        successfulDeliveries: Int,
        forwardedConsoleFailures: [GMLuaForwardedConsoleCommandFailure]
    ) {
        self.processedDeliveries = processedDeliveries
        self.successfulDeliveries = successfulDeliveries
        self.forwardedConsoleFailures = forwardedConsoleFailures
    }
}

/// Realm-local native net binding owned by a ``GMLuaNetTransport`` session.
///
/// Lua retains only native closures. The host session owns packet routing and
/// this endpoint retains no Lua values, so server and client states remain
/// isolated exactly as separate GMod realms are.
public final class GMLuaNetEndpoint: @unchecked Sendable {
    public let realm: GMLuaRealm

    fileprivate let identifier: Int
    fileprivate weak var state: LuaState?
    private weak var transport: GMLuaNetTransport?
    private weak var entityRegistry: GMLuaEntityRegistry?
    private weak var consoleCommandDispatcher: GMLuaConsoleCommandDispatcher?
    private let consoleMessageSink: (LuaString) -> Void
    private let lock = NSLock()
    private var writer: GMLuaNetWriter?
    private var reader: GMLuaNetBitReader?
    private var entityReplicationHandler: GMLuaEntityReplicationHandler?
    private var gameplayEventHandler: GMLuaGameplayEventHandler?

    fileprivate init(
        identifier: Int,
        realm: GMLuaRealm,
        state: LuaState,
        entityRegistry: GMLuaEntityRegistry,
        consoleMessageSink: @escaping (LuaString) -> Void,
        transport: GMLuaNetTransport
    ) {
        self.identifier = identifier
        self.realm = realm
        self.state = state
        self.entityRegistry = entityRegistry
        self.consoleMessageSink = consoleMessageSink
        self.transport = transport
    }

    fileprivate func installBindings(into state: LuaState) throws {
        state.register("__gmod_net_Start") { [unowned self] arguments in
            let name = try self.requiredString(
                arguments.first,
                position: 1,
                function: "net.Start"
            )
            let unreliable: Bool
            if arguments.indices.contains(1), case let .boolean(value) = arguments[1] {
                unreliable = value
            } else if !arguments.indices.contains(1) {
                unreliable = false
            } else if case .nilValue = arguments[1] {
                unreliable = false
            } else {
                throw self.argumentError(
                    arguments[1],
                    position: 2,
                    function: "net.Start",
                    expected: "boolean"
                )
            }
            try self.start(name: name, unreliable: unreliable)
            return [.boolean(true)]
        }

        state.register("__gmod_net_Abort") { [unowned self] _ in
            self.abort()
            return []
        }

        state.register("__gmod_net_WriteBit") { [unowned self] arguments in
            guard let value = arguments.first, case let .boolean(bit) = value else {
                throw self.argumentError(
                    arguments.first,
                    position: 1,
                    function: "net.WriteBit",
                    expected: "boolean"
                )
            }
            try self.writeUInt(bit ? 1 : 0, bitCount: 1, function: "net.WriteBit")
            return []
        }

        state.register("__gmod_net_ReadBit") { [unowned self] _ in
            let bit = try self.readUInt(bitCount: 1, function: "net.ReadBit")
            return [.number(Double(bit))]
        }

        state.register("__gmod_net_WriteUInt") { [unowned self] arguments in
            let bitCount = try self.requiredBitCount(
                arguments.indices.contains(1) ? arguments[1] : nil,
                position: 2,
                function: "net.WriteUInt"
            )
            let value = try self.requiredUnsignedInteger(
                arguments.first,
                bitCount: bitCount,
                function: "net.WriteUInt"
            )
            try self.writeUInt(value, bitCount: bitCount, function: "net.WriteUInt")
            return []
        }

        state.register("__gmod_net_ReadUInt") { [unowned self] arguments in
            let bitCount = try self.requiredBitCount(
                arguments.first,
                position: 1,
                function: "net.ReadUInt"
            )
            let value = try self.readUInt(bitCount: bitCount, function: "net.ReadUInt")
            return [.number(Double(value))]
        }

        state.register("__gmod_net_WriteInt") { [unowned self] arguments in
            let bitCount = try self.requiredBitCount(
                arguments.indices.contains(1) ? arguments[1] : nil,
                position: 2,
                function: "net.WriteInt"
            )
            let value = try self.requiredSignedInteger(
                arguments.first,
                bitCount: bitCount,
                function: "net.WriteInt"
            )
            let mask = bitCount == 32
                ? UInt64(UInt32.max)
                : (UInt64(1) << UInt64(bitCount)) - 1
            let encoded = UInt64(bitPattern: value) & mask
            try self.writeUInt(encoded, bitCount: bitCount, function: "net.WriteInt")
            return []
        }

        state.register("__gmod_net_ReadInt") { [unowned self] arguments in
            let bitCount = try self.requiredBitCount(
                arguments.first,
                position: 1,
                function: "net.ReadInt"
            )
            let encoded = try self.readUInt(bitCount: bitCount, function: "net.ReadInt")
            let signMask = UInt64(1) << UInt64(bitCount - 1)
            let mask = bitCount == 32
                ? UInt64(UInt32.max)
                : (UInt64(1) << UInt64(bitCount)) - 1
            let decoded = encoded & signMask == 0
                ? Int64(encoded)
                : Int64(bitPattern: encoded | ~mask)
            return [.number(Double(decoded))]
        }

        state.register("__gmod_net_WriteFloat") { [unowned self] arguments in
            let number = try self.requiredNumber(
                arguments.first,
                position: 1,
                function: "net.WriteFloat"
            )
            try self.writeUInt(
                UInt64(Float(number).bitPattern),
                bitCount: 32,
                function: "net.WriteFloat"
            )
            return []
        }

        state.register("__gmod_net_ReadFloat") { [unowned self] _ in
            let bits = try self.readUInt(bitCount: 32, function: "net.ReadFloat")
            return [.number(Double(Float(bitPattern: UInt32(bits))))]
        }

        state.register("__gmod_net_WriteString") { [unowned self] arguments in
            let string = try self.requiredLuaString(
                arguments.first,
                position: 1,
                function: "net.WriteString"
            )
            var bytes = Array(string.bytes.prefix { $0 != 0 })
            bytes.append(0)
            try self.writeBytes(bytes, function: "net.WriteString")
            return []
        }

        state.register("__gmod_net_ReadString") { [unowned self] _ in
            [.string(try self.readTerminatedString())]
        }

        state.register("__gmod_net_WriteData") { [unowned self] arguments in
            let data = try self.requiredLuaString(
                arguments.first,
                position: 1,
                function: "net.WriteData"
            )
            let length: Int
            if arguments.indices.contains(1), case .nilValue = arguments[1] {
                length = data.count
            } else if arguments.indices.contains(1) {
                length = try self.requiredByteCount(
                    arguments[1],
                    position: 2,
                    function: "net.WriteData"
                )
            } else {
                length = data.count
            }
            guard length <= data.count else {
                throw LuaError.runtime(
                    "bad argument #2 to 'net.WriteData' (length exceeds binary data size)"
                )
            }
            try self.writeBytes(Array(data.bytes.prefix(length)), function: "net.WriteData")
            return []
        }

        state.register("__gmod_net_ReadData") { [unowned self] arguments in
            let length = try self.requiredByteCount(
                arguments.first,
                position: 1,
                function: "net.ReadData"
            )
            return [.string(LuaString(bytes: try self.readBytes(
                count: length,
                function: "net.ReadData"
            )))]
        }

        state.register("__gmod_net_ReadHeader") { [unowned self] _ in
            let value = try self.readUInt(bitCount: 16, function: "net.ReadHeader")
            return [.number(Double(value))]
        }

        state.register("__gmod_net_Broadcast") { [unowned self] _ in
            guard let transport = self.transport else {
                throw LuaError.runtime("net.Broadcast transport is unavailable")
            }
            try transport.broadcast(from: self)
            return []
        }

        state.register("__gmod_net_SendToServer") { [unowned self] _ in
            guard self.realm != .server else {
                throw LuaError.runtime("net.SendToServer is client-only")
            }
            guard let transport = self.transport else {
                throw LuaError.runtime("net.SendToServer transport is unavailable")
            }
            try transport.sendToServer(from: self)
            return []
        }

        state.register("__gmod_net_Send") { [unowned self] arguments in
            guard self.realm == .server else {
                throw LuaError.runtime("net.Send is server-only")
            }
            guard let transport = self.transport else {
                throw LuaError.runtime("net.Send transport is unavailable")
            }
            let recipients = try self.recipientPlayerIndices(arguments.first)
            try transport.send(from: self, toPlayerIndices: recipients)
            return []
        }

        state.register("__gmod_net_BytesWritten") { [unowned self] _ in
            guard let result = self.bytesWritten() else {
                return [.nilValue, .nilValue]
            }
            return [.number(Double(result.bytes)), .number(Double(result.bits))]
        }

        state.register("__gmod_net_BytesLeft") { [unowned self] _ in
            guard let result = self.bytesLeft() else {
                return [.nilValue, .nilValue]
            }
            return [.number(Double(result.bytes)), .number(Double(result.bits))]
        }

        if realm == .server {
            guard let entityRegistry else {
                throw LuaError.runtime(
                    "Player:SendLua Entity registry is unavailable"
                )
            }
            try entityRegistry.installPlayerMethod(
                named: "SendLua",
                function: .nativeFunction(LuaNativeFunctionBox(
                    { [unowned self] arguments in
                        guard let registry = self.entityRegistry else {
                            throw LuaError.runtime(
                                "Player:SendLua Entity registry is unavailable"
                            )
                        }
                        guard let player = arguments.first else {
                            throw LuaError.runtime(
                                "bad self to 'Player:SendLua' (Player expected)"
                            )
                        }
                        let playerIndex = try registry.playerNetworkIndex(
                            from: player,
                            function: "Player:SendLua"
                        )
                        guard arguments.indices.contains(1),
                              case let .string(code) = arguments[1] else {
                            let actual = arguments.indices.contains(1)
                                ? arguments[1].typeName
                                : "no value"
                            throw LuaError.runtime(
                                "bad argument #1 to 'Player:SendLua' " +
                                    "(string expected, got \(actual))"
                            )
                        }
                        guard let transport = self.transport else {
                            throw LuaError.runtime(
                                "Player:SendLua transport is unavailable"
                            )
                        }
                        try transport.enqueueClientLua(
                            code,
                            from: self,
                            toPlayerIndex: playerIndex
                        )
                        return []
                    },
                    debugName: "Player:SendLua"
                ))
            )
        }
    }

    private func start(name: LuaString, unreliable: Bool) throws {
        guard let transport else {
            throw LuaError.runtime("net.Start transport is unavailable")
        }
        let messageID = transport.networkedGlobalTransport.networkStringID(for: name)
        guard messageID > 0 else {
            throw LuaError.runtime(
                "net.Start called with unpooled message name '\(name.utf8String)'"
            )
        }
        lock.lock()
        writer = GMLuaNetWriter(messageID: messageID, unreliable: unreliable)
        lock.unlock()
    }

    private func abort() {
        lock.lock()
        writer = nil
        lock.unlock()
    }

    private func writeUInt(
        _ value: UInt64,
        bitCount: Int,
        function: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var activeWriter = writer else {
            throw LuaError.runtime("\(function) called without net.Start")
        }
        guard activeWriter.payload.bitCount + bitCount <= GMLuaNetTransport.maximumPayloadBits else {
            writer = nil
            throw LuaError.runtime(
                "\(function) exceeded the 65,533-byte net message limit"
            )
        }
        activeWriter.payload.appendUInt(value, bitCount: bitCount)
        writer = activeWriter
    }

    private func readUInt(bitCount: Int, function: String) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard var activeReader = reader else {
            throw LuaError.runtime("\(function) called outside an incoming net message")
        }
        let value = try activeReader.readUInt(
            bitCount: bitCount,
            function: function
        )
        reader = activeReader
        return value
    }

    private func writeBytes(_ bytes: [UInt8], function: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var activeWriter = writer else {
            throw LuaError.runtime("\(function) called without net.Start")
        }
        let requestedBits = bytes.count * 8
        guard activeWriter.payload.bitCount + requestedBits <= GMLuaNetTransport.maximumPayloadBits else {
            writer = nil
            throw LuaError.runtime(
                "\(function) exceeded the 65,533-byte net message limit"
            )
        }
        for byte in bytes {
            activeWriter.payload.appendUInt(UInt64(byte), bitCount: 8)
        }
        writer = activeWriter
    }

    private func readBytes(count: Int, function: String) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard var activeReader = reader else {
            throw LuaError.runtime("\(function) called outside an incoming net message")
        }
        let requestedBits = count * 8
        guard requestedBits <= activeReader.bitsLeft else {
            throw LuaError.runtime(
                "\(function) tried to read \(count) bytes with only \(activeReader.bitsLeft) bits remaining"
            )
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8(try activeReader.readUInt(
                bitCount: 8,
                function: function
            )))
        }
        reader = activeReader
        return bytes
    }

    private func readTerminatedString() throws -> LuaString {
        lock.lock()
        defer { lock.unlock() }
        guard var activeReader = reader else {
            throw LuaError.runtime("net.ReadString called outside an incoming net message")
        }
        var bytes: [UInt8] = []
        while true {
            guard activeReader.bitsLeft >= 8 else {
                throw LuaError.runtime(
                    "net.ReadString reached the end of the message before its NUL terminator"
                )
            }
            let byte = UInt8(try activeReader.readUInt(
                bitCount: 8,
                function: "net.ReadString"
            ))
            if byte == 0 { break }
            bytes.append(byte)
        }
        reader = activeReader
        return LuaString(bytes: bytes)
    }

    private func bytesWritten() -> (bytes: Int, bits: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let writer else { return nil }
        // Facepunch documents three bytes of engine overhead in both values.
        let totalBits = writer.payload.bitCount + 24
        return ((totalBits + 7) / 8, totalBits)
    }

    private func bytesLeft() -> (bytes: Int, bits: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let reader else { return nil }
        return ((reader.bitsLeft + 7) / 8, reader.bitsLeft)
    }

    fileprivate func takeWriter(function: String) throws -> GMLuaNetWriter {
        lock.lock()
        defer { lock.unlock() }
        guard let activeWriter = writer else {
            throw LuaError.runtime("\(function) called without net.Start")
        }
        writer = nil
        return activeWriter
    }

    fileprivate func beginReading(_ bits: GMLuaNetBitBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard reader == nil else {
            throw LuaError.runtime("incoming net reader is already active")
        }
        reader = GMLuaNetBitReader(buffer: bits)
    }

    fileprivate func finishReading() {
        lock.lock()
        reader = nil
        lock.unlock()
    }

    fileprivate func resetForConnectionBoundary() {
        lock.lock()
        writer = nil
        reader = nil
        lock.unlock()
    }

    func connectConsoleCommandDispatcher(
        _ dispatcher: GMLuaConsoleCommandDispatcher
    ) {
        lock.lock()
        consoleCommandDispatcher = dispatcher
        lock.unlock()
        if realm == .server {
            dispatcher.connectTargetedClients {
                [weak self] player, playerIndex, commands in
                guard let self else {
                    throw LuaError.runtime(
                        "Player:ConCommand SERVER endpoint is unavailable"
                    )
                }
                try self.enqueueTargetedClientConsoleCommands(
                    player: player,
                    toPlayerIndex: playerIndex,
                    commands: commands
                )
            }
        }
    }

    private func enqueueTargetedClientConsoleCommands(
        player: LuaValue,
        toPlayerIndex playerIndex: Int,
        commands: [GMLuaConsoleCommandInvocation]
    ) throws {
        guard realm == .server, let transport else {
            throw LuaError.runtime(
                "Player:ConCommand SERVER endpoint is unavailable"
            )
        }
        try transport.enqueueTargetedClientConsoleCommands(
            from: self,
            validating: player,
            toPlayerIndex: playerIndex,
            commands: commands
        )
    }

    /// Queues SERVER `MsgAll` for every currently connected CLIENT. CLIENT
    /// and MENU use their local `Msg` behavior and never enter this path.
    func broadcastConsoleMessage(_ message: LuaString) throws {
        guard realm == .server, let transport else {
            throw LuaError.runtime("MsgAll SERVER endpoint is unavailable")
        }
        try transport.enqueueBroadcastConsoleMessage(message, from: self)
    }

    /// Queues one engine-owned gameplay event for all current CLIENT
    /// connections. No destination realm is entered until the host pumps the
    /// shared transport FIFO.
    public func broadcastGameplayEvent(
        _ payload: GMLuaGameplayEventPayload
    ) throws {
        guard realm == .server, let transport else {
            throw LuaError.runtime(
                "gameplay event broadcast requires an attached SERVER endpoint"
            )
        }
        try transport.enqueueGameplayEvent(payload, from: self)
    }

    fileprivate func validateCurrentServerPlayer(
        _ player: LuaValue,
        expectedIndex: Int
    ) throws {
        guard realm == .server, let entityRegistry else {
            throw LuaError.runtime(
                "Player:ConCommand SERVER Player registry is unavailable"
            )
        }
        let actualIndex = try entityRegistry.playerNetworkIndex(
            from: player,
            function: "Player:ConCommand"
        )
        guard actualIndex == expectedIndex else {
            throw LuaError.runtime(
                "Player:ConCommand target Player changed during delivery"
            )
        }
    }

    /// Installs the canonical replication sink on the destination endpoint,
    /// keeping CLIENT state ownership out of the shareable transport queue.
    func connectEntityReplicationHandler(
        _ handler: @escaping GMLuaEntityReplicationHandler
    ) throws {
        guard realm == .client else {
            throw GMLuaEntityReplicationTransportError.clientDestinationRequired
        }
        lock.lock()
        entityReplicationHandler = handler
        lock.unlock()
    }

    /// Connects the CLIENT-owned effect/audio/animation handoff. Replacing the
    /// handler is explicit and does not execute any queued packet immediately.
    public func connectGameplayEventHandler(
        _ handler: @escaping GMLuaGameplayEventHandler
    ) throws {
        guard realm == .client else {
            throw LuaError.runtime(
                "gameplay event handler destination must be CLIENT"
            )
        }
        lock.lock()
        gameplayEventHandler = handler
        lock.unlock()
    }

    public func disconnectGameplayEventHandler() {
        lock.lock()
        gameplayEventHandler = nil
        lock.unlock()
    }

    fileprivate func detachFromSession() {
        lock.lock()
        writer = nil
        reader = nil
        state = nil
        transport = nil
        entityRegistry = nil
        consoleCommandDispatcher = nil
        entityReplicationHandler = nil
        gameplayEventHandler = nil
        lock.unlock()
    }

    fileprivate func invokeIncoming(
        totalBits: Int,
        senderPlayerIndex: Int?
    ) throws {
        guard let state else {
            throw LuaError.runtime("destination Lua state is unavailable")
        }
        guard case let .table(netTable) = state.getGlobal("net") else {
            throw LuaError.runtime("net.Incoming is unavailable (net table missing)")
        }
        let incoming = try state.rawTableValue(
            for: .string("Incoming"),
            in: netTable
        )
        guard incoming.typeName == "function" else {
            throw LuaError.runtime("net.Incoming is unavailable")
        }
        let sender: LuaValue
        if realm == .server {
            guard let senderPlayerIndex,
                  let entityRegistry else {
                throw LuaError.runtime(
                    "SERVER net.Incoming requires a connected sender Player"
                )
            }
            sender = entityRegistry.player(at: senderPlayerIndex)
            guard GMLuaTypeSystem.typedObject(from: sender)?.isValid == true else {
                throw LuaError.runtime(
                    "SERVER net.Incoming sender Player mirror is unavailable"
                )
            }
        } else {
            sender = .nilValue
        }
        _ = try state.call(
            incoming,
            arguments: [.number(Double(totalBits)), sender]
        )
    }

    fileprivate func invokeConsoleCommand(
        command: String,
        arguments: [String],
        senderPlayerIndex: Int
    ) throws {
        let destination = try consoleCommandDestination(
            senderPlayerIndex: senderPlayerIndex
        )
        try destination.dispatcher.dispatchRemoteCommand(
            command: command,
            arguments: arguments,
            caller: destination.sender
        )
    }

    fileprivate func invokeClientLua(_ packet: GMLuaClientLuaPacket) throws {
        guard realm == .client, let state else {
            throw LuaError.runtime(
                "Player:SendLua destination CLIENT state is unavailable"
            )
        }
        guard let source = LuaSourceDecoder.decode(Data(packet.code.bytes)) else {
            throw LuaError.runtime("Player:SendLua could not decode Lua source")
        }
        try state.execute(
            source,
            sourceName: "=(Player:SendLua #\(packet.sequence))"
        )
    }

    fileprivate func invokeTargetedClientConsoleCommand(
        _ packet: GMLuaTargetedClientConsolePacket
    ) throws {
        lock.lock()
        let dispatcher = consoleCommandDispatcher
        lock.unlock()
        guard realm == .client, let dispatcher else {
            throw LuaError.runtime(
                "Player:ConCommand destination CLIENT dispatcher is unavailable"
            )
        }
        try dispatcher.dispatchTargetedClientCommand(
            command: packet.command,
            arguments: packet.arguments
        )
    }

    fileprivate func invokeBroadcastConsoleMessage(
        _ packet: GMLuaBroadcastConsoleMessagePacket
    ) {
        // MsgAll is an engine console broadcast, not a call through the
        // destination realm's mutable Lua global `Msg`. Keeping the sink on
        // the endpoint prevents client scripts from dropping or redirecting
        // an already accepted FIFO delivery by replacing that global.
        consoleMessageSink(packet.message)
    }

    fileprivate func invokeEntityReplication(
        _ delivery: GMLuaEntityReplicationDelivery
    ) throws {
        lock.lock()
        let handler = entityReplicationHandler
        lock.unlock()
        guard let handler else {
            throw GMLuaEntityReplicationTransportError.clientHandlerUnavailable
        }
        switch try handler(delivery.packet) {
        case .applied:
            return
        case let .rejected(rejection):
            throw GMLuaEntityReplicationTransportError.packetRejected(
                transportSequence: delivery.sequence,
                packetSequence: delivery.packet.sequence,
                rejection: rejection
            )
        }
    }

    fileprivate func invokeGameplayEvent(
        _ packet: GMLuaGameplayEventPacket
    ) throws {
        lock.lock()
        let handler = gameplayEventHandler
        lock.unlock()
        guard realm == .client, let handler else {
            throw LuaError.runtime(
                "gameplay event CLIENT handler is unavailable"
            )
        }
        try handler(GMLuaGameplayEventDelivery(
            transportSequence: packet.sequence,
            payload: packet.payload
        ))
    }

    /// Returns only a typed expected user-action failure from the SERVER
    /// dispatcher. Every transport prerequisite, dispatcher invariant, and
    /// throwing host handler remains outside that value boundary.
    fileprivate func invokeConsoleCommandReportingCommandFailure(
        command: String,
        arguments: [String],
        senderPlayerIndex: Int
    ) throws -> String? {
        let destination = try consoleCommandDestination(
            senderPlayerIndex: senderPlayerIndex
        )
        switch try destination.dispatcher
            .dispatchRemoteCommandReportingActionFailures(
            command: command,
            arguments: arguments,
            caller: destination.sender
        ) {
        case .handled:
            return nil
        case let .actionFailure(message):
            return message
        }
    }

    private func consoleCommandDestination(
        senderPlayerIndex: Int
    ) throws -> (dispatcher: GMLuaConsoleCommandDispatcher, sender: LuaValue) {
        guard realm == .server,
              let entityRegistry,
              let dispatcher = consoleCommandDispatcher else {
            throw LuaError.runtime(
                "SERVER console command destination is unavailable"
            )
        }
        let sender = entityRegistry.player(at: senderPlayerIndex)
        guard GMLuaTypeSystem.typedObject(from: sender)?.isValid == true else {
            throw LuaError.runtime(
                "SERVER console command sender Player mirror is unavailable"
            )
        }
        return (dispatcher, sender)
    }

    private func recipientPlayerIndices(_ value: LuaValue?) throws -> [Int] {
        guard let value else {
            throw LuaError.runtime(
                "bad argument #1 to 'net.Send' (Player or table expected, got no value)"
            )
        }
        guard let entityRegistry else {
            throw LuaError.runtime("net.Send Player registry is unavailable")
        }
        let values: [LuaValue]
        if case let .table(table) = value {
            guard let state else {
                throw LuaError.runtime("net.Send Lua state is unavailable")
            }
            values = try state.rawTablePairs(in: table).map { $0.1 }
        } else {
            values = [value]
        }
        var seen: Set<Int> = []
        var result: [Int] = []
        for recipient in values {
            let index = try entityRegistry.playerNetworkIndex(
                from: recipient,
                function: "net.Send"
            )
            if seen.insert(index).inserted { result.append(index) }
        }
        return result
    }

    private func requiredString(
        _ value: LuaValue?,
        position: Int,
        function: String
    ) throws -> LuaString {
        guard let value, case let .string(string) = value else {
            throw argumentError(
                value,
                position: position,
                function: function,
                expected: "string"
            )
        }
        return string
    }

    private func requiredBitCount(
        _ value: LuaValue?,
        position: Int,
        function: String
    ) throws -> Int {
        guard let value, case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 1,
              number <= 32,
              (1...32).contains(Int(number)) else {
            throw argumentError(
                value,
                position: position,
                function: function,
                expected: "bit count from 1 to 32"
            )
        }
        return Int(number)
    }

    private func requiredNumber(
        _ value: LuaValue?,
        position: Int,
        function: String
    ) throws -> Double {
        guard let value, case let .number(number) = value else {
            throw argumentError(
                value,
                position: position,
                function: function,
                expected: "number"
            )
        }
        return number
    }

    private func requiredLuaString(
        _ value: LuaValue?,
        position: Int,
        function: String
    ) throws -> LuaString {
        guard let value, case let .string(string) = value else {
            throw argumentError(
                value,
                position: position,
                function: function,
                expected: "string"
            )
        }
        return string
    }

    private func requiredSignedInteger(
        _ value: LuaValue?,
        bitCount: Int,
        function: String
    ) throws -> Int64 {
        let magnitude = Int64(1) << Int64(bitCount - 1)
        let minimum = -magnitude
        let maximum = magnitude - 1
        guard let value, case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(minimum),
              number <= Double(maximum) else {
            throw argumentError(
                value,
                position: 1,
                function: function,
                expected: "signed \(bitCount)-bit integer"
            )
        }
        return Int64(number)
    }

    private func requiredByteCount(
        _ value: LuaValue?,
        position: Int,
        function: String
    ) throws -> Int {
        guard let value, case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 0,
              number <= Double(GMLuaNetTransport.maximumPayloadBytes) else {
            throw argumentError(
                value,
                position: position,
                function: function,
                expected: "byte count from 0 to \(GMLuaNetTransport.maximumPayloadBytes)"
            )
        }
        return Int(number)
    }

    private func requiredUnsignedInteger(
        _ value: LuaValue?,
        bitCount: Int,
        function: String
    ) throws -> UInt64 {
        let maximum = bitCount == 32
            ? UInt64(UInt32.max)
            : (UInt64(1) << UInt64(bitCount)) - 1
        guard let value, case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 0,
              number <= Double(maximum) else {
            throw argumentError(
                value,
                position: 1,
                function: function,
                expected: "unsigned \(bitCount)-bit integer"
            )
        }
        return UInt64(number)
    }

    private func argumentError(
        _ value: LuaValue?,
        position: Int,
        function: String,
        expected: String
    ) -> LuaError {
        let actual = value?.typeName ?? "no value"
        return LuaError.runtime(
            "bad argument #\(position) to '\(function)' (\(expected) expected, got \(actual))"
        )
    }
}

/// Host-owned, shareable net session with one server and any number of clients.
///
/// `Broadcast` only enqueues immutable deliveries. Hosts call ``pump`` at a
/// safe tick boundary; pump then invokes the destination realm's original Lua
/// `net.Incoming` function. This prevents send-time Lua re-entry and gives the
/// renderer/simulation host a deterministic delivery boundary.
public enum GMLuaPhysicsSequenceReservationError: Error, Equatable, Sendable {
    case negativeCount(Int)
    case sequenceExhausted
}

public final class GMLuaNetTransport: @unchecked Sendable,
    SourceCanonicalPropPhysicsCommandSequenceSource,
    SourceCanonicalPropPhysicsMutationCommandQueue,
    SourceCanonicalPhysicsConstraintCommandQueue
{
    public static let maximumPayloadBytes = 65_533
    public static let maximumPayloadBits = maximumPayloadBytes * 8
    /// Current documented Garry's Mod `Player:SendLua` script limit. Counted
    /// from Lua's exact byte string rather than Swift characters.
    public static let maximumSendLuaCodeBytes = 6_000

    public let networkedGlobalTransport: GMLuaNetworkedGlobalTransport

    // LuaState is deliberately entered only at host pump boundaries. The
    // condition serializes boundaries, but is never held while Lua executes.
    // That matters because host-native callbacks may inspect session state.
    private let boundaryCondition = NSCondition()
    private var boundaryActive = false
    private let lock = NSLock()
    private var nextEndpointID = 1
    private var nextSequence: UInt64 = 0
    private var serverEndpointID: Int?
    private var endpoints: [Int: GMLuaNetEndpoint] = [:]
    private struct ClientConnection: Sendable {
        let endpointID: Int
        let playerIndex: Int
        let generation: UInt64
    }
    private var clientConnectionsByEndpoint: [Int: ClientConnection] = [:]
    private var clientEndpointByPlayerIndex: [Int: Int] = [:]
    private var disconnectHandlers: [Int: @Sendable () -> Void] = [:]
    private var deliveries: [GMLuaTransportDelivery] = []
    private var pendingPhysicsBodyCommands: [SourcePhysicsCommand] = []
    private var completedMessages: UInt64 = 0
    private var requiresExplicitClientConnections = false

    public init(
        networkedGlobalTransport: GMLuaNetworkedGlobalTransport = GMLuaNetworkedGlobalTransport()
    ) {
        self.networkedGlobalTransport = networkedGlobalTransport
    }

    /// Marks this transport as the substrate of a host-owned shared session.
    /// In that mode merely constructing a CLIENT runtime does not make it a
    /// broadcast recipient; only an explicit player connection does.
    func requireExplicitClientConnections() {
        lock.lock()
        requiresExplicitClientConnections = true
        lock.unlock()
    }

    public var pendingDeliveryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveries.count
    }

    public var completedMessageCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return completedMessages
    }

    public var pendingPhysicsBodyCommandCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingPhysicsBodyCommands.count
    }

    /// Reserves physics commands from the transport's existing global FIFO.
    ///
    /// Physics commands are executed by the authoritative simulation lane and
    /// therefore do not become transport deliveries, but consuming their
    /// sequence identities here keeps net, console, Entity replication, and
    /// rigid-body work in one total order. Gaps in the delivery queue are
    /// intentional and are permitted by `SourcePhysicsCommandBatch`.
    public func reservePhysicsCommandSequences(count: Int) throws -> [UInt64] {
        guard count >= 0 else {
            throw GMLuaPhysicsSequenceReservationError.negativeCount(count)
        }
        guard count > 0 else { return [] }

        lock.lock()
        defer { lock.unlock() }
        let requested = UInt64(count)
        guard requested <= UInt64.max - nextSequence else {
            throw GMLuaPhysicsSequenceReservationError.sequenceExhausted
        }
        let first = nextSequence + 1
        nextSequence += requested
        return (0 ..< count).map { first + UInt64($0) }
    }

    @discardableResult
    public func enqueueCanonicalPhysicsBodyCommands(
        _ bodyCommands: [SourceCanonicalQueuedPhysicsBodyCommand]
    ) throws -> [SourcePhysicsCommand] {
        try enqueueCanonicalPhysicsPayloads(bodyCommands.map(\.payload))
    }

    @discardableResult
    public func enqueueCanonicalPhysicsConstraintCommands(
        _ constraintCommands: [SourceCanonicalQueuedPhysicsConstraintCommand]
    ) throws -> [SourcePhysicsCommand] {
        try enqueueCanonicalPhysicsPayloads(constraintCommands.map(\.payload))
    }

    private func enqueueCanonicalPhysicsPayloads(
        _ payloads: [SourcePhysicsCommandPayload]
    ) throws -> [SourcePhysicsCommand] {
        guard !payloads.isEmpty else { return [] }
        let transaction = Thread.current.threadDictionary[
            deliveryTransactionThreadKey
        ] as? GMLuaTransportDeliveryTransactionContext
        lock.lock()
        defer { lock.unlock() }
        let requested = UInt64(payloads.count)
        guard requested <= UInt64.max - nextSequence else {
            throw GMLuaPhysicsSequenceReservationError.sequenceExhausted
        }
        let first = nextSequence + 1
        nextSequence += requested
        let commands = payloads.enumerated().map { offset, payload in
            SourcePhysicsCommand(
                sequence: first + UInt64(offset),
                payload: payload
            )
        }
        if let transaction {
            transaction.physicsBodyCommands.append(contentsOf: commands)
        } else {
            pendingPhysicsBodyCommands.append(contentsOf: commands)
        }
        return commands
    }

    public func rollbackCanonicalPhysicsConstraintCommands(
        _ commands: [SourcePhysicsCommand]
    ) {
        guard !commands.isEmpty else { return }
        let transaction = Thread.current.threadDictionary[
            deliveryTransactionThreadKey
        ] as? GMLuaTransportDeliveryTransactionContext
        lock.lock()
        defer { lock.unlock() }
        if let transaction {
            precondition(transaction.physicsBodyCommands.count >= commands.count)
            precondition(
                Array(transaction.physicsBodyCommands.suffix(commands.count)) == commands,
                "constraint rollback must match the staged physics FIFO suffix"
            )
            transaction.physicsBodyCommands.removeLast(commands.count)
        } else {
            precondition(pendingPhysicsBodyCommands.count >= commands.count)
            precondition(
                Array(pendingPhysicsBodyCommands.suffix(commands.count)) == commands,
                "constraint rollback must match the pending physics FIFO suffix"
            )
            pendingPhysicsBodyCommands.removeLast(commands.count)
        }
    }

    public func preparePendingCanonicalPhysicsBodyCommands()
        -> [SourcePhysicsCommand]
    {
        lock.lock()
        defer { lock.unlock() }
        return pendingPhysicsBodyCommands
    }

    public func commitPendingCanonicalPhysicsBodyCommands(
        _ commands: [SourcePhysicsCommand]
    ) {
        guard !commands.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        precondition(pendingPhysicsBodyCommands.count >= commands.count)
        precondition(Array(pendingPhysicsBodyCommands.prefix(commands.count)) == commands)
        pendingPhysicsBodyCommands.removeFirst(commands.count)
    }

    /// Stages deliveries enqueued by the current thread until `body` returns.
    ///
    /// This is the narrow transport half of a future forwarded-console action
    /// transaction. Other threads continue to enqueue normally. Their packets
    /// are neither hidden nor removed if this scope rolls back; a successful
    /// scope merges its reserved sequences back into the global FIFO order.
    /// Pending/completed public counters intentionally exclude staged work.
    ///
    /// Nested scopes on the same transport and thread are rejected. A nested
    /// Lua command remains part of its outer forwarded action instead of
    /// gaining an independently committable packet transaction.
    func withStagedForwardedConsoleDeliveries<T>(
        _ body: () throws -> T
    ) throws -> T {
        let dictionary = Thread.current.threadDictionary
        let key = deliveryTransactionThreadKey
        guard dictionary[key] == nil else {
            throw GMLuaNetTransportDeliveryTransactionError.nestedTransaction
        }

        let context = GMLuaTransportDeliveryTransactionContext()
        dictionary[key] = context
        defer { dictionary.removeObject(forKey: key) }

        let result = try body()
        lock.lock()
        if !context.deliveries.isEmpty {
            deliveries = Self.mergeDeliveriesBySequence(
                deliveries,
                context.deliveries
            )
        }
        if !context.physicsBodyCommands.isEmpty {
            pendingPhysicsBodyCommands.append(
                contentsOf: context.physicsBodyCommands
            )
            pendingPhysicsBodyCommands.sort { $0.sequence < $1.sequence }
        }
        completedMessages &+= context.completedMessageCount
        lock.unlock()
        return result
    }

    public var connectedClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return endpoints.values.reduce(into: 0) { count, endpoint in
            if endpoint.realm == .client && endpoint.state != nil { count += 1 }
        }
    }

    /// True only on the thread currently invoking a Lua receiver from `pump`.
    /// Lifecycle APIs use this to reject synchronous detach/reconnect rather
    /// than deadlocking or closing a LuaState underneath its own callback.
    func isPumpingOnCurrentThread() -> Bool {
        Thread.current.threadDictionary[pumpThreadMarkerKey] as? Bool == true
    }

    /// Serializes a complete host lifecycle mutation against packet delivery.
    /// The condition itself is released before `body` runs; same-thread nested
    /// transport helpers reuse the boundary rather than deadlocking.
    func withExclusiveLifecycleBoundary<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        beginExclusiveBoundary()
        defer { endExclusiveBoundary() }
        return try body()
    }

    func installEndpoint(
        into state: LuaState,
        realm: GMLuaRealm,
        entityRegistry: GMLuaEntityRegistry,
        consoleMessageSink: @escaping (LuaString) -> Void
    ) throws -> GMLuaNetEndpoint {
        lock.lock()
        if realm == .server, serverEndpointID != nil {
            lock.unlock()
            throw LuaError.runtime("GMLuaNetTransport supports exactly one SERVER endpoint")
        }
        let identifier = nextEndpointID
        nextEndpointID += 1
        let endpoint = GMLuaNetEndpoint(
            identifier: identifier,
            realm: realm,
            state: state,
            entityRegistry: entityRegistry,
            consoleMessageSink: consoleMessageSink,
            transport: self
        )
        endpoints[identifier] = endpoint
        if realm == .server { serverEndpointID = identifier }
        lock.unlock()

        do {
            try endpoint.installBindings(into: state)
            return endpoint
        } catch {
            lock.lock()
            if endpoints[identifier] === endpoint {
                endpoints.removeValue(forKey: identifier)
                if serverEndpointID == identifier { serverEndpointID = nil }
            }
            lock.unlock()
            endpoint.detachFromSession()
            throw error
        }
    }

    func detachEndpoint(_ endpoint: GMLuaNetEndpoint) {
        // Wait for any in-flight callback before allowing its LuaState to be
        // closed. Runtime shutdown is itself a host lifecycle boundary.
        beginExclusiveBoundary()
        var cleanupHandlers: [@Sendable () -> Void] = []
        lock.lock()
        if endpoints[endpoint.identifier] === endpoint {
            endpoints.removeValue(forKey: endpoint.identifier)
            if serverEndpointID == endpoint.identifier {
                serverEndpointID = nil
                cleanupHandlers.append(contentsOf: disconnectHandlers.values)
                disconnectHandlers.removeAll()
                clientConnectionsByEndpoint.removeAll()
                clientEndpointByPlayerIndex.removeAll()
            } else if let connection = clientConnectionsByEndpoint.removeValue(
                forKey: endpoint.identifier
            ) {
                clientEndpointByPlayerIndex.removeValue(forKey: connection.playerIndex)
                if let handler = disconnectHandlers.removeValue(
                    forKey: endpoint.identifier
                ) {
                    cleanupHandlers.append(handler)
                }
            }
            deliveries.removeAll {
                $0.sourceEndpointID == endpoint.identifier ||
                    $0.destinationEndpointID == endpoint.identifier ||
                    endpoint.realm == .server
            }
        }
        lock.unlock()
        endpoint.detachFromSession()
        cleanupHandlers.forEach { $0() }
        endExclusiveBoundary()
    }

    func connectClientEndpoint(
        _ endpoint: GMLuaNetEndpoint,
        playerIndex: Int,
        generation: UInt64,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        guard endpoint.realm == .client else {
            throw LuaError.runtime("shared session can only connect CLIENT endpoints")
        }
        beginExclusiveBoundary()
        lock.lock()
        let serverAvailable = serverEndpointID.flatMap { endpoints[$0] }?.state != nil
        let endpointAvailable = endpoints[endpoint.identifier] === endpoint
        let endpointUnused = clientConnectionsByEndpoint[endpoint.identifier] == nil
        let playerUnused = clientEndpointByPlayerIndex[playerIndex] == nil
        if serverAvailable, endpointAvailable, endpointUnused, playerUnused {
            let connection = ClientConnection(
                endpointID: endpoint.identifier,
                playerIndex: playerIndex,
                generation: generation
            )
            clientConnectionsByEndpoint[endpoint.identifier] = connection
            clientEndpointByPlayerIndex[playerIndex] = endpoint.identifier
            disconnectHandlers[endpoint.identifier] = onDisconnect
        }
        lock.unlock()
        if serverAvailable, endpointAvailable, endpointUnused, playerUnused {
            endpoint.resetForConnectionBoundary()
            endExclusiveBoundary()
            return
        }
        endExclusiveBoundary()
        if !serverAvailable {
            throw LuaError.runtime("shared session SERVER endpoint is unavailable")
        }
        if !endpointAvailable {
            throw LuaError.runtime("shared session CLIENT endpoint is detached")
        }
        if !endpointUnused {
            throw LuaError.runtime("shared session CLIENT endpoint is already connected")
        }
        throw LuaError.runtime("shared session player index \(playerIndex) is already connected")
    }

    func disconnectClientEndpoint(_ endpoint: GMLuaNetEndpoint) {
        beginExclusiveBoundary()
        lock.lock()
        let connection = clientConnectionsByEndpoint.removeValue(
            forKey: endpoint.identifier
        )
        if let connection {
            clientEndpointByPlayerIndex.removeValue(forKey: connection.playerIndex)
            deliveries.removeAll {
                $0.sourceEndpointID == endpoint.identifier ||
                    $0.destinationEndpointID == endpoint.identifier
            }
        }
        let handler = disconnectHandlers.removeValue(forKey: endpoint.identifier)
        lock.unlock()
        endpoint.resetForConnectionBoundary()
        handler?()
        endExclusiveBoundary()
    }

    fileprivate func broadcast(from source: GMLuaNetEndpoint) throws {
        guard source.realm == .server else {
            throw LuaError.runtime("net.Broadcast is server-only")
        }
        let writer = try source.takeWriter(function: "net.Broadcast")
        var messageBits = GMLuaNetBitBuffer()
        messageBits.appendUInt(UInt64(writer.messageID), bitCount: 16)
        messageBits.append(writer.payload)

        lock.lock()
        defer { lock.unlock() }
        guard endpoints[source.identifier] === source else {
            throw LuaError.runtime("net.Broadcast endpoint is detached")
        }
        recordCompletedMessageLocked()
        let destinations = endpoints.values
            .filter {
                $0.realm == .client && $0.state != nil &&
                    (!requiresExplicitClientConnections ||
                        clientConnectionsByEndpoint[$0.identifier] != nil)
            }
            .sorted { $0.identifier < $1.identifier }
        for destination in destinations {
            nextSequence &+= 1
            appendDeliveryLocked(.net(GMLuaNetPacket(
                sequence: nextSequence,
                sourceEndpointID: source.identifier,
                destinationEndpointID: destination.identifier,
                senderPlayerIndex: nil,
                connectionGeneration: clientConnectionsByEndpoint[destination.identifier]?.generation,
                unreliable: writer.unreliable,
                bits: messageBits
            )))
        }
    }

    fileprivate func sendToServer(from source: GMLuaNetEndpoint) throws {
        guard source.realm == .client else {
            throw LuaError.runtime("net.SendToServer is client-only")
        }
        lock.lock()
        let connection = clientConnectionsByEndpoint[source.identifier]
        let destinationID = serverEndpointID
        let destinationAvailable = destinationID.flatMap { endpoints[$0] }?.state != nil
        lock.unlock()
        guard let connection, let destinationID, destinationAvailable else {
            throw LuaError.runtime(
                "net.SendToServer cannot send: client transport is disconnected"
            )
        }

        let writer = try source.takeWriter(function: "net.SendToServer")
        var messageBits = GMLuaNetBitBuffer()
        messageBits.appendUInt(UInt64(writer.messageID), bitCount: 16)
        messageBits.append(writer.payload)

        lock.lock()
        defer { lock.unlock() }
        guard clientConnectionsByEndpoint[source.identifier]?.generation == connection.generation,
              serverEndpointID == destinationID,
              endpoints[destinationID]?.state != nil else {
            throw LuaError.runtime(
                "net.SendToServer cannot send: client transport disconnected during send"
            )
        }
        recordCompletedMessageLocked()
        nextSequence &+= 1
        appendDeliveryLocked(.net(GMLuaNetPacket(
            sequence: nextSequence,
            sourceEndpointID: source.identifier,
            destinationEndpointID: destinationID,
            senderPlayerIndex: connection.playerIndex,
            connectionGeneration: connection.generation,
            unreliable: writer.unreliable,
            bits: messageBits
        )))
    }

    fileprivate func send(
        from source: GMLuaNetEndpoint,
        toPlayerIndices playerIndices: [Int]
    ) throws {
        guard source.realm == .server else {
            throw LuaError.runtime("net.Send is server-only")
        }
        let writer = try source.takeWriter(function: "net.Send")
        var messageBits = GMLuaNetBitBuffer()
        messageBits.appendUInt(UInt64(writer.messageID), bitCount: 16)
        messageBits.append(writer.payload)

        lock.lock()
        defer { lock.unlock() }
        guard serverEndpointID == source.identifier,
              endpoints[source.identifier] === source else {
            throw LuaError.runtime("net.Send SERVER endpoint is detached")
        }
        let destinations = playerIndices.map { playerIndex -> ClientConnection in
            guard let endpointID = clientEndpointByPlayerIndex[playerIndex],
                  let connection = clientConnectionsByEndpoint[endpointID] else {
                // A stale or foreign Player must not become an accidental
                // broadcast or a silent success.
                return ClientConnection(
                    endpointID: -1,
                    playerIndex: playerIndex,
                    generation: 0
                )
            }
            return connection
        }
        if let missing = destinations.first(where: { $0.endpointID < 0 }) {
            throw LuaError.runtime(
                "net.Send target Player(\(missing.playerIndex)) is not connected"
            )
        }
        recordCompletedMessageLocked()
        for destination in destinations {
            nextSequence &+= 1
            appendDeliveryLocked(.net(GMLuaNetPacket(
                sequence: nextSequence,
                sourceEndpointID: source.identifier,
                destinationEndpointID: destination.endpointID,
                senderPlayerIndex: nil,
                connectionGeneration: destination.generation,
                unreliable: writer.unreliable,
                bits: messageBits
            )))
        }
    }

    func enqueueConsoleCommand(
        from source: GMLuaNetEndpoint,
        command: String,
        arguments: [String]
    ) throws {
        guard source.realm == .client else {
            throw LuaError.runtime("remote console commands require a CLIENT endpoint")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let connection = clientConnectionsByEndpoint[source.identifier],
              let destinationID = serverEndpointID,
              endpoints[destinationID]?.state != nil else {
            throw LuaError.runtime(
                "RunConsoleCommand cannot send: client transport is disconnected"
            )
        }
        nextSequence &+= 1
        appendDeliveryLocked(.console(GMLuaConsolePacket(
            sequence: nextSequence,
            sourceEndpointID: source.identifier,
            destinationEndpointID: destinationID,
            senderPlayerIndex: connection.playerIndex,
            connectionGeneration: connection.generation,
            command: command,
            arguments: arguments
        )))
    }

    /// Queues parsed SERVER `Player:ConCommand` requests for exactly one
    /// currently connected CLIENT. This is a host FIFO contract, not a direct
    /// realm call: each packet captures the connection generation and uses the
    /// active outer forwarded-action staging scope when present.
    func enqueueTargetedClientConsoleCommands(
        from source: GMLuaNetEndpoint,
        validating player: LuaValue,
        toPlayerIndex playerIndex: Int,
        commands: [GMLuaConsoleCommandInvocation]
    ) throws {
        guard source.realm == .server else {
            throw LuaError.runtime(
                "Player:ConCommand targeted delivery requires SERVER"
            )
        }
        guard !commands.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard serverEndpointID == source.identifier,
              endpoints[source.identifier] === source,
              endpoints[source.identifier]?.state != nil else {
            throw LuaError.runtime(
                "Player:ConCommand SERVER endpoint is detached"
            )
        }
        try source.validateCurrentServerPlayer(
            player,
            expectedIndex: playerIndex
        )
        guard let destinationID = clientEndpointByPlayerIndex[playerIndex],
              let connection = clientConnectionsByEndpoint[destinationID],
              connection.playerIndex == playerIndex,
              endpoints[destinationID]?.state != nil else {
            throw LuaError.runtime(
                "Player:ConCommand target Player(\(playerIndex)) is not connected"
            )
        }

        for command in commands {
            nextSequence &+= 1
            appendDeliveryLocked(.targetedClientConsole(
                GMLuaTargetedClientConsolePacket(
                    sequence: nextSequence,
                    sourceEndpointID: source.identifier,
                    destinationEndpointID: destinationID,
                    targetPlayerIndex: playerIndex,
                    connectionGeneration: connection.generation,
                    command: command.command,
                    arguments: command.arguments
                )
            ))
        }
    }

    /// Fans one `MsgAll` payload out to the currently connected CLIENT
    /// endpoints in stable endpoint order. Each delivery retains the current
    /// connection generation and participates in the forwarded-action staging
    /// scope just like net, console-command, and entity deliveries.
    func enqueueBroadcastConsoleMessage(
        _ message: LuaString,
        from source: GMLuaNetEndpoint
    ) throws {
        guard source.realm == .server else {
            throw LuaError.runtime("MsgAll broadcast requires SERVER")
        }

        lock.lock()
        defer { lock.unlock() }
        guard serverEndpointID == source.identifier,
              endpoints[source.identifier] === source,
              endpoints[source.identifier]?.state != nil else {
            throw LuaError.runtime("MsgAll SERVER endpoint is detached")
        }
        let destinations = endpoints.values
            .filter {
                $0.realm == .client && $0.state != nil &&
                    (!requiresExplicitClientConnections ||
                        clientConnectionsByEndpoint[$0.identifier] != nil)
            }
            .sorted { $0.identifier < $1.identifier }
        for destination in destinations {
            nextSequence &+= 1
            appendDeliveryLocked(.broadcastConsoleMessage(
                GMLuaBroadcastConsoleMessagePacket(
                    sequence: nextSequence,
                    sourceEndpointID: source.identifier,
                    destinationEndpointID: destination.identifier,
                    connectionGeneration:
                        clientConnectionsByEndpoint[destination.identifier]?.generation,
                    message: message
                )
            ))
        }
    }

    /// Fans one engine gameplay event out in stable CLIENT endpoint order.
    /// Each immutable packet is generation-bound and enters the transport-wide
    /// FIFO (including any active forwarded-action transaction) exactly once.
    fileprivate func enqueueGameplayEvent(
        _ payload: GMLuaGameplayEventPayload,
        from source: GMLuaNetEndpoint
    ) throws {
        guard source.realm == .server else {
            throw LuaError.runtime("gameplay event broadcast requires SERVER")
        }

        lock.lock()
        defer { lock.unlock() }
        guard serverEndpointID == source.identifier,
              endpoints[source.identifier] === source,
              endpoints[source.identifier]?.state != nil else {
            throw LuaError.runtime("gameplay event SERVER endpoint is detached")
        }
        let destinations = endpoints.values
            .filter {
                $0.realm == .client && $0.state != nil &&
                    (!requiresExplicitClientConnections ||
                        clientConnectionsByEndpoint[$0.identifier] != nil)
            }
            .sorted { $0.identifier < $1.identifier }
        for destination in destinations {
            nextSequence &+= 1
            appendDeliveryLocked(.gameplayEvent(GMLuaGameplayEventPacket(
                sequence: nextSequence,
                sourceEndpointID: source.identifier,
                destinationEndpointID: destination.identifier,
                connectionGeneration:
                    clientConnectionsByEndpoint[destination.identifier]?.generation,
                payload: payload
            )))
        }
    }

    /// Queues one generation-bound SERVER `Player:SendLua` delivery for the
    /// exact connected Player. It shares the net/console/entity FIFO and the
    /// current forwarded-command staging scope; no CLIENT Lua executes here.
    func enqueueClientLua(
        _ code: LuaString,
        from source: GMLuaNetEndpoint,
        toPlayerIndex playerIndex: Int
    ) throws {
        guard source.realm == .server else {
            throw LuaError.runtime("Player:SendLua is server-only")
        }
        guard code.count <= Self.maximumSendLuaCodeBytes else {
            throw LuaError.runtime(
                "Player:SendLua code exceeds the " +
                    "\(Self.maximumSendLuaCodeBytes)-byte limit"
            )
        }

        lock.lock()
        defer { lock.unlock() }
        guard serverEndpointID == source.identifier,
              endpoints[source.identifier] === source else {
            throw LuaError.runtime("Player:SendLua SERVER endpoint is detached")
        }
        guard let destinationID = clientEndpointByPlayerIndex[playerIndex],
              let connection = clientConnectionsByEndpoint[destinationID],
              endpoints[destinationID]?.state != nil else {
            throw LuaError.runtime(
                "Player:SendLua target Player(\(playerIndex)) is not connected"
            )
        }
        nextSequence &+= 1
        appendDeliveryLocked(.clientLua(GMLuaClientLuaPacket(
            sequence: nextSequence,
            sourceEndpointID: source.identifier,
            destinationEndpointID: destinationID,
            connectionGeneration: connection.generation,
            code: code
        )))
    }

    /// Adds an immutable SERVER snapshot/delta to the same outer FIFO used by
    /// net packets and forwarded console commands. The packet is not visible
    /// to its CLIENT-owned handler until the host pumps this transport.
    func enqueueEntityReplication(
        _ packet: SourceEntityReplicationPacket,
        from source: GMLuaNetEndpoint,
        to destination: GMLuaNetEndpoint
    ) throws {
        try enqueueEntityReplications(
            [GMLuaEntityReplicationEnqueueRequest(
                packet: packet,
                destination: destination
            )],
            from: source
        )
    }

    /// Validates an entire multi-CLIENT fan-out and appends it to the global
    /// FIFO as one lock transaction. A stale final destination cannot leave
    /// earlier clients with a packet the SERVER stream did not commit.
    func enqueueEntityReplications(
        _ requests: [GMLuaEntityReplicationEnqueueRequest],
        from source: GMLuaNetEndpoint
    ) throws {
        guard source.realm == .server else {
            throw GMLuaEntityReplicationTransportError.serverSourceRequired
        }
        guard requests.allSatisfy({ $0.destination.realm == .client }) else {
            throw GMLuaEntityReplicationTransportError.clientDestinationRequired
        }
        guard !requests.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard serverEndpointID == source.identifier,
              endpoints[source.identifier] === source else {
            throw GMLuaEntityReplicationTransportError.sourceEndpointDetached
        }
        for request in requests {
            let destination = request.destination
            guard endpoints[destination.identifier] === destination else {
                throw GMLuaEntityReplicationTransportError.destinationEndpointDetached
            }
            guard let connection = clientConnectionsByEndpoint[destination.identifier] else {
                throw GMLuaEntityReplicationTransportError.destinationNotConnected
            }
            let expectedGeneration = SourceEntityReplicationConnectionGeneration(
                rawValue: connection.generation
            )
            guard request.packet.connectionGeneration == expectedGeneration else {
                throw GMLuaEntityReplicationTransportError.connectionGenerationMismatch(
                    expected: expectedGeneration,
                    received: request.packet.connectionGeneration
                )
            }
        }
        let requestedSequenceCount = UInt64(requests.count)
        guard requestedSequenceCount <= UInt64.max - nextSequence else {
            throw GMLuaEntityReplicationTransportError.transportSequenceExhausted
        }

        var batch: [GMLuaTransportDelivery] = []
        batch.reserveCapacity(requests.count)
        for (offset, request) in requests.enumerated() {
            let destination = request.destination
            let connection = clientConnectionsByEndpoint[destination.identifier]!
            batch.append(.entity(GMLuaEntityReplicationDelivery(
                sequence: nextSequence + UInt64(offset) + 1,
                sourceEndpointID: source.identifier,
                destinationEndpointID: destination.identifier,
                connectionGeneration: connection.generation,
                packet: request.packet
            )))
        }
        nextSequence += requestedSequenceCount
        appendDeliveriesLocked(batch)
    }

    /// Requires `lock`. Sequence reservation remains global even when the
    /// resulting delivery is current-thread staged, so concurrent producers
    /// retain one total ordering and rollback never rewinds their clock.
    private func appendDeliveryLocked(_ delivery: GMLuaTransportDelivery) {
        if let context = currentDeliveryTransactionContext {
            context.deliveries.append(delivery)
        } else {
            deliveries.append(delivery)
        }
    }

    /// Requires `lock`.
    private func appendDeliveriesLocked(_ batch: [GMLuaTransportDelivery]) {
        guard !batch.isEmpty else { return }
        if let context = currentDeliveryTransactionContext {
            context.deliveries.append(contentsOf: batch)
        } else {
            deliveries.append(contentsOf: batch)
        }
    }

    /// Requires `lock`. A completed message becomes externally countable at
    /// the same commit boundary as every delivery produced by that message.
    private func recordCompletedMessageLocked() {
        if let context = currentDeliveryTransactionContext {
            context.completedMessageCount &+= 1
        } else {
            completedMessages &+= 1
        }
    }

    private var currentDeliveryTransactionContext:
        GMLuaTransportDeliveryTransactionContext? {
        Thread.current.threadDictionary[deliveryTransactionThreadKey]
            as? GMLuaTransportDeliveryTransactionContext
    }

    private static func mergeDeliveriesBySequence(
        _ existing: [GMLuaTransportDelivery],
        _ staged: [GMLuaTransportDelivery]
    ) -> [GMLuaTransportDelivery] {
        var merged: [GMLuaTransportDelivery] = []
        merged.reserveCapacity(existing.count + staged.count)
        var existingIndex = 0
        var stagedIndex = 0

        while existingIndex < existing.count, stagedIndex < staged.count {
            if existing[existingIndex].sequence < staged[stagedIndex].sequence {
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else {
                merged.append(staged[stagedIndex])
                stagedIndex += 1
            }
        }
        if existingIndex < existing.count {
            merged.append(contentsOf: existing[existingIndex...])
        }
        if stagedIndex < staged.count {
            merged.append(contentsOf: staged[stagedIndex...])
        }
        return merged
    }

    /// Delivers queued packets in deterministic sequence order.
    ///
    /// A receiver error is propagated after its reader is cleared. Any later
    /// deliveries remain queued for a subsequent host pump.
    @discardableResult
    public func pump(maxDeliveries: Int = .max) throws -> Int {
        try pump(
            maxDeliveries: maxDeliveries,
            reportForwardedConsoleFailures: false
        ).successfulDeliveries
    }

    /// Drains the same FIFO as ``pump``, but turns only typed expected SERVER
    /// action failures from forwarded console packets into values and
    /// continues. Connection-generation checks, endpoint/Player/dispatcher
    /// invariants, throwing host handlers, re-entry, and all net receiver
    /// failures retain the throwing contract.
    public func pumpReportingForwardedConsoleFailures(
        maxDeliveries: Int = .max
    ) throws -> GMLuaNetPumpReport {
        try pump(
            maxDeliveries: maxDeliveries,
            reportForwardedConsoleFailures: true
        )
    }

    private func pump(
        maxDeliveries: Int,
        reportForwardedConsoleFailures: Bool
    ) throws -> GMLuaNetPumpReport {
        guard maxDeliveries > 0 else {
            return GMLuaNetPumpReport(
                processedDeliveries: 0,
                successfulDeliveries: 0,
                forwardedConsoleFailures: []
            )
        }
        guard !isPumpingOnCurrentThread() else {
            throw LuaError.runtime(
                "GMLuaNetTransport.pump cannot be re-entered from a Lua delivery callback"
            )
        }
        beginExclusiveBoundary(markPumpThread: true)
        defer { endExclusiveBoundary(markPumpThread: true) }
        var processed = 0
        var successful = 0
        var consoleFailures: [GMLuaForwardedConsoleCommandFailure] = []
        while processed < maxDeliveries {
            let next: (GMLuaNetEndpoint, GMLuaTransportDelivery)?
            lock.lock()
            if deliveries.isEmpty {
                next = nil
            } else {
                let delivery = deliveries.removeFirst()
                if let endpoint = endpoints[delivery.destinationEndpointID] {
                    next = (endpoint, delivery)
                } else {
                    next = nil
                }
            }
            lock.unlock()
            guard let (endpoint, delivery) = next else {
                if pendingDeliveryCount == 0 { break }
                continue
            }
            switch delivery {
            case let .net(packet):
                try validateConnectionGeneration(
                    endpoint: endpoint,
                    sourceEndpointID: packet.sourceEndpointID,
                    senderPlayerIndex: packet.senderPlayerIndex,
                    generation: packet.connectionGeneration
                )
                try endpoint.beginReading(packet.bits)
                do {
                    try endpoint.invokeIncoming(
                        totalBits: packet.bits.bitCount,
                        senderPlayerIndex: packet.senderPlayerIndex
                    )
                    endpoint.finishReading()
                } catch {
                    endpoint.finishReading()
                    throw error
                }
            case let .console(packet):
                try validateConnectionGeneration(
                    endpoint: endpoint,
                    sourceEndpointID: packet.sourceEndpointID,
                    senderPlayerIndex: packet.senderPlayerIndex,
                    generation: packet.connectionGeneration
                )
                if reportForwardedConsoleFailures {
                    if let message = try endpoint
                        .invokeConsoleCommandReportingCommandFailure(
                        command: packet.command,
                        arguments: packet.arguments,
                        senderPlayerIndex: packet.senderPlayerIndex
                    ) {
                        consoleFailures.append(
                            GMLuaForwardedConsoleCommandFailure(
                                sequence: packet.sequence,
                                command: packet.command,
                                arguments: packet.arguments,
                                message: message
                            )
                        )
                    } else {
                        successful += 1
                    }
                } else {
                    try endpoint.invokeConsoleCommand(
                        command: packet.command,
                        arguments: packet.arguments,
                        senderPlayerIndex: packet.senderPlayerIndex
                    )
                    successful += 1
                }
            case let .targetedClientConsole(packet):
                try validateTargetedClientConsoleConnection(
                    endpoint: endpoint,
                    packet: packet
                )
                try endpoint.invokeTargetedClientConsoleCommand(packet)
                successful += 1
            case let .broadcastConsoleMessage(packet):
                try validateBroadcastConsoleConnection(
                    endpoint: endpoint,
                    packet: packet
                )
                endpoint.invokeBroadcastConsoleMessage(packet)
                successful += 1
            case let .clientLua(packet):
                try validateClientLuaConnection(
                    endpoint: endpoint,
                    packet: packet
                )
                try endpoint.invokeClientLua(packet)
                successful += 1
            case let .entity(entityDelivery):
                try validateEntityReplicationConnection(
                    endpoint: endpoint,
                    delivery: entityDelivery
                )
                try endpoint.invokeEntityReplication(entityDelivery)
                successful += 1
            case let .gameplayEvent(packet):
                try validateGameplayEventConnection(
                    endpoint: endpoint,
                    packet: packet
                )
                try endpoint.invokeGameplayEvent(packet)
                successful += 1
            }
            if case .net = delivery { successful += 1 }
            processed += 1
        }
        return GMLuaNetPumpReport(
            processedDeliveries: processed,
            successfulDeliveries: successful,
            forwardedConsoleFailures: consoleFailures
        )
    }

    private func validateConnectionGeneration(
        endpoint: GMLuaNetEndpoint,
        sourceEndpointID: Int,
        senderPlayerIndex: Int?,
        generation: UInt64?
    ) throws {
        lock.lock()
        let connection: ClientConnection?
        if endpoint.realm == .server {
            connection = clientConnectionsByEndpoint[sourceEndpointID]
        } else {
            connection = clientConnectionsByEndpoint[endpoint.identifier]
        }
        lock.unlock()
        if endpoint.realm == .client,
           senderPlayerIndex == nil,
           generation == nil,
           connection == nil {
            // Preserve the transport's standalone server-broadcast mode. A
            // player-connected shared session always carries a generation.
            return
        }
        guard let connection,
              connection.generation == generation else {
            throw LuaError.runtime(
                "queued delivery belongs to a stale player connection generation"
            )
        }
        if let senderPlayerIndex,
           connection.playerIndex != senderPlayerIndex {
            throw LuaError.runtime(
                "queued delivery sender does not match its connected Player"
            )
        }
    }

    private func validateTargetedClientConsoleConnection(
        endpoint: GMLuaNetEndpoint,
        packet: GMLuaTargetedClientConsolePacket
    ) throws {
        lock.lock()
        let sourceIsCurrentServer = serverEndpointID == packet.sourceEndpointID &&
            endpoints[packet.sourceEndpointID]?.state != nil
        let connection = clientConnectionsByEndpoint[endpoint.identifier]
        lock.unlock()

        guard sourceIsCurrentServer,
              endpoint.realm == .client,
              let connection,
              connection.endpointID == packet.destinationEndpointID,
              connection.playerIndex == packet.targetPlayerIndex,
              connection.generation == packet.connectionGeneration else {
            throw LuaError.runtime(
                "queued Player:ConCommand delivery belongs to a stale " +
                    "player connection generation"
            )
        }
    }

    private func validateBroadcastConsoleConnection(
        endpoint: GMLuaNetEndpoint,
        packet: GMLuaBroadcastConsoleMessagePacket
    ) throws {
        lock.lock()
        let sourceIsCurrentServer = serverEndpointID == packet.sourceEndpointID &&
            endpoints[packet.sourceEndpointID]?.state != nil
        let connection = clientConnectionsByEndpoint[endpoint.identifier]
        let standaloneBroadcast = !requiresExplicitClientConnections &&
            connection == nil && packet.connectionGeneration == nil
        lock.unlock()

        guard sourceIsCurrentServer,
              endpoint.realm == .client,
              endpoint.identifier == packet.destinationEndpointID else {
            throw LuaError.runtime(
                "queued MsgAll delivery belongs to a detached SERVER or CLIENT"
            )
        }
        if standaloneBroadcast { return }
        guard let connection,
              connection.endpointID == packet.destinationEndpointID,
              connection.generation == packet.connectionGeneration else {
            throw LuaError.runtime(
                "queued MsgAll delivery belongs to a stale player connection generation"
            )
        }
    }

    private func validateGameplayEventConnection(
        endpoint: GMLuaNetEndpoint,
        packet: GMLuaGameplayEventPacket
    ) throws {
        lock.lock()
        let sourceIsCurrentServer = serverEndpointID == packet.sourceEndpointID &&
            endpoints[packet.sourceEndpointID]?.state != nil
        let connection = clientConnectionsByEndpoint[endpoint.identifier]
        let standaloneBroadcast = !requiresExplicitClientConnections &&
            connection == nil && packet.connectionGeneration == nil
        lock.unlock()

        guard sourceIsCurrentServer,
              endpoint.realm == .client,
              endpoint.identifier == packet.destinationEndpointID else {
            throw LuaError.runtime(
                "queued gameplay event belongs to a detached SERVER or CLIENT"
            )
        }
        if standaloneBroadcast { return }
        guard let connection,
              connection.endpointID == packet.destinationEndpointID,
              connection.generation == packet.connectionGeneration else {
            throw LuaError.runtime(
                "queued gameplay event belongs to a stale player connection generation"
            )
        }
    }

    private func validateClientLuaConnection(
        endpoint: GMLuaNetEndpoint,
        packet: GMLuaClientLuaPacket
    ) throws {
        lock.lock()
        let sourceIsCurrentServer = serverEndpointID == packet.sourceEndpointID &&
            endpoints[packet.sourceEndpointID]?.state != nil
        let connection = clientConnectionsByEndpoint[endpoint.identifier]
        lock.unlock()

        guard sourceIsCurrentServer,
              endpoint.realm == .client,
              let connection,
              connection.endpointID == packet.destinationEndpointID,
              connection.generation == packet.connectionGeneration else {
            throw LuaError.runtime(
                "queued Player:SendLua delivery belongs to a stale " +
                    "player connection generation"
            )
        }
    }

    private func validateEntityReplicationConnection(
        endpoint: GMLuaNetEndpoint,
        delivery: GMLuaEntityReplicationDelivery
    ) throws {
        lock.lock()
        let sourceIsCurrentServer = serverEndpointID == delivery.sourceEndpointID &&
            endpoints[delivery.sourceEndpointID]?.state != nil
        let connection = clientConnectionsByEndpoint[endpoint.identifier]
        lock.unlock()

        guard sourceIsCurrentServer else {
            throw GMLuaEntityReplicationTransportError.sourceEndpointDetached
        }
        guard let connection else {
            throw GMLuaEntityReplicationTransportError.destinationNotConnected
        }
        let expectedGeneration = SourceEntityReplicationConnectionGeneration(
            rawValue: connection.generation
        )
        let receivedGeneration = SourceEntityReplicationConnectionGeneration(
            rawValue: delivery.connectionGeneration
        )
        guard delivery.packet.connectionGeneration == receivedGeneration,
              receivedGeneration == expectedGeneration else {
            throw GMLuaEntityReplicationTransportError.connectionGenerationMismatch(
                expected: expectedGeneration,
                received: delivery.packet.connectionGeneration
            )
        }
    }

    private var pumpThreadMarkerKey: String {
        "GMLuaNetTransport.pump.\(ObjectIdentifier(self))"
    }

    private var deliveryTransactionThreadKey: String {
        "GMLuaNetTransport.deliveryTransaction.\(ObjectIdentifier(self))"
    }

    private var boundaryThreadMarkerKey: String {
        "GMLuaNetTransport.boundary.\(ObjectIdentifier(self))"
    }

    private func beginExclusiveBoundary(markPumpThread: Bool = false) {
        let threadDictionary = Thread.current.threadDictionary
        if let depth = threadDictionary[boundaryThreadMarkerKey] as? Int {
            threadDictionary[boundaryThreadMarkerKey] = depth + 1
            if markPumpThread { threadDictionary[pumpThreadMarkerKey] = true }
            return
        }
        boundaryCondition.lock()
        while boundaryActive { boundaryCondition.wait() }
        boundaryActive = true
        boundaryCondition.unlock()
        threadDictionary[boundaryThreadMarkerKey] = 1
        if markPumpThread {
            threadDictionary[pumpThreadMarkerKey] = true
        }
    }

    private func endExclusiveBoundary(markPumpThread: Bool = false) {
        let threadDictionary = Thread.current.threadDictionary
        if markPumpThread {
            threadDictionary.removeObject(forKey: pumpThreadMarkerKey)
        }
        guard let depth = threadDictionary[boundaryThreadMarkerKey] as? Int else {
            preconditionFailure("unbalanced GMLuaNetTransport lifecycle boundary")
        }
        if depth > 1 {
            threadDictionary[boundaryThreadMarkerKey] = depth - 1
            return
        }
        threadDictionary.removeObject(forKey: boundaryThreadMarkerKey)
        boundaryCondition.lock()
        boundaryActive = false
        boundaryCondition.broadcast()
        boundaryCondition.unlock()
    }
}

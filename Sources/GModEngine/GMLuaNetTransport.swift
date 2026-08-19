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
    let unreliable: Bool
    let bits: GMLuaNetBitBuffer
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
    private let lock = NSLock()
    private var writer: GMLuaNetWriter?
    private var reader: GMLuaNetBitReader?

    fileprivate init(
        identifier: Int,
        realm: GMLuaRealm,
        state: LuaState,
        transport: GMLuaNetTransport
    ) {
        self.identifier = identifier
        self.realm = realm
        self.state = state
        self.transport = transport
    }

    fileprivate func installBindings(into state: LuaState) {
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
            throw transport.sendToServerError(for: self)
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

    fileprivate func detachFromSession() {
        lock.lock()
        writer = nil
        reader = nil
        state = nil
        transport = nil
        lock.unlock()
    }

    fileprivate func invokeIncoming(totalBits: Int) throws {
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
        _ = try state.call(
            incoming,
            arguments: [.number(Double(totalBits)), .nilValue]
        )
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
public final class GMLuaNetTransport: @unchecked Sendable {
    public static let maximumPayloadBytes = 65_533
    public static let maximumPayloadBits = maximumPayloadBytes * 8

    public let networkedGlobalTransport: GMLuaNetworkedGlobalTransport

    // LuaState is deliberately entered only at host pump boundaries. Keep the
    // whole dequeue/callback/reader-cleanup operation single-filed so two host
    // callers cannot remove packets for the same realm concurrently.
    private let pumpLock = NSLock()
    private let lock = NSLock()
    private var nextEndpointID = 1
    private var nextSequence: UInt64 = 0
    private var serverEndpointID: Int?
    private var endpoints: [Int: GMLuaNetEndpoint] = [:]
    private var deliveries: [GMLuaNetPacket] = []
    private var completedMessages: UInt64 = 0

    public init(
        networkedGlobalTransport: GMLuaNetworkedGlobalTransport = GMLuaNetworkedGlobalTransport()
    ) {
        self.networkedGlobalTransport = networkedGlobalTransport
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

    public var connectedClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return endpoints.values.reduce(into: 0) { count, endpoint in
            if endpoint.realm == .client && endpoint.state != nil { count += 1 }
        }
    }

    func installEndpoint(
        into state: LuaState,
        realm: GMLuaRealm
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
            transport: self
        )
        endpoints[identifier] = endpoint
        if realm == .server { serverEndpointID = identifier }
        lock.unlock()

        endpoint.installBindings(into: state)
        return endpoint
    }

    func detachEndpoint(_ endpoint: GMLuaNetEndpoint) {
        // Wait for any in-flight callback before allowing its LuaState to be
        // closed. Runtime shutdown is itself a host lifecycle boundary.
        pumpLock.lock()
        defer { pumpLock.unlock() }

        lock.lock()
        if endpoints[endpoint.identifier] === endpoint {
            endpoints.removeValue(forKey: endpoint.identifier)
            if serverEndpointID == endpoint.identifier {
                serverEndpointID = nil
            }
            deliveries.removeAll {
                $0.sourceEndpointID == endpoint.identifier ||
                    $0.destinationEndpointID == endpoint.identifier
            }
        }
        lock.unlock()
        endpoint.detachFromSession()
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
        completedMessages &+= 1
        let destinations = endpoints.values
            .filter { $0.realm == .client && $0.state != nil }
            .sorted { $0.identifier < $1.identifier }
        for destination in destinations {
            nextSequence &+= 1
            deliveries.append(GMLuaNetPacket(
                sequence: nextSequence,
                sourceEndpointID: source.identifier,
                destinationEndpointID: destination.identifier,
                unreliable: writer.unreliable,
                bits: messageBits
            ))
        }
    }

    fileprivate func sendToServerError(for source: GMLuaNetEndpoint) -> LuaError {
        lock.lock()
        let hasServer = serverEndpointID.flatMap { endpoints[$0] }?.state != nil
        lock.unlock()
        if !hasServer {
            return LuaError.runtime(
                "net.SendToServer cannot send: client transport is disconnected"
            )
        }
        return LuaError.runtime(
            "net.SendToServer requires a canonical server-side Player endpoint (not implemented in P0/P1)"
        )
    }

    /// Delivers queued packets in deterministic sequence order.
    ///
    /// A receiver error is propagated after its reader is cleared. Any later
    /// deliveries remain queued for a subsequent host pump.
    @discardableResult
    public func pump(maxDeliveries: Int = .max) throws -> Int {
        guard maxDeliveries > 0 else { return 0 }
        pumpLock.lock()
        defer { pumpLock.unlock() }
        var delivered = 0
        while delivered < maxDeliveries {
            let next: (GMLuaNetEndpoint, GMLuaNetPacket)?
            lock.lock()
            if deliveries.isEmpty {
                next = nil
            } else {
                let packet = deliveries.removeFirst()
                if let endpoint = endpoints[packet.destinationEndpointID] {
                    next = (endpoint, packet)
                } else {
                    next = nil
                }
            }
            lock.unlock()
            guard let (endpoint, packet) = next else {
                if pendingDeliveryCount == 0 { break }
                continue
            }

            try endpoint.beginReading(packet.bits)
            defer { endpoint.finishReading() }
            try endpoint.invokeIncoming(totalBits: packet.bits.bitCount)
            delivered += 1
        }
        return delivered
    }
}

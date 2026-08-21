import Foundation
import GModLua

/// Value-only Vector payload retained when CLIENT Lua dispatches an effect.
/// Realm-local mutable Vector userdata never crosses the renderer boundary.
public struct GMLuaEffectVector: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Immutable subset of CEffectData currently consumed by the stock Sandbox
/// prop-spawn path.
public struct GMLuaEffectDataSnapshot: Sendable, Equatable {
    public let origin: GMLuaEffectVector
    public let entityIdentity: SourceCanonicalEntityIdentity?

    public init(
        origin: GMLuaEffectVector,
        entityIdentity: SourceCanonicalEntityIdentity?
    ) {
        self.origin = origin
        self.entityIdentity = entityIdentity
    }
}

/// One renderer-neutral CLIENT `util.Effect` dispatch.
///
/// Capturing this request is the engine/renderer handoff. It does not claim
/// that a Lua EFFECT instance or Metal particles were rendered.
public struct GMLuaEffectRequest: Sendable, Equatable {
    public let sequence: UInt64
    public let name: String
    public let data: GMLuaEffectDataSnapshot
    public let allowOverride: Bool
    public let ignorePrediction: Bool?

    public init(
        sequence: UInt64,
        name: String,
        data: GMLuaEffectDataSnapshot,
        allowOverride: Bool,
        ignorePrediction: Bool?
    ) {
        self.sequence = sequence
        self.name = name
        self.data = data
        self.allowOverride = allowOverride
        self.ignorePrediction = ignorePrediction
    }
}

public typealias GMLuaEffectRequestSink = @Sendable (GMLuaEffectRequest) -> Void

private final class GMLuaEffectDataPayload: @unchecked Sendable {
    private let lock = NSLock()
    private var originStorage = GMLuaEffectVector(x: 0, y: 0, z: 0)
    private var entityIdentityStorage: SourceCanonicalEntityIdentity?

    var snapshot: GMLuaEffectDataSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return GMLuaEffectDataSnapshot(
            origin: originStorage,
            entityIdentity: entityIdentityStorage
        )
    }

    func setOrigin(_ origin: GMLuaEffectVector) {
        lock.lock()
        originStorage = origin
        lock.unlock()
    }

    func setEntityIdentity(_ identity: SourceCanonicalEntityIdentity?) {
        lock.lock()
        entityIdentityStorage = identity
        lock.unlock()
    }
}

/// CLIENT CEffectData and `util.Effect` host boundary.
///
/// Desktop Garry's Mod returns one shared CEffectData reference from repeated
/// `EffectData()` calls. This bridge preserves that aliasing behavior and
/// snapshots its mutable fields when `util.Effect` is dispatched. Requests are
/// bounded and observable so the call is never treated as a successful no-op.
public final class GMLuaEffects: @unchecked Sendable {
    public static let maximumBufferedRequests = 4_096

    private let lock = NSLock()
    private let sharedEffectData: LuaValue
    private var requestStorage: [GMLuaEffectRequest] = []
    private var droppedRequestCountStorage: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private var sinkStorage: GMLuaEffectRequestSink?

    private init(
        sharedEffectData: LuaValue,
        requestSink: GMLuaEffectRequestSink?
    ) {
        self.sharedEffectData = sharedEffectData
        sinkStorage = requestSink
    }

    public var capturedRequests: [GMLuaEffectRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    public var droppedRequestCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedRequestCountStorage
    }

    public func drainCapturedRequests() -> [GMLuaEffectRequest] {
        lock.lock()
        defer { lock.unlock() }
        let requests = requestStorage
        requestStorage.removeAll(keepingCapacity: true)
        droppedRequestCountStorage = 0
        return requests
    }

    public func connectRequestSink(_ sink: @escaping GMLuaEffectRequestSink) {
        lock.lock()
        sinkStorage = sink
        lock.unlock()
    }

    public func disconnectRequestSink() {
        lock.lock()
        sinkStorage = nil
        lock.unlock()
    }

    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        typeSystem: GMLuaTypeSystem,
        entityRegistry: GMLuaEntityRegistry,
        requestSink: GMLuaEffectRequestSink? = nil
    ) throws -> GMLuaEffects? {
        // SERVER util.Effect requires recipient networking, which this local
        // renderer handoff deliberately does not pretend to implement.
        guard realm == .client else { return nil }

        guard let metatable = typeSystem.metatable(named: "CEffectData") else {
            throw LuaError.runtime("GLua CEffectData metatable was not installed")
        }
        let payload = GMLuaEffectDataPayload()
        let shared = try typeSystem.makeObject(
            metaName: "CEffectData",
            payload: payload
        )
        let bridge = GMLuaEffects(
            sharedEffectData: shared,
            requestSink: requestSink
        )

        func setMethod(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) throws {
            let function = LuaNativeFunctionBox(
                body,
                debugName: "CEffectData:\(name)",
                gcReferences: { [weak bridge] in bridge?.references ?? [] }
            )
            try state.setRawTableValue(
                .nativeFunction(function),
                for: .string(LuaString(name)),
                in: metatable
            )
        }

        try setMethod("SetOrigin") { arguments in
            let receiver = try requiredPayload(
                arguments.first,
                function: "CEffectData:SetOrigin"
            )
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'SetOrigin' (Vector expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[1],
                function: "CEffectData:SetOrigin"
            )
            receiver.setOrigin(GMLuaEffectVector(
                x: components.0,
                y: components.1,
                z: components.2
            ))
            return []
        }
        try setMethod("GetOrigin") { arguments in
            let receiver = try requiredPayload(
                arguments.first,
                function: "CEffectData:GetOrigin"
            )
            let origin = receiver.snapshot.origin
            return [try GMLuaVectorAngle.makeNetworkVector(
                origin.x,
                origin.y,
                origin.z,
                typeSystem: typeSystem
            )]
        }
        try setMethod("SetEntity") { arguments in
            let receiver = try requiredPayload(
                arguments.first,
                function: "CEffectData:SetEntity"
            )
            guard arguments.indices.contains(1),
                  let typed = GMLuaTypeSystem.typedObject(from: arguments[1]),
                  typed.typeID == GMLuaTypeID.entity else {
                let actual = arguments.indices.contains(1)
                    ? arguments[1].typeName
                    : "no value"
                throw LuaError.runtime(
                    "bad argument #1 to 'SetEntity' (Entity expected, got \(actual))"
                )
            }
            let identity = entityRegistry.canonicalIdentity(for: arguments[1])
            if typed.isValid, identity == nil {
                throw LuaError.runtime(
                    "CEffectData:SetEntity requires an engine-owned Entity"
                )
            }
            receiver.setEntityIdentity(identity)
            return []
        }
        try setMethod("GetEntity") { arguments in
            let receiver = try requiredPayload(
                arguments.first,
                function: "CEffectData:GetEntity"
            )
            guard let identity = receiver.snapshot.entityIdentity else {
                return [state.getGlobal("NULL")]
            }
            let value = entityRegistry.entity(at: identity.index)
            guard entityRegistry.canonicalIdentity(for: value) == identity else {
                return [state.getGlobal("NULL")]
            }
            return [value]
        }

        let constructor = LuaNativeFunctionBox(
            { [weak bridge] _ in
                guard let bridge else {
                    throw LuaError.runtime("EffectData bridge is unavailable")
                }
                return [bridge.sharedEffectData]
            },
            debugName: "EffectData",
            gcReferences: { [weak bridge] in bridge?.references ?? [] }
        )
        state.setGlobal("EffectData", value: .nativeFunction(constructor))

        let util: LuaTable
        if case let .table(existing) = state.getGlobal("util") {
            util = existing
        } else {
            util = LuaTable()
        }
        let dispatch = LuaNativeFunctionBox(
            { [weak bridge] arguments in
                guard let bridge else {
                    throw LuaError.runtime("util.Effect bridge is unavailable")
                }
                let name = try requiredString(
                    arguments,
                    index: 0,
                    function: "util.Effect"
                )
                let data = try requiredPayload(
                    arguments.indices.contains(1) ? arguments[1] : nil,
                    function: "util.Effect"
                ).snapshot
                let allowOverride = try optionalBoolean(
                    arguments,
                    index: 2,
                    default: true,
                    function: "util.Effect"
                )
                let ignorePrediction = try optionalBooleanOrNil(
                    arguments,
                    index: 3,
                    function: "util.Effect"
                )
                bridge.capture(
                    name: name,
                    data: data,
                    allowOverride: allowOverride,
                    ignorePrediction: ignorePrediction
                )
                return []
            },
            debugName: "util.Effect",
            gcReferences: { [weak bridge] in bridge?.references ?? [] }
        )
        try state.setRawTableValue(
            .nativeFunction(dispatch),
            for: .string("Effect"),
            in: util
        )
        state.setGlobal("util", value: .table(util))
        return bridge
    }

    private var references: [LuaValue] { [sharedEffectData] }

    private func capture(
        name: String,
        data: GMLuaEffectDataSnapshot,
        allowOverride: Bool,
        ignorePrediction: Bool?
    ) {
        let sink: GMLuaEffectRequestSink?
        let request: GMLuaEffectRequest
        lock.lock()
        request = GMLuaEffectRequest(
            sequence: nextSequence,
            name: name,
            data: data,
            allowOverride: allowOverride,
            ignorePrediction: ignorePrediction
        )
        nextSequence &+= 1
        if requestStorage.count < Self.maximumBufferedRequests {
            requestStorage.append(request)
        } else if droppedRequestCountStorage < UInt64.max {
            droppedRequestCountStorage += 1
        }
        sink = sinkStorage
        lock.unlock()
        sink?(request)
    }
}

private func requiredPayload(
    _ value: LuaValue?,
    function: String
) throws -> GMLuaEffectDataPayload {
    guard let value,
          let object = GMLuaTypeSystem.typedObject(from: value),
          object.metaName == "CEffectData",
          let payload = object.payload as? GMLuaEffectDataPayload else {
        throw LuaError.runtime(
            "bad argument to '\(function)' (CEffectData expected, got " +
                "\(value?.typeName ?? "no value"))"
        )
    }
    return payload
}

private func requiredString(
    _ arguments: [LuaValue],
    index: Int,
    function: String
) throws -> String {
    guard arguments.indices.contains(index) else {
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' " +
                "(string expected, got no value)"
        )
    }
    switch arguments[index] {
    case let .string(value):
        return value.utf8String
    case let .number(value):
        return String(value)
    default:
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' " +
                "(string expected, got \(arguments[index].typeName))"
        )
    }
}

private func optionalBoolean(
    _ arguments: [LuaValue],
    index: Int,
    default defaultValue: Bool,
    function: String
) throws -> Bool {
    guard arguments.indices.contains(index) else { return defaultValue }
    if case .nilValue = arguments[index] { return defaultValue }
    guard case let .boolean(value) = arguments[index] else {
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' " +
                "(boolean expected, got \(arguments[index].typeName))"
        )
    }
    return value
}

private func optionalBooleanOrNil(
    _ arguments: [LuaValue],
    index: Int,
    function: String
) throws -> Bool? {
    guard arguments.indices.contains(index) else { return nil }
    if case .nilValue = arguments[index] { return nil }
    guard case let .boolean(value) = arguments[index] else {
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' " +
                "(boolean or CRecipientFilter expected, got " +
                "\(arguments[index].typeName))"
        )
    }
    return value
}

import Foundation
import GModLua

/// Immutable read surface for one canonical Source physics body.
///
/// A value is created either from the verified definition queued between
/// `Entity:Spawn` and the next fixed physics tick, or from the solver's latest
/// body snapshot. Both routes retain the complete EHANDLE and solid index and
/// derive bounds only from decoded collision vertices.
public struct SourceCanonicalPhysicsObjectSnapshot: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let localAxisAlignedBounds: SourceCollisionProperty
    public let massProperties: SourcePhysicsMassProperties
    public let transform: SourceEntityTransform
    public let linearVelocity: SourceVector3
    public let angularVelocity: SourceVector3
    public let motionType: SourcePhysicsMotionType
    public let isMotionEnabled: Bool
    public let isGravityEnabled: Bool
    public let isCollisionEnabled: Bool
    public let isSleeping: Bool

    /// Builds the truthful pre-simulation view of a spawned canonical prop.
    /// `SourceCanonicalPropPhysicsInput` performs the same model, solid,
    /// movement, lifecycle, and definition checks used by body creation.
    public init(
        pendingEntity entity: SourceCanonicalEntitySnapshot,
        definition: SourceCanonicalPropPhysicsBodyDefinition
    ) throws {
        _ = try SourceCanonicalPropPhysicsInput(
            entity: entity,
            bodyDefinition: definition
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity.identity,
            solidIndex: definition.solidIndex
        )
        self.bodyID = bodyID
        localAxisAlignedBounds = try Self.bounds(of: definition.shape)
        massProperties = definition.massProperties
        transform = entity.transform
        linearVelocity = entity.motion.linearVelocity
        angularVelocity = entity.motion.angularVelocity
        motionType = definition.motionType
        isMotionEnabled = definition.motionType != .staticBody
        isGravityEnabled = definition.isGravityEnabled
        isCollisionEnabled = definition.isCollisionEnabled
        isSleeping = !definition.startsAwake
    }

    /// Builds the post-simulation view without replacing any solver-authored
    /// pose, velocity, sleeping, or enablement state.
    public init(body: SourcePhysicsBodySnapshot) throws {
        bodyID = body.bodyID
        localAxisAlignedBounds = try Self.bounds(of: body.shape)
        massProperties = body.massProperties
        transform = body.transform
        linearVelocity = body.linearVelocity
        angularVelocity = body.angularVelocity
        motionType = body.motionType
        isMotionEnabled = body.isMotionEnabled
        isGravityEnabled = body.isGravityEnabled
        isCollisionEnabled = body.isCollisionEnabled
        isSleeping = body.isSleeping
    }

    private static func bounds(
        of shape: SourcePhysicsShapeSnapshot
    ) throws -> SourceCollisionProperty {
        var minimums = SourceVector3(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var maximums = SourceVector3(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )
        for part in shape.parts {
            for vertex in part.vertices {
                minimums.x = min(minimums.x, vertex.x)
                minimums.y = min(minimums.y, vertex.y)
                minimums.z = min(minimums.z, vertex.z)
                maximums.x = max(maximums.x, vertex.x)
                maximums.y = max(maximums.y, vertex.y)
                maximums.z = max(maximums.z, vertex.z)
            }
        }
        return try SourceCollisionProperty(mins: minimums, maxs: maximums)
    }
}

/// Read-only host boundary for the native `Entity`/`PhysObj` GLua ABI.
///
/// The entity lookup chooses the primary solid for `GetPhysicsObject`. Every
/// subsequent userdata call re-resolves its complete body ID, so slot reuse
/// cannot make an old generation observe a replacement body.
public protocol SourceCanonicalPhysicsObjectLuaHost: AnyObject {
    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot?

    func canonicalPhysicsObject(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot?

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws
}

public enum SourceCanonicalPhysicsObjectGLuaBridgeError:
    Error,
    CustomStringConvertible
{
    case missingRuntimeSurface(String)

    public var description: String {
        switch self {
        case let .missingRuntimeSurface(surface):
            return "canonical PhysObj ABI requires \(surface)"
        }
    }
}

private final class SourceCanonicalPhysicsObjectLuaWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalPhysicsObjectLuaHost)?

    init(_ value: any SourceCanonicalPhysicsObjectLuaHost) {
        self.value = value
    }
}

private final class SourceCanonicalPhysicsObjectLuaPayload: @unchecked Sendable {
    let owner: SourceCanonicalPhysicsObjectLuaOwner
    let bodyID: SourcePhysicsBodyID

    init(
        owner: SourceCanonicalPhysicsObjectLuaOwner,
        bodyID: SourcePhysicsBodyID
    ) {
        self.owner = owner
        self.bodyID = bodyID
    }
}

private final class SourceCanonicalPhysicsObjectLuaOwner: @unchecked Sendable {}

/// Installs a realm-local cache of full-identity `PhysObj` userdata.
///
/// Mutators enqueue validated commands on the authoritative SERVER host. They
/// never edit the read snapshot locally; the next fixed physics tick publishes
/// the solver result back through the same complete body identity.
public final class SourceCanonicalPhysicsObjectGLuaBridge: @unchecked Sendable {
    private let state: LuaState
    private let typeSystem: GMLuaTypeSystem
    private let entityRegistry: GMLuaEntityRegistry
    private let host: SourceCanonicalPhysicsObjectLuaWeakHost
    private let owner = SourceCanonicalPhysicsObjectLuaOwner()
    private let cacheLock = NSLock()
    private var valuesByBodyID: [SourcePhysicsBodyID: LuaValue] = [:]

    private init(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        entityRegistry: GMLuaEntityRegistry,
        host: any SourceCanonicalPhysicsObjectLuaHost
    ) {
        self.state = state
        self.typeSystem = typeSystem
        self.entityRegistry = entityRegistry
        self.host = SourceCanonicalPhysicsObjectLuaWeakHost(host)
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        host: any SourceCanonicalPhysicsObjectLuaHost
    ) throws -> SourceCanonicalPhysicsObjectGLuaBridge {
        guard !runtime.isClosed else {
            throw SourceCanonicalPhysicsObjectGLuaBridgeError
                .missingRuntimeSurface("an open runtime")
        }
        guard let typeSystem = runtime.typeSystem,
              let entityRegistry = runtime.entityRegistry,
              typeSystem.metatable(named: "Entity") != nil,
              typeSystem.metatable(named: "PhysObj") != nil else {
            throw SourceCanonicalPhysicsObjectGLuaBridgeError
                .missingRuntimeSurface("Entity registry and PhysObj metatable")
        }

        let bridge = SourceCanonicalPhysicsObjectGLuaBridge(
            state: runtime.state,
            typeSystem: typeSystem,
            entityRegistry: entityRegistry,
            host: host
        )
        try bridge.installMethods()
        return bridge
    }

    private var references: [LuaValue] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return Array(valuesByBodyID.values)
    }

    private func installMethods() throws {
        guard let entityMetatable = typeSystem.metatable(named: "Entity"),
              let physicsMetatable = typeSystem.metatable(named: "PhysObj") else {
            throw SourceCanonicalPhysicsObjectGLuaBridgeError
                .missingRuntimeSurface("Entity and PhysObj metatables")
        }

        try setMethod("Entity:GetPhysicsObject", on: entityMetatable) { arguments in
            guard let value = arguments.first,
                  let entity = self.entityRegistry.canonicalSnapshot(for: value) else {
                throw LuaError.runtime(
                    "bad self to 'Entity:GetPhysicsObject' " +
                    "(live canonical Entity expected)"
                )
            }
            guard let snapshot = self.host.value?.primaryCanonicalPhysicsObject(
                for: entity.identity
            ) else {
                return [self.state.getGlobal("NULL")]
            }
            guard snapshot.bodyID.entityIdentity == entity.identity else {
                throw LuaError.runtime(
                    "Entity:GetPhysicsObject host returned a mismatched EHANDLE"
                )
            }
            return [try self.cachedValue(for: snapshot.bodyID)]
        }

        try setMethod("PhysObj:IsValid", on: physicsMetatable) { arguments in
            guard let value = arguments.first,
                  let payload = self.payload(for: value),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
                return [.boolean(false)]
            }
            guard self.currentSnapshot(for: payload, value: value) != nil else {
                return [.boolean(false)]
            }
            return [.boolean(true)]
        }

        try setPhysicsReadMethod("GetAABB") { snapshot in
            [
                try self.vector(snapshot.localAxisAlignedBounds.mins),
                try self.vector(snapshot.localAxisAlignedBounds.maxs),
            ]
        }
        try setPhysicsReadMethod("GetMass") { snapshot in
            [.number(Double(snapshot.massProperties.massKilograms))]
        }
        try setPhysicsReadMethod("GetInertia") { snapshot in
            [try self.vector(snapshot.massProperties.principalInertia)]
        }
        try setPhysicsReadMethod("GetPos") { snapshot in
            [try self.vector(snapshot.transform.origin)]
        }
        try setPhysicsReadMethod("GetAngles") { snapshot in
            [try self.angle(snapshot.transform.angles)]
        }
        try setPhysicsReadMethod("GetVelocity") { snapshot in
            [try self.vector(snapshot.linearVelocity)]
        }
        try setPhysicsReadMethod("GetAngleVelocity") { snapshot in
            [try self.vector(snapshot.angularVelocity)]
        }
        try setPhysicsReadMethod("IsMotionEnabled") { snapshot in
            [.boolean(snapshot.isMotionEnabled)]
        }
        try setPhysicsReadMethod("IsGravityEnabled") { snapshot in
            [.boolean(snapshot.isGravityEnabled)]
        }
        try setPhysicsReadMethod("IsCollisionEnabled") { snapshot in
            [.boolean(snapshot.isCollisionEnabled)]
        }
        try setPhysicsReadMethod("IsAsleep") { snapshot in
            [.boolean(snapshot.isSleeping)]
        }

        try setPhysicsMutationMethod("Wake") { _ in .wake }
        try setPhysicsMutationMethod("Sleep") { _ in .sleep }
        try setPhysicsMutationMethod("EnableMotion") { arguments in
            .setMotionEnabled(try self.requiredBoolean(
                arguments,
                at: 1,
                function: "PhysObj:EnableMotion"
            ))
        }
        try setPhysicsMutationMethod("EnableGravity") { arguments in
            .setGravityEnabled(try self.requiredBoolean(
                arguments,
                at: 1,
                function: "PhysObj:EnableGravity"
            ))
        }
        try setPhysicsMutationMethod("EnableCollisions") { arguments in
            .setCollisionEnabled(try self.requiredBoolean(
                arguments,
                at: 1,
                function: "PhysObj:EnableCollisions"
            ))
        }
        try setPhysicsMutationMethod("SetVelocity") { arguments in
            .setLinearVelocity(try self.requiredVector(
                arguments,
                at: 1,
                function: "PhysObj:SetVelocity"
            ))
        }
        try setPhysicsMutationMethod("AddVelocity") { arguments in
            .addLinearVelocity(try self.requiredVector(
                arguments,
                at: 1,
                function: "PhysObj:AddVelocity"
            ))
        }
        try setPhysicsMutationMethod("SetAngleVelocity") { arguments in
            .setAngularVelocity(try self.requiredVector(
                arguments,
                at: 1,
                function: "PhysObj:SetAngleVelocity"
            ))
        }
        try setPhysicsMutationMethod("AddAngleVelocity") { arguments in
            .addAngularVelocity(try self.requiredVector(
                arguments,
                at: 1,
                function: "PhysObj:AddAngleVelocity"
            ))
        }
        try setPhysicsMutationMethod("ApplyForceCenter") { arguments in
            .applyCenterForce(try self.requiredVector(
                arguments,
                at: 1,
                function: "PhysObj:ApplyForceCenter"
            ))
        }
    }

    private func setPhysicsMutationMethod(
        _ name: String,
        mutation: @escaping ([LuaValue]) throws -> SourcePhysicsBodyMutation
    ) throws {
        guard let metatable = typeSystem.metatable(named: "PhysObj") else {
            throw SourceCanonicalPhysicsObjectGLuaBridgeError
                .missingRuntimeSurface("PhysObj metatable")
        }
        try setMethod("PhysObj:\(name)", on: metatable) { arguments in
            let snapshot = try self.requiredSnapshot(
                arguments.first,
                function: "PhysObj:\(name)"
            )
            guard let host = self.host.value else {
                throw LuaError.runtime(
                    "PhysObj:\(name) authoritative SERVER host is unavailable"
                )
            }
            try host.enqueueCanonicalPhysicsObjectMutation(
                SourcePhysicsBodyMutationCommand(
                    bodyID: snapshot.bodyID,
                    mutation: try mutation(arguments)
                )
            )
            return []
        }
    }

    private func setPhysicsReadMethod(
        _ name: String,
        body: @escaping (SourceCanonicalPhysicsObjectSnapshot) throws -> [LuaValue]
    ) throws {
        guard let metatable = typeSystem.metatable(named: "PhysObj") else {
            throw SourceCanonicalPhysicsObjectGLuaBridgeError
                .missingRuntimeSurface("PhysObj metatable")
        }
        try setMethod("PhysObj:\(name)", on: metatable) { arguments in
            let snapshot = try self.requiredSnapshot(
                arguments.first,
                function: "PhysObj:\(name)"
            )
            return try body(snapshot)
        }
    }

    private func setMethod(
        _ debugName: String,
        on metatable: LuaTable,
        body: @escaping LuaNativeFunction
    ) throws {
        let name = debugName.split(separator: ":").last.map(String.init) ?? debugName
        let function = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                body,
                debugName: debugName,
                gcReferences: { [weak self] in self?.references ?? [] }
            )
        )
        try state.setRawTableValue(
            function,
            for: .string(LuaString(name)),
            in: metatable
        )
    }

    private func cachedValue(for bodyID: SourcePhysicsBodyID) throws -> LuaValue {
        cacheLock.lock()
        if let cached = valuesByBodyID[bodyID],
           GMLuaTypeSystem.typedObject(from: cached)?.isValid == true {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let payload = SourceCanonicalPhysicsObjectLuaPayload(
            owner: owner,
            bodyID: bodyID
        )
        let value = try typeSystem.makeObject(metaName: "PhysObj", payload: payload)

        cacheLock.lock()
        if let raced = valuesByBodyID[bodyID],
           GMLuaTypeSystem.typedObject(from: raced)?.isValid == true {
            cacheLock.unlock()
            return raced
        }
        valuesByBodyID[bodyID] = value
        cacheLock.unlock()
        return value
    }

    private func payload(
        for value: LuaValue
    ) -> SourceCanonicalPhysicsObjectLuaPayload? {
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "PhysObj",
              let payload = object.payload as? SourceCanonicalPhysicsObjectLuaPayload,
              payload.owner === owner else { return nil }
        return payload
    }

    private func requiredSnapshot(
        _ value: LuaValue?,
        function: String
    ) throws -> SourceCanonicalPhysicsObjectSnapshot {
        guard let value,
              let payload = payload(for: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true,
              let snapshot = currentSnapshot(for: payload, value: value) else {
            throw LuaError.runtime(
                "bad self to '\(function)' (live canonical PhysObj expected)"
            )
        }
        return snapshot
    }

    private func currentSnapshot(
        for payload: SourceCanonicalPhysicsObjectLuaPayload,
        value: LuaValue
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        guard let snapshot = host.value?.canonicalPhysicsObject(for: payload.bodyID),
              snapshot.bodyID == payload.bodyID else {
            invalidate(value, bodyID: payload.bodyID)
            return nil
        }
        return snapshot
    }

    private func invalidate(_ value: LuaValue, bodyID: SourcePhysicsBodyID) {
        GMLuaTypeSystem.typedObject(from: value)?.isValid = false
        cacheLock.lock()
        if let cached = valuesByBodyID[bodyID], Self.sameUserdata(cached, value) {
            valuesByBodyID.removeValue(forKey: bodyID)
        }
        cacheLock.unlock()
    }

    private static func sameUserdata(_ lhs: LuaValue, _ rhs: LuaValue) -> Bool {
        guard case let .userdata(left) = lhs,
              case let .userdata(right) = rhs else { return false }
        return left === right
    }

    private func vector(_ value: SourceVector3) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkVector(
            Double(value.x),
            Double(value.y),
            Double(value.z),
            typeSystem: typeSystem
        )
    }

    private func angle(_ value: SourceQAngle) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkAngle(
            Double(value.pitch),
            Double(value.yaw),
            Double(value.roll),
            typeSystem: typeSystem
        )
    }

    private func requiredBoolean(
        _ arguments: [LuaValue],
        at index: Int,
        function: String
    ) throws -> Bool {
        guard arguments.indices.contains(index),
              case let .boolean(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(index) to '\(function)' " +
                "(boolean expected, got \(actual))"
            )
        }
        return value
    }

    private func requiredVector(
        _ arguments: [LuaValue],
        at index: Int,
        function: String
    ) throws -> SourceVector3 {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index) to '\(function)' " +
                "(Vector expected, got no value)"
            )
        }
        let components = try GMLuaVectorAngle.networkVectorComponents(
            from: arguments[index],
            function: function
        )
        return SourceVector3(
            Float(components.0),
            Float(components.1),
            Float(components.2)
        )
    }
}

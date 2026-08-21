import Foundation
import GModLua

/// The narrow authoritative host used by GLua's native Entity ABI. The bridge
/// receives immutable snapshots and mutation transactions only; it never owns
/// a second Entity table or allocates a synthetic handle.
public protocol SourceCanonicalEntityLuaHost: AnyObject {
    func validateCanonicalModel(
        _ model: SourceEntityModelReference,
        for kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation

    func validateCanonicalPropPhysicsModel(
        _ model: SourceEntityModelReference
    ) -> SourceCanonicalModelValidation

    func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot?

    func createCanonicalEntity(
        kind: SourceCanonicalEntityKind,
        at entryIndex: Int?,
        state: SourceCanonicalEntityState?,
        playerUserID: Int?
    ) throws -> SourceCanonicalEntitySnapshot

    func updateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot

    func setCanonicalBodyGroups(
        _ subModelIDs: String,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func spawnCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func activateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func markCanonicalEntityForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func rollbackCanonicalEntityCreation(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot
}

public enum SourceCanonicalEntityGLuaBridgeError: Error, CustomStringConvertible {
    case serverRealmRequired(GMLuaRealm)
    case missingRuntimeSurface(String)

    public var description: String {
        switch self {
        case let .serverRealmRequired(realm):
            return "canonical Entity mutation ABI requires SERVER, got \(realm.rawValue)"
        case let .missingRuntimeSurface(surface):
            return "canonical Entity mutation ABI requires \(surface)"
        }
    }
}

private final class SourceCanonicalEntityLuaWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

/// Swift requires a weak reference to live in mutable storage. Keeping the
/// mutable slot inside this retained box lets native closures avoid extending
/// registry/type-system lifetime on Apple and Windows alike.
private final class SourceCanonicalEntityLuaWeakObject<Value: AnyObject>:
    @unchecked Sendable
{
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

/// Installs the original GLua spellings over canonical Entity snapshots.
/// SERVER additionally receives mutators/`ents.Create` through its injected
/// authoritative host. CLIENT receives getters only and continues to be
/// populated exclusively by the ordered replication stream.
public enum SourceCanonicalEntityGLuaBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil
    ) throws {
        guard runtime.realm != .menu else {
            throw SourceCanonicalEntityGLuaBridgeError.serverRealmRequired(runtime.realm)
        }
        if runtime.realm == .server, host == nil {
            throw SourceCanonicalEntityGLuaBridgeError.missingRuntimeSurface(
                "an authoritative SERVER host"
            )
        }
        guard !runtime.isClosed else {
            throw SourceCanonicalEntityGLuaBridgeError.missingRuntimeSurface("an open runtime")
        }
        guard let registry = runtime.entityRegistry else {
            throw SourceCanonicalEntityGLuaBridgeError.missingRuntimeSurface("Entity registry")
        }
        guard let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw SourceCanonicalEntityGLuaBridgeError.missingRuntimeSurface(
                "Entity and Player metatables"
            )
        }

        let state = runtime.state
        let hostBox = SourceCanonicalEntityLuaWeakHost(host)
        let nullValue = state.getGlobal("NULL")
        let registryBox = SourceCanonicalEntityLuaWeakObject(registry)
        let typeSystemBox = SourceCanonicalEntityLuaWeakObject(typeSystem)

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func setMethod(
            _ name: String,
            on metatable: LuaTable,
            body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                native(name, body),
                for: .string(LuaString(name.split(separator: ":").last.map(String.init) ?? name)),
                in: metatable
            )
        }

        func requiredHost(_ function: String) throws -> any SourceCanonicalEntityLuaHost {
            guard let host = hostBox.value else {
                throw LuaError.runtime("\(function) canonical entity host is unavailable")
            }
            return host
        }

        func requiredSnapshot(
            _ value: LuaValue?,
            function: String,
            kind: SourceCanonicalEntityKind? = nil
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let registry = registryBox.value,
                  let value,
                  let snapshot = registry.canonicalSnapshot(for: value) else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            if let kind, snapshot.kind != kind {
                throw LuaError.runtime(
                    "bad self to '\(function)' (\(kind.className) expected, got \(snapshot.className))"
                )
            }
            return snapshot
        }

        func requiredString(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> String {
            guard arguments.indices.contains(index),
                  case let .string(value) = arguments[index] else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(string expected, got \(arguments.indices.contains(index) ? arguments[index].typeName : "no value"))"
                )
            }
            return value.utf8String
        }

        func requiredInteger(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Int {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (number expected, got no value)"
                )
            }
            let number: Double?
            switch arguments[index] {
            case let .number(value):
                number = value
            case let .string(value):
                number = Double(value.utf8String)
            default:
                number = nil
            }
            guard let number,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= 0,
                  number <= Double(Int32.max) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (non-negative integer expected)"
                )
            }
            return Int(number)
        }

        func vector(
            _ source: SourceVector3
        ) throws -> LuaValue {
            guard let typeSystem = typeSystemBox.value else {
                throw LuaError.runtime("Vector canonical type surface is unavailable")
            }
            return try GMLuaVectorAngle.makeNetworkVector(
                Double(source.x),
                Double(source.y),
                Double(source.z),
                typeSystem: typeSystem
            )
        }

        func angle(
            _ source: SourceQAngle
        ) throws -> LuaValue {
            guard let typeSystem = typeSystemBox.value else {
                throw LuaError.runtime("Angle canonical type surface is unavailable")
            }
            return try GMLuaVectorAngle.makeNetworkAngle(
                Double(source.pitch),
                Double(source.yaw),
                Double(source.roll),
                typeSystem: typeSystem
            )
        }

        func requiredCollisionProperty(
            _ snapshot: SourceCanonicalEntitySnapshot,
            function: String
        ) throws -> SourceCollisionProperty {
            guard let property = snapshot.collisionProperty else {
                throw LuaError.runtime(
                    "\(function) canonical collision property is unavailable"
                )
            }
            return property
        }

        try setMethod("Entity:GetPos", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:GetPos")
            return [try vector(snapshot.transform.origin)]
        }
        try setMethod("Entity:LocalToWorld", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:LocalToWorld"
            )
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:LocalToWorld' (Vector expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[1],
                function: "Entity:LocalToWorld"
            )
            let local = SourceVector3(
                Float(components.0),
                Float(components.1),
                Float(components.2)
            )
            return [try vector(snapshot.transform.transformPointFromLocal(local))]
        }
        try setMethod("Entity:WorldToLocal", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:WorldToLocal"
            )
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:WorldToLocal' (Vector expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[1],
                function: "Entity:WorldToLocal"
            )
            let world = SourceVector3(
                Float(components.0),
                Float(components.1),
                Float(components.2)
            )
            return [try vector(snapshot.transform.inverseTransformPointToLocal(world))]
        }
        try setMethod("Entity:OBBMins", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:OBBMins"
            )
            let property = try requiredCollisionProperty(
                snapshot,
                function: "Entity:OBBMins"
            )
            return [try vector(property.mins)]
        }
        try setMethod("Entity:OBBMaxs", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:OBBMaxs"
            )
            let property = try requiredCollisionProperty(
                snapshot,
                function: "Entity:OBBMaxs"
            )
            return [try vector(property.maxs)]
        }
        try setMethod("Entity:GetCollisionBounds", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetCollisionBounds"
            )
            let property = try requiredCollisionProperty(
                snapshot,
                function: "Entity:GetCollisionBounds"
            )
            return [try vector(property.mins), try vector(property.maxs)]
        }
        try setMethod("Entity:NearestPoint", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:NearestPoint"
            )
            let property = try requiredCollisionProperty(
                snapshot,
                function: "Entity:NearestPoint"
            )
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:NearestPoint' (Vector expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[1],
                function: "Entity:NearestPoint"
            )
            let worldPoint = SourceVector3(
                Float(components.0),
                Float(components.1),
                Float(components.2)
            )
            return [try vector(property.nearestPoint(
                to: worldPoint,
                transform: snapshot.transform
            ))]
        }
        try setMethod("Entity:GetVelocity", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetVelocity"
            )
            return [try vector(snapshot.motion.linearVelocity)]
        }
        try setMethod("Entity:GetMoveType", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetMoveType"
            )
            return [.number(Double(snapshot.moveType.rawValue))]
        }
        try setMethod("Entity:IsConstraint", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:IsConstraint"
            )
            switch snapshot.kind {
            case .world, .player, .propPhysics:
                return [.boolean(false)]
            }
        }
        try setMethod("Entity:IsWidget", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:IsWidget"
            )
            switch snapshot.kind {
            case .world, .player, .propPhysics:
                return [.boolean(false)]
            }
        }
        try setMethod("Entity:GetSkin", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:GetSkin")
            return [.number(Double(snapshot.skin))]
        }

        try setMethod("Player:Alive", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:Alive",
                kind: .player
            )
            return [.boolean(snapshot.motion.isAlive)]
        }
        try setMethod("Player:GetShootPos", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetShootPos",
                kind: .player
            )
            return [try vector(snapshot.transform.origin + snapshot.viewOffset)]
        }
        try setMethod("Player:EyeAngles", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:EyeAngles",
                kind: .player
            )
            return [try angle(snapshot.transform.angles)]
        }
        try setMethod("Player:GetVehicle", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetVehicle",
                kind: .player
            )
            guard let vehicle = snapshot.vehicle else { return [nullValue] }
            guard let registry = registryBox.value else { return [nullValue] }
            let value = registry.entity(at: vehicle.entryIndex)
            guard registry.canonicalIdentity(for: value) == vehicle else {
                return [nullValue]
            }
            return [value]
        }

        // CLIENT owns immutable replicated snapshots only. Returning here
        // keeps every mutation surface and ents.Create SERVER-exclusive.
        guard runtime.realm == .server else { return }

        try setMethod("Entity:SetModel", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetModel"
            )
            let path = try requiredString(arguments, index: 1, function: "Entity:SetModel")
            let host = try requiredHost("Entity:SetModel")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.model = SourceEntityModelReference(path)
            }
            return []
        }
        try setMethod("Entity:SetSkin", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:SetSkin")
            let skin = try requiredInteger(arguments, index: 1, function: "Entity:SetSkin")
            let host = try requiredHost("Entity:SetSkin")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.skin = skin
            }
            return []
        }
        try setMethod("Entity:SetBodyGroups", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetBodyGroups"
            )
            let subModelIDs = try requiredString(
                arguments,
                index: 1,
                function: "Entity:SetBodyGroups"
            )
            let host = try requiredHost("Entity:SetBodyGroups")
            _ = try host.setCanonicalBodyGroups(
                subModelIDs,
                for: snapshot.identity
            )
            return []
        }
        try setMethod("Entity:SetPos", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:SetPos")
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetPos' (Vector expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[1],
                function: "Entity:SetPos"
            )
            let host = try requiredHost("Entity:SetPos")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.transform.origin = SourceVector3(
                    Float(components.0),
                    Float(components.1),
                    Float(components.2)
                )
            }
            return []
        }
        try setMethod("Entity:SetAngles", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetAngles"
            )
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetAngles' (Angle expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkAngleComponents(
                from: arguments[1],
                function: "Entity:SetAngles"
            )
            let host = try requiredHost("Entity:SetAngles")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.transform.angles = SourceQAngle(
                    pitch: Float(components.0),
                    yaw: Float(components.1),
                    roll: Float(components.2)
                )
            }
            return []
        }
        try setMethod("Entity:SetCreator", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetCreator"
            )
            guard let registry = registryBox.value else {
                throw LuaError.runtime("Entity:SetCreator Entity registry is unavailable")
            }
            guard arguments.indices.contains(1),
                  let creator = registry.canonicalIdentity(for: arguments[1]) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetCreator' (live canonical Entity expected)"
                )
            }
            let host = try requiredHost("Entity:SetCreator")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.creator = creator
            }
            return []
        }
        try setMethod("Entity:Spawn", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:Spawn")
            let host = try requiredHost("Entity:Spawn")
            do {
                _ = try host.spawnCanonicalEntity(snapshot.identity)
            } catch {
                if host.canonicalSnapshot(for: snapshot.identity)?.lifecycle == .created {
                    do {
                        _ = try host.rollbackCanonicalEntityCreation(snapshot.identity)
                    } catch let rollbackError {
                        throw LuaError.runtime(
                            "Entity:Spawn failed: \(error); exact EHANDLE rollback failed: \(rollbackError)"
                        )
                    }
                }
                throw LuaError.runtime("Entity:Spawn failed: \(error)")
            }
            return []
        }
        try setMethod("Entity:Activate", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:Activate")
            let host = try requiredHost("Entity:Activate")
            _ = try host.activateCanonicalEntity(snapshot.identity)
            return []
        }
        try setMethod("Entity:Remove", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:Remove")
            let host = try requiredHost("Entity:Remove")
            _ = try host.markCanonicalEntityForRemoval(snapshot.identity)
            return []
        }

        let ents: LuaTable
        if case let .table(existing) = state.getGlobal("ents") {
            ents = existing
        } else {
            ents = LuaTable()
        }
        try state.setRawTableValue(
            native("ents.Create") { arguments in
                let className = try requiredString(arguments, index: 0, function: "ents.Create")
                guard className == SourceCanonicalEntityKind.propPhysics.className else {
                    return [nullValue]
                }
                let host = try requiredHost("ents.Create")
                let snapshot: SourceCanonicalEntitySnapshot
                do {
                    snapshot = try host.createCanonicalEntity(
                        kind: .propPhysics,
                        at: nil,
                        state: nil,
                        playerUserID: nil
                    )
                } catch SourceCanonicalEntityError.noFreeNetworkableSlot {
                    return [nullValue]
                }

                guard let registry = registryBox.value else {
                    _ = try host.rollbackCanonicalEntityCreation(snapshot.identity)
                    throw LuaError.runtime("ents.Create Entity registry is unavailable")
                }
                let value = registry.entity(at: snapshot.identity.entryIndex)
                guard registry.canonicalIdentity(for: value) == snapshot.identity else {
                    _ = try host.rollbackCanonicalEntityCreation(snapshot.identity)
                    throw LuaError.runtime(
                        "ents.Create failed to publish the exact canonical EHANDLE"
                    )
                }
                return [value]
            },
            for: .string("Create"),
            in: ents
        )
        state.setGlobal("ents", value: .table(ents))

        let util: LuaTable
        if case let .table(existing) = state.getGlobal("util") {
            util = existing
        } else {
            util = LuaTable()
        }
        try state.setRawTableValue(
            native("util.IsValidModel") { arguments in
                let path = try requiredString(
                    arguments,
                    index: 0,
                    function: "util.IsValidModel"
                )
                guard let host = hostBox.value else { return [.boolean(false)] }
                let validation = host.validateCanonicalModel(
                    SourceEntityModelReference(path),
                    for: .propPhysics
                )
                return [.boolean(validation == .valid)]
            },
            for: .string("IsValidModel"),
            in: util
        )
        try state.setRawTableValue(
            native("util.IsValidProp") { arguments in
                let path = try requiredString(
                    arguments,
                    index: 0,
                    function: "util.IsValidProp"
                )
                guard let host = hostBox.value else { return [.boolean(false)] }
                let validation = host.validateCanonicalPropPhysicsModel(
                    SourceEntityModelReference(path)
                )
                return [.boolean(validation == .valid)]
            },
            for: .string("IsValidProp"),
            in: util
        )
        state.setGlobal("util", value: .table(util))
    }
}

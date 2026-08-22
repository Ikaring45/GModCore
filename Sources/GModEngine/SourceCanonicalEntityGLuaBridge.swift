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

    /// Allocates one registered SWEP class as an unowned world Weapon. The
    /// caller supplies the exact inherited `WorldModel` already resolved from
    /// `weapons.Get`; the host must validate that asset before touching a
    /// SourceEntityList slot. This is deliberately separate from Player:Give,
    /// which creates an inventory-owned Weapon and has different solidity.
    func createCanonicalWorldWeapon(
        className: String,
        worldModel: SourceEntityModelReference
    ) throws -> SourceCanonicalEntitySnapshot

    func updateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot

    func setCanonicalMaterialOverride(
        _ materialName: String,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func giveCanonicalWeapon(
        className: String,
        to player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    @discardableResult
    func selectCanonicalWeapon(
        className: String,
        for player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func canonicalBodyGroupLayout(
        for model: SourceEntityModelReference
    ) throws -> SourceStudioBodyGroupLayout

    func canonicalModelAppearance(
        for model: SourceEntityModelReference
    ) throws -> SourceStudioModelAppearanceLayout

    func setCanonicalSkin(
        _ skinFamily: Int,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func setCanonicalBodyGroup(
        _ bodyGroupID: Int,
        selection: Int,
        for identity: SourceCanonicalEntityIdentity
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
              let playerMetatable = typeSystem.metatable(named: "Player"),
              let weaponMetatable = typeSystem.metatable(named: "Weapon") else {
            throw SourceCanonicalEntityGLuaBridgeError.missingRuntimeSurface(
                "Entity, Player, and Weapon metatables"
            )
        }

        let state = runtime.state
        let hostBox = SourceCanonicalEntityLuaWeakHost(host)
        let nullValue = state.getGlobal("NULL")
        let registryBox = SourceCanonicalEntityLuaWeakObject(registry)
        let typeSystemBox = SourceCanonicalEntityLuaWeakObject(typeSystem)

        // Public GLua spellings for Source SDK `RenderMode_t`. Installing the
        // complete native enum keeps the bundled colour stool's alpha branch
        // and later renderer consumers on one numeric contract.
        let renderModeConstants: [(String, SourceEntityRenderMode)] = [
            ("RENDERMODE_NORMAL", .normal),
            ("RENDERMODE_TRANSCOLOR", .transColor),
            ("RENDERMODE_TRANSTEXTURE", .transTexture),
            ("RENDERMODE_GLOW", .glow),
            ("RENDERMODE_TRANSALPHA", .transAlpha),
            ("RENDERMODE_TRANSADD", .transAdd),
            ("RENDERMODE_ENVIRONMENTAL", .environmental),
            ("RENDERMODE_TRANSADDFRAMEBLEND", .transAddFrameBlend),
            ("RENDERMODE_TRANSALPHAADD", .transAlphaAdd),
            ("RENDERMODE_WORLDGLOW", .worldGlow),
            ("RENDERMODE_NONE", .none),
        ]
        for (name, mode) in renderModeConstants {
            state.setGlobal(name, value: .number(Double(mode.rawValue)))
        }

        let observerModeConstants: [
            (String, SourceCanonicalPlayerObserverMode)
        ] = [
            ("OBS_MODE_NONE", .none),
            ("OBS_MODE_DEATHCAM", .deathCam),
            ("OBS_MODE_FREEZECAM", .freezeCam),
            ("OBS_MODE_FIXED", .fixed),
            ("OBS_MODE_IN_EYE", .inEye),
            ("OBS_MODE_CHASE", .chase),
            ("OBS_MODE_ROAMING", .roaming),
        ]
        for (name, mode) in observerModeConstants {
            state.setGlobal(name, value: .number(Double(mode.rawValue)))
        }

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

        func requiredPlayerMovementSettings(
            _ snapshot: SourceCanonicalEntitySnapshot,
            function: String
        ) throws -> SourceCanonicalPlayerMovementSettings {
            guard let settings = snapshot.motion.playerMovementSettings else {
                throw LuaError.runtime(
                    "\(function) canonical Player movement state is unavailable"
                )
            }
            return settings
        }

        func requiredPlayerObserverState(
            _ snapshot: SourceCanonicalEntitySnapshot,
            function: String
        ) throws -> SourceCanonicalPlayerObserverState {
            guard let observer = snapshot.motion.playerObserverState else {
                throw LuaError.runtime(
                    "\(function) canonical Player observer state is unavailable"
                )
            }
            return observer
        }

        func requiredPlayerColorState(
            _ snapshot: SourceCanonicalEntitySnapshot,
            function: String
        ) throws -> SourceCanonicalPlayerColorState {
            guard let colors = snapshot.playerColorState else {
                throw LuaError.runtime(
                    "\(function) canonical Player color state is unavailable"
                )
            }
            return colors
        }

        func requiredPlayerAmmoState(
            _ snapshot: SourceCanonicalEntitySnapshot,
            function: String
        ) throws -> SourceCanonicalPlayerAmmoState {
            guard let ammo = snapshot.playerAmmoState else {
                throw LuaError.runtime(
                    "\(function) canonical Player ammo state is unavailable"
                )
            }
            return ammo
        }

        func liveWeaponValue(
            _ record: SourceCanonicalWeaponRecord
        ) -> LuaValue? {
            guard let registry = registryBox.value else { return nil }
            let value = registry.entity(at: record.identity.entryIndex)
            guard let snapshot = registry.canonicalSnapshot(for: value),
                  snapshot.identity == record.identity,
                  snapshot.kind == .weapon,
                  snapshot.className.caseInsensitiveCompare(record.className)
                    == .orderedSame,
                  snapshot.lifecycle != .pendingRemoval,
                  snapshot.lifecycle != .removed else { return nil }
            return value
        }

        func weaponRecord(
            in snapshot: SourceCanonicalEntitySnapshot,
            className: String
        ) -> SourceCanonicalWeaponRecord? {
            guard let record = snapshot.weaponInventory.weapon(
                className: className
            ), liveWeaponValue(record) != nil else { return nil }
            return record
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

        func requiredSignedInteger(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Int {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                        "(32-bit integer expected, got no value)"
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
                  let value = Int32(exactly: number) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                        "(32-bit integer expected)"
                )
            }
            return Int(value)
        }

        func requiredAmmoAmount(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Int32 {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(32-bit integer expected, got no value)"
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
                  let amount = Int32(exactly: number) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(32-bit integer expected)"
                )
            }
            return amount
        }

        func resolvedDefaultAmmoType(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> SourceCanonicalDefaultAmmoType? {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(default ammo name or ID expected, got no value)"
                )
            }
            switch arguments[index] {
            case let .string(value):
                return SourceCanonicalDefaultAmmoCatalog.type(
                    name: value.utf8String
                )
            case let .number(value):
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      let id = Int32(exactly: value) else {
                    throw LuaError.runtime(
                        "bad argument #\(index) to '\(function)' " +
                        "(32-bit ammo ID expected)"
                    )
                }
                return SourceCanonicalDefaultAmmoCatalog.type(id: id)
            default:
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(default ammo name or ID expected)"
                )
            }
        }

        func optionalBoolean(
            _ arguments: [LuaValue],
            index: Int,
            function: String,
            default defaultValue: Bool
        ) throws -> Bool {
            guard arguments.indices.contains(index) else { return defaultValue }
            switch arguments[index] {
            case let .boolean(value):
                return value
            case .nilValue:
                return defaultValue
            default:
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(boolean expected)"
                )
            }
        }

        func maximumReserveAmmoCount(function: String) throws -> Int32 {
            // Garry's Mod's engine default is 9999. A positive host ConVar
            // overrides it. Values below one request per-type maxcarry data,
            // which this fixed default catalog does not yet own.
            guard let raw = runtime.engineConVarCatalog?.currentValue(
                for: "gmod_maxammo"
            ) else { return 9_999 }
            guard let number = Double(raw), number.isFinite else {
                throw LuaError.runtime(
                    "\(function) gmod_maxammo is not a finite number"
                )
            }
            let integer = number.rounded(.towardZero)
            guard integer >= 1 else {
                throw LuaError.runtime(
                    "\(function) per-ammo maxcarry is unavailable while " +
                    "gmod_maxammo is below one"
                )
            }
            guard integer <= Double(Int32.max),
                  let maximum = Int32(exactly: integer) else {
                throw LuaError.runtime(
                    "\(function) gmod_maxammo exceeds Source's 32-bit range"
                )
            }
            return maximum
        }

        func requiredNonNegativeFloat(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Float {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(finite non-negative number expected, got no value)"
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
                  number >= 0,
                  number <= Double(Float.greatestFiniteMagnitude) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(finite non-negative number expected)"
                )
            }
            return Float(number)
        }

        func requiredFinitePlayerColorVector(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> SourceVector3 {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(finite Vector expected, got no value)"
                )
            }
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: arguments[index],
                function: function
            )
            guard components.0.isFinite,
                  components.1.isFinite,
                  components.2.isFinite,
                  abs(components.0) <= Double(Float.greatestFiniteMagnitude),
                  abs(components.1) <= Double(Float.greatestFiniteMagnitude),
                  abs(components.2) <= Double(Float.greatestFiniteMagnitude) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' " +
                    "(finite Vector expected)"
                )
            }
            // The public API documents normalized RGB, but bundled Sandbox's
            // own cl_weaponcolor default is 0.30 1.80 2.10. Preserve the
            // engine-authored finite values instead of inventing a clamp that
            // would change the original route.
            return SourceVector3(
                Float(components.0),
                Float(components.1),
                Float(components.2)
            )
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
        try setMethod("Entity:IsWorld", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:IsWorld"
            )
            return [.boolean(snapshot.kind == .world)]
        }
        try setMethod("Entity:GetCollisionGroup", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetCollisionGroup"
            )
            return [.number(Double(snapshot.collisionGroup))]
        }
        try setMethod("Entity:GetPersistent", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetPersistent"
            )
            return [.boolean(snapshot.isPersistent)]
        }
        try setMethod("Entity:IsConstraint", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:IsConstraint"
            )
            switch snapshot.kind {
            case .physicsConstraint:
                return [.boolean(true)]
            case .world, .player, .propPhysics, .playerHands, .weapon:
                return [.boolean(false)]
            }
        }
        try setMethod("Entity:IsWidget", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:IsWidget"
            )
            switch snapshot.kind {
            case .world, .player, .propPhysics, .physicsConstraint,
                 .playerHands, .weapon:
                return [.boolean(false)]
            }
        }
        try setMethod("Entity:GetSkin", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(arguments.first, function: "Entity:GetSkin")
            return [.number(Double(snapshot.skin))]
        }
        try setMethod("Entity:SkinCount", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SkinCount"
            )
            guard let model = snapshot.model else { return [.number(0)] }
            let appearance = try requiredHost("Entity:SkinCount")
                .canonicalModelAppearance(for: model)
            return [.number(Double(appearance.skinFamilyCount))]
        }
        try setMethod("Entity:GetMaterial", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetMaterial"
            )
            return [.string(LuaString(snapshot.materialOverride?.name ?? ""))]
        }
        try setMethod("Entity:GetNumBodyGroups", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetNumBodyGroups"
            )
            guard let model = snapshot.model else { return [.number(0)] }
            let layout = try requiredHost("Entity:GetNumBodyGroups")
                .canonicalBodyGroupLayout(for: model)
            return [.number(Double(layout.bodyGroupCount))]
        }
        try setMethod("Entity:GetBodygroup", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetBodygroup"
            )
            let bodyGroupID = try requiredSignedInteger(
                arguments,
                index: 1,
                function: "Entity:GetBodygroup"
            )
            guard let model = snapshot.model else { return [.number(0)] }
            let layout = try requiredHost("Entity:GetBodygroup")
                .canonicalBodyGroupLayout(for: model)
            return [.number(Double(try layout.selection(
                forBodyGroupID: bodyGroupID,
                bodyValue: snapshot.bodyValue
            )))]
        }
        try setMethod("Entity:GetBodygroupCount", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetBodygroupCount"
            )
            let bodyGroupID = try requiredSignedInteger(
                arguments,
                index: 1,
                function: "Entity:GetBodygroupCount"
            )
            guard let model = snapshot.model else { return [.number(0)] }
            let layout = try requiredHost("Entity:GetBodygroupCount")
                .canonicalBodyGroupLayout(for: model)
            guard layout.bodyParts.indices.contains(bodyGroupID) else {
                return [.number(0)]
            }
            return [.number(Double(layout.bodyParts[bodyGroupID].modelCount))]
        }
        try setMethod("Entity:GetBodygroupName", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetBodygroupName"
            )
            let bodyGroupID = try requiredSignedInteger(
                arguments,
                index: 1,
                function: "Entity:GetBodygroupName"
            )
            guard let model = snapshot.model else {
                return [.string(LuaString(""))]
            }
            let appearance = try requiredHost("Entity:GetBodygroupName")
                .canonicalModelAppearance(for: model)
            return [.string(LuaString(
                appearance.bodyGroup(id: bodyGroupID)?.name ?? ""
            ))]
        }
        try setMethod("Entity:GetBodyGroups", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetBodyGroups"
            )
            let result = LuaTable()
            guard let model = snapshot.model else { return [.table(result)] }
            let appearance = try requiredHost("Entity:GetBodyGroups")
                .canonicalModelAppearance(for: model)
            for bodyGroup in appearance.bodyGroups {
                let entry = LuaTable()
                try state.setRawTableValue(
                    .number(Double(bodyGroup.id)),
                    for: .string(LuaString("id")),
                    in: entry
                )
                try state.setRawTableValue(
                    .string(LuaString(bodyGroup.name)),
                    for: .string(LuaString("name")),
                    in: entry
                )
                try state.setRawTableValue(
                    .number(Double(bodyGroup.modelCount)),
                    for: .string(LuaString("num")),
                    in: entry
                )
                let submodels = LuaTable()
                for (submodelID, name) in bodyGroup.submodelNames.enumerated() {
                    try state.setRawTableValue(
                        .string(LuaString(name)),
                        for: .number(Double(submodelID)),
                        in: submodels
                    )
                }
                try state.setRawTableValue(
                    .table(submodels),
                    for: .string(LuaString("submodels")),
                    in: entry
                )
                try state.setRawTableValue(
                    .table(entry),
                    for: .number(Double(bodyGroup.id + 1)),
                    in: result
                )
            }
            return [.table(result)]
        }
        // `lua/includes/extensions/entity.lua` implements the public
        // Entity:GetColor/SetColor methods over these native four-part APIs.
        // Returning four numbers lets the bundled Color constructor and Color
        // metatable remain the only Lua color representation.
        try setMethod("Entity:GetColor4Part", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetColor4Part"
            )
            let color = snapshot.renderState.color
            return [
                .number(Double(color.red)),
                .number(Double(color.green)),
                .number(Double(color.blue)),
                .number(Double(color.alpha)),
            ]
        }
        try setMethod("Entity:GetRenderMode", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetRenderMode"
            )
            return [.number(Double(snapshot.renderState.mode.rawValue))]
        }
        try setMethod("Entity:GetRenderFX", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetRenderFX"
            )
            return [.number(Double(snapshot.renderState.fx.rawValue))]
        }
        try setMethod("Weapon:GetHoldType", on: weaponMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Weapon:GetHoldType",
                kind: .weapon
            )
            guard let holdType = snapshot.weaponHoldType else {
                throw LuaError.runtime(
                    "Weapon:GetHoldType canonical hold type is unavailable"
                )
            }
            return [.string(LuaString(holdType))]
        }

        try setMethod("Player:Alive", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:Alive",
                kind: .player
            )
            return [.boolean(snapshot.motion.isAlive)]
        }
        try setMethod("Player:GetClassID", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetClassID",
                kind: .player
            )
            guard let classID = snapshot.motion.playerClassID else {
                throw LuaError.runtime(
                    "Player:GetClassID canonical Player class state is unavailable"
                )
            }
            return [.number(Double(classID))]
        }
        try setMethod("Player:GetObserverMode", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetObserverMode",
                kind: .player
            )
            let observer = try requiredPlayerObserverState(
                snapshot,
                function: "Player:GetObserverMode"
            )
            return [.number(Double(observer.mode.rawValue))]
        }
        try setMethod("Player:GetPlayerColor", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetPlayerColor",
                kind: .player
            )
            return [try vector(try requiredPlayerColorState(
                snapshot,
                function: "Player:GetPlayerColor"
            ).playerColor)]
        }
        try setMethod("Player:GetWeaponColor", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetWeaponColor",
                kind: .player
            )
            return [try vector(try requiredPlayerColorState(
                snapshot,
                function: "Player:GetWeaponColor"
            ).weaponColor)]
        }
        for field in SourceCanonicalPlayerMovementField.allCases {
            let function = "Player:\(field.getterName)"
            try setMethod(function, on: playerMetatable) { arguments in
                let snapshot = try requiredSnapshot(
                    arguments.first,
                    function: function,
                    kind: .player
                )
                let settings = try requiredPlayerMovementSettings(
                    snapshot,
                    function: function
                )
                return [.number(Double(field.value(in: settings)))]
            }
        }
        try setMethod("Player:InVehicle", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:InVehicle",
                kind: .player
            )
            return [.boolean(snapshot.vehicle != nil)]
        }
        for method in ["Nick", "Name", "GetName"] {
            try setMethod("Player:\(method)", on: playerMetatable) { arguments in
                let snapshot = try requiredSnapshot(
                    arguments.first,
                    function: "Player:\(method)",
                    kind: .player
                )
                guard let displayName = snapshot.playerDisplayName else {
                    throw LuaError.runtime(
                        "Player:\(method) canonical display name is unavailable"
                    )
                }
                return [.string(LuaString(displayName))]
            }
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
        try setMethod("Player:HasWeapon", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:HasWeapon",
                kind: .player
            )
            let className = try requiredString(
                arguments,
                index: 1,
                function: "Player:HasWeapon"
            )
            return [.boolean(
                weaponRecord(in: snapshot, className: className) != nil
            )]
        }
        try setMethod("Player:GetWeapon", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetWeapon",
                kind: .player
            )
            let className = try requiredString(
                arguments,
                index: 1,
                function: "Player:GetWeapon"
            )
            guard let record = weaponRecord(
                in: snapshot,
                className: className
            ), let value = liveWeaponValue(record) else { return [nullValue] }
            return [value]
        }
        try setMethod("Player:GetWeapons", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetWeapons",
                kind: .player
            )
            let table = LuaTable()
            var luaIndex = 1
            for record in snapshot.weaponInventory.weapons {
                guard let value = liveWeaponValue(record) else { continue }
                try state.setRawTableValue(
                    value,
                    for: .number(Double(luaIndex)),
                    in: table
                )
                luaIndex += 1
            }
            return [.table(table)]
        }
        try setMethod("Player:GetActiveWeapon", on: playerMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Player:GetActiveWeapon",
                kind: .player
            )
            guard let identity = snapshot.weaponInventory.activeWeapon,
                  let record = snapshot.weaponInventory.weapon(identity: identity),
                  let value = liveWeaponValue(record) else { return [nullValue] }
            return [value]
        }
        try setMethod("Player:GetAmmoCount", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:GetAmmoCount",
                kind: .player
            )
            guard let type = try resolvedDefaultAmmoType(
                arguments,
                index: 1,
                function: "Player:GetAmmoCount"
            ) else { return [.number(0)] }
            let ammo = try requiredPlayerAmmoState(
                player,
                function: "Player:GetAmmoCount"
            )
            return [.number(Double(ammo.count(for: type)))]
        }

        // Model validation is a read surface in both SERVER and CLIENT. Stock
        // Sandbox uses it from client ghost/entity helpers, so install it
        // before the SERVER-only mutation boundary below.
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
                guard let host = hostBox.value else {
                    throw LuaError.runtime(
                        "util.IsValidModel validation host is unavailable for \(path)"
                    )
                }
                let validation = host.validateCanonicalModel(
                    SourceEntityModelReference(path),
                    for: .propPhysics
                )
                switch validation {
                case .valid:
                    return [.boolean(true)]
                case .invalid:
                    return [.boolean(false)]
                case .unavailable:
                    throw LuaError.runtime(
                        "util.IsValidModel validation is unavailable for \(path)"
                    )
                }
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
                guard let host = hostBox.value else {
                    throw LuaError.runtime(
                        "util.IsValidProp validation host is unavailable for \(path)"
                    )
                }
                let validation = host.validateCanonicalPropPhysicsModel(
                    SourceEntityModelReference(path)
                )
                switch validation {
                case .valid:
                    return [.boolean(true)]
                case .invalid:
                    return [.boolean(false)]
                case .unavailable:
                    // `false` means the engine actually rejected this model as
                    // a prop. An absent attestation is a different state.
                    throw LuaError.runtime(
                        "util.IsValidProp validation is unavailable for \(path)"
                    )
                }
            },
            for: .string("IsValidProp"),
            in: util
        )
        state.setGlobal("util", value: .table(util))

        // CLIENT owns immutable replicated snapshots only. Returning here
        // keeps every mutation surface and ents.Create SERVER-exclusive.
        guard runtime.realm == .server else { return }

        try setMethod("Player:SetClassID", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:SetClassID",
                kind: .player
            )
            let classID = try requiredInteger(
                arguments,
                index: 1,
                function: "Player:SetClassID"
            )
            let host = try requiredHost("Player:SetClassID")
            _ = try host.updateCanonicalEntity(player.identity) { candidate in
                candidate.motion.playerClassID = Int32(classID)
            }
            return []
        }

        try setMethod("Player:Spectate", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:Spectate",
                kind: .player
            )
            let rawMode = try requiredInteger(
                arguments,
                index: 1,
                function: "Player:Spectate"
            )
            guard let mode = SourceCanonicalPlayerObserverMode(
                rawValue: Int32(rawMode)
            ) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Player:Spectate' (OBS_MODE expected)"
                )
            }
            _ = try requiredHost("Player:Spectate")
                .updateCanonicalEntity(player.identity) { candidate in
                    try candidate.startCanonicalSpectating(in: mode)
                }
            return []
        }

        try setMethod("Player:SetObserverMode", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:SetObserverMode",
                kind: .player
            )
            let rawMode = try requiredInteger(
                arguments,
                index: 1,
                function: "Player:SetObserverMode"
            )
            guard let mode = SourceCanonicalPlayerObserverMode(
                rawValue: Int32(rawMode)
            ) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Player:SetObserverMode' (OBS_MODE expected)"
                )
            }
            _ = try requiredHost("Player:SetObserverMode")
                .updateCanonicalEntity(player.identity) { candidate in
                    try candidate.setCanonicalObserverMode(mode)
                }
            return []
        }

        try setMethod("Player:UnSpectate", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:UnSpectate",
                kind: .player
            )
            let observer = try requiredPlayerObserverState(
                player,
                function: "Player:UnSpectate"
            )
            guard observer.mode != .none else { return [] }
            _ = try requiredHost("Player:UnSpectate")
                .updateCanonicalEntity(player.identity) { candidate in
                    candidate.stopCanonicalSpectating()
                }
            return []
        }

        try setMethod("Player:SetPlayerColor", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:SetPlayerColor",
                kind: .player
            )
            let color = try requiredFinitePlayerColorVector(
                arguments,
                index: 1,
                function: "Player:SetPlayerColor"
            )
            _ = try requiredHost("Player:SetPlayerColor")
                .updateCanonicalEntity(player.identity) { candidate in
                    guard var colors = candidate.playerColorState else {
                        throw LuaError.runtime(
                            "Player:SetPlayerColor canonical Player color state is unavailable"
                        )
                    }
                    colors.playerColor = color
                    candidate.playerColorState = colors
                }
            return []
        }

        try setMethod("Player:SetWeaponColor", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:SetWeaponColor",
                kind: .player
            )
            let color = try requiredFinitePlayerColorVector(
                arguments,
                index: 1,
                function: "Player:SetWeaponColor"
            )
            _ = try requiredHost("Player:SetWeaponColor")
                .updateCanonicalEntity(player.identity) { candidate in
                    guard var colors = candidate.playerColorState else {
                        throw LuaError.runtime(
                            "Player:SetWeaponColor canonical Player color state is unavailable"
                        )
                    }
                    colors.weaponColor = color
                    candidate.playerColorState = colors
                }
            return []
        }

        for field in SourceCanonicalPlayerMovementField.allCases {
            let function = "Player:\(field.setterName)"
            try setMethod(function, on: playerMetatable) { arguments in
                let player = try requiredSnapshot(
                    arguments.first,
                    function: function,
                    kind: .player
                )
                let value = try requiredNonNegativeFloat(
                    arguments,
                    index: 1,
                    function: function
                )
                let host = try requiredHost(function)
                _ = try host.updateCanonicalEntity(player.identity) { candidate in
                    guard var settings = candidate.motion.playerMovementSettings else {
                        throw LuaError.runtime(
                            "\(function) canonical Player movement state is unavailable"
                        )
                    }
                    field.set(value, in: &settings)
                    candidate.motion.playerMovementSettings = settings
                }
                return []
            }
        }

        try setMethod("Weapon:SetHoldType", on: weaponMetatable) { arguments in
            let weapon = try requiredSnapshot(
                arguments.first,
                function: "Weapon:SetHoldType",
                kind: .weapon
            )
            let holdType = try requiredString(
                arguments,
                index: 1,
                function: "Weapon:SetHoldType"
            )
            let host = try requiredHost("Weapon:SetHoldType")
            _ = try host.updateCanonicalEntity(weapon.identity) { candidate in
                candidate.weaponHoldType = holdType
            }
            return []
        }

        try setMethod("Player:RemoveAllAmmo", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:RemoveAllAmmo",
                kind: .player
            )
            let current = try requiredPlayerAmmoState(
                player,
                function: "Player:RemoveAllAmmo"
            )
            guard !current.entries.isEmpty else { return [] }
            _ = try requiredHost("Player:RemoveAllAmmo")
                .updateCanonicalEntity(player.identity) { candidate in
                    guard var ammo = candidate.playerAmmoState,
                          ammo.removeAll() else {
                        throw SourceCanonicalEntityError.invalidPlayerAmmoState
                    }
                    candidate.playerAmmoState = ammo
                }
            return []
        }

        try setMethod("Player:GiveAmmo", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:GiveAmmo",
                kind: .player
            )
            let amount = try requiredAmmoAmount(
                arguments,
                index: 1,
                function: "Player:GiveAmmo"
            )
            let type = try resolvedDefaultAmmoType(
                arguments,
                index: 2,
                function: "Player:GiveAmmo"
            )
            _ = try optionalBoolean(
                arguments,
                index: 3,
                function: "Player:GiveAmmo",
                default: false
            )
            guard amount > 0, let type else { return [.number(0)] }
            let maximum = try maximumReserveAmmoCount(
                function: "Player:GiveAmmo"
            )
            var prospective = try requiredPlayerAmmoState(
                player,
                function: "Player:GiveAmmo"
            )
            let expectedAdded = prospective.give(
                amount,
                of: type,
                maximumCount: maximum
            )
            guard expectedAdded > 0 else { return [.number(0)] }

            _ = try requiredHost("Player:GiveAmmo")
                .updateCanonicalEntity(player.identity) { candidate in
                    guard var ammo = candidate.playerAmmoState else {
                        throw SourceCanonicalEntityError.playerAmmoStateRequired
                    }
                    let added = ammo.give(
                        amount,
                        of: type,
                        maximumCount: maximum
                    )
                    guard added == expectedAdded else {
                        throw SourceCanonicalEntityError.invalidPlayerAmmoState
                    }
                    candidate.playerAmmoState = ammo
                }
            return [.number(Double(expectedAdded))]
        }

        try setMethod("Player:Give", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:Give",
                kind: .player
            )
            let className = try requiredString(
                arguments,
                index: 1,
                function: "Player:Give"
            )
            guard SourceCanonicalEntityKind
                .isStructurallyValidWeaponClassName(className) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Give' (valid Weapon class name expected)"
                )
            }
            let host = try requiredHost("Player:Give")
            let weapon = try host.giveCanonicalWeapon(
                className: className,
                to: player.identity
            )
            guard let value = liveWeaponValue(SourceCanonicalWeaponRecord(
                identity: weapon.identity,
                className: weapon.className
            )) else {
                throw LuaError.runtime(
                    "Player:Give did not publish the exact canonical Weapon EHANDLE"
                )
            }
            return [value]
        }
        try setMethod("Player:SelectWeapon", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:SelectWeapon",
                kind: .player
            )
            let className = try requiredString(
                arguments,
                index: 1,
                function: "Player:SelectWeapon"
            )
            let host = try requiredHost("Player:SelectWeapon")
            _ = try host.selectCanonicalWeapon(
                className: className,
                for: player.identity
            )
            return []
        }

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
            _ = try requiredHost("Entity:SetSkin").setCanonicalSkin(
                skin,
                for: snapshot.identity
            )
            return []
        }
        try setMethod("Entity:SetMaterial", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetMaterial"
            )
            let materialName = try requiredString(
                arguments,
                index: 1,
                function: "Entity:SetMaterial"
            )
            _ = try requiredHost("Entity:SetMaterial")
                .setCanonicalMaterialOverride(
                    materialName,
                    for: snapshot.identity
                )
            return []
        }
        try setMethod("Entity:SetColor4Part", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetColor4Part"
            )
            let components = try (1...4).map { index -> UInt8 in
                let value = try requiredInteger(
                    arguments,
                    index: index,
                    function: "Entity:SetColor4Part"
                )
                guard let component = UInt8(exactly: value) else {
                    throw LuaError.runtime(
                        "bad argument #\(index) to 'Entity:SetColor4Part' " +
                            "(color byte expected)"
                    )
                }
                return component
            }
            let host = try requiredHost("Entity:SetColor4Part")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.renderState.color = SourceEntityRenderColor(
                    red: components[0],
                    green: components[1],
                    blue: components[2],
                    alpha: components[3]
                )
            }
            return []
        }
        try setMethod("Entity:SetRenderMode", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetRenderMode"
            )
            let rawValue = try requiredInteger(
                arguments,
                index: 1,
                function: "Entity:SetRenderMode"
            )
            guard let rawByte = UInt8(exactly: rawValue),
                  let mode = SourceEntityRenderMode(rawValue: rawByte) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetRenderMode' " +
                        "(Source RenderMode_t expected)"
                )
            }
            let host = try requiredHost("Entity:SetRenderMode")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.renderState.mode = mode
            }
            return []
        }
        try setMethod("Entity:SetKeyValue", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetKeyValue"
            )
            let key = try requiredString(
                arguments,
                index: 1,
                function: "Entity:SetKeyValue"
            )
            guard key.caseInsensitiveCompare("renderfx") == .orderedSame else {
                throw LuaError.runtime(
                    "Entity:SetKeyValue canonical key '\(key)' is unsupported"
                )
            }
            let rawValue = try requiredInteger(
                arguments,
                index: 2,
                function: "Entity:SetKeyValue"
            )
            guard let rawByte = UInt8(exactly: rawValue),
                  let fx = SourceEntityRenderFX(rawValue: rawByte) else {
                throw LuaError.runtime(
                    "bad argument #2 to 'Entity:SetKeyValue' " +
                        "(Source RenderFx_t expected for renderfx)"
                )
            }
            let host = try requiredHost("Entity:SetKeyValue")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.renderState.fx = fx
            }
            return []
        }
        try setMethod("Entity:SetCollisionGroup", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetCollisionGroup"
            )
            let value = try requiredInteger(
                arguments,
                index: 1,
                function: "Entity:SetCollisionGroup"
            )
            let host = try requiredHost("Entity:SetCollisionGroup")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.collisionGroup = Int32(value)
            }
            return []
        }
        try setMethod("Entity:SetPersistent", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetPersistent"
            )
            guard arguments.indices.contains(1),
                  case let .boolean(value) = arguments[1] else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetPersistent' (boolean expected)"
                )
            }
            let host = try requiredHost("Entity:SetPersistent")
            _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                candidate.isPersistent = value
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
        try setMethod("Entity:SetBodygroup", on: entityMetatable) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetBodygroup"
            )
            let bodyGroupID = try requiredSignedInteger(
                arguments,
                index: 1,
                function: "Entity:SetBodygroup"
            )
            let selection = try requiredSignedInteger(
                arguments,
                index: 2,
                function: "Entity:SetBodygroup"
            )
            let host = try requiredHost("Entity:SetBodygroup")
            _ = try host.setCanonicalBodyGroup(
                bodyGroupID,
                selection: selection,
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
                let host = try requiredHost("ents.Create")
                let snapshot: SourceCanonicalEntitySnapshot
                do {
                    if className == SourceCanonicalEntityKind.propPhysics.className {
                        snapshot = try host.createCanonicalEntity(
                            kind: .propPhysics,
                            at: nil,
                            state: nil,
                            playerUserID: nil
                        )
                    } else {
                        // The structural check alone is not an Entity factory.
                        // Resolve the real inherited SWEP table and its exact
                        // WorldModel before allocating a canonical handle.
                        guard SourceCanonicalEntityKind
                            .isStructurallyValidWeaponClassName(className),
                              let definition = try? runtime
                                .scriptedWeaponRenderDefinition(
                                    className: className
                                ),
                              let worldModel = definition.worldModel else {
                            return [nullValue]
                        }
                        snapshot = try host.createCanonicalWorldWeapon(
                            className: className,
                            worldModel: worldModel
                        )
                    }
                } catch SourceCanonicalEntityError.noFreeNetworkableSlot {
                    return [nullValue]
                } catch SourceCanonicalEntityError.modelRejected {
                    return [nullValue]
                } catch SourceCanonicalEntityError.modelValidationUnavailable {
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

    }
}

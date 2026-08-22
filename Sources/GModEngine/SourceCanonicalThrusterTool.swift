import Foundation

/// The two numpad directions registered by the bundled Sandbox thruster.
public enum SourceCanonicalThrusterDirection: Int8, Equatable, Sendable {
    case forward = 1
    case reverse = -1

    var multiplier: Int32 { Int32(rawValue) }
}

/// Exact client values consumed by the bundled `thruster.lua` route.
///
/// `force` is normalized by the SERVER coordinator with the stock
/// `math.Clamp(value, 0, 1E10)` range. Only the model is restricted by the
/// stock tool list: the bundled Lua stores arbitrary effect and sound strings,
/// then simply declines to render/play them when no registered entry matches.
public struct SourceCanonicalThrusterToolSettings: Equatable, Sendable {
    public let force: Float
    public let model: SourceEntityModelReference
    public let forwardKey: Int32
    public let reverseKey: Int32
    public let isToggle: Bool
    public let disablesCollisionsWhenWelded: Bool
    public let effect: String
    public let activatesOnDamage: Bool
    public let soundName: String

    public init(
        force: Float,
        model: SourceEntityModelReference,
        forwardKey: Int32,
        reverseKey: Int32,
        isToggle: Bool,
        disablesCollisionsWhenWelded: Bool,
        effect: String,
        activatesOnDamage: Bool,
        soundName: String
    ) {
        self.force = force
        self.model = model
        self.forwardKey = forwardKey
        self.reverseKey = reverseKey
        self.isToggle = isToggle
        self.disablesCollisionsWhenWelded =
            disablesCollisionsWhenWelded
        self.effect = effect
        self.activatesOnDamage = activatesOnDamage
        self.soundName = soundName
    }

    public static let bundledDefaults = Self(
        force: 1_500,
        model: SourceEntityModelReference(
            "models/props_phx2/garbage_metalcan001a.mdl"
        ),
        forwardKey: 45,
        reverseKey: 42,
        isToggle: false,
        // The stock convar is named `collision`; zero means pass `nocollide`
        // to constraint.Weld and disable the new thruster body's collisions.
        disablesCollisionsWhenWelded: true,
        effect: "fire",
        activatesOnDamage: false,
        soundName: "PhysicsCannister.ThrusterLoop"
    )
}

/// Values registered by the bundled `gmod_thruster.lua` and `thruster.lua`.
/// Model matching follows the stock case-insensitive lookup while effect and
/// sound identifiers remain exact strings, as their list lookups do.
public struct SourceCanonicalThrusterStockCatalog: Equatable, Sendable {
    private let modelsByLowercasePath: [String: SourceEntityModelReference]
    public let effects: Set<String>
    public let sounds: Set<String>

    public init(
        modelPaths: [String],
        effects: Set<String>,
        sounds: Set<String>
    ) {
        var models: [String: SourceEntityModelReference] = [:]
        for path in modelPaths {
            models[path.lowercased()] = SourceEntityModelReference(path)
        }
        modelsByLowercasePath = models
        self.effects = effects
        self.sounds = sounds
    }

    public func canonicalModel(
        matching requested: SourceEntityModelReference
    ) -> SourceEntityModelReference? {
        modelsByLowercasePath[requested.path.lowercased()]
    }

    public func contains(effect: String) -> Bool {
        effects.contains(effect)
    }

    public func contains(sound: String) -> Bool {
        sounds.contains(sound)
    }

    public static let bundled = Self(
        modelPaths: [
            "models/dav0r/thruster.mdl",
            "models/MaxOfS2D/thruster_projector.mdl",
            "models/MaxOfS2D/thruster_propeller.mdl",
            "models/thrusters/jetpack.mdl",
            "models/props_junk/plasticbucket001a.mdl",
            "models/props_junk/PropaneCanister001a.mdl",
            "models/props_junk/propane_tank001a.mdl",
            "models/props_junk/PopCan01a.mdl",
            "models/props_junk/MetalBucket01a.mdl",
            "models/props_lab/jar01a.mdl",
            "models/props_c17/lampShade001a.mdl",
            "models/props_c17/canister_propane01a.mdl",
            "models/props_c17/canister01a.mdl",
            "models/props_c17/canister02a.mdl",
            "models/props_trainstation/trainstation_ornament002.mdl",
            "models/props_junk/TrafficCone001a.mdl",
            "models/props_c17/clock01.mdl",
            "models/props_junk/terracotta01.mdl",
            "models/props_c17/TrapPropeller_Engine.mdl",
            "models/props_c17/FurnitureSink001a.mdl",
            "models/props_trainstation/trainstation_ornament001.mdl",
            "models/props_trainstation/trashcan_indoor001b.mdl",
            "models/props_c17/pottery02a.mdl",
            "models/props_c17/pottery03a.mdl",
            "models/props_phx2/garbage_metalcan001a.mdl",
            "models/hunter/plates/plate.mdl",
            "models/hunter/blocks/cube025x025x025.mdl",
            "models/XQM/AfterBurner1.mdl",
            "models/XQM/AfterBurner1Medium.mdl",
            "models/XQM/AfterBurner1Big.mdl",
            "models/XQM/AfterBurner1Huge.mdl",
            "models/XQM/AfterBurner1Large.mdl",
        ],
        effects: ["none", "fire", "plasma", "magic", "rings", "smoke"],
        sounds: [
            "",
            "PhysicsCannister.ThrusterLoop",
            "WeaponDissolve.Charge",
            "WeaponDissolve.Beam",
            "eli_lab.elevator_move",
            "combine.sheild_loop",
            "k_lab.ringsrotating",
            "k_lab.teleport_rings_high",
            "k_lab2.DropshipRotorLoop",
            "Town.d1_town_01_spin_loop",
        ]
    )
}

public enum SourceCanonicalThrusterModelDefinitionError:
    Error, Equatable, Sendable
{
    case nonDynamicPhysicsBody
}

/// Asset-backed data needed by `MakeThruster`. OBB bounds and physical data
/// are mandatory; neither is synthesized from render bounds or a fallback
/// density.
public struct SourceCanonicalThrusterModelDefinition: Equatable, Sendable {
    public let model: SourceEntityModelReference
    public let collisionBounds: SourceCollisionProperty
    public let body: SourceCanonicalPropPhysicsBodyDefinition

    public init(
        model: SourceEntityModelReference,
        collisionBounds: SourceCollisionProperty,
        body: SourceCanonicalPropPhysicsBodyDefinition
    ) throws {
        guard body.motionType == .dynamicBody else {
            throw SourceCanonicalThrusterModelDefinitionError
                .nonDynamicPhysicsBody
        }
        self.model = model
        self.collisionBounds = collisionBounds
        self.body = body
    }
}

public typealias SourceCanonicalThrusterModelResolver =
    (SourceEntityModelReference) throws ->
        SourceCanonicalThrusterModelDefinition?

public enum SourceCanonicalThrusterLimitPhase: Equatable, Sendable {
    /// `self:GetWeapon():CheckLimit("thrusters")` in `TOOL:LeftClick`.
    case weapon
    /// The second `ply:CheckLimit("thrusters")` inside `MakeThruster`.
    case player
}

public struct SourceCanonicalThrusterLimitRequest: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let category: String
    public let phase: SourceCanonicalThrusterLimitPhase

    public init(
        player: SourceCanonicalEntityIdentity,
        phase: SourceCanonicalThrusterLimitPhase
    ) {
        self.player = player
        category = "thrusters"
        self.phase = phase
    }
}

public typealias SourceCanonicalThrusterLimitGate =
    (SourceCanonicalThrusterLimitRequest) throws -> Bool

public struct SourceCanonicalThrusterTrace: Equatable, Sendable {
    public let hitPosition: SourceVector3
    public let hitNormal: SourceVector3
    public let target: SourceCanonicalEntityIdentity
    public let physicsBone: Int

    public init(
        hitPosition: SourceVector3,
        hitNormal: SourceVector3,
        target: SourceCanonicalEntityIdentity,
        physicsBone: Int
    ) {
        self.hitPosition = hitPosition
        self.hitNormal = hitNormal
        self.target = target
        self.physicsBone = physicsBone
    }
}

public struct SourceCanonicalThrusterToolRequest: Equatable, Sendable {
    public let actor: SourceCanonicalEntitySnapshot
    public let trace: SourceCanonicalThrusterTrace
    public let settings: SourceCanonicalThrusterToolSettings

    public init(
        actor: SourceCanonicalEntitySnapshot,
        trace: SourceCanonicalThrusterTrace,
        settings: SourceCanonicalThrusterToolSettings
    ) {
        self.actor = actor
        self.trace = trace
        self.settings = settings
    }

    /// Toolgun hook spellings supplied to the stock `CanTool` route.
    public var mode: String { "thruster" }
    public var action: Int32 { 1 }
}

public typealias SourceCanonicalThrusterCanTool =
    (SourceCanonicalThrusterToolRequest) throws -> Bool

public enum SourceCanonicalThrusterCollisionGroup: Equatable, Sendable {
    case defaultGroup
    case world
}

public struct SourceCanonicalThrusterWeldBinding: Equatable, Sendable {
    public let graphIdentifier: UInt64
    public let constraintID: SourcePhysicsConstraintID
    public let constraintEntity: SourceCanonicalEntityIdentity
    public let targetEntity: SourceCanonicalEntityIdentity
    public let targetBodyID: SourcePhysicsBodyID

    public init(
        graphIdentifier: UInt64,
        constraintID: SourcePhysicsConstraintID,
        constraintEntity: SourceCanonicalEntityIdentity,
        targetEntity: SourceCanonicalEntityIdentity,
        targetBodyID: SourcePhysicsBodyID
    ) {
        self.graphIdentifier = graphIdentifier
        self.constraintID = constraintID
        self.constraintEntity = constraintEntity
        self.targetEntity = targetEntity
        self.targetBodyID = targetBodyID
    }
}

/// Complete SERVER state for one `gmod_thruster` Entity. The identity and body
/// both retain the packed Source EHANDLE generation.
public struct SourceCanonicalThrusterEntitySnapshot: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let className: String
    public let lifecycle: SourceCanonicalEntityLifecycle
    public let revision: UInt64
    public let transform: SourceEntityTransform
    public let model: SourceEntityModelReference
    public let collisionBounds: SourceCollisionProperty
    public let bodyID: SourcePhysicsBodyID
    public let owner: SourceCanonicalEntityIdentity
    public let creator: SourceCanonicalEntityIdentity
    public let target: SourceCanonicalEntityIdentity
    public let weld: SourceCanonicalThrusterWeldBinding?
    public let force: Float
    public let forwardKey: Int32
    public let reverseKey: Int32
    public let isToggle: Bool
    public let disablesCollisionsWhenWelded: Bool
    public let collisionGroup: SourceCanonicalThrusterCollisionGroup
    public let effect: String
    public let activatesOnDamage: Bool
    public let soundName: String
    public let multiply: Int32
    public let forceSimulationMultiplier: Int32
    public let isSwitchedOn: Bool
    public let damageSwitchOffTime: Float?
    public let forwardThrustOffset: SourceVector3
    public let reverseEffectOffset: SourceVector3
    public let effectOffset: SourceVector3

    public var isOn: Bool {
        lifecycle == .active && isSwitchedOn
    }
}

/// Renderer/effect projection copied out of SERVER state. It contains no
/// mutable Entity or PhysObj reference and therefore cannot become a second
/// simulation owner on CLIENT.
public struct SourceCanonicalThrusterClientSnapshot: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let className: String
    public let lifecycle: SourceCanonicalEntityLifecycle
    public let revision: UInt64
    public let transform: SourceEntityTransform
    public let model: SourceEntityModelReference
    public let collisionBounds: SourceCollisionProperty
    public let effect: String
    public let soundName: String
    public let multiply: Int32
    public let effectOrigin: SourceVector3
    public let effectDirection: SourceVector3?
    public let isEffectVisible: Bool
    public let isLoopSoundActive: Bool
}

public enum SourceCanonicalThrusterReplicationOperation:
    Equatable, Sendable
{
    case create(SourceCanonicalThrusterClientSnapshot)
    case update(SourceCanonicalThrusterClientSnapshot)
    case remove(SourceCanonicalThrusterClientSnapshot)
}

public struct SourceCanonicalThrusterReplicationBatch: Equatable, Sendable {
    public let sequence: UInt64
    public let operations: [SourceCanonicalThrusterReplicationOperation]

    public init(
        sequence: UInt64,
        operations: [SourceCanonicalThrusterReplicationOperation]
    ) {
        self.sequence = sequence
        self.operations = operations
    }
}

public struct SourceCanonicalThrusterUndoRecord: Equatable, Sendable {
    public let identifier: UInt64
    public let name: String
    public let player: SourceCanonicalEntityIdentity
    public let thruster: SourceCanonicalEntityIdentity
    public let constraintEntity: SourceCanonicalEntityIdentity?
    public let isLive: Bool

    public init(
        identifier: UInt64,
        player: SourceCanonicalEntityIdentity,
        thruster: SourceCanonicalEntityIdentity,
        constraintEntity: SourceCanonicalEntityIdentity?,
        isLive: Bool
    ) {
        self.identifier = identifier
        name = "gmod_thruster"
        self.player = player
        self.thruster = thruster
        self.constraintEntity = constraintEntity
        self.isLive = isLive
    }
}

public struct SourceCanonicalThrusterSpawnResult: Equatable, Sendable {
    public let thruster: SourceCanonicalThrusterEntitySnapshot
    public let undo: SourceCanonicalThrusterUndoRecord
    public let cleanupCategory: String
    public let cleanupEntities: [SourceCanonicalEntityIdentity]

    public init(
        thruster: SourceCanonicalThrusterEntitySnapshot,
        undo: SourceCanonicalThrusterUndoRecord
    ) {
        self.thruster = thruster
        self.undo = undo
        cleanupCategory = "thrusters"
        cleanupEntities = ([thruster.identity] +
            [thruster.weld?.constraintEntity].compactMap { $0 }).sorted {
                $0.handle.rawValue < $1.handle.rawValue
            }
    }
}

public enum SourceCanonicalThrusterToolRejection:
    Error, Equatable, Sendable
{
    case actorIsNotLivePlayer
    case canToolDenied
    case invalidTrace
    case targetUnavailable(SourceCanonicalEntityIdentity)
    case targetIsPlayer(SourceCanonicalEntityIdentity)
    case targetPhysicsUnavailable(
        SourceCanonicalEntityIdentity,
        solidIndex: Int
    )
    case nonFiniteForce
    case modelNotInStockCatalog(SourceEntityModelReference)
    case modelAssetUnavailable(SourceEntityModelReference)
    case thrusterLimitReached
}

public enum SourceCanonicalThrusterToolResult: Equatable, Sendable {
    case spawned(SourceCanonicalThrusterSpawnResult)
    case updated(SourceCanonicalThrusterEntitySnapshot)
    case rejected(SourceCanonicalThrusterToolRejection)
}

public enum SourceCanonicalThrusterInputSource: Equatable, Sendable {
    case numpad(key: Int32)
    case touch(actionIdentifier: UInt64)
}

public struct SourceCanonicalThrusterInput: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let thruster: SourceCanonicalEntityIdentity
    public let direction: SourceCanonicalThrusterDirection
    public let isPressed: Bool
    public let source: SourceCanonicalThrusterInputSource

    public init(
        player: SourceCanonicalEntityIdentity,
        thruster: SourceCanonicalEntityIdentity,
        direction: SourceCanonicalThrusterDirection,
        isPressed: Bool,
        source: SourceCanonicalThrusterInputSource
    ) {
        self.player = player
        self.thruster = thruster
        self.direction = direction
        self.isPressed = isPressed
        self.source = source
    }
}

/// Exact force vector and application point authored by `ENT:SetForce`.
/// `applyForceOffset` is the existing backend mutation that decomposes one
/// application into both linear force and angular torque at its FIFO position.
public struct SourceCanonicalThrusterForceTorqueApplication:
    Equatable, Sendable
{
    public let thruster: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID
    public let worldForce: SourceVector3
    public let worldApplicationPoint: SourceVector3
    public let mutation: SourcePhysicsBodyMutationCommand

    public init(
        thruster: SourceCanonicalEntityIdentity,
        bodyID: SourcePhysicsBodyID,
        worldForce: SourceVector3,
        worldApplicationPoint: SourceVector3,
        mutation: SourcePhysicsBodyMutationCommand
    ) {
        self.thruster = thruster
        self.bodyID = bodyID
        self.worldForce = worldForce
        self.worldApplicationPoint = worldApplicationPoint
        self.mutation = mutation
    }
}

public enum SourceCanonicalThrusterError: Error, Equatable, Sendable {
    case noFreeNetworkableSlot
    case ticketSpaceExhausted
    case unknownThruster(SourceCanonicalEntityIdentity)
    case invalidLifecycle(SourceCanonicalEntityLifecycle)
    case modelDefinitionMismatch(
        expected: SourceEntityModelReference,
        received: SourceEntityModelReference
    )
    case inputMultiplierOverflow(SourceCanonicalEntityIdentity)
    case nonFiniteForceApplication(SourceCanonicalEntityIdentity)
    case nonFiniteServerTime
    case replicationSequence(expected: UInt64, actual: UInt64)
    case replicationSlotOccupied(Int)
    case replicationIdentityMismatch(SourceCanonicalEntityIdentity)
    case replicationRevision(expected: UInt64, actual: UInt64)
}

/// Body create/mutate and fixed-constraint work reuse the existing queues. A
/// deletion method is explicit because the prop coordinator intentionally
/// exposes no arbitrary body-delete command. Implementations must append it to
/// the same global net/console/entity/physics FIFO and support exact-suffix
/// rollback through `rollbackCanonicalPhysicsConstraintCommands`.
public protocol SourceCanonicalThrusterPhysicsCommandQueue:
    SourceCanonicalPropPhysicsMutationCommandQueue,
    SourceCanonicalPhysicsConstraintCommandQueue
{
    @discardableResult
    func enqueueCanonicalThrusterPhysicsBodyDeletionCommands(
        _ commands: [SourcePhysicsBodyDeletionCommand]
    ) throws -> [SourcePhysicsCommand]
}

private final class SourceCanonicalThrusterEntityStorage: SourceEntity {
    init() { super.init(className: "gmod_thruster") }
}

private final class SourceCanonicalThrusterConstraintEntityStorage:
    SourceEntity
{
    init() { super.init(className: "phys_constraint") }
}

private struct SourceCanonicalThrusterMutableState {
    var lifecycle: SourceCanonicalEntityLifecycle
    var revision: UInt64
    var transform: SourceEntityTransform
    let modelDefinition: SourceCanonicalThrusterModelDefinition
    let bodyID: SourcePhysicsBodyID
    let owner: SourceCanonicalEntityIdentity
    let creator: SourceCanonicalEntityIdentity
    let target: SourceCanonicalEntityIdentity
    let weld: SourceCanonicalThrusterWeldBinding?
    var force: Float
    var forwardKey: Int32
    var reverseKey: Int32
    var isToggle: Bool
    let disablesCollisionsWhenWelded: Bool
    let collisionGroup: SourceCanonicalThrusterCollisionGroup
    var effect: String
    var activatesOnDamage: Bool
    var soundName: String
    var multiply: Int32
    var forceSimulationMultiplier: Int32
    var usesForwardEffectOffset: Bool
    var isSwitchedOn: Bool
    var damageSwitchOffTime: Float?
}

private enum SourceCanonicalResolvedThrusterTarget {
    case world(SourceCanonicalEntityIdentity)
    case body(SourceCanonicalEntityIdentity, SourcePhysicsBodyID)

    var identity: SourceCanonicalEntityIdentity {
        switch self {
        case let .world(identity), let .body(identity, _): identity
        }
    }

    var bodyID: SourcePhysicsBodyID? {
        if case let .body(_, bodyID) = self { return bodyID }
        return nil
    }
}

/// SERVER-lane authoritative stock Thruster coordinator. Entity allocation,
/// settings, input state, undo/cleanup, physics commands, and replication are
/// all keyed by full Source EHANDLEs.
public final class SourceCanonicalThrusterToolCoordinator {
    public let entityList: SourceEntityList
    public let constraintGraph: SourceCanonicalConstraintGraph

    private let physicsHost: any SourceCanonicalPhysicsObjectLuaHost
    private let commandQueue: any SourceCanonicalThrusterPhysicsCommandQueue
    private let modelResolver: SourceCanonicalThrusterModelResolver
    private let limitGate: SourceCanonicalThrusterLimitGate
    private let catalog: SourceCanonicalThrusterStockCatalog
    private var statesByHandle: [UInt32: SourceCanonicalThrusterMutableState]
        = [:]
    private var thrusterOrder: [UInt32] = []
    private var thrustersByPlayer: [
        SourceCanonicalEntityIdentity: Set<SourceCanonicalEntityIdentity>
    ] = [:]
    private var undoStorage: [SourceCanonicalThrusterUndoRecord] = []
    private var nextUndoIdentifier: UInt64 = 1
    private var pendingReplication: [
        SourceCanonicalThrusterReplicationOperation
    ] = []
    private var nextReplicationSequence: UInt64 = 1

    public init(
        entityList: SourceEntityList,
        physicsHost: any SourceCanonicalPhysicsObjectLuaHost,
        commandQueue: any SourceCanonicalThrusterPhysicsCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph =
            SourceCanonicalConstraintGraph(),
        catalog: SourceCanonicalThrusterStockCatalog = .bundled,
        modelResolver: @escaping SourceCanonicalThrusterModelResolver,
        limitGate: @escaping SourceCanonicalThrusterLimitGate
    ) {
        self.entityList = entityList
        self.physicsHost = physicsHost
        self.commandQueue = commandQueue
        self.constraintGraph = constraintGraph
        self.catalog = catalog
        self.modelResolver = modelResolver
        self.limitGate = limitGate
    }

    public var snapshots: [SourceCanonicalThrusterEntitySnapshot] {
        thrusterOrder.compactMap { raw in
            snapshot(for: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(raw)
            ))
        }
    }

    public var undoRecords: [SourceCanonicalThrusterUndoRecord] {
        undoStorage
    }

    public func snapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalThrusterEntitySnapshot? {
        guard let state = statesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) is
                SourceCanonicalThrusterEntityStorage else { return nil }
        return makeSnapshot(identity: identity, state: state)
    }

    public func cleanupThrusters(
        for player: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        Array(thrustersByPlayer[player] ?? []).sorted(by: Self.identityOrder)
    }

    @discardableResult
    public func perform(
        _ request: SourceCanonicalThrusterToolRequest,
        canTool: SourceCanonicalThrusterCanTool
    ) throws -> SourceCanonicalThrusterToolResult {
        guard let actor = authoritativeLivePlayer(request.actor.identity) else {
            return .rejected(.actorIsNotLivePlayer)
        }
        let authoritativeRequest = SourceCanonicalThrusterToolRequest(
            actor: actor,
            trace: request.trace,
            settings: request.settings
        )
        guard try canTool(authoritativeRequest) else {
            return .rejected(.canToolDenied)
        }
        guard Self.isFinite(request.trace.hitPosition),
              Self.isFinite(request.trace.hitNormal),
              request.trace.hitNormal.lengthSquared > 0,
              request.trace.physicsBone >= 0 else {
            return .rejected(.invalidTrace)
        }
        guard request.settings.force.isFinite else {
            return .rejected(.nonFiniteForce)
        }
        let resolvedTarget: SourceCanonicalResolvedThrusterTarget
        switch resolveTarget(request.trace) {
        case let .success(target):
            resolvedTarget = target
        case let .failure(rejection):
            return .rejected(rejection)
        }

        if var existing = statesByHandle[
            resolvedTarget.identity.handle.rawValue
        ], existing.owner == actor.identity,
           entityList.entity(for: resolvedTarget.identity.handle) is
            SourceCanonicalThrusterEntityStorage,
           existing.lifecycle != .pendingRemoval,
           existing.lifecycle != .removed {
            existing.force = Self.clampStockForce(request.settings.force)
            existing.forwardKey = request.settings.forwardKey
            existing.reverseKey = request.settings.reverseKey
            existing.isToggle = request.settings.isToggle
            existing.effect = request.settings.effect
            existing.activatesOnDamage =
                request.settings.activatesOnDamage
            existing.soundName = request.settings.soundName
            // ENT:SetForce(force) supplies its default mul=1 even if the
            // numpad Multiply field currently points backward.
            existing.forceSimulationMultiplier = 1
            existing.usesForwardEffectOffset = true
            existing.revision &+= 1
            statesByHandle[resolvedTarget.identity.handle.rawValue] = existing
            let updated = makeSnapshot(
                identity: resolvedTarget.identity,
                state: existing
            )
            pendingReplication.append(.update(makeClientSnapshot(updated)))
            return .updated(updated)
        }

        guard let model = catalog.canonicalModel(
            matching: request.settings.model
        ) else {
            return .rejected(.modelNotInStockCatalog(
                request.settings.model
            ))
        }
        guard let definition = try modelResolver(model) else {
            return .rejected(.modelAssetUnavailable(model))
        }
        guard definition.model.path.lowercased() == model.path.lowercased()
        else {
            throw SourceCanonicalThrusterError.modelDefinitionMismatch(
                expected: model,
                received: definition.model
            )
        }
        guard try limitGate(SourceCanonicalThrusterLimitRequest(
            player: actor.identity,
            phase: .weapon
        )) else {
            return .rejected(.thrusterLimitReached)
        }
        // `MakeThruster` performs the player limit check again. Keep this as a
        // separate authoritative gate so a count change between the stool and
        // factory boundaries cannot overrun `sbox_maxthrusters`.
        guard try limitGate(SourceCanonicalThrusterLimitRequest(
            player: actor.identity,
            phase: .player
        )) else {
            return .rejected(.thrusterLimitReached)
        }
        guard nextUndoIdentifier != UInt64.max else {
            throw SourceCanonicalThrusterError.ticketSpaceExhausted
        }

        let normal = request.trace.hitNormal /
            request.trace.hitNormal.length
        let horizontal = (normal.x * normal.x + normal.y * normal.y)
            .squareRoot()
        let radiansToDegrees = Float(180) / Float.pi
        let angles = SourceQAngle(
            pitch: atan2(-normal.z, horizontal) * radiansToDegrees + 90,
            yaw: atan2(normal.y, normal.x) * radiansToDegrees,
            roll: 0
        )
        let transform = SourceEntityTransform(
            origin: request.trace.hitPosition -
                normal * definition.collisionBounds.mins.z,
            angles: angles
        )

        let thrusterStorage = SourceCanonicalThrusterEntityStorage()
        let thrusterHandle = try entityList.addNetworkableEntity(
            thrusterStorage,
            at: firstFreeNetworkableEntryIndex()
        )
        let thrusterIdentity = SourceCanonicalEntityIdentity(
            handle: thrusterHandle
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: thrusterIdentity,
            solidIndex: definition.body.solidIndex
        )
        var graphRecord: SourceCanonicalConstraintRecord?
        var constraintStorage:
            SourceCanonicalThrusterConstraintEntityStorage?
        var constraintIdentity: SourceCanonicalEntityIdentity?
        var weld: SourceCanonicalThrusterWeldBinding?
        var queued: [SourcePhysicsCommand] = []

        do {
            if let targetBodyID = resolvedTarget.bodyID {
                let record = try constraintGraph.insert(entities: [
                    thrusterIdentity,
                    resolvedTarget.identity,
                ])
                graphRecord = record
                let storage =
                    SourceCanonicalThrusterConstraintEntityStorage()
                constraintStorage = storage
                let handle = try entityList.addNetworkableEntity(
                    storage,
                    at: firstFreeNetworkableEntryIndex()
                )
                let identity = SourceCanonicalEntityIdentity(handle: handle)
                constraintIdentity = identity
                let constraintID = try SourcePhysicsConstraintID(
                    rawValue: record.identifier
                )
                weld = SourceCanonicalThrusterWeldBinding(
                    graphIdentifier: record.identifier,
                    constraintID: constraintID,
                    constraintEntity: identity,
                    targetEntity: resolvedTarget.identity,
                    targetBodyID: targetBodyID
                )
            }

            let collisionsEnabled = (
                weld == nil ||
                    !request.settings.disablesCollisionsWhenWelded
            ) ? definition.body.isCollisionEnabled : false
            let creation = try SourcePhysicsBodyCreationCommand(
                bodyID: bodyID,
                shape: definition.body.shape,
                massProperties: definition.body.massProperties,
                transform: transform,
                linearVelocity: .zero,
                angularVelocity: .zero,
                damping: definition.body.damping,
                motionType: definition.body.motionType,
                materialIndex: definition.body.materialIndex,
                isGravityEnabled: definition.body.isGravityEnabled,
                isCollisionEnabled: collisionsEnabled,
                startsAwake: true
            )
            queued += try commandQueue.enqueueCanonicalPhysicsBodyCommands([
                .create(creation),
            ])
            if let weld {
                queued += try commandQueue
                    .enqueueCanonicalPhysicsConstraintCommands([
                        .createFixed(
                            try SourcePhysicsFixedConstraintCreationCommand(
                                constraintID: weld.constraintID,
                                referenceBodyID: weld.targetBodyID,
                                attachedBodyID: bodyID
                            )
                        ),
                    ])
                queued += try commandQueue.enqueueCanonicalPhysicsBodyCommands([
                    .mutate(try SourcePhysicsBodyMutationCommand(
                        bodyID: bodyID,
                        mutation: .wake
                    )),
                    .mutate(try SourcePhysicsBodyMutationCommand(
                        bodyID: weld.targetBodyID,
                        mutation: .wake
                    )),
                ])
            }
        } catch {
            if !queued.isEmpty {
                commandQueue.rollbackCanonicalPhysicsConstraintCommands(queued)
            }
            if let record = graphRecord {
                _ = constraintGraph.remove(identifier: record.identifier)
            }
            if let constraintStorage, let constraintIdentity {
                precondition(entityList.rollbackUnpublishedAddition(
                    constraintIdentity.handle,
                    entity: constraintStorage
                ), "thruster constraint rollback lost its exact EHANDLE")
            }
            precondition(entityList.rollbackUnpublishedAddition(
                thrusterHandle,
                entity: thrusterStorage
            ), "thruster rollback lost its exact EHANDLE")
            throw error
        }

        let noCollide = weld != nil &&
            request.settings.disablesCollisionsWhenWelded
        let createdState = SourceCanonicalThrusterMutableState(
            lifecycle: .created,
            revision: 0,
            transform: transform,
            modelDefinition: definition,
            bodyID: bodyID,
            owner: actor.identity,
            creator: actor.identity,
            target: resolvedTarget.identity,
            weld: weld,
            force: Self.clampStockForce(request.settings.force),
            forwardKey: request.settings.forwardKey,
            reverseKey: request.settings.reverseKey,
            isToggle: request.settings.isToggle,
            disablesCollisionsWhenWelded: noCollide,
            collisionGroup: noCollide ? .world : .defaultGroup,
            effect: request.settings.effect,
            activatesOnDamage: request.settings.activatesOnDamage,
            soundName: request.settings.soundName,
            multiply: 0,
            // MakeThruster calls SetForce(force) before Switch(false).
            forceSimulationMultiplier: 1,
            usesForwardEffectOffset: true,
            isSwitchedOn: false,
            damageSwitchOffTime: nil
        )
        statesByHandle[thrusterHandle.rawValue] = createdState
        thrusterOrder.append(thrusterHandle.rawValue)
        let created = makeSnapshot(
            identity: thrusterIdentity,
            state: createdState
        )
        pendingReplication.append(.create(makeClientSnapshot(created)))

        var activeState = createdState
        activeState.lifecycle = .active
        activeState.revision = 1
        statesByHandle[thrusterHandle.rawValue] = activeState
        let active = makeSnapshot(
            identity: thrusterIdentity,
            state: activeState
        )
        pendingReplication.append(.update(makeClientSnapshot(active)))
        thrustersByPlayer[actor.identity, default: []].insert(
            thrusterIdentity
        )
        let undo = SourceCanonicalThrusterUndoRecord(
            identifier: nextUndoIdentifier,
            player: actor.identity,
            thruster: thrusterIdentity,
            constraintEntity: weld?.constraintEntity,
            isLive: true
        )
        nextUndoIdentifier += 1
        undoStorage.append(undo)
        return .spawned(SourceCanonicalThrusterSpawnResult(
            thruster: active,
            undo: undo
        ))
    }

    /// Implements `Thruster_On`/`Thruster_Off` and `ENT:AddMul`, including the
    /// stock toggle rule that ignores key-up and toggles only the requested
    /// signed multiplier.
    @discardableResult
    public func handleInput(
        _ input: SourceCanonicalThrusterInput
    ) throws -> SourceCanonicalThrusterEntitySnapshot? {
        guard authoritativeLivePlayer(input.player) != nil,
              var state = statesByHandle[input.thruster.handle.rawValue],
              entityList.entity(for: input.thruster.handle) is
                SourceCanonicalThrusterEntityStorage,
              state.owner == input.player,
              state.lifecycle == .active else { return nil }
        if case let .numpad(key) = input.source {
            let expected = input.direction == .forward
                ? state.forwardKey
                : state.reverseKey
            guard key == expected else { return nil }
        }

        let requested = input.direction.multiplier
        if state.isToggle {
            guard input.isPressed else { return nil }
            state.multiply = state.multiply == requested ? 0 : requested
        } else {
            let delta = input.isPressed ? requested : -requested
            let (next, overflow) = state.multiply.addingReportingOverflow(delta)
            guard !overflow else {
                throw SourceCanonicalThrusterError
                    .inputMultiplierOverflow(input.thruster)
            }
            state.multiply = next
        }
        state.forceSimulationMultiplier = state.multiply
        state.usesForwardEffectOffset = state.multiply > 0
        state.isSwitchedOn = state.multiply != 0
        _ = try commandQueue.enqueueCanonicalPhysicsBodyCommands([
            .mutate(try SourcePhysicsBodyMutationCommand(
                bodyID: state.bodyID,
                mutation: .wake
            )),
        ])
        state.revision &+= 1
        statesByHandle[input.thruster.handle.rawValue] = state
        let snapshot = makeSnapshot(identity: input.thruster, state: state)
        pendingReplication.append(.update(makeClientSnapshot(snapshot)))
        return snapshot
    }

    /// Mirrors `ENT:OnTakeDamage`: when the stock damage option is enabled,
    /// Switch(true) lasts five seconds without rewriting the last force vector
    /// calculated by SetForce/AddMul.
    @discardableResult
    public func handleDamageActivation(
        thruster identity: SourceCanonicalEntityIdentity,
        serverTime: Float
    ) throws -> SourceCanonicalThrusterEntitySnapshot? {
        guard serverTime.isFinite else {
            throw SourceCanonicalThrusterError.nonFiniteServerTime
        }
        guard var state = statesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) is
                SourceCanonicalThrusterEntityStorage,
              state.lifecycle == .active,
              state.activatesOnDamage else { return nil }
        let switchOff = serverTime + 5
        guard switchOff.isFinite else {
            throw SourceCanonicalThrusterError.nonFiniteServerTime
        }
        state.isSwitchedOn = true
        state.damageSwitchOffTime = switchOff
        _ = try commandQueue.enqueueCanonicalPhysicsBodyCommands([
            .mutate(try SourcePhysicsBodyMutationCommand(
                bodyID: state.bodyID,
                mutation: .wake
            )),
        ])
        state.revision &+= 1
        statesByHandle[identity.handle.rawValue] = state
        let snapshot = makeSnapshot(identity: identity, state: state)
        pendingReplication.append(.update(makeClientSnapshot(snapshot)))
        return snapshot
    }

    /// Applies the exact `SwitchOffTime < CurTime()` expiry rule used by the
    /// bundled entity. Equal time remains on until a later Think.
    @discardableResult
    public func advanceServerTime(
        _ serverTime: Float
    ) throws -> [SourceCanonicalThrusterEntitySnapshot] {
        guard serverTime.isFinite else {
            throw SourceCanonicalThrusterError.nonFiniteServerTime
        }
        var candidates: [
            (UInt32, SourceCanonicalThrusterMutableState)
        ] = []
        for raw in thrusterOrder {
            guard var state = statesByHandle[raw],
                  state.lifecycle == .active,
                  let switchOff = state.damageSwitchOffTime,
                  switchOff < serverTime else { continue }
            state.damageSwitchOffTime = nil
            state.isSwitchedOn = false
            candidates.append((raw, state))
        }
        if !candidates.isEmpty {
            _ = try commandQueue.enqueueCanonicalPhysicsBodyCommands(
                try candidates.map { _, state in
                    .mutate(try SourcePhysicsBodyMutationCommand(
                        bodyID: state.bodyID,
                        mutation: .wake
                    ))
                }
            )
        }
        var changed: [SourceCanonicalThrusterEntitySnapshot] = []
        for (raw, var state) in candidates {
            state.revision &+= 1
            statesByHandle[raw] = state
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(raw)
            )
            let snapshot = makeSnapshot(identity: identity, state: state)
            pendingReplication.append(.update(makeClientSnapshot(snapshot)))
            changed.append(snapshot)
        }
        return changed
    }

    /// Enqueues one stock force application per active thruster. The literal
    /// `ThrustOffset * -1 * force * multiply * 50` expression and world
    /// application point come from `gmod_thruster.lua`; the backend's existing
    /// offset-force mutation supplies both force and torque.
    @discardableResult
    public func enqueueActiveForceTorqueApplications()
        throws -> [SourceCanonicalThrusterForceTorqueApplication]
    {
        var applications: [SourceCanonicalThrusterForceTorqueApplication] = []
        for raw in thrusterOrder {
            guard var state = statesByHandle[raw],
                  state.lifecycle == .active else { continue }
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(raw)
            )
            if let body = physicsHost.canonicalPhysicsObject(
                for: state.bodyID
            ), body.bodyID == state.bodyID,
               body.transform != state.transform {
                state.transform = body.transform
                state.revision &+= 1
                statesByHandle[raw] = state
                pendingReplication.append(.update(makeClientSnapshot(
                    makeSnapshot(identity: identity, state: state)
                )))
            }
            guard state.isSwitchedOn,
                  state.forceSimulationMultiplier != 0 else { continue }
            let localOffset = SourceVector3(
                0,
                0,
                state.modelDefinition.collisionBounds.maxs.z
            )
            let localForce = (-localOffset) * state.force *
                Float(state.forceSimulationMultiplier) * 50
            let worldForce = state.transform.transformDirectionFromLocal(
                localForce
            )
            let worldPoint = state.transform.transformPointFromLocal(
                localOffset
            )
            guard Self.isFinite(worldForce), Self.isFinite(worldPoint) else {
                throw SourceCanonicalThrusterError
                    .nonFiniteForceApplication(identity)
            }
            let mutation = try SourcePhysicsBodyMutationCommand(
                bodyID: state.bodyID,
                mutation: .applyForceOffset(
                    force: worldForce,
                    worldPosition: worldPoint
                )
            )
            applications.append(SourceCanonicalThrusterForceTorqueApplication(
                thruster: identity,
                bodyID: state.bodyID,
                worldForce: worldForce,
                worldApplicationPoint: worldPoint,
                mutation: mutation
            ))
        }
        if !applications.isEmpty {
            _ = try commandQueue.enqueueCanonicalPhysicsBodyCommands(
                applications.map { .mutate($0.mutation) }
            )
        }
        return applications
    }

    @discardableResult
    public func undoLatestThruster(
        for player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntityIdentity? {
        guard let index = undoStorage.lastIndex(where: {
            $0.player == player && $0.isLive && snapshot(for: $0.thruster) != nil
        }) else { return nil }
        let record = undoStorage[index]
        _ = try markForRemoval(record.thruster)
        undoStorage[index] = SourceCanonicalThrusterUndoRecord(
            identifier: record.identifier,
            player: record.player,
            thruster: record.thruster,
            constraintEntity: record.constraintEntity,
            isLive: false
        )
        return record.thruster
    }

    @discardableResult
    public func markCleanupForRemoval(
        player: SourceCanonicalEntityIdentity
    ) throws -> [SourceCanonicalEntityIdentity] {
        let identities = cleanupThrusters(for: player)
        for identity in identities {
            _ = try markForRemoval(identity)
        }
        return identities
    }

    @discardableResult
    public func markForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalThrusterEntitySnapshot {
        guard var state = statesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) is
                SourceCanonicalThrusterEntityStorage else {
            throw SourceCanonicalThrusterError.unknownThruster(identity)
        }
        if state.lifecycle == .pendingRemoval {
            return makeSnapshot(identity: identity, state: state)
        }
        guard state.lifecycle != .removed else {
            throw SourceCanonicalThrusterError
                .invalidLifecycle(state.lifecycle)
        }

        var queued: [SourcePhysicsCommand] = []
        do {
            if let weld = state.weld {
                queued += try commandQueue
                    .enqueueCanonicalPhysicsConstraintCommands([
                        .delete(SourcePhysicsConstraintDeletionCommand(
                            constraintID: weld.constraintID
                        )),
                    ])
            }
            queued += try commandQueue
                .enqueueCanonicalThrusterPhysicsBodyDeletionCommands([
                    SourcePhysicsBodyDeletionCommand(bodyID: state.bodyID),
                ])
        } catch {
            if !queued.isEmpty {
                commandQueue.rollbackCanonicalPhysicsConstraintCommands(queued)
            }
            throw error
        }
        if let weld = state.weld {
            _ = constraintGraph.remove(identifier: weld.graphIdentifier)
            entityList.markForDeletion(weld.constraintEntity.handle)
        }
        entityList.markForDeletion(identity.handle)
        state.lifecycle = .pendingRemoval
        state.revision &+= 1
        state.multiply = 0
        state.isSwitchedOn = false
        state.damageSwitchOffTime = nil
        statesByHandle[identity.handle.rawValue] = state
        let pending = makeSnapshot(identity: identity, state: state)
        pendingReplication.append(.update(makeClientSnapshot(pending)))
        return pending
    }

    /// Called only after the shared SourceEntityList cleanup phase. Requiring
    /// both exact handles to disappear prevents a reused entry from completing
    /// an older thruster's cleanup.
    @discardableResult
    public func acknowledgeCleanup(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalThrusterEntitySnapshot? {
        guard var state = statesByHandle[identity.handle.rawValue],
              state.lifecycle == .pendingRemoval else { return nil }
        guard entityList.entity(for: identity.handle) == nil else { return nil }
        if let weld = state.weld,
           entityList.entity(for: weld.constraintEntity.handle) != nil {
            return nil
        }
        state.lifecycle = .removed
        state.revision &+= 1
        statesByHandle.removeValue(forKey: identity.handle.rawValue)
        thrusterOrder.removeAll { $0 == identity.handle.rawValue }
        thrustersByPlayer[state.owner]?.remove(identity)
        if thrustersByPlayer[state.owner]?.isEmpty == true {
            thrustersByPlayer.removeValue(forKey: state.owner)
        }
        for index in undoStorage.indices
            where undoStorage[index].thruster == identity &&
                undoStorage[index].isLive {
            let record = undoStorage[index]
            undoStorage[index] = SourceCanonicalThrusterUndoRecord(
                identifier: record.identifier,
                player: record.player,
                thruster: record.thruster,
                constraintEntity: record.constraintEntity,
                isLive: false
            )
        }
        let removed = makeSnapshot(identity: identity, state: state)
        pendingReplication.append(.remove(makeClientSnapshot(removed)))
        return removed
    }

    public func drainReplicationBatch()
        throws -> SourceCanonicalThrusterReplicationBatch?
    {
        guard !pendingReplication.isEmpty else { return nil }
        guard nextReplicationSequence != UInt64.max else {
            throw SourceCanonicalThrusterError.ticketSpaceExhausted
        }
        let batch = SourceCanonicalThrusterReplicationBatch(
            sequence: nextReplicationSequence,
            operations: pendingReplication
        )
        nextReplicationSequence += 1
        pendingReplication.removeAll(keepingCapacity: true)
        return batch
    }

    private func authoritativeLivePlayer(
        _ identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        guard let entity = entityList.entity(for: identity.handle) as?
                SourceCanonicalEntity,
              entity.kind == .player,
              let snapshot = entity.snapshot,
              snapshot.identity == identity,
              snapshot.lifecycle == .active else { return nil }
        return snapshot
    }

    private func resolveTarget(
        _ trace: SourceCanonicalThrusterTrace
    ) -> Result<
        SourceCanonicalResolvedThrusterTarget,
        SourceCanonicalThrusterToolRejection
    > {
        if let state = statesByHandle[trace.target.handle.rawValue],
           entityList.entity(for: trace.target.handle) is
            SourceCanonicalThrusterEntityStorage,
           state.lifecycle != .pendingRemoval,
           state.lifecycle != .removed {
            guard trace.physicsBone == state.bodyID.solidIndex else {
                return .failure(.targetPhysicsUnavailable(
                    trace.target,
                    solidIndex: trace.physicsBone
                ))
            }
            return .success(.body(trace.target, state.bodyID))
        }
        guard let entity = entityList.entity(for: trace.target.handle) as?
                SourceCanonicalEntity,
              let snapshot = entity.snapshot,
              snapshot.identity == trace.target,
              snapshot.lifecycle != .pendingRemoval,
              snapshot.lifecycle != .removed else {
            return .failure(.targetUnavailable(trace.target))
        }
        if snapshot.kind == .player {
            return .failure(.targetIsPlayer(trace.target))
        }
        if snapshot.kind == .world {
            return .success(.world(trace.target))
        }
        guard let bodyID = try? SourcePhysicsBodyID(
            entityIdentity: trace.target,
            solidIndex: trace.physicsBone
        ), physicsHost.canonicalPhysicsObject(for: bodyID)?.bodyID == bodyID
        else {
            return .failure(.targetPhysicsUnavailable(
                trace.target,
                solidIndex: trace.physicsBone
            ))
        }
        return .success(.body(trace.target, bodyID))
    }

    private func firstFreeNetworkableEntryIndex() throws -> Int {
        for index in 1..<SourceEntityConstants.maxEdicts
            where entityList.entity(at: index) == nil {
            return index
        }
        throw SourceCanonicalThrusterError.noFreeNetworkableSlot
    }

    private func makeSnapshot(
        identity: SourceCanonicalEntityIdentity,
        state: SourceCanonicalThrusterMutableState
    ) -> SourceCanonicalThrusterEntitySnapshot {
        let bounds = state.modelDefinition.collisionBounds
        return SourceCanonicalThrusterEntitySnapshot(
            identity: identity,
            className: "gmod_thruster",
            lifecycle: state.lifecycle,
            revision: state.revision,
            transform: state.transform,
            model: state.modelDefinition.model,
            collisionBounds: bounds,
            bodyID: state.bodyID,
            owner: state.owner,
            creator: state.creator,
            target: state.target,
            weld: state.weld,
            force: state.force,
            forwardKey: state.forwardKey,
            reverseKey: state.reverseKey,
            isToggle: state.isToggle,
            disablesCollisionsWhenWelded:
                state.disablesCollisionsWhenWelded,
            collisionGroup: state.collisionGroup,
            effect: state.effect,
            activatesOnDamage: state.activatesOnDamage,
            soundName: state.soundName,
            multiply: state.multiply,
            forceSimulationMultiplier: state.forceSimulationMultiplier,
            isSwitchedOn: state.isSwitchedOn,
            damageSwitchOffTime: state.damageSwitchOffTime,
            forwardThrustOffset: SourceVector3(0, 0, bounds.maxs.z),
            reverseEffectOffset: SourceVector3(0, 0, bounds.mins.z),
            effectOffset: SourceVector3(
                0,
                0,
                state.usesForwardEffectOffset ? bounds.maxs.z : bounds.mins.z
            )
        )
    }

    private func makeClientSnapshot(
        _ snapshot: SourceCanonicalThrusterEntitySnapshot
    ) -> SourceCanonicalThrusterClientSnapshot {
        let offset = snapshot.effectOffset
        let effectOrigin = snapshot.transform.transformPointFromLocal(offset)
        let length = offset.length
        let direction = length > 0 ? snapshot.transform
            .transformDirectionFromLocal(offset / length) : nil
        let visible = snapshot.isOn &&
            catalog.contains(effect: snapshot.effect) &&
            snapshot.effect != "none" && !snapshot.effect.isEmpty &&
            direction != nil
        return SourceCanonicalThrusterClientSnapshot(
            identity: snapshot.identity,
            className: snapshot.className,
            lifecycle: snapshot.lifecycle,
            revision: snapshot.revision,
            transform: snapshot.transform,
            model: snapshot.model,
            collisionBounds: snapshot.collisionBounds,
            effect: snapshot.effect,
            soundName: snapshot.soundName,
            multiply: snapshot.multiply,
            effectOrigin: effectOrigin,
            effectDirection: direction,
            isEffectVisible: visible,
            isLoopSoundActive: snapshot.isOn &&
                !snapshot.soundName.isEmpty &&
                catalog.contains(sound: snapshot.soundName)
        )
    }

    private static func clampStockForce(_ force: Float) -> Float {
        min(max(force, 0), 10_000_000_000)
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private static func identityOrder(
        _ lhs: SourceCanonicalEntityIdentity,
        _ rhs: SourceCanonicalEntityIdentity
    ) -> Bool {
        lhs.handle.rawValue < rhs.handle.rawValue
    }
}

/// CLIENT-owned immutable render/effect projection. Ordered SERVER revisions
/// are the only write surface; stale generations cannot overwrite a reused
/// entity-list entry.
public final class SourceCanonicalThrusterClientProjection {
    private var nextSequence: UInt64 = 1
    private var snapshotsByHandle: [
        UInt32: SourceCanonicalThrusterClientSnapshot
    ] = [:]
    private var handleByEntry: [Int: UInt32] = [:]

    public init() {}

    public var snapshots: [SourceCanonicalThrusterClientSnapshot] {
        snapshotsByHandle.values.sorted {
            $0.identity.handle.rawValue < $1.identity.handle.rawValue
        }
    }

    public func snapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalThrusterClientSnapshot? {
        snapshotsByHandle[identity.handle.rawValue]
    }

    public func apply(
        _ batch: SourceCanonicalThrusterReplicationBatch
    ) throws {
        guard batch.sequence == nextSequence else {
            throw SourceCanonicalThrusterError.replicationSequence(
                expected: nextSequence,
                actual: batch.sequence
            )
        }
        var nextByHandle = snapshotsByHandle
        var nextByEntry = handleByEntry
        for operation in batch.operations {
            switch operation {
            case let .create(snapshot):
                let entry = snapshot.identity.entryIndex
                if let occupied = nextByEntry[entry],
                   occupied != snapshot.identity.handle.rawValue {
                    throw SourceCanonicalThrusterError
                        .replicationSlotOccupied(entry)
                }
                nextByHandle[snapshot.identity.handle.rawValue] = snapshot
                nextByEntry[entry] = snapshot.identity.handle.rawValue
            case let .update(snapshot):
                guard let previous = nextByHandle[
                    snapshot.identity.handle.rawValue
                ], previous.identity == snapshot.identity else {
                    throw SourceCanonicalThrusterError
                        .replicationIdentityMismatch(snapshot.identity)
                }
                let expected = previous.revision &+ 1
                guard snapshot.revision == expected else {
                    throw SourceCanonicalThrusterError.replicationRevision(
                        expected: expected,
                        actual: snapshot.revision
                    )
                }
                nextByHandle[snapshot.identity.handle.rawValue] = snapshot
            case let .remove(snapshot):
                guard let previous = nextByHandle[
                    snapshot.identity.handle.rawValue
                ], previous.identity == snapshot.identity else {
                    throw SourceCanonicalThrusterError
                        .replicationIdentityMismatch(snapshot.identity)
                }
                let expected = previous.revision &+ 1
                guard snapshot.revision == expected else {
                    throw SourceCanonicalThrusterError.replicationRevision(
                        expected: expected,
                        actual: snapshot.revision
                    )
                }
                nextByHandle.removeValue(
                    forKey: snapshot.identity.handle.rawValue
                )
                nextByEntry.removeValue(forKey: snapshot.identity.entryIndex)
            }
        }
        snapshotsByHandle = nextByHandle
        handleByEntry = nextByEntry
        nextSequence &+= 1
    }
}

import Foundation

/// The first engine-owned entity classes being unified behind one
/// `SourceEntityList` and one EHANDLE lifetime contract.
///
/// The raw values are the canonical Source/GMod class names. A later GLua
/// adapter can therefore route `ents.Create("prop_physics")` without owning a
/// second class-name or lifetime registry.
public enum SourceCanonicalEntityKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case world = "worldspawn"
    case player = "player"
    case propPhysics = "prop_physics"
    /// Engine-owned entity representing one live VPhysics constraint. The
    /// concrete backend object remains identified separately by
    /// `SourcePhysicsConstraintID`; this entity supplies Source lifetime,
    /// EHANDLE generation, undo, and replication semantics.
    case physicsConstraint = "phys_constraint"
    /// One concrete SWEP owned by the canonical entity list. Its snapshot
    /// `className` is the actual registered SWEP class rather than this
    /// category spelling.
    case weapon = "weapon"

    public var className: String { rawValue }

    func accepts(className: String) -> Bool {
        switch self {
        case .weapon:
            return Self.isStructurallyValidWeaponClassName(className)
        case .world, .player, .propPhysics, .physicsConstraint:
            return className == self.className
        }
    }

    static func isStructurallyValidWeaponClassName(_ className: String) -> Bool {
        !className.isEmpty &&
            className.utf8.count < 260 &&
            !className.contains("\0") &&
            !className.contains("/") &&
            !className.contains("\\") &&
            !className.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
            })
    }
}

/// Engine-owned pose. Source simulation remains Float based; renderers may
/// convert a snapshot, but must not become the owner of these values.
public struct SourceEntityTransform: Equatable, Sendable {
    public var origin: SourceVector3
    public var angles: SourceQAngle

    public init(origin: SourceVector3 = .zero, angles: SourceQAngle = .zero) {
        self.origin = origin
        self.angles = angles
    }

    public static let identity = SourceEntityTransform()

    fileprivate var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && origin.z.isFinite &&
            angles.pitch.isFinite && angles.yaw.isFinite && angles.roll.isFinite
    }
}

/// Engine-owned motion state shared by Player movement and future rigid-body
/// entities. Position and view angles remain in ``SourceEntityTransform`` so
/// there is still exactly one authoritative pose.
public struct SourceEntityMotionState: Equatable, Sendable {
    public var linearVelocity: SourceVector3
    public var angularVelocity: SourceVector3
    public var baseVelocity: SourceVector3
    /// Portion of `baseVelocity` authored by BSP `CONTENTS_CURRENT_*` during
    /// the previous PlayerMove. Source's pre-command moving-ground phase
    /// transfers this unflagged current momentum into velocity on the next
    /// tick; retaining the provenance keeps dynamic ground velocity outside
    /// the world-only movement slice.
    public var waterCurrentBaseVelocity: SourceVector3
    public var outputWishVelocity: SourceVector3
    public var isOnGround: Bool
    public var entityGravity: Float
    public var surfaceFriction: Float
    public var waterJumpTime: Float
    public var waterLevel: SourcePlayerWaterLevel
    /// Fully-ducked Source Player state. Timed transition and duck-jump state
    /// remain movement capability boundaries rather than hidden host mirrors.
    public var isDucked: Bool
    /// Last world ladder plane retained by Source player movement while
    /// `MOVETYPE_LADDER` is active. This lives in the canonical Player motion
    /// snapshot so the next fixed tick does not depend on a host-side mirror.
    public var ladderNormal: SourceVector3
    public var isAlive: Bool
    /// Player-only engine values behind the stock speed/jump GLua ABI. Nil on
    /// world, prop, and Weapon entities so snapshots cannot silently treat a
    /// non-Player as movement-configurable.
    public var playerMovementSettings:
        SourceCanonicalPlayerMovementSettings?
    /// Original `player_manager` stores the registered class through this
    /// engine integer before it calls `OnPlayerSpawn`. Keeping it beside the
    /// Player-only snapshot state avoids a realm-local Lua mirror.
    public var playerClassID: Int32?
    /// Source observer mode is Player-only engine state. Nil is reserved for
    /// non-Player entities; canonical Players always carry an explicit mode.
    public var playerObserverState: SourceCanonicalPlayerObserverState?

    public init(
        linearVelocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero,
        baseVelocity: SourceVector3 = .zero,
        waterCurrentBaseVelocity: SourceVector3 = .zero,
        outputWishVelocity: SourceVector3 = .zero,
        isOnGround: Bool = false,
        entityGravity: Float = 0,
        surfaceFriction: Float = 1,
        waterJumpTime: Float = 0,
        waterLevel: SourcePlayerWaterLevel = .notInWater,
        isDucked: Bool = false,
        ladderNormal: SourceVector3 = .zero,
        isAlive: Bool = true,
        playerMovementSettings:
            SourceCanonicalPlayerMovementSettings? = nil,
        playerClassID: Int32? = nil,
        playerObserverState: SourceCanonicalPlayerObserverState? = nil
    ) {
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.baseVelocity = baseVelocity
        self.waterCurrentBaseVelocity = waterCurrentBaseVelocity
        self.outputWishVelocity = outputWishVelocity
        self.isOnGround = isOnGround
        self.entityGravity = entityGravity
        self.surfaceFriction = surfaceFriction
        self.waterJumpTime = waterJumpTime
        self.waterLevel = waterLevel
        self.isDucked = isDucked
        self.ladderNormal = ladderNormal
        self.isAlive = isAlive
        self.playerMovementSettings = playerMovementSettings
        self.playerClassID = playerClassID
        self.playerObserverState = playerObserverState
    }

    fileprivate var isFinite: Bool {
        Self.isFinite(linearVelocity) &&
            Self.isFinite(angularVelocity) &&
            Self.isFinite(baseVelocity) &&
            Self.isFinite(waterCurrentBaseVelocity) &&
            Self.isFinite(outputWishVelocity) &&
            Self.isFinite(ladderNormal) &&
            entityGravity.isFinite &&
            surfaceFriction.isFinite && surfaceFriction >= 0 &&
            waterJumpTime.isFinite && waterJumpTime >= 0 &&
            (playerMovementSettings?.isFiniteAndNonNegative ?? true)
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}

/// A requested Source model name, not proof that an MDL exists.
///
/// Existence is deliberately decided by `SourceCanonicalModelValidator`. This
/// keeps an unavailable filesystem/Studio implementation from being mistaken
/// for a valid prop model.
public struct SourceEntityModelReference: Equatable, Hashable, Sendable {
    public let path: String

    public init(_ path: String) {
        self.path = path
    }
}

/// Numeric `SolidType_t` values from Source SDK 2013 `const.h`.
public enum SourceEntitySolidType: UInt8, CaseIterable, Equatable, Sendable {
    case none = 0
    case bsp = 1
    case boundingBox = 2
    case orientedBoundingBox = 3
    case orientedBoundingBoxYaw = 4
    case custom = 5
    case vPhysics = 6
}

/// Explicit lifetime stages shared by world, Player, and prop entities.
public enum SourceCanonicalEntityLifecycle: UInt8, CaseIterable, Equatable, Sendable {
    case created
    case spawned
    case active
    case pendingRemoval
    case removed
}

/// One GLua string preserved as bytes across the engine-owned NW-variable
/// state. Lua strings are byte sequences, so canonical snapshots must not
/// collapse distinct non-UTF-8 keys or values through a Swift `String` round
/// trip.
public struct SourceNetworkVariableString: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ value: String) {
        bytes = Array(value.utf8)
    }

    fileprivate func precedes(_ other: Self) -> Bool {
        bytes.lexicographicallyPrecedes(other.bytes)
    }
}

/// `Entity:SetNWInt` is historically named as an integer API, but Garry's
/// Mod documents that the value is transported as a float and is not rounded.
/// Keeping the exact Source float bits makes NaN and signed zero deterministic
/// Equatable snapshot values instead of inventing an integer conversion.
public struct SourceNetworkedIntValue: Equatable, Sendable {
    public let sourceFloatBitPattern: UInt32

    public init(luaNumber: Double) {
        sourceFloatBitPattern = Float(luaNumber).bitPattern
    }

    public init(sourceFloatBitPattern: UInt32) {
        self.sourceFloatBitPattern = sourceFloatBitPattern
    }

    public var luaNumber: Double {
        Double(Float(bitPattern: sourceFloatBitPattern))
    }
}

/// Retained-memory limits for one canonical Entity's legacy `SetNW*` state.
///
/// These values are an iPad host allocation guard, not Source/GMod protocol
/// constants. They only bound bytes retained by canonical snapshots and the
/// pending full-snapshot journal; Lua strings keep their original raw bytes.
/// Hosts may inject a different policy when their memory envelope differs.
public struct SourceNetworkVariableAllocationPolicy: Equatable, Sendable {
    public static let `default` = SourceNetworkVariableAllocationPolicy()

    public let maximumEntryCount: Int
    public let maximumAggregateStoredBytes: Int
    public let maximumKeyBytes: Int
    public let maximumStringValueBytes: Int

    public init(
        maximumEntryCount: Int = 256,
        maximumAggregateStoredBytes: Int = 64 * 1_024,
        maximumKeyBytes: Int = 1_024,
        maximumStringValueBytes: Int = 16 * 1_024
    ) {
        precondition(
            maximumEntryCount >= 0,
            "NW-variable entry limit cannot be negative"
        )
        precondition(
            maximumAggregateStoredBytes >= 0,
            "NW-variable aggregate-byte limit cannot be negative"
        )
        precondition(
            maximumKeyBytes >= 0,
            "NW-variable key-byte limit cannot be negative"
        )
        precondition(
            maximumStringValueBytes >= 0,
            "NW-variable string-byte limit cannot be negative"
        )
        self.maximumEntryCount = maximumEntryCount
        self.maximumAggregateStoredBytes = maximumAggregateStoredBytes
        self.maximumKeyBytes = maximumKeyBytes
        self.maximumStringValueBytes = maximumStringValueBytes
    }
}

public struct SourceNetworkVariableAllocationUsage: Equatable, Sendable {
    public let entryCount: Int
    public let aggregateStoredBytes: Int

    public init(entryCount: Int, aggregateStoredBytes: Int) {
        self.entryCount = entryCount
        self.aggregateStoredBytes = aggregateStoredBytes
    }
}

public enum SourceNetworkVariableAllocationError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case entryCountExceeded(actual: Int, maximum: Int)
    case keyByteCountExceeded(actual: Int, maximum: Int)
    case stringValueByteCountExceeded(actual: Int, maximum: Int)
    case aggregateStoredByteCountExceeded(actual: Int, maximum: Int)

    public var description: String {
        switch self {
        case let .entryCountExceeded(actual, maximum):
            return "NW-variable entry count \(actual) exceeds host cap \(maximum)"
        case let .keyByteCountExceeded(actual, maximum):
            return "NW-variable key is \(actual) bytes; host cap is \(maximum)"
        case let .stringValueByteCountExceeded(actual, maximum):
            return "NW-variable string value is \(actual) bytes; host cap is \(maximum)"
        case let .aggregateStoredByteCountExceeded(actual, maximum):
            return "NW-variable state retains \(actual) bytes; host cap is \(maximum)"
        }
    }
}

/// Type-specific, key-sorted NW state carried by every canonical Entity
/// snapshot. The arrays are maintained in raw Lua-byte order, so replication
/// and equality never depend on Dictionary iteration order.
public struct SourceEntityNetworkVariables: Equatable, Sendable {
    /// `SetNWInt` retains the exact Source float bits represented by UInt32.
    /// This fixed payload participates in the host aggregate-byte budget.
    public static let numericValueByteCount = MemoryLayout<UInt32>.size

    public struct StringEntry: Equatable, Sendable {
        public let key: SourceNetworkVariableString
        public let value: SourceNetworkVariableString

        public init(
            key: SourceNetworkVariableString,
            value: SourceNetworkVariableString
        ) {
            self.key = key
            self.value = value
        }
    }

    public struct IntEntry: Equatable, Sendable {
        public let key: SourceNetworkVariableString
        public let value: SourceNetworkedIntValue

        public init(
            key: SourceNetworkVariableString,
            value: SourceNetworkedIntValue
        ) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var stringEntries: [StringEntry]
    public private(set) var intEntries: [IntEntry]

    public init(
        stringEntries: [StringEntry] = [],
        intEntries: [IntEntry] = []
    ) {
        self.stringEntries = []
        self.intEntries = []
        for entry in stringEntries {
            _ = setString(entry.value, forKey: entry.key)
        }
        for entry in intEntries {
            _ = setInt(entry.value, forKey: entry.key)
        }
    }

    public func string(
        forKey key: SourceNetworkVariableString
    ) -> SourceNetworkVariableString? {
        stringEntries.first { $0.key == key }?.value
    }

    public func int(
        forKey key: SourceNetworkVariableString
    ) -> SourceNetworkedIntValue? {
        intEntries.first { $0.key == key }?.value
    }

    /// Exact retained payload accounting for this canonical value. Container
    /// overhead is separately bounded by `entryCount`; no UTF-8 conversion is
    /// performed while measuring raw Lua strings.
    public var allocationUsage: SourceNetworkVariableAllocationUsage {
        var aggregateStoredBytes = 0
        func addSaturating(_ byteCount: Int) {
            let (sum, overflow) = aggregateStoredBytes.addingReportingOverflow(
                byteCount
            )
            aggregateStoredBytes = overflow ? Int.max : sum
        }
        for entry in stringEntries {
            addSaturating(entry.key.bytes.count)
            addSaturating(entry.value.bytes.count)
        }
        for entry in intEntries {
            addSaturating(entry.key.bytes.count)
            addSaturating(Self.numericValueByteCount)
        }
        let (entryCount, overflow) = stringEntries.count.addingReportingOverflow(
            intEntries.count
        )
        return SourceNetworkVariableAllocationUsage(
            entryCount: overflow ? Int.max : entryCount,
            aggregateStoredBytes: aggregateStoredBytes
        )
    }

    /// Validates a complete prospective snapshot before canonical state,
    /// revision, realm projection, or replication journal mutation.
    public func validate(
        allocationPolicy policy: SourceNetworkVariableAllocationPolicy
    ) throws {
        let usage = allocationUsage
        guard usage.entryCount <= policy.maximumEntryCount else {
            throw SourceNetworkVariableAllocationError.entryCountExceeded(
                actual: usage.entryCount,
                maximum: policy.maximumEntryCount
            )
        }

        for entry in stringEntries {
            try Self.validate(
                key: entry.key,
                policy: policy
            )
            guard entry.value.bytes.count <= policy.maximumStringValueBytes else {
                throw SourceNetworkVariableAllocationError
                    .stringValueByteCountExceeded(
                        actual: entry.value.bytes.count,
                        maximum: policy.maximumStringValueBytes
                    )
            }
        }
        for entry in intEntries {
            try Self.validate(
                key: entry.key,
                policy: policy
            )
        }

        guard usage.aggregateStoredBytes <= policy.maximumAggregateStoredBytes else {
            throw SourceNetworkVariableAllocationError
                .aggregateStoredByteCountExceeded(
                    actual: usage.aggregateStoredBytes,
                    maximum: policy.maximumAggregateStoredBytes
                )
        }
    }

    /// Returns false only when the exact key/value bytes were already stored.
    @discardableResult
    public mutating func setString(
        _ value: SourceNetworkVariableString,
        forKey key: SourceNetworkVariableString
    ) -> Bool {
        let replacement = StringEntry(key: key, value: value)
        for index in stringEntries.indices {
            if stringEntries[index].key == key {
                guard stringEntries[index].value != value else { return false }
                stringEntries[index] = replacement
                return true
            }
            if key.precedes(stringEntries[index].key) {
                stringEntries.insert(replacement, at: index)
                return true
            }
        }
        stringEntries.append(replacement)
        return true
    }

    /// Returns false only when the exact Source float bits were already stored.
    @discardableResult
    public mutating func setInt(
        _ value: SourceNetworkedIntValue,
        forKey key: SourceNetworkVariableString
    ) -> Bool {
        let replacement = IntEntry(key: key, value: value)
        for index in intEntries.indices {
            if intEntries[index].key == key {
                guard intEntries[index].value != value else { return false }
                intEntries[index] = replacement
                return true
            }
            if key.precedes(intEntries[index].key) {
                intEntries.insert(replacement, at: index)
                return true
            }
        }
        intEntries.append(replacement)
        return true
    }

    private static func validate(
        key: SourceNetworkVariableString,
        policy: SourceNetworkVariableAllocationPolicy
    ) throws {
        guard key.bytes.count <= policy.maximumKeyBytes else {
            throw SourceNetworkVariableAllocationError.keyByteCountExceeded(
                actual: key.bytes.count,
                maximum: policy.maximumKeyBytes
            )
        }
    }
}

/// One Player-owned SWEP. Both ownership and lookup retain the complete
/// packed EHANDLE, so a recycled entity index cannot silently become an item
/// in an older Player's inventory.
public struct SourceCanonicalWeaponRecord: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let className: String

    public init(identity: SourceCanonicalEntityIdentity, className: String) {
        self.identity = identity
        self.className = className
    }
}

/// Damageable state owned by the canonical Entity. Source keeps health on
/// `CBaseEntity`, so props and future NPCs use the same representation as a
/// Player instead of a weapon-specific side table.
public struct SourceCanonicalCombatState: Equatable, Sendable {
    public var health: Int32
    public var maximumHealth: Int32
    public var takeDamageMode: Int32
    public var isBot: Bool
    public var isLagCompensationEnabled: Bool
    /// Present only for a canonical Player. These values travel in the same
    /// full-EHANDLE snapshot/FIFO as health and lifecycle state.
    public var playerSpawnSettings: SourceCanonicalPlayerSpawnSettings?

    public init(
        health: Int32 = 0,
        maximumHealth: Int32 = 0,
        takeDamageMode: Int32 = 0,
        isBot: Bool = false,
        isLagCompensationEnabled: Bool = false,
        playerSpawnSettings: SourceCanonicalPlayerSpawnSettings? = nil
    ) {
        self.health = health
        self.maximumHealth = maximumHealth
        self.takeDamageMode = takeDamageMode
        self.isBot = isBot
        self.isLagCompensationEnabled = isLagCompensationEnabled
        self.playerSpawnSettings = playerSpawnSettings
    }

    public static let player = SourceCanonicalCombatState(
        health: 100,
        maximumHealth: 100,
        takeDamageMode: 2,
        playerSpawnSettings: .playerClassDefaults
    )
}

/// Native Weapon fields used by ItemPostFrame and generated data-table
/// accessors. Values are copied in the same full-EHANDLE snapshot as the
/// Weapon; neither realm owns an independent clip/cooldown mirror.
public struct SourceCanonicalWeaponRuntimeState: Equatable, Sendable {
    public var clip1: Int32
    public var clip2: Int32
    public var nextPrimaryFire: Float
    public var nextSecondaryFire: Float
    public var floatNetworkVariables: [Float?]
    public var intNetworkVariables: [Int32?]
    public var animationSequence: Int32
    public var animationSequenceName: String
    public var animationPlaybackRate: Float
    /// Zero is the real unavailable-duration result while no decoded Studio
    /// sequence metadata is mounted. It is not promoted to a guessed duration.
    public var animationSequenceDuration: Float

    public init(
        clip1: Int32 = 0,
        clip2: Int32 = 0,
        nextPrimaryFire: Float = 0,
        nextSecondaryFire: Float = 0,
        floatNetworkVariables: [Float?] = [],
        intNetworkVariables: [Int32?] = [],
        animationSequence: Int32 = -1,
        animationSequenceName: String = "",
        animationPlaybackRate: Float = 1,
        animationSequenceDuration: Float = 0
    ) {
        self.clip1 = clip1
        self.clip2 = clip2
        self.nextPrimaryFire = nextPrimaryFire
        self.nextSecondaryFire = nextSecondaryFire
        self.floatNetworkVariables = floatNetworkVariables
        self.intNetworkVariables = intNetworkVariables
        self.animationSequence = animationSequence
        self.animationSequenceName = animationSequenceName
        self.animationPlaybackRate = animationPlaybackRate
        self.animationSequenceDuration = animationSequenceDuration
    }
}

/// Ordered, engine-owned Player inventory carried by canonical snapshots.
/// Realm registries resolve these immutable identities to their own userdata;
/// Lua never owns or directly mirrors this state.
public struct SourceCanonicalWeaponInventory: Equatable, Sendable {
    public private(set) var weapons: [SourceCanonicalWeaponRecord]
    public private(set) var activeWeapon: SourceCanonicalEntityIdentity?

    public init(
        weapons: [SourceCanonicalWeaponRecord] = [],
        activeWeapon: SourceCanonicalEntityIdentity? = nil
    ) {
        self.weapons = weapons
        self.activeWeapon = activeWeapon
    }

    public func weapon(className: String) -> SourceCanonicalWeaponRecord? {
        weapons.first {
            $0.className.caseInsensitiveCompare(className) == .orderedSame
        }
    }

    public func weapon(
        identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalWeaponRecord? {
        weapons.first { $0.identity == identity }
    }

    @discardableResult
    public mutating func insert(_ weapon: SourceCanonicalWeaponRecord) -> Bool {
        guard self.weapon(className: weapon.className) == nil,
              self.weapon(identity: weapon.identity) == nil else { return false }
        weapons.append(weapon)
        return true
    }

    @discardableResult
    public mutating func select(className: String) -> Bool {
        guard let weapon = weapon(className: className) else { return false }
        guard activeWeapon != weapon.identity else { return false }
        activeWeapon = weapon.identity
        return true
    }

    /// Removes only the exact full EHANDLE from this ordered inventory. If the
    /// active Weapon is dropped, Source immediately falls back to the first
    /// remaining owned Weapon (or NULL when the inventory became empty).
    @discardableResult
    public mutating func remove(
        identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalWeaponRecord? {
        guard let index = weapons.firstIndex(where: {
            $0.identity == identity
        }) else { return nil }
        let removed = weapons.remove(at: index)
        if activeWeapon == identity {
            activeWeapon = weapons.first?.identity
        }
        return removed
    }
}

/// Mutable state used by one atomic engine-owned update transaction.
///
/// Lifecycle and EHANDLE identity are intentionally absent. Callers may alter
/// gameplay state, while only `SourceCanonicalEntityStore` can transition
/// lifetime or generation.
public struct SourceCanonicalEntityState: Equatable, Sendable {
    public var transform: SourceEntityTransform
    public var motion: SourceEntityMotionState
    public var model: SourceEntityModelReference?
    /// Entity-local collision bounds supplied by an authoritative solid or
    /// physics asset. A missing property is preserved as unavailable instead
    /// of falling back to Studio render bounds.
    public var collisionProperty: SourceCollisionProperty?
    /// Source collision-group number consumed by game-rules filtering. Zero is
    /// `COLLISION_GROUP_NONE`; negative values are invalid engine state.
    public var collisionGroup: Int32
    /// Source's `FSOLID_NOT_SOLID` state. This is intentionally independent
    /// from `solidType`: `Entity:SetNotSolid` toggles a solid flag without
    /// rewriting the entity's authored collision representation.
    public var isNotSolid: Bool
    /// Engine-owned `EF_NODRAW` state consumed by realm snapshots and the
    /// renderer. Keeping it canonical prevents a SERVER removal transition
    /// from becoming a realm-local visual side table.
    public var isNoDraw: Bool
    /// Sandbox persistence is an authoritative Entity property. It is kept
    /// on the canonical full EHANDLE so `GM:PhysgunPickup` and duplicator Lua
    /// never fall back to a realm-local flag or inherit a reused slot's value.
    public var isPersistent: Bool
    /// Source color32 modulation, render mode, and RenderFX. RenderFX is
    /// retained as authored state even when a renderer does not yet animate
    /// that effect.
    public var renderState: SourceEntityRenderState
    public var solidType: SourceEntitySolidType
    public var moveType: SourceMoveType
    /// Studio skin-family selection. Range validation against the loaded MDL
    /// remains the responsibility of the real Studio asset boundary.
    public var skin: Int
    /// Source `m_nBody` value. Bodypart decomposition remains owned by the
    /// decoded MDL; this canonical value is not guessed from a submodel index.
    public var bodyValue: Int
    /// Local eye offset used by `CBasePlayer::EyePosition`/`GetShootPos`.
    /// Keeping this beside the authoritative origin avoids a Lua-owned eye
    /// position that can drift away from movement state.
    public var viewOffset: SourceVector3
    /// Full EHANDLE relationships. A nil vehicle is the truthful on-foot
    /// state; neither relationship is reduced to an entry index.
    public var vehicle: SourceCanonicalEntityIdentity?
    public var creator: SourceCanonicalEntityIdentity?
    /// Host-configured local display name for a canonical Player. It is part
    /// of the replicated entity snapshot rather than a Lua-side nickname.
    public var playerDisplayName: String?
    /// PlayerColor and PlayerWeaponColor material-proxy inputs. This is
    /// Player-only vector state, not Entity color32 modulation.
    public var playerColorState: SourceCanonicalPlayerColorState?
    /// Player reserve ammunition keyed by the engine's canonical ammo IDs.
    /// Nil is reserved for non-Player entities.
    public var playerAmmoState: SourceCanonicalPlayerAmmoState?
    /// Source-relative time at which the engine allocated this entity.
    /// CLIENT receives the SERVER value in the canonical snapshot so
    /// `GetCreationTime` remains comparable with the shared `CurTime` clock.
    public var creationTime: Float
    /// Networked spawn-effect bit consumed exactly once by CLIENT entity
    /// creation handling. The renderer does not infer this flag from class.
    public var spawnEffect: Bool
    /// Legacy `SetNW*` values are part of the engine-owned Entity, not a
    /// realm-local Lua side table. CLIENT receives this value only inside the
    /// existing full-EHANDLE snapshot FIFO.
    public var networkVariables: SourceEntityNetworkVariables
    /// Player-only SWEP ownership and active selection. This remains empty on
    /// world, prop, and Weapon entities.
    public var weaponInventory: SourceCanonicalWeaponInventory
    /// Weapon-only hold type exposed by the native Weapon ABI. The value is
    /// engine-owned and replicated with the same full-EHANDLE snapshot as the
    /// Weapon instead of living in one realm's scripted table.
    public var weaponHoldType: String?
    /// Weapon `NetworkVar("Entity", slot, name)` values. The declarations and
    /// generated Lua accessors belong to each realm's resolved SWEP table; the
    /// full-EHANDLE values themselves are authoritative engine state and ride
    /// the ordinary canonical snapshot FIFO.
    public var weaponEntityNetworkVariables: [SourceCanonicalEntityIdentity?]
    public var combat: SourceCanonicalCombatState
    public var weaponRuntime: SourceCanonicalWeaponRuntimeState

    public init(
        transform: SourceEntityTransform = .identity,
        motion: SourceEntityMotionState = SourceEntityMotionState(),
        model: SourceEntityModelReference? = nil,
        collisionProperty: SourceCollisionProperty? = nil,
        collisionGroup: Int32 = 0,
        isNotSolid: Bool = false,
        isNoDraw: Bool = false,
        isPersistent: Bool = false,
        renderState: SourceEntityRenderState = .init(),
        solidType: SourceEntitySolidType = .none,
        moveType: SourceMoveType = .none,
        skin: Int = 0,
        bodyValue: Int = 0,
        viewOffset: SourceVector3 = .zero,
        vehicle: SourceCanonicalEntityIdentity? = nil,
        creator: SourceCanonicalEntityIdentity? = nil,
        playerDisplayName: String? = nil,
        playerColorState: SourceCanonicalPlayerColorState? = nil,
        playerAmmoState: SourceCanonicalPlayerAmmoState? = nil,
        creationTime: Float = 0,
        spawnEffect: Bool = false,
        networkVariables: SourceEntityNetworkVariables = .init(),
        weaponInventory: SourceCanonicalWeaponInventory = .init(),
        weaponHoldType: String? = nil,
        weaponEntityNetworkVariables: [SourceCanonicalEntityIdentity?] = [],
        combat: SourceCanonicalCombatState = .init(),
        weaponRuntime: SourceCanonicalWeaponRuntimeState = .init()
    ) {
        self.transform = transform
        self.motion = motion
        self.model = model
        self.collisionProperty = collisionProperty
        self.collisionGroup = collisionGroup
        self.isNotSolid = isNotSolid
        self.isNoDraw = isNoDraw
        self.isPersistent = isPersistent
        self.renderState = renderState
        self.solidType = solidType
        self.moveType = moveType
        self.skin = skin
        self.bodyValue = bodyValue
        self.viewOffset = viewOffset
        self.vehicle = vehicle
        self.creator = creator
        self.playerDisplayName = playerDisplayName
        self.playerColorState = playerColorState
        self.playerAmmoState = playerAmmoState
        self.creationTime = creationTime
        self.spawnEffect = spawnEffect
        self.networkVariables = networkVariables
        self.weaponInventory = weaponInventory
        self.weaponHoldType = weaponHoldType
        self.weaponEntityNetworkVariables = weaponEntityNetworkVariables
        self.combat = combat
        self.weaponRuntime = weaponRuntime
    }

    /// Converts the canonical Player state into the existing movement core's
    /// value input without transferring ownership to the host session.
    public var playerWalkState: SourceWorldWalkState {
        SourceWorldWalkState(
            movement: SourceMoveData(
                origin: transform.origin,
                velocity: motion.linearVelocity,
                baseVelocity: motion.baseVelocity,
                outputWishVelocity: motion.outputWishVelocity,
                isOnGround: motion.isOnGround,
                entityGravity: motion.entityGravity,
                surfaceFriction: motion.surfaceFriction,
                waterJumpTime: motion.waterJumpTime,
                isDead: !motion.isAlive
            ),
            viewAngles: transform.angles,
            moveType: moveType,
            waterLevel: motion.waterLevel,
            waterCurrentBaseVelocity: motion.waterCurrentBaseVelocity,
            isDucked: motion.isDucked,
            viewOffset: viewOffset,
            ladderNormal: motion.ladderNormal
        )
    }

    /// Commits one completed movement tick back into the canonical entity
    /// candidate. The enclosing store transaction performs validation before
    /// this state becomes visible.
    public mutating func applyPlayerWalkState(_ walkState: SourceWorldWalkState) {
        transform.origin = walkState.movement.origin
        transform.angles = walkState.viewAngles
        motion.linearVelocity = walkState.movement.velocity
        motion.baseVelocity = walkState.movement.baseVelocity
        motion.outputWishVelocity = walkState.movement.outputWishVelocity
        motion.isOnGround = walkState.movement.isOnGround
        motion.entityGravity = walkState.movement.entityGravity
        motion.surfaceFriction = walkState.movement.surfaceFriction
        motion.waterJumpTime = walkState.movement.waterJumpTime
        motion.waterLevel = walkState.waterLevel
        motion.waterCurrentBaseVelocity = walkState.waterCurrentBaseVelocity
        motion.isDucked = walkState.isDucked
        motion.ladderNormal = walkState.ladderNormal
        motion.isAlive = !walkState.movement.isDead
        viewOffset = walkState.viewOffset
        moveType = walkState.moveType
    }

    public static func defaults(for kind: SourceCanonicalEntityKind) -> Self {
        switch kind {
        case .world:
            return Self(
                model: SourceEntityModelReference("*0"),
                solidType: .bsp,
                moveType: .none
            )
        case .player:
            // Source SDK's standing VEC_VIEW is 64 units above the player
            // origin. Ducking can later authoritatively change this value.
            return Self(
                motion: SourceEntityMotionState(
                    playerMovementSettings: .legacyWorldWalkDefaults,
                    playerClassID: 0,
                    playerObserverState: .notObserving
                ),
                solidType: .boundingBox,
                moveType: .walk,
                viewOffset: SourceVector3(0, 0, 64),
                playerDisplayName: "Player",
                playerColorState: .white,
                playerAmmoState: .empty,
                combat: .player
            )
        case .propPhysics:
            return Self(solidType: .vPhysics, moveType: .vPhysics)
        case .physicsConstraint:
            return Self(solidType: .none, moveType: .none)
        case .weapon:
            return Self(weaponHoldType: "normal")
        }
    }
}

/// Stable Source identity. `generation` is the complete packed EHANDLE value;
/// `serialNumber` exposes the slot generation without inventing another ID.
public struct SourceCanonicalEntityIdentity: Equatable, Hashable, Sendable {
    public let handle: SourceBaseHandle

    public init(handle: SourceBaseHandle) {
        precondition(handle.isValid, "canonical entity identity requires a valid EHANDLE")
        self.handle = handle
    }

    public var entryIndex: Int { handle.entryIndex }
    /// Compatibility spelling used by the existing GLua Entity registry.
    public var index: Int { entryIndex }
    public var serialNumber: Int { handle.serialNumber }
    public var generation: UInt64 { UInt64(handle.rawValue) }
}

/// Legacy API spelling retained while Runtime/Registry call sites migrate.
/// Both names now denote the same full Source EHANDLE identity.
public typealias GMLuaSourceEntityIdentity = SourceCanonicalEntityIdentity

/// Immutable handoff shared by Lua replication and Metal model rendering.
///
/// The renderer and realm registries consume this value; neither receives a
/// mutable entity reference or owns entity lifetime.
public struct SourceCanonicalEntitySnapshot: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let kind: SourceCanonicalEntityKind
    public let className: String
    public let transform: SourceEntityTransform
    public let motion: SourceEntityMotionState
    public let model: SourceEntityModelReference?
    public let collisionProperty: SourceCollisionProperty?
    public let collisionGroup: Int32
    public let isNotSolid: Bool
    public let isNoDraw: Bool
    public let isPersistent: Bool
    public let renderState: SourceEntityRenderState
    public let solidType: SourceEntitySolidType
    public let moveType: SourceMoveType
    public let skin: Int
    public let bodyValue: Int
    public let viewOffset: SourceVector3
    public let vehicle: SourceCanonicalEntityIdentity?
    public let creator: SourceCanonicalEntityIdentity?
    public let playerDisplayName: String?
    public let playerColorState: SourceCanonicalPlayerColorState?
    public let playerAmmoState: SourceCanonicalPlayerAmmoState?
    public let creationTime: Float
    public let spawnEffect: Bool
    public let networkVariables: SourceEntityNetworkVariables
    public let weaponInventory: SourceCanonicalWeaponInventory
    public let weaponHoldType: String?
    public let weaponEntityNetworkVariables: [SourceCanonicalEntityIdentity?]
    public let combat: SourceCanonicalCombatState
    public let weaponRuntime: SourceCanonicalWeaponRuntimeState
    public let lifecycle: SourceCanonicalEntityLifecycle
    public let isNetworkable: Bool
    public let revision: UInt64

    public init(
        identity: SourceCanonicalEntityIdentity,
        kind: SourceCanonicalEntityKind,
        className: String,
        transform: SourceEntityTransform,
        motion: SourceEntityMotionState,
        model: SourceEntityModelReference?,
        collisionProperty: SourceCollisionProperty? = nil,
        collisionGroup: Int32 = 0,
        isNotSolid: Bool = false,
        isNoDraw: Bool = false,
        isPersistent: Bool = false,
        renderState: SourceEntityRenderState = .init(),
        solidType: SourceEntitySolidType,
        moveType: SourceMoveType,
        lifecycle: SourceCanonicalEntityLifecycle,
        isNetworkable: Bool,
        revision: UInt64,
        skin: Int = 0,
        bodyValue: Int = 0,
        viewOffset: SourceVector3 = .zero,
        vehicle: SourceCanonicalEntityIdentity? = nil,
        creator: SourceCanonicalEntityIdentity? = nil,
        playerDisplayName: String? = nil,
        playerColorState: SourceCanonicalPlayerColorState? = nil,
        playerAmmoState: SourceCanonicalPlayerAmmoState? = nil,
        creationTime: Float = 0,
        spawnEffect: Bool = false,
        networkVariables: SourceEntityNetworkVariables = .init(),
        weaponInventory: SourceCanonicalWeaponInventory = .init(),
        weaponHoldType: String? = nil,
        weaponEntityNetworkVariables: [SourceCanonicalEntityIdentity?] = [],
        combat: SourceCanonicalCombatState = .init(),
        weaponRuntime: SourceCanonicalWeaponRuntimeState = .init()
    ) {
        self.identity = identity
        self.kind = kind
        self.className = className
        self.transform = transform
        self.motion = motion
        self.model = model
        self.collisionProperty = collisionProperty
        self.collisionGroup = collisionGroup
        self.isNotSolid = isNotSolid
        self.isNoDraw = isNoDraw
        self.isPersistent = isPersistent
        self.renderState = renderState
        self.solidType = solidType
        self.moveType = moveType
        self.skin = skin
        self.bodyValue = bodyValue
        self.viewOffset = viewOffset
        self.vehicle = vehicle
        self.creator = creator
        self.playerDisplayName = playerDisplayName
        self.playerColorState = playerColorState
        self.playerAmmoState = playerAmmoState
        self.creationTime = creationTime
        self.spawnEffect = spawnEffect
        self.networkVariables = networkVariables
        self.weaponInventory = weaponInventory
        self.weaponHoldType = weaponHoldType
        self.weaponEntityNetworkVariables = weaponEntityNetworkVariables
        self.combat = combat
        self.weaponRuntime = weaponRuntime
        self.lifecycle = lifecycle
        self.isNetworkable = isNetworkable
        self.revision = revision
    }
}

/// Result of the real filesystem/Studio validation boundary.
public enum SourceCanonicalModelValidation: Equatable, Sendable {
    case valid
    case invalid
    case unavailable
}

public typealias SourceCanonicalModelValidator = (
    _ model: SourceEntityModelReference,
    _ kind: SourceCanonicalEntityKind
) -> SourceCanonicalModelValidation

/// Resolves GLua body-group selections against one already validated Studio
/// model. The Engine owns the atomic entity-state transaction while the host
/// supplies filesystem-backed model metadata; omission never implies a
/// permissive fallback.
public typealias SourceCanonicalBodyGroupResolver = (
    _ model: SourceEntityModelReference,
    _ subModelIDs: String,
    _ currentBodyValue: Int
) throws -> Int

public enum SourceCanonicalEntityError: Error, Equatable, CustomStringConvertible {
    case entityList(SourceEntityListError)
    case noFreeNetworkableSlot
    case unknownEntity(SourceCanonicalEntityIdentity)
    case invalidWorldEntryIndex(Int)
    case invalidTransform
    case invalidMotion
    case invalidSkin(Int)
    case invalidBodyValue(Int)
    case invalidCreationTime(Float)
    case invalidClassName(kind: SourceCanonicalEntityKind, className: String)
    case weaponInventoryRequiresPlayer
    case invalidWeaponInventory(String)
    case weaponHoldTypeRequired
    case weaponHoldTypeRequiresWeapon
    case weaponDataTableRequiresWeapon
    case weaponEntityNetworkVariableLimitExceeded(Int)
    case weaponNumericNetworkVariableLimitExceeded(type: String, count: Int)
    case weaponRuntimeRequiresWeapon
    case invalidWeaponRuntime(String)
    case playerCombatFlagRequiresPlayer(String)
    case playerSpawnSettingsRequired
    case playerSpawnSettingsRequiresPlayer
    case invalidPlayerSpawnSettings(String)
    case invalidWeaponHoldType(String)
    case invalidCollisionGroup(Int32)
    case playerDisplayNameRequired
    case playerDisplayNameRequiresPlayer
    case playerColorStateRequired
    case playerColorStateRequiresPlayer
    case invalidPlayerColorState
    case playerAmmoStateRequired
    case playerAmmoStateRequiresPlayer
    case invalidPlayerAmmoState
    case invalidModelPath(String)
    case modelRequired(SourceCanonicalEntityKind)
    case modelValidationUnavailable(SourceEntityModelReference)
    case modelRejected(SourceEntityModelReference)
    case invalidLifecycleTransition(
        from: SourceCanonicalEntityLifecycle,
        to: SourceCanonicalEntityLifecycle
    )

    public var description: String {
        switch self {
        case let .entityList(error):
            return "Source entity list rejected the transaction: \(error)"
        case .noFreeNetworkableSlot:
            return "no free networkable Source entity slot is available"
        case let .unknownEntity(identity):
            return "Source entity EHANDLE \(identity.handle.rawValue) is stale or unknown"
        case let .invalidWorldEntryIndex(index):
            return "worldspawn must use Source entity index 0, got \(index)"
        case .invalidTransform:
            return "Source entity transform contains a non-finite component"
        case .invalidMotion:
            return "Source entity motion contains a non-finite or invalid component"
        case let .invalidSkin(skin):
            return "Source entity Studio skin index is invalid: \(skin)"
        case let .invalidBodyValue(value):
            return "Source entity Studio body value is invalid: \(value)"
        case let .invalidCreationTime(value):
            return "Source entity creation time is invalid: \(value)"
        case let .invalidClassName(kind, className):
            return "Source \(kind.rawValue) class name is invalid: \(className)"
        case .weaponInventoryRequiresPlayer:
            return "canonical Weapon inventory is only valid on a Player"
        case let .invalidWeaponInventory(message):
            return "canonical Player Weapon inventory is invalid: \(message)"
        case .weaponHoldTypeRequired:
            return "canonical Weapon requires an engine-owned hold type"
        case .weaponHoldTypeRequiresWeapon:
            return "canonical Weapon hold type is only valid on a Weapon"
        case .weaponDataTableRequiresWeapon:
            return "canonical Weapon data-table values are only valid on a Weapon"
        case let .weaponEntityNetworkVariableLimitExceeded(count):
            return "canonical Weapon Entity NetworkVar count exceeds 32 slots: \(count)"
        case let .weaponNumericNetworkVariableLimitExceeded(type, count):
            return "canonical Weapon \(type) NetworkVar count exceeds 32 slots: \(count)"
        case .weaponRuntimeRequiresWeapon:
            return "canonical Weapon runtime state is only valid on a Weapon"
        case let .invalidWeaponRuntime(field):
            return "canonical Weapon runtime field is invalid: \(field)"
        case let .playerCombatFlagRequiresPlayer(field):
            return "canonical combat flag \(field) is only valid on a Player"
        case .playerSpawnSettingsRequired:
            return "canonical Player requires engine-owned spawn settings"
        case .playerSpawnSettingsRequiresPlayer:
            return "canonical Player spawn settings are only valid on a Player"
        case let .invalidPlayerSpawnSettings(field):
            return "canonical Player spawn setting is invalid: \(field)"
        case let .invalidWeaponHoldType(value):
            return "canonical Weapon hold type is invalid: \(value)"
        case let .invalidCollisionGroup(value):
            return "canonical Entity collision group must be nonnegative: \(value)"
        case .playerDisplayNameRequired:
            return "canonical Player requires a host-owned display name"
        case .playerDisplayNameRequiresPlayer:
            return "canonical Player display name is only valid on a Player"
        case .playerColorStateRequired:
            return "canonical Player requires engine-owned material-proxy colors"
        case .playerColorStateRequiresPlayer:
            return "canonical Player material-proxy colors are only valid on a Player"
        case .invalidPlayerColorState:
            return "canonical Player material-proxy color contains a non-finite component"
        case .playerAmmoStateRequired:
            return "canonical Player requires engine-owned reserve ammunition"
        case .playerAmmoStateRequiresPlayer:
            return "canonical reserve ammunition is only valid on a Player"
        case .invalidPlayerAmmoState:
            return "canonical Player reserve ammunition violates the default ammo catalog"
        case let .invalidModelPath(path):
            return "Source entity model path is structurally invalid: \(path)"
        case let .modelRequired(kind):
            return "\(kind.className) requires a model before Spawn"
        case let .modelValidationUnavailable(model):
            return "model validation is unavailable for \(model.path)"
        case let .modelRejected(model):
            return "model validation rejected \(model.path)"
        case let .invalidLifecycleTransition(from, to):
            return "invalid Source entity lifecycle transition \(from) -> \(to)"
        }
    }
}

/// One canonical engine entity type for world, Player, and prop state.
///
/// State setters are fileprivate so GLua, Metal, and App code cannot establish
/// competing mirrors. They receive `snapshot` values instead.
public final class SourceCanonicalEntity: SourceEntity {
    public let kind: SourceCanonicalEntityKind

    private var stateStorage: SourceCanonicalEntityState
    public fileprivate(set) var lifecycle: SourceCanonicalEntityLifecycle
    public fileprivate(set) var revision: UInt64

    fileprivate init(
        kind: SourceCanonicalEntityKind,
        className: String,
        state: SourceCanonicalEntityState,
        lifecycle: SourceCanonicalEntityLifecycle = .created,
        revision: UInt64 = 0
    ) {
        self.kind = kind
        stateStorage = state
        self.lifecycle = lifecycle
        self.revision = revision
        super.init(className: className)
    }

    public var state: SourceCanonicalEntityState { stateStorage }

    public var snapshot: SourceCanonicalEntitySnapshot? {
        guard refHandle.isValid else { return nil }
        return makeSnapshot(identity: SourceCanonicalEntityIdentity(handle: refHandle))
    }

    fileprivate func commit(_ state: SourceCanonicalEntityState) {
        stateStorage = state
        revision &+= 1
    }

    fileprivate func transition(to lifecycle: SourceCanonicalEntityLifecycle) {
        self.lifecycle = lifecycle
        revision &+= 1
    }

    /// Commits the state prepared by DispatchSpawn and its lifecycle edge as
    /// one canonical revision. Publishing happens before this method is called,
    /// so a failed realm projection cannot expose either half of the change.
    fileprivate func commitSpawn(_ state: SourceCanonicalEntityState) {
        stateStorage = state
        lifecycle = .spawned
        revision &+= 1
    }

    fileprivate func makeSnapshot(
        identity: SourceCanonicalEntityIdentity,
        state overrideState: SourceCanonicalEntityState? = nil,
        lifecycle overrideLifecycle: SourceCanonicalEntityLifecycle? = nil,
        revision overrideRevision: UInt64? = nil
    ) -> SourceCanonicalEntitySnapshot {
        let state = overrideState ?? stateStorage
        return SourceCanonicalEntitySnapshot(
            identity: identity,
            kind: kind,
            className: className,
            transform: state.transform,
            motion: state.motion,
            model: state.model,
            collisionProperty: state.collisionProperty,
            collisionGroup: state.collisionGroup,
            isNotSolid: state.isNotSolid,
            isNoDraw: state.isNoDraw,
            isPersistent: state.isPersistent,
            renderState: state.renderState,
            solidType: state.solidType,
            moveType: state.moveType,
            lifecycle: overrideLifecycle ?? lifecycle,
            isNetworkable: true,
            revision: overrideRevision ?? revision,
            skin: state.skin,
            bodyValue: state.bodyValue,
            viewOffset: state.viewOffset,
            vehicle: state.vehicle,
            creator: state.creator,
            playerDisplayName: state.playerDisplayName,
            playerColorState: state.playerColorState,
            playerAmmoState: state.playerAmmoState,
            creationTime: state.creationTime,
            spawnEffect: state.spawnEffect,
            networkVariables: state.networkVariables,
            weaponInventory: state.weaponInventory,
            weaponHoldType: state.weaponHoldType,
            weaponEntityNetworkVariables: state.weaponEntityNetworkVariables,
            combat: state.combat,
            weaponRuntime: state.weaponRuntime
        )
    }
}

/// Owns canonical gameplay state while reusing SourceEntityList's exact slot,
/// serial, think, and deferred-destruction behavior.
///
/// This class intentionally has no realm, renderer, or transport dependency.
/// A later adapter may enqueue its snapshots into the same host FIFO as net and
/// console delivery without restoring direct realm mirrors.
public final class SourceCanonicalEntityStore {
    public let entityList: SourceEntityList
    public let networkVariableAllocationPolicy:
        SourceNetworkVariableAllocationPolicy

    private let modelValidator: SourceCanonicalModelValidator
    private var entitiesByHandle: [UInt32: SourceCanonicalEntity] = [:]
    private var handleOrder: [UInt32] = []

    public init(
        entityList: SourceEntityList = SourceEntityList(),
        modelValidator: SourceCanonicalModelValidator? = nil,
        networkVariableAllocationPolicy:
            SourceNetworkVariableAllocationPolicy = .default
    ) {
        self.entityList = entityList
        self.modelValidator = modelValidator ?? { _, _ in .unavailable }
        self.networkVariableAllocationPolicy = networkVariableAllocationPolicy
    }

    public var count: Int { entitiesByHandle.count }

    /// Consults the injected filesystem/Studio boundary without manufacturing
    /// success when that boundary is absent. Structural path rejection is also
    /// reported as invalid, before any asset lookup occurs.
    public func validateModel(
        _ model: SourceEntityModelReference,
        for kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation {
        do {
            try validateModelPath(model, kind: kind)
        } catch {
            return .invalid
        }
        return modelValidator(model, kind)
    }

    /// Creates a networkable canonical entity. All validation occurs before the
    /// Source slot is touched, and SourceEntityList itself performs the final
    /// atomic occupied/generation check.
    @discardableResult
    public func create(
        kind: SourceCanonicalEntityKind,
        className: String? = nil,
        at requestedEntryIndex: Int? = nil,
        state requestedState: SourceCanonicalEntityState? = nil
    ) throws -> SourceCanonicalEntitySnapshot {
        try create(
            kind: kind,
            className: className,
            at: requestedEntryIndex,
            state: requestedState,
            publishing: { _ in }
        )
    }

    /// Publishes the immutable creation snapshot before the new entity becomes
    /// part of this store. A failed publisher rolls back only the exact fresh
    /// EHANDLE and advances its slot serial, leaving every deferred deletion
    /// and removal callback untouched.
    @discardableResult
    func create(
        kind: SourceCanonicalEntityKind,
        className requestedClassName: String? = nil,
        at requestedEntryIndex: Int? = nil,
        state requestedState: SourceCanonicalEntityState? = nil,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entryIndex = try resolveEntryIndex(for: kind, requested: requestedEntryIndex)
        let className = requestedClassName ?? kind.className
        guard kind.accepts(className: className) else {
            throw SourceCanonicalEntityError.invalidClassName(
                kind: kind,
                className: className
            )
        }
        let state = requestedState ?? .defaults(for: kind)
        try validate(state: state, kind: kind, lifecycle: .created)

        let entity = SourceCanonicalEntity(
            kind: kind,
            className: className,
            state: state
        )
        let handle: SourceBaseHandle
        do {
            handle = try entityList.addNetworkableEntity(entity, at: entryIndex)
        } catch let error as SourceEntityListError {
            throw SourceCanonicalEntityError.entityList(error)
        }

        let identity = SourceCanonicalEntityIdentity(handle: handle)
        let snapshot = entity.makeSnapshot(identity: identity)
        do {
            try publish(snapshot)
        } catch {
            precondition(
                entityList.rollbackUnpublishedAddition(handle, entity: entity),
                "fresh canonical entity rollback lost its exact EHANDLE"
            )
            throw error
        }

        entitiesByHandle[handle.rawValue] = entity
        handleOrder.append(handle.rawValue)
        return snapshot
    }

    public func entity(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntity? {
        guard let entity = entitiesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) === entity else { return nil }
        return entity
    }

    public func snapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        entity(for: identity)?.snapshot
    }

    /// Stable creation order for initial CLIENT replication. Entities already
    /// queued for deferred removal are omitted: a newly attached CLIENT must
    /// never observe a create packet whose lifecycle the replication protocol
    /// rejects. Their existing realms retain the EHANDLE until cleanup emits
    /// the final removed snapshot.
    public var orderedSnapshots: [SourceCanonicalEntitySnapshot] {
        handleOrder.compactMap { rawHandle in
            guard let snapshot = entitiesByHandle[rawHandle]?.snapshot,
                  snapshot.lifecycle != .pendingRemoval,
                  snapshot.lifecycle != .removed else { return nil }
            return snapshot
        }
    }

    /// Applies gameplay state as a copy/validate/commit transaction. A thrown
    /// body or failed validation leaves all entity state and revision unchanged.
    @discardableResult
    public func update(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        try update(identity, mutation, publishing: { _ in })
    }

    /// Validates and publishes a prospective snapshot before committing its
    /// state. A throwing publisher therefore leaves state and revision exact.
    @discardableResult
    func update(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle != .pendingRemoval, entity.lifecycle != .removed else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: entity.lifecycle
            )
        }

        var candidate = entity.state
        try mutation(&candidate)
        try validate(state: candidate, kind: entity.kind, lifecycle: entity.lifecycle)
        let snapshot = entity.makeSnapshot(
            identity: identity,
            state: candidate,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.commit(candidate)
        return snapshot
    }

    /// Mirrors `DispatchSpawn`: a prop cannot cross this boundary until a real
    /// filesystem/Studio validator confirms its MDL.
    @discardableResult
    public func spawn(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try spawn(identity, publishing: { _ in })
    }

    @discardableResult
    func spawn(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        try spawn(identity, mutating: { _ in }, publishing: publish)
    }

    /// DispatchSpawn transaction that may attach authoritative state recovered
    /// from the exact validated asset. The prospective state and lifecycle are
    /// validated and published together, then committed as one revision.
    @discardableResult
    func spawn(
        _ identity: SourceCanonicalEntityIdentity,
        mutating mutation: (inout SourceCanonicalEntityState) throws -> Void,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle == .created else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .spawned
            )
        }
        var candidate = entity.state
        try mutation(&candidate)
        try validate(state: candidate, kind: entity.kind, lifecycle: .spawned)
        let snapshot = entity.makeSnapshot(
            identity: identity,
            state: candidate,
            lifecycle: .spawned,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.commitSpawn(candidate)
        return snapshot
    }

    @discardableResult
    public func activate(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try activate(identity, publishing: { _ in })
    }

    @discardableResult
    func activate(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle == .spawned else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .active
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .active,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.transition(to: .active)
        return snapshot
    }

    /// UTIL_Remove-compatible scheduling. The EHANDLE and snapshots remain
    /// resolvable until SourceEntityList reaches an actual cleanup boundary.
    @discardableResult
    public func markForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try markForRemoval(identity, publishing: { _ in })
    }

    @discardableResult
    func markForRemoval(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        if entity.lifecycle == .pendingRemoval {
            let snapshot = entity.makeSnapshot(identity: identity)
            try publish(snapshot)
            return snapshot
        }
        guard entity.lifecycle != .removed else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: .removed,
                to: .pendingRemoval
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .pendingRemoval,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.transition(to: .pendingRemoval)
        entityList.markForDeletion(identity.handle)
        return snapshot
    }

    /// Reverses an `ents.Create` transaction that has not crossed Spawn. The
    /// exact full handle is removed immediately only after its published realm
    /// projection accepts the matching final removal snapshot. No unrelated
    /// deferred deletion is drained.
    @discardableResult
    public func rollbackCreated(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try rollbackCreated(identity, publishing: { _ in })
    }

    @discardableResult
    func rollbackCreated(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle == .created else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .removed
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .removed,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        precondition(
            entityList.rollbackUnpublishedAddition(identity.handle, entity: entity),
            "created canonical entity rollback lost its exact EHANDLE"
        )
        entity.transition(to: .removed)
        entitiesByHandle.removeValue(forKey: identity.handle.rawValue)
        if let index = handleOrder.firstIndex(of: identity.handle.rawValue) {
            handleOrder.remove(at: index)
        }
        return snapshot
    }

    /// Host-private rollback for an entity whose complete mutation history is
    /// still unpublished outside one engine transaction. Unlike ordinary
    /// removal this accepts created, spawned, or active state, emits no Source
    /// cleanup callback, and removes only the exact full EHANDLE/object pair.
    /// If this same unpublished action queued deferred removal, only that exact
    /// handle is withdrawn from SourceEntityList's pending queue first.
    @discardableResult
    func rollbackUnpublished(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle != .removed else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .removed
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .removed,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        precondition(
            entityList.rollbackUnpublishedTransactionAddition(
                identity.handle,
                entity: entity
            ),
            "unpublished canonical entity rollback lost its exact EHANDLE"
        )
        entity.transition(to: .removed)
        entitiesByHandle.removeValue(forKey: identity.handle.rawValue)
        if let index = handleOrder.firstIndex(of: identity.handle.rawValue) {
            handleOrder.remove(at: index)
        }
        return snapshot
    }

    /// Standalone cleanup boundary for dedicated tests and future hosts that do
    /// not yet use SourceRuntimeKernel. Integrated runtimes should call
    /// `didCleanup(capturedHandle:entity:)` from the kernel's removal callback.
    @discardableResult
    public func cleanupDeferredRemovals() -> [SourceCanonicalEntitySnapshot] {
        var removed: [SourceCanonicalEntitySnapshot] = []
        _ = entityList.cleanupDeleteList { [unowned self] handle, entity in
            if let snapshot = self.didCleanup(capturedHandle: handle, entity: entity) {
                removed.append(snapshot)
            }
        }
        return removed
    }

    /// Consumes the exact pre-invalidation handle reported by SourceEntityList.
    /// A stale callback cannot remove a later occupant of a reused slot.
    @discardableResult
    public func didCleanup(
        capturedHandle: SourceBaseHandle,
        entity removedEntity: SourceEntity
    ) -> SourceCanonicalEntitySnapshot? {
        guard let entity = entitiesByHandle[capturedHandle.rawValue],
              entity === removedEntity else { return nil }
        let identity = SourceCanonicalEntityIdentity(handle: capturedHandle)
        let removedRevision = entity.revision &+ 1
        entity.transition(to: .removed)
        entitiesByHandle.removeValue(forKey: capturedHandle.rawValue)
        if let index = handleOrder.firstIndex(of: capturedHandle.rawValue) {
            handleOrder.remove(at: index)
        }
        return entity.makeSnapshot(
            identity: identity,
            lifecycle: .removed,
            revision: removedRevision
        )
    }

    private func resolveEntryIndex(
        for kind: SourceCanonicalEntityKind,
        requested: Int?
    ) throws -> Int {
        if kind == .world {
            let entryIndex = requested ?? 0
            guard entryIndex == 0 else {
                throw SourceCanonicalEntityError.invalidWorldEntryIndex(entryIndex)
            }
            return entryIndex
        }

        if let requested { return requested }
        for entryIndex in 1..<SourceEntityConstants.maxEdicts
            where entityList.entity(at: entryIndex) == nil {
            return entryIndex
        }
        throw SourceCanonicalEntityError.noFreeNetworkableSlot
    }

    private func requireEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntity {
        guard let entity = entity(for: identity) else {
            throw SourceCanonicalEntityError.unknownEntity(identity)
        }
        return entity
    }

    private func validate(
        state: SourceCanonicalEntityState,
        kind: SourceCanonicalEntityKind,
        lifecycle: SourceCanonicalEntityLifecycle
    ) throws {
        try state.networkVariables.validate(
            allocationPolicy: networkVariableAllocationPolicy
        )
        guard state.transform.isFinite else {
            throw SourceCanonicalEntityError.invalidTransform
        }
        guard state.collisionGroup >= 0 else {
            throw SourceCanonicalEntityError.invalidCollisionGroup(
                state.collisionGroup
            )
        }
        guard state.motion.isFinite else {
            throw SourceCanonicalEntityError.invalidMotion
        }
        if kind == .player {
            guard state.motion.playerMovementSettings != nil,
                  let playerClassID = state.motion.playerClassID,
                  playerClassID >= 0,
                  state.motion.playerObserverState != nil else {
                throw SourceCanonicalEntityError.invalidMotion
            }
        } else if state.motion.playerMovementSettings != nil ||
                    state.motion.playerClassID != nil ||
                    state.motion.playerObserverState != nil {
            throw SourceCanonicalEntityError.invalidMotion
        }
        guard state.skin >= 0, state.skin <= Int(Int32.max) else {
            throw SourceCanonicalEntityError.invalidSkin(state.skin)
        }
        guard state.bodyValue >= 0, state.bodyValue <= Int(Int32.max) else {
            throw SourceCanonicalEntityError.invalidBodyValue(state.bodyValue)
        }
        guard state.creationTime.isFinite, state.creationTime >= 0 else {
            throw SourceCanonicalEntityError.invalidCreationTime(
                state.creationTime
            )
        }
        guard state.viewOffset.x.isFinite,
              state.viewOffset.y.isFinite,
              state.viewOffset.z.isFinite else {
            throw SourceCanonicalEntityError.invalidTransform
        }

        for relationship in [state.vehicle, state.creator].compactMap({ $0 }) {
            guard entity(for: relationship) != nil else {
                throw SourceCanonicalEntityError.unknownEntity(relationship)
            }
        }

        if kind != .player, !state.weaponInventory.weapons.isEmpty ||
            state.weaponInventory.activeWeapon != nil {
            throw SourceCanonicalEntityError.weaponInventoryRequiresPlayer
        }
        if kind == .weapon {
            guard let holdType = state.weaponHoldType else {
                throw SourceCanonicalEntityError.weaponHoldTypeRequired
            }
            guard !holdType.isEmpty,
                  holdType.utf8.count <= 64,
                  !holdType.contains("\0") else {
                throw SourceCanonicalEntityError.invalidWeaponHoldType(holdType)
            }
        } else if state.weaponHoldType != nil {
            throw SourceCanonicalEntityError.weaponHoldTypeRequiresWeapon
        }
        if kind != .weapon, !state.weaponEntityNetworkVariables.isEmpty {
            throw SourceCanonicalEntityError.weaponDataTableRequiresWeapon
        }
        guard state.weaponEntityNetworkVariables.count <= 32 else {
            throw SourceCanonicalEntityError.weaponEntityNetworkVariableLimitExceeded(
                state.weaponEntityNetworkVariables.count
            )
        }
        guard state.weaponRuntime.floatNetworkVariables.count <= 32 else {
            throw SourceCanonicalEntityError
                .weaponNumericNetworkVariableLimitExceeded(
                    type: "Float",
                    count: state.weaponRuntime.floatNetworkVariables.count
                )
        }
        guard state.weaponRuntime.intNetworkVariables.count <= 32 else {
            throw SourceCanonicalEntityError
                .weaponNumericNetworkVariableLimitExceeded(
                    type: "Int",
                    count: state.weaponRuntime.intNetworkVariables.count
                )
        }
        if kind != .weapon, state.weaponRuntime != .init() {
            throw SourceCanonicalEntityError.weaponRuntimeRequiresWeapon
        }
        let weaponRuntime = state.weaponRuntime
        guard weaponRuntime.nextPrimaryFire.isFinite else {
            throw SourceCanonicalEntityError.invalidWeaponRuntime(
                "nextPrimaryFire"
            )
        }
        guard weaponRuntime.nextSecondaryFire.isFinite else {
            throw SourceCanonicalEntityError.invalidWeaponRuntime(
                "nextSecondaryFire"
            )
        }
        guard weaponRuntime.floatNetworkVariables.allSatisfy({
            $0?.isFinite ?? true
        }) else {
            throw SourceCanonicalEntityError.invalidWeaponRuntime(
                "Float NetworkVar"
            )
        }
        guard weaponRuntime.animationSequence >= -1,
              !weaponRuntime.animationSequenceName.contains("\0"),
              weaponRuntime.animationSequenceName.utf8.count <= 256,
              weaponRuntime.animationPlaybackRate.isFinite,
              weaponRuntime.animationPlaybackRate >= 0,
              weaponRuntime.animationSequenceDuration.isFinite,
              weaponRuntime.animationSequenceDuration >= 0 else {
            throw SourceCanonicalEntityError.invalidWeaponRuntime("animation")
        }
        guard state.combat.maximumHealth >= 0,
              (0...3).contains(state.combat.takeDamageMode) else {
            throw SourceCanonicalEntityError.invalidWeaponRuntime(
                "combat state"
            )
        }
        if kind != .player, state.combat.isBot {
            throw SourceCanonicalEntityError.playerCombatFlagRequiresPlayer(
                "isBot"
            )
        }
        if kind != .player, state.combat.isLagCompensationEnabled {
            throw SourceCanonicalEntityError.playerCombatFlagRequiresPlayer(
                "lag compensation"
            )
        }
        if kind == .player {
            guard let settings = state.combat.playerSpawnSettings else {
                throw SourceCanonicalEntityError.playerSpawnSettingsRequired
            }
            guard settings.maximumArmor >= 0 else {
                throw SourceCanonicalEntityError.invalidPlayerSpawnSettings(
                    "maximumArmor"
                )
            }
        } else if state.combat.playerSpawnSettings != nil {
            throw SourceCanonicalEntityError.playerSpawnSettingsRequiresPlayer
        }
        if kind == .player {
            guard state.playerDisplayName != nil else {
                throw SourceCanonicalEntityError.playerDisplayNameRequired
            }
        } else if state.playerDisplayName != nil {
            throw SourceCanonicalEntityError.playerDisplayNameRequiresPlayer
        }
        if kind == .player {
            guard let colors = state.playerColorState else {
                throw SourceCanonicalEntityError.playerColorStateRequired
            }
            guard colors.isFinite else {
                throw SourceCanonicalEntityError.invalidPlayerColorState
            }
        } else if state.playerColorState != nil {
            throw SourceCanonicalEntityError.playerColorStateRequiresPlayer
        }
        if kind == .player {
            guard let ammo = state.playerAmmoState else {
                throw SourceCanonicalEntityError.playerAmmoStateRequired
            }
            guard ammo.isValid else {
                throw SourceCanonicalEntityError.invalidPlayerAmmoState
            }
        } else if state.playerAmmoState != nil {
            throw SourceCanonicalEntityError.playerAmmoStateRequiresPlayer
        }
        if kind == .player {
            var classNames: [String] = []
            var identities: Set<SourceCanonicalEntityIdentity> = []
            for record in state.weaponInventory.weapons {
                guard SourceCanonicalEntityKind
                    .isStructurallyValidWeaponClassName(record.className) else {
                    throw SourceCanonicalEntityError.invalidWeaponInventory(
                        "invalid class name \(record.className)"
                    )
                }
                let folded = record.className.lowercased()
                guard !classNames.contains(folded) else {
                    throw SourceCanonicalEntityError.invalidWeaponInventory(
                        "duplicate class name \(record.className)"
                    )
                }
                classNames.append(folded)
                guard identities.insert(record.identity).inserted else {
                    throw SourceCanonicalEntityError.invalidWeaponInventory(
                        "duplicate EHANDLE \(record.identity.handle.rawValue)"
                    )
                }
                guard let weapon = snapshot(for: record.identity),
                      weapon.kind == .weapon,
                      weapon.className.caseInsensitiveCompare(record.className)
                        == .orderedSame,
                      weapon.lifecycle != .pendingRemoval,
                      weapon.lifecycle != .removed else {
                    throw SourceCanonicalEntityError.invalidWeaponInventory(
                        "weapon \(record.className) does not resolve to its live full EHANDLE"
                    )
                }
            }
            if let active = state.weaponInventory.activeWeapon,
               state.weaponInventory.weapon(identity: active) == nil {
                throw SourceCanonicalEntityError.invalidWeaponInventory(
                    "active EHANDLE is not present in the ordered inventory"
                )
            }
        }

        if let model = state.model {
            try validateModelPath(model, kind: kind)
        }

        guard lifecycle == .spawned || lifecycle == .active else { return }
        if kind == .propPhysics {
            guard let model = state.model else {
                throw SourceCanonicalEntityError.modelRequired(kind)
            }
            switch validateModel(model, for: kind) {
            case .valid:
                break
            case .invalid:
                throw SourceCanonicalEntityError.modelRejected(model)
            case .unavailable:
                throw SourceCanonicalEntityError.modelValidationUnavailable(model)
            }
        }
    }

    private func validateModelPath(
        _ model: SourceEntityModelReference,
        kind: SourceCanonicalEntityKind
    ) throws {
        let path = model.path
        let lowercased = path.lowercased()
        let hasForbiddenComponent = path.isEmpty ||
            path.utf8.count >= 260 ||
            path.contains("\\") ||
            path.contains(":") ||
            path.contains("\0") ||
            path.split(separator: "/", omittingEmptySubsequences: false).contains("..")

        if kind == .world, path == "*0" { return }
        guard !hasForbiddenComponent,
              lowercased.hasPrefix("models/"),
              lowercased.hasSuffix(".mdl") else {
            throw SourceCanonicalEntityError.invalidModelPath(path)
        }
    }
}

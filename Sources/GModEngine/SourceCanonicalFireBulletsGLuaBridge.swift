import Foundation
import GModLua

private final class SourceCanonicalFireBulletsWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalFireBulletsWeakRegistry:
    @unchecked Sendable
{
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

private struct SourceCanonicalBulletRequest {
    let source: SourceVector3
    let direction: SourceVector3
    let spread: SourceVector3
    let count: Int32
    let distance: Float
    let tracerFrequency: Int32
    let tracerName: LuaString?
    let damage: Float
    let forceScale: Float
    let ammoType: SourceCanonicalDefaultAmmoType
    let attacker: SourceCanonicalEntityIdentity
    let inflictor: SourceCanonicalEntityIdentity?
    let ignoreEntity: SourceCanonicalEntityIdentity?
}

/// Independent implementation of the integer/shuffle-table stream exposed by
/// Source's `CUniformRandomStream` public layout. One stream is freshly seeded
/// for every pellet, matching `CBaseEntity::FireBullets`; it is never shared
/// with Lua's unrelated `math.random` state.
private struct SourceCanonicalUniformRandomStream {
    private static let tableCount = 32
    private static let modulus: Int64 = 2_147_483_647
    private static let multiplier: Int64 = 16_807
    private static let quotient: Int64 = 127_773
    private static let remainder: Int64 = 2_836
    private static let divisor = 1 + (modulus - 1) / Int64(tableCount)

    private var seed: Int64
    private var shuffledValue: Int64 = 0
    private var shuffle = Array(repeating: Int64(0), count: tableCount)

    init(seed: Int32) {
        let value = Int64(seed)
        self.seed = value > 0 ? -value : value
    }

    mutating func randomFloat(minimum: Float, maximum: Float) -> Float {
        let unit = Float(generate()) / Float(Self.modulus)
        return minimum + (maximum - minimum) * unit
    }

    private mutating func generate() -> Int64 {
        if seed <= 0 || shuffledValue == 0 {
            seed = max(-seed, 1)
            for index in stride(from: Self.tableCount + 7, through: 0, by: -1) {
                let quotient = seed / Self.quotient
                seed = Self.multiplier * (seed - quotient * Self.quotient) -
                    Self.remainder * quotient
                if seed < 0 { seed += Self.modulus }
                if index < Self.tableCount { shuffle[index] = seed }
            }
            shuffledValue = shuffle[0]
        }

        let quotient = seed / Self.quotient
        seed = Self.multiplier * (seed - quotient * Self.quotient) -
            Self.remainder * quotient
        if seed < 0 { seed += Self.modulus }
        let index = Int(shuffledValue / Self.divisor)
        shuffledValue = shuffle[index]
        shuffle[index] = seed
        return shuffledValue
    }
}

/// SERVER-authoritative projection of GMod's `Entity:FireBullets` surface.
/// It deliberately reuses the installed world/Studio trace bridge and the
/// existing canonical `CTakeDamageInfo` path; no render AABB or duplicate
/// health store is introduced here.
public final class SourceCanonicalFireBulletsGLuaBridge:
    @unchecked Sendable
{
    public static let maximumPelletsPerCall: Int32 = 4_096

    private let lock = NSLock()
    private var authoritativeCommand: SourceUserCommand?
    private var tracerCount: UInt64 = 0

    private init() {}

    /// Opens the same narrow command interval in which Source exposes its
    /// prediction random seed to Player weapon code.
    public func beginAuthoritativeCommand(_ command: SourceUserCommand) {
        lock.lock()
        authoritativeCommand = command
        lock.unlock()
    }

    /// Clears only the command which opened this interval. A stale host call
    /// cannot erase a newer command installed on the same runtime lane.
    public func endAuthoritativeCommand(commandNumber: Int32) {
        lock.lock()
        if authoritativeCommand?.commandNumber == commandNumber {
            authoritativeCommand = nil
        }
        lock.unlock()
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil
    ) throws -> SourceCanonicalFireBulletsGLuaBridge {
        guard runtime.realm != .menu,
              let typeSystem = runtime.typeSystem,
              let registry = runtime.entityRegistry,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime(
                "canonical FireBullets requires the game Entity metatable"
            )
        }
        if runtime.realm == .server, host == nil {
            throw LuaError.runtime(
                "canonical FireBullets SERVER requires an authoritative host"
            )
        }
        guard let endpoint = runtime.netEndpoint else {
            throw LuaError.runtime(
                "canonical FireBullets requires a net transport endpoint"
            )
        }

        let bridge = SourceCanonicalFireBulletsGLuaBridge()
        let state = runtime.state
        let realm = runtime.realm
        let hostBox = SourceCanonicalFireBulletsWeakHost(host)
        let registryBox = SourceCanonicalFireBulletsWeakRegistry(registry)

        let function = LuaNativeFunctionBox(
            { [weak bridge] arguments in
                guard let bridge else {
                    throw LuaError.runtime(
                        "Entity:FireBullets bridge is unavailable"
                    )
                }
                guard realm == .server, let host = hostBox.value else {
                    throw LuaError.runtime(
                        "Entity:FireBullets requires SERVER authority; CLIENT prediction is not connected"
                    )
                }
                guard let registry = registryBox.value else {
                    throw LuaError.runtime(
                        "Entity:FireBullets canonical registry is unavailable"
                    )
                }
                guard let shooterValue = arguments.first,
                      let shooter = registry.canonicalSnapshot(
                        for: shooterValue
                      ), shooter.kind == .player,
                      let authoritativeShooter = host.canonicalSnapshot(
                        for: shooter.identity
                      ), authoritativeShooter.kind == .player else {
                    throw LuaError.runtime(
                        "bad self to 'Entity:FireBullets' (live canonical Player expected)"
                    )
                }
                guard arguments.indices.contains(1),
                      case let .table(bulletTable) = arguments[1] else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'Entity:FireBullets' (Bullet table expected)"
                    )
                }
                if arguments.indices.contains(2),
                   !Self.isNil(arguments[2]) {
                    guard case let .boolean(suppressed) = arguments[2] else {
                        throw LuaError.runtime(
                            "bad argument #2 to 'Entity:FireBullets' (boolean expected)"
                        )
                    }
                    if suppressed {
                        throw LuaError.runtime(
                            "Entity:FireBullets suppressHostEvents multiplayer routing is not implemented"
                        )
                    }
                }

                let original = try Self.parseRequest(
                    bulletTable,
                    shooter: shooter.identity,
                    state: state,
                    registry: registry
                )
                let hookResult = try Self.dispatchEntityFireBulletsHook(
                    state: state,
                    shooterValue: shooterValue,
                    bulletTable: bulletTable
                )
                let request: SourceCanonicalBulletRequest
                switch hookResult {
                case .suppressed:
                    return []
                case .unchanged:
                    request = original
                case .applyChanges:
                    request = try Self.parseRequest(
                        bulletTable,
                        shooter: shooter.identity,
                        state: state,
                        registry: registry
                    )
                }

                guard host.canonicalSnapshot(for: request.attacker) != nil else {
                    throw LuaError.runtime(
                        "Entity:FireBullets Attacker EHANDLE became unavailable"
                    )
                }
                if let inflictor = request.inflictor,
                   host.canonicalSnapshot(for: inflictor) == nil {
                    throw LuaError.runtime(
                        "Entity:FireBullets Inflictor EHANDLE became unavailable"
                    )
                }
                if let ignored = request.ignoreEntity,
                   host.canonicalSnapshot(for: ignored) == nil {
                    throw LuaError.runtime(
                        "Entity:FireBullets IgnoreEntity EHANDLE became unavailable"
                    )
                }

                let seed = bridge.predictionSeed()
                var pellets: [GMLuaFiredBulletTrace] = []
                pellets.reserveCapacity(Int(request.count))
                for pelletIndex in 0..<request.count {
                    let pelletSeed = seed &+ pelletIndex
                    let direction = try Self.spreadDirection(
                        request.direction,
                        spread: request.spread,
                        seed: pelletSeed
                    )
                    let trace = try Self.trace(
                        source: request.source,
                        direction: direction,
                        distance: request.distance,
                        shooter: shooter.identity,
                        additionalIgnore: request.ignoreEntity,
                        runtime: runtime,
                        registry: registry,
                        host: host
                    )
                    if let handle = trace.entityHandle,
                       trace.didHit, handle.entryIndex != 0 {
                        try Self.applyDamage(
                            request.damage,
                            trace: trace,
                            bulletDirection: direction,
                            forceScale: request.forceScale,
                            ammoType: request.ammoType,
                            attacker: request.attacker,
                            inflictor: request.inflictor,
                            state: state,
                            typeSystem: typeSystem,
                            registry: registry,
                            host: host
                        )
                    }
                    pellets.append(GMLuaFiredBulletTrace(
                        pelletIndex: pelletIndex,
                        predictionSeed: pelletSeed,
                        direction: direction,
                        trace: trace,
                        emitsTracer: bridge.nextTracerDisposition(
                            frequency: request.tracerFrequency
                        )
                    ))
                }

                try endpoint.broadcastGameplayEvent(.fireBullets(
                    GMLuaFireBulletsEvent(
                        shooterIdentity: shooter.identity,
                        attackerIdentity: request.attacker,
                        inflictorIdentity: request.inflictor,
                        canonicalShootPosition:
                            authoritativeShooter.transform.origin +
                            authoritativeShooter.viewOffset,
                        canonicalEyeAngles:
                            authoritativeShooter.transform.angles,
                        source: request.source,
                        direction: request.direction,
                        spread: request.spread,
                        distance: request.distance,
                        tracerFrequency: request.tracerFrequency,
                        tracerName: request.tracerName,
                        damage: request.damage,
                        forceScale: request.forceScale,
                        ammoType: LuaString(request.ammoType.name),
                        pellets: pellets
                    )
                ))
                return []
            },
            debugName: "Entity:FireBullets"
        )
        try state.setRawTableValue(
            .nativeFunction(function),
            for: .string("FireBullets"),
            in: entityMetatable
        )
        try state.setRawTableValue(
            .nativeFunction(LuaNativeFunctionBox(
                { arguments in
                    guard realm == .server else {
                        throw LuaError.runtime(
                            "Player:MuzzleFlash requires SERVER authority"
                        )
                    }
                    let player = try Self.playerSnapshot(
                        arguments.first,
                        registry: registryBox.value,
                        function: "Player:MuzzleFlash"
                    )
                    try endpoint.broadcastGameplayEvent(.playerMuzzleFlash(
                        GMLuaPlayerMuzzleFlashEvent(
                            playerIdentity: player.identity
                        )
                    ))
                    return []
                },
                debugName: "Player:MuzzleFlash"
            )),
            for: .string("MuzzleFlash"),
            in: playerMetatable
        )
        try state.setRawTableValue(
            .nativeFunction(LuaNativeFunctionBox(
                { arguments in
                    guard realm == .server else {
                        throw LuaError.runtime(
                            "Player:ViewPunch requires SERVER authority"
                        )
                    }
                    let player = try Self.playerSnapshot(
                        arguments.first,
                        registry: registryBox.value,
                        function: "Player:ViewPunch"
                    )
                    guard arguments.indices.contains(1) else {
                        throw LuaError.runtime(
                            "bad argument #1 to 'Player:ViewPunch' (Angle expected)"
                        )
                    }
                    let components = try GMLuaVectorAngle
                        .networkAngleComponents(
                            from: arguments[1],
                            function: "Player:ViewPunch"
                        )
                    let limit = Double(Float.greatestFiniteMagnitude)
                    guard components.0.isFinite, components.1.isFinite,
                          components.2.isFinite,
                          abs(components.0) <= limit,
                          abs(components.1) <= limit,
                          abs(components.2) <= limit else {
                        throw LuaError.runtime(
                            "Player:ViewPunch Angle exceeds Source Float range"
                        )
                    }
                    try endpoint.broadcastGameplayEvent(.playerViewPunch(
                        GMLuaPlayerViewPunchEvent(
                            playerIdentity: player.identity,
                            impulse: SourceQAngle(
                                pitch: Float(components.0),
                                yaw: Float(components.1),
                                roll: Float(components.2)
                            )
                        )
                    ))
                    return []
                },
                debugName: "Player:ViewPunch"
            )),
            for: .string("ViewPunch"),
            in: playerMetatable
        )
        return bridge
    }

    private func predictionSeed() -> Int32 {
        lock.lock()
        let seed = authoritativeCommand?.randomSeed ?? -1
        lock.unlock()
        return Int32(bitPattern: UInt32(bitPattern: seed) & 255)
    }

    private func nextTracerDisposition(frequency: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldEmit = frequency != 0 &&
            tracerCount % UInt64(frequency) == 0
        tracerCount &+= 1
        return shouldEmit
    }

    private enum HookResult {
        case unchanged
        case applyChanges
        case suppressed
    }

    private static func dispatchEntityFireBulletsHook(
        state: LuaState,
        shooterValue: LuaValue,
        bulletTable: LuaTable
    ) throws -> HookResult {
        guard case let .table(hook) = state.getGlobal("hook") else {
            throw LuaError.runtime(
                "Entity:FireBullets requires the hook table"
            )
        }
        let call = try state.rawTableValue(for: .string("Call"), in: hook)
        switch call {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "hook.Call is \(call.typeName), expected function"
            )
        }
        let gamemode = state.getGlobal("GAMEMODE")
        guard case .table = gamemode else {
            throw LuaError.runtime(
                "GAMEMODE is \(gamemode.typeName), expected table"
            )
        }
        let result = try state.call(call, arguments: [
            .string("EntityFireBullets"),
            gamemode,
            shooterValue,
            .table(bulletTable),
        ]).first ?? .nilValue
        switch result {
        case .nilValue:
            return .unchanged
        case .boolean(true):
            return .applyChanges
        case .boolean(false):
            return .suppressed
        default:
            throw LuaError.runtime(
                "EntityFireBullets returned \(result.typeName), expected boolean or nil"
            )
        }
    }

    private static func parseRequest(
        _ table: LuaTable,
        shooter: SourceCanonicalEntityIdentity,
        state: LuaState,
        registry: GMLuaEntityRegistry
    ) throws -> SourceCanonicalBulletRequest {
        let function = "Entity:FireBullets"
        let source = try vectorField(
            "Src",
            in: table,
            defaultValue: .zero,
            state: state,
            function: function
        )
        let direction = try vectorField(
            "Dir",
            in: table,
            defaultValue: .zero,
            state: state,
            function: function
        )
        let spread = try vectorField(
            "Spread",
            in: table,
            defaultValue: .zero,
            state: state,
            function: function
        )
        let count = try integerField(
            "Num",
            in: table,
            defaultValue: 1,
            state: state,
            function: function
        )
        guard count > 0, count <= maximumPelletsPerCall else {
            throw LuaError.runtime(
                "Entity:FireBullets Num must be in 1...\(maximumPelletsPerCall)"
            )
        }
        let distance = try floatField(
            "Distance",
            in: table,
            defaultValue: 56_756,
            state: state,
            function: function
        )
        guard distance > 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets Distance must be positive"
            )
        }
        let tracer = try integerField(
            "Tracer",
            in: table,
            defaultValue: 1,
            state: state,
            function: function
        )
        guard tracer >= 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets Tracer must be nonnegative"
            )
        }
        let damage = try floatField(
            "Damage",
            in: table,
            defaultValue: 1,
            state: state,
            function: function
        )
        guard damage > 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets Damage=0 ammo-data lookup is unavailable; an explicit positive Damage is required"
            )
        }
        let force = try floatField(
            "Force",
            in: table,
            defaultValue: 1,
            state: state,
            function: function
        )
        guard force >= 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets Force must be nonnegative"
            )
        }
        let hullSize = try floatField(
            "HullSize",
            in: table,
            defaultValue: 0,
            state: state,
            function: function
        )
        guard hullSize == 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets HullSize requires the unattested bullet hull trace path; line Studio hitboxes remain active"
            )
        }

        let ammoName = try stringField(
            "AmmoType",
            in: table,
            defaultValue: "",
            state: state,
            function: function
        )
        guard let ammoType = SourceCanonicalDefaultAmmoCatalog.type(
            name: ammoName
        ) else {
            throw LuaError.runtime(
                "Entity:FireBullets AmmoType '\(ammoName)' is not in the canonical default ammo catalog; custom game.AddAmmoType is unavailable"
            )
        }
        let tracerNameValue = try field("TracerName", in: table, state: state)
        let tracerName: LuaString?
        switch tracerNameValue {
        case .nilValue:
            tracerName = nil
        case let .string(value):
            tracerName = value
        default:
            throw LuaError.runtime(
                "Entity:FireBullets TracerName must be a string or nil"
            )
        }

        let callback = try field("Callback", in: table, state: state)
        if !isNil(callback) {
            throw LuaError.runtime(
                "Entity:FireBullets Callback damage/effect arbitration is not implemented"
            )
        }

        let attacker = try entityField(
            "Attacker",
            in: table,
            defaultValue: shooter,
            state: state,
            registry: registry,
            function: function,
            allowsNull: false
        )
        let inflictor = try entityField(
            "Inflictor",
            in: table,
            defaultValue: nil,
            state: state,
            registry: registry,
            function: function,
            allowsNull: true
        )
        let ignore = try entityField(
            "IgnoreEntity",
            in: table,
            defaultValue: nil,
            state: state,
            registry: registry,
            function: function,
            allowsNull: true
        )
        guard let attacker else {
            preconditionFailure("non-null attacker parser")
        }
        return SourceCanonicalBulletRequest(
            source: source,
            direction: direction,
            spread: spread,
            count: count,
            distance: distance,
            tracerFrequency: tracer,
            tracerName: tracerName,
            damage: damage,
            forceScale: force,
            ammoType: ammoType,
            attacker: attacker,
            inflictor: inflictor,
            ignoreEntity: ignore
        )
    }

    private static func spreadDirection(
        _ forward: SourceVector3,
        spread: SourceVector3,
        seed: Int32
    ) throws -> SourceVector3 {
        guard forward.lengthSquared.isFinite, forward.lengthSquared > 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets Dir must be a finite nonzero Vector"
            )
        }
        if spread.x == 0, spread.y == 0 {
            return forward
        }

        let basis = try vectorVectors(forward)
        var random = SourceCanonicalUniformRandomStream(seed: seed)
        for _ in 0..<4_096 {
            // Player bullets use Source's unbiased circular Gaussian path:
            // each axis is the sum of two half-scale uniform samples.
            let x = random.randomFloat(minimum: -1, maximum: 1) * 0.5 +
                random.randomFloat(minimum: -1, maximum: 1) * 0.5
            let y = random.randomFloat(minimum: -1, maximum: 1) * 0.5 +
                random.randomFloat(minimum: -1, maximum: 1) * 0.5
            if x * x + y * y <= 1 {
                let result = forward + basis.right * (x * spread.x) +
                    basis.up * (y * spread.y)
                guard finite(result), result.lengthSquared.isFinite else {
                    throw LuaError.runtime(
                        "Entity:FireBullets spread direction exceeds Source Float range"
                    )
                }
                return result
            }
        }
        throw LuaError.runtime(
            "Entity:FireBullets spread sampler exceeded its rejection cap"
        )
    }

    private static func vectorVectors(
        _ forward: SourceVector3
    ) throws -> (right: SourceVector3, up: SourceVector3) {
        if forward.x == 0, forward.y == 0 {
            return (
                SourceVector3(0, -1, 0),
                SourceVector3(-forward.z, 0, 0)
            )
        }
        let rawRight = SourceVector3(forward.y, -forward.x, 0)
        let right = try normalized(rawRight, field: "spread right")
        let rawUp = SourceVector3(
            right.y * forward.z - right.z * forward.y,
            right.z * forward.x - right.x * forward.z,
            right.x * forward.y - right.y * forward.x
        )
        return (
            right,
            try normalized(rawUp, field: "spread up")
        )
    }

    private static func trace(
        source: SourceVector3,
        direction: SourceVector3,
        distance: Float,
        shooter: SourceCanonicalEntityIdentity,
        additionalIgnore: SourceCanonicalEntityIdentity?,
        runtime: GMLuaRuntime,
        registry: GMLuaEntityRegistry,
        host: any SourceCanonicalEntityLuaHost
    ) throws -> SourceGameTrace {
        guard let traceBridge = runtime.traceBridge else {
            throw LuaError.runtime(
                "Entity:FireBullets world trace provider is unavailable"
            )
        }
        let end = source + direction * distance
        let delta = end - source
        guard finite(source), finite(end), finite(delta),
              delta.lengthSquared.isFinite else {
            throw LuaError.runtime(
                "Entity:FireBullets source/end delta exceeds Source Float range"
            )
        }
        guard let worldIdentity = registry.canonicalIdentity(at: 0) else {
            throw LuaError.runtime(
                "Entity:FireBullets canonical Source Entity(0) is unavailable"
            )
        }
        var excluded = [shooter.handle]
        if let additionalIgnore, additionalIgnore != shooter {
            excluded.append(additionalIgnore.handle)
        }
        let request = GMLuaTraceRequest(
            kind: .line,
            ray: SourceRay(start: source, end: end),
            mask: SourceMasks.shot,
            worldIdentity: worldIdentity,
            collisionGroup: 0,
            excludedEntityHandles: excluded
        )
        let result: SourceGameTrace
        do {
            result = try traceBridge.trace(request) { candidate in
                !excluded.contains(candidate.identity.handle)
            }
        } catch {
            throw LuaError.runtime(
                "Entity:FireBullets trace failed: \(String(describing: error))"
            )
        }
        guard registry.canonicalIdentity(at: 0) == worldIdentity else {
            throw LuaError.runtime(
                "Entity:FireBullets Entity(0) changed during the trace"
            )
        }
        if let handle = result.entityHandle, result.didHit {
            if handle.entryIndex == 0 {
                guard handle == worldIdentity.handle else {
                    throw LuaError.runtime(
                        "Entity:FireBullets trace returned a stale world EHANDLE"
                    )
                }
            } else {
                let identity = SourceCanonicalEntityIdentity(handle: handle)
                guard registry.canonicalIdentity(at: handle.entryIndex) == identity,
                      host.canonicalSnapshot(for: identity) != nil else {
                    throw LuaError.runtime(
                        "Entity:FireBullets trace returned unavailable EHANDLE \(handle.rawValue)"
                    )
                }
            }
        } else if result.entityHandle != nil {
            throw LuaError.runtime(
                "Entity:FireBullets trace miss carried an Entity EHANDLE"
            )
        }
        return result
    }

    private static func applyDamage(
        _ damage: Float,
        trace: SourceGameTrace,
        bulletDirection: SourceVector3,
        forceScale: Float,
        ammoType: SourceCanonicalDefaultAmmoType,
        attacker: SourceCanonicalEntityIdentity,
        inflictor: SourceCanonicalEntityIdentity?,
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        registry: GMLuaEntityRegistry,
        host: any SourceCanonicalEntityLuaHost
    ) throws {
        guard let targetHandle = trace.entityHandle else { return }
        let targetIdentity = SourceCanonicalEntityIdentity(handle: targetHandle)
        guard let target = host.canonicalSnapshot(for: targetIdentity),
              target.combat.takeDamageMode != 0 else { return }

        let physicsPushScale = try sourcePhysicsPushScale(state: state)
        let damageForce: SourceVector3
        do {
            damageForce = try SourceCanonicalBulletDamageForce.impulse(
                ammoTypeName: ammoType.name,
                direction: bulletDirection,
                forceScale: forceScale,
                physicsPushScale: physicsPushScale
            )
        } catch {
            throw LuaError.runtime(
                "Entity:FireBullets damage force failed: " +
                    String(describing: error)
            )
        }

        let targetValue = try liveEntityValue(
            targetIdentity,
            registry: registry,
            function: "Entity:FireBullets target"
        )
        let attackerValue = try liveEntityValue(
            attacker,
            registry: registry,
            function: "Entity:FireBullets Attacker"
        )
        let inflictorValue = try inflictor.map {
            try liveEntityValue(
                $0,
                registry: registry,
                function: "Entity:FireBullets Inflictor"
            )
        }

        let constructor = state.getGlobal("DamageInfo")
        switch constructor {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "DamageInfo is \(constructor.typeName), expected function"
            )
        }
        let damageInfo = try state.call(constructor).first ?? .nilValue
        guard let damageMetatable = typeSystem.metatable(
            named: "CTakeDamageInfo"
        ), let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime(
                "Entity:FireBullets damage metatables are unavailable"
            )
        }

        try callMethod(
            "SetDamage",
            on: damageMetatable,
            receiver: damageInfo,
            arguments: [.number(Double(damage))],
            state: state
        )
        try callMethod(
            "SetDamageForce",
            on: damageMetatable,
            receiver: damageInfo,
            arguments: [try luaVector(damageForce, typeSystem: typeSystem)],
            state: state
        )
        try callMethod(
            "SetDamagePosition",
            on: damageMetatable,
            receiver: damageInfo,
            arguments: [try luaVector(trace.endPosition, typeSystem: typeSystem)],
            state: state
        )
        try callMethod(
            "SetAttacker",
            on: damageMetatable,
            receiver: damageInfo,
            arguments: [attackerValue],
            state: state
        )
        if let inflictorValue {
            try callMethod(
                "SetInflictor",
                on: damageMetatable,
                receiver: damageInfo,
                arguments: [inflictorValue],
                state: state
            )
            if let inflictor,
               host.canonicalSnapshot(for: inflictor)?.kind == .weapon {
                try callMethod(
                    "SetWeapon",
                    on: damageMetatable,
                    receiver: damageInfo,
                    arguments: [inflictorValue],
                    state: state
                )
            }
        }
        try callMethod(
            "TakeDamageInfo",
            on: entityMetatable,
            receiver: targetValue,
            arguments: [damageInfo],
            state: state
        )
    }

    /// Source's calculator reads the live replicated ConVar. Missing or
    /// non-finite state is a compatibility failure, not an implicit scale 1.
    private static func sourcePhysicsPushScale(
        state: LuaState
    ) throws -> Float {
        let getter = state.getGlobal("GetConVarNumber")
        switch getter {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "GetConVarNumber is \(getter.typeName), expected function"
            )
        }
        let value = try state.call(
            getter,
            arguments: [.string("phys_pushscale")]
        ).first ?? .nilValue
        guard case let .number(number) = value,
              number.isFinite,
              abs(number) <= Double(Float.greatestFiniteMagnitude) else {
            throw LuaError.runtime(
                "phys_pushscale must resolve to a finite Source Float"
            )
        }
        return Float(number)
    }

    private static func callMethod(
        _ name: String,
        on metatable: LuaTable,
        receiver: LuaValue,
        arguments: [LuaValue],
        state: LuaState
    ) throws {
        let function = try state.rawTableValue(
            for: .string(LuaString(name)),
            in: metatable
        )
        switch function {
        case .luaFunction, .nativeFunction:
            _ = try state.call(
                function,
                arguments: [receiver] + arguments
            )
        default:
            throw LuaError.runtime(
                "\(name) is \(function.typeName), expected function"
            )
        }
    }

    private static func liveEntityValue(
        _ identity: SourceCanonicalEntityIdentity,
        registry: GMLuaEntityRegistry,
        function: String
    ) throws -> LuaValue {
        let value = registry.entity(at: identity.entryIndex)
        guard registry.canonicalIdentity(for: value) == identity else {
            throw LuaError.runtime(
                "\(function) EHANDLE \(identity.handle.rawValue) is unavailable"
            )
        }
        return value
    }

    private static func playerSnapshot(
        _ value: LuaValue?,
        registry: GMLuaEntityRegistry?,
        function: String
    ) throws -> SourceCanonicalEntitySnapshot {
        guard let value,
              let player = registry?.canonicalSnapshot(for: value),
              player.kind == .player else {
            throw LuaError.runtime(
                "bad self to '\(function)' (live canonical Player expected)"
            )
        }
        return player
    }

    private static func field(
        _ name: String,
        in table: LuaTable,
        state: LuaState
    ) throws -> LuaValue {
        try state.rawTableValue(
            for: .string(LuaString(name)),
            in: table
        )
    }

    private static func vectorField(
        _ name: String,
        in table: LuaTable,
        defaultValue: SourceVector3,
        state: LuaState,
        function: String
    ) throws -> SourceVector3 {
        let value = try field(name, in: table, state: state)
        if isNil(value) { return defaultValue }
        let components = try GMLuaVectorAngle.networkVectorComponents(
            from: value,
            function: "\(function) field '\(name)'"
        )
        let limit = Double(Float.greatestFiniteMagnitude)
        guard components.0.isFinite, components.1.isFinite,
              components.2.isFinite,
              abs(components.0) <= limit, abs(components.1) <= limit,
              abs(components.2) <= limit else {
            throw LuaError.runtime(
                "\(function) field '\(name)' exceeds Source Float range"
            )
        }
        return SourceVector3(
            Float(components.0),
            Float(components.1),
            Float(components.2)
        )
    }

    private static func floatField(
        _ name: String,
        in table: LuaTable,
        defaultValue: Float,
        state: LuaState,
        function: String
    ) throws -> Float {
        let value = try field(name, in: table, state: state)
        if isNil(value) { return defaultValue }
        guard case let .number(number) = value, number.isFinite,
              abs(number) <= Double(Float.greatestFiniteMagnitude) else {
            throw LuaError.runtime(
                "\(function) field '\(name)' must be a finite Source Float"
            )
        }
        return Float(number)
    }

    private static func integerField(
        _ name: String,
        in table: LuaTable,
        defaultValue: Int32,
        state: LuaState,
        function: String
    ) throws -> Int32 {
        let value = try field(name, in: table, state: state)
        if isNil(value) { return defaultValue }
        guard case let .number(number) = value, number.isFinite,
              number.rounded(.towardZero) == number,
              let result = Int32(exactly: number) else {
            throw LuaError.runtime(
                "\(function) field '\(name)' must be a 32-bit integer"
            )
        }
        return result
    }

    private static func stringField(
        _ name: String,
        in table: LuaTable,
        defaultValue: String,
        state: LuaState,
        function: String
    ) throws -> String {
        let value = try field(name, in: table, state: state)
        if isNil(value) { return defaultValue }
        guard case let .string(string) = value else {
            throw LuaError.runtime(
                "\(function) field '\(name)' must be a string"
            )
        }
        return string.utf8String
    }

    private static func entityField(
        _ name: String,
        in table: LuaTable,
        defaultValue: SourceCanonicalEntityIdentity?,
        state: LuaState,
        registry: GMLuaEntityRegistry,
        function: String,
        allowsNull: Bool
    ) throws -> SourceCanonicalEntityIdentity? {
        let value = try field(name, in: table, state: state)
        if isNil(value) { return defaultValue }
        if let object = GMLuaTypeSystem.typedObject(from: value),
           !object.isValid {
            if allowsNull { return nil }
            throw LuaError.runtime(
                "\(function) field '\(name)' requires a live canonical Entity"
            )
        }
        guard let identity = registry.canonicalIdentity(for: value) else {
            throw LuaError.runtime(
                "\(function) field '\(name)' requires a live canonical Entity"
            )
        }
        return identity
    }

    private static func luaVector(
        _ value: SourceVector3,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkVector(
            Double(value.x),
            Double(value.y),
            Double(value.z),
            typeSystem: typeSystem
        )
    }

    private static func normalized(
        _ value: SourceVector3,
        field: String
    ) throws -> SourceVector3 {
        let length = value.length
        guard length.isFinite, length > 0 else {
            throw LuaError.runtime(
                "Entity:FireBullets \(field) is degenerate"
            )
        }
        return value / length
    }

    private static func finite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func isNil(_ value: LuaValue) -> Bool {
        if case .nilValue = value { return true }
        return false
    }
}

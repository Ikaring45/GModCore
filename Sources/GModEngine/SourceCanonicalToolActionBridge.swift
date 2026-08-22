import Foundation
import GModLua

public struct SourceCanonicalConstraintRecord: Equatable, Sendable {
    public let identifier: UInt64
    public let entities: [SourceCanonicalEntityIdentity]

    public init(
        identifier: UInt64,
        entities: [SourceCanonicalEntityIdentity]
    ) {
        self.identifier = identifier
        self.entities = entities
    }
}

public struct SourceCanonicalConstraintRemovalResult: Equatable, Sendable {
    public let removed: [SourceCanonicalConstraintRecord]

    public init(removed: [SourceCanonicalConstraintRecord]) {
        self.removed = removed
    }

    public var didRemoveAny: Bool { !removed.isEmpty }
    public var removedCount: Int { removed.count }
}

public enum SourceCanonicalConstraintGraphError: Error, Equatable, Sendable {
    case insufficientDistinctEntities
    case identifierExhausted
}

/// Engine-owned topology for canonical constraints. The initial empty graph is
/// a real state: queries include the starting entity and `RemoveAll` reports
/// zero removals. Public insertion keeps the same bridge usable when concrete
/// constraint entities/bodies are added instead of hard-coding an empty no-op.
public final class SourceCanonicalConstraintGraph: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIdentifier: UInt64 = 1
    private var recordsByIdentifier: [UInt64: SourceCanonicalConstraintRecord] = [:]

    public init() {}

    public var records: [SourceCanonicalConstraintRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsByIdentifier.values.sorted {
            $0.identifier < $1.identifier
        }
    }

    @discardableResult
    public func insert(
        entities: [SourceCanonicalEntityIdentity]
    ) throws -> SourceCanonicalConstraintRecord {
        let distinct = Array(Set(entities)).sorted {
            $0.handle.rawValue < $1.handle.rawValue
        }
        guard distinct.count >= 2 else {
            throw SourceCanonicalConstraintGraphError.insufficientDistinctEntities
        }
        lock.lock()
        defer { lock.unlock() }
        guard nextIdentifier != UInt64.max else {
            throw SourceCanonicalConstraintGraphError.identifierExhausted
        }
        let record = SourceCanonicalConstraintRecord(
            identifier: nextIdentifier,
            entities: distinct
        )
        nextIdentifier += 1
        recordsByIdentifier[record.identifier] = record
        return record
    }

    public func hasConstraints(
        involving entity: SourceCanonicalEntityIdentity
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordsByIdentifier.values.contains {
            $0.entities.contains(entity)
        }
    }

    public func removeAll(
        involving entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalConstraintRemovalResult {
        lock.lock()
        let identifiers = recordsByIdentifier.values
            .filter { $0.entities.contains(entity) }
            .map(\.identifier)
            .sorted()
        let removed = identifiers.compactMap {
            recordsByIdentifier.removeValue(forKey: $0)
        }
        lock.unlock()
        return SourceCanonicalConstraintRemovalResult(removed: removed)
    }

    /// Returns the complete connected component in deterministic full-EHANDLE
    /// order, including `entity` even when the graph is empty.
    public func allConstrainedEntities(
        startingAt entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        lock.lock()
        let records = Array(recordsByIdentifier.values)
        lock.unlock()

        var visited: Set<SourceCanonicalEntityIdentity> = [entity]
        var queue: [SourceCanonicalEntityIdentity] = [entity]
        var offset = 0
        while offset < queue.count {
            let current = queue[offset]
            offset += 1
            for record in records where record.entities.contains(current) {
                for connected in record.entities where visited.insert(connected).inserted {
                    queue.append(connected)
                }
            }
        }
        return visited.sorted { $0.handle.rawValue < $1.handle.rawValue }
    }
}

private final class SourceCanonicalToolWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalToolWeakRegistry: @unchecked Sendable {
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

/// Native engine bridge needed by the stock toolgun action after its Source
/// trace succeeds. SERVER mutations target canonical state; effects, sounds,
/// and animation requests enter the net/console/entity transport FIFO.
public final class SourceCanonicalToolActionBridge: @unchecked Sendable {
    public let constraintGraph: SourceCanonicalConstraintGraph
    public let clientEventState: GMLuaGameplayEventClientState?

    private init(
        constraintGraph: SourceCanonicalConstraintGraph,
        clientEventState: GMLuaGameplayEventClientState?
    ) {
        self.constraintGraph = constraintGraph
        self.clientEventState = clientEventState
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil,
        constraintGraph: SourceCanonicalConstraintGraph =
            SourceCanonicalConstraintGraph(),
        firstTimePredicted: (@Sendable () -> Bool)? = nil
    ) throws -> SourceCanonicalToolActionBridge {
        guard runtime.realm != .menu,
              let typeSystem = runtime.typeSystem,
              let registry = runtime.entityRegistry,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let weaponMetatable = typeSystem.metatable(named: "Weapon"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime(
                "canonical tool action bridge requires game Entity metatables"
            )
        }
        if runtime.realm == .server, host == nil {
            throw LuaError.runtime(
                "canonical tool action bridge SERVER requires an authoritative host"
            )
        }
        guard let endpoint = runtime.netEndpoint else {
            throw LuaError.runtime(
                "canonical tool action bridge requires a net transport endpoint"
            )
        }

        let state = runtime.state
        let realm = runtime.realm
        let hostBox = SourceCanonicalToolWeakHost(host)
        let registryBox = SourceCanonicalToolWeakRegistry(registry)
        let clientState = realm == .client
            ? GMLuaGameplayEventClientState()
            : nil
        let bridge = SourceCanonicalToolActionBridge(
            constraintGraph: constraintGraph,
            clientEventState: clientState
        )

        let moveTypeConstants: [(String, SourceMoveType)] = [
            ("MOVETYPE_NONE", .none),
            ("MOVETYPE_ISOMETRIC", .isometric),
            ("MOVETYPE_WALK", .walk),
            ("MOVETYPE_STEP", .step),
            ("MOVETYPE_FLY", .fly),
            ("MOVETYPE_FLYGRAVITY", .flyGravity),
            ("MOVETYPE_VPHYSICS", .vPhysics),
            ("MOVETYPE_PUSH", .push),
            ("MOVETYPE_NOCLIP", .noClip),
            ("MOVETYPE_LADDER", .ladder),
            ("MOVETYPE_OBSERVER", .observer),
            ("MOVETYPE_CUSTOM", .custom),
        ]
        for (name, value) in moveTypeConstants {
            state.setGlobal(name, value: .number(Double(value.rawValue)))
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
                for: .string(LuaString(
                    name.split(separator: ":").last.map(String.init) ?? name
                )),
                in: metatable
            )
        }

        func snapshot(
            _ value: LuaValue?,
            function: String,
            kind: SourceCanonicalEntityKind? = nil
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let result = registryBox.value?.canonicalSnapshot(for: value),
                  kind == nil || result.kind == kind else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            return result
        }

        func requiredHost(
            _ function: String
        ) throws -> any SourceCanonicalEntityLuaHost {
            guard realm == .server, let host = hostBox.value else {
                throw LuaError.runtime("\(function) requires SERVER authority")
            }
            return host
        }

        func requiredBoolean(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Bool {
            guard arguments.indices.contains(index),
                  case let .boolean(value) = arguments[index] else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (boolean expected)"
                )
            }
            return value
        }

        func optionalNumber(
            _ arguments: [LuaValue],
            index: Int,
            default defaultValue: Double,
            function: String
        ) throws -> Double {
            guard arguments.indices.contains(index) else { return defaultValue }
            if case .nilValue = arguments[index] { return defaultValue }
            guard case let .number(value) = arguments[index], value.isFinite else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (finite number expected)"
                )
            }
            return value
        }

        func requiredInt32(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Int32 {
            let value = try optionalNumber(
                arguments,
                index: index,
                default: .nan,
                function: function
            )
            guard value.rounded(.towardZero) == value,
                  value >= Double(Int32.min),
                  value <= Double(Int32.max) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (32-bit integer expected)"
                )
            }
            return Int32(value)
        }

        func requiredSoundName(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> LuaString {
            guard arguments.indices.contains(index),
                  case let .string(value) = arguments[index],
                  !value.bytes.isEmpty,
                  !value.bytes.contains(0) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (non-empty sound name expected)"
                )
            }
            return value
        }

        try setMethod("Entity:GetNotSolid", on: entityMetatable) { arguments in
            [.boolean(try snapshot(
                arguments.first,
                function: "Entity:GetNotSolid"
            ).isNotSolid)]
        }
        try setMethod("Entity:GetNoDraw", on: entityMetatable) { arguments in
            [.boolean(try snapshot(
                arguments.first,
                function: "Entity:GetNoDraw"
            ).isNoDraw)]
        }

        if realm == .server {
            try setMethod("Entity:SetNotSolid", on: entityMetatable) { arguments in
                let entity = try snapshot(
                    arguments.first,
                    function: "Entity:SetNotSolid"
                )
                let value = try requiredBoolean(
                    arguments,
                    index: 1,
                    function: "Entity:SetNotSolid"
                )
                _ = try requiredHost("Entity:SetNotSolid")
                    .updateCanonicalEntity(entity.identity) {
                        $0.isNotSolid = value
                    }
                return []
            }
            try setMethod("Entity:SetNoDraw", on: entityMetatable) { arguments in
                let entity = try snapshot(
                    arguments.first,
                    function: "Entity:SetNoDraw"
                )
                let value = try requiredBoolean(
                    arguments,
                    index: 1,
                    function: "Entity:SetNoDraw"
                )
                _ = try requiredHost("Entity:SetNoDraw")
                    .updateCanonicalEntity(entity.identity) {
                        $0.isNoDraw = value
                    }
                return []
            }
            try setMethod("Entity:SetMoveType", on: entityMetatable) { arguments in
                let entity = try snapshot(
                    arguments.first,
                    function: "Entity:SetMoveType"
                )
                let raw = try requiredInt32(
                    arguments,
                    index: 1,
                    function: "Entity:SetMoveType"
                )
                guard let moveType = UInt8(exactly: raw).flatMap(SourceMoveType.init) else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'Entity:SetMoveType' (Source MOVETYPE expected)"
                    )
                }
                _ = try requiredHost("Entity:SetMoveType")
                    .updateCanonicalEntity(entity.identity) {
                        $0.moveType = moveType
                    }
                return []
            }
        }

        try setMethod("Entity:IsConstrained", on: entityMetatable) { arguments in
            guard realm == .server else {
                throw LuaError.runtime(
                    "Entity:IsConstrained CLIENT constraint snapshot is unavailable"
                )
            }
            let entity = try snapshot(
                arguments.first,
                function: "Entity:IsConstrained"
            )
            return [.boolean(constraintGraph.hasConstraints(
                involving: entity.identity
            ))]
        }

        if realm == .server {
            let constraintTable: LuaTable
            if case let .table(existing) = state.getGlobal("constraint") {
                constraintTable = existing
            } else {
                constraintTable = LuaTable()
            }
            try state.setRawTableValue(
                native("constraint.RemoveAll") { arguments in
                    let entity = try snapshot(
                        arguments.first,
                        function: "constraint.RemoveAll"
                    )
                    let result = constraintGraph.removeAll(
                        involving: entity.identity
                    )
                    return [
                        .boolean(result.didRemoveAny),
                        .number(Double(result.removedCount)),
                    ]
                },
                for: .string("RemoveAll"),
                in: constraintTable
            )
            try state.setRawTableValue(
                native("constraint.GetAllConstrainedEntities") { arguments in
                    let entity = try snapshot(
                        arguments.first,
                        function: "constraint.GetAllConstrainedEntities"
                    )
                    let output: LuaTable
                    if arguments.indices.contains(1),
                       case let .table(existing) = arguments[1] {
                        output = existing
                    } else if arguments.indices.contains(1),
                              case .nilValue = arguments[1] {
                        output = LuaTable()
                    } else if arguments.indices.contains(1) {
                        throw LuaError.runtime(
                            "bad argument #2 to 'constraint.GetAllConstrainedEntities' (table expected)"
                        )
                    } else {
                        output = LuaTable()
                    }
                    guard let registry = registryBox.value else {
                        throw LuaError.runtime(
                            "constraint Entity registry is unavailable"
                        )
                    }
                    for identity in constraintGraph.allConstrainedEntities(
                        startingAt: entity.identity
                    ) {
                        let value = registry.entity(at: identity.entryIndex)
                        guard registry.canonicalIdentity(for: value) == identity else {
                            continue
                        }
                        try state.setRawTableValue(value, for: value, in: output)
                    }
                    return [.table(output)]
                },
                for: .string("GetAllConstrainedEntities"),
                in: constraintTable
            )
            state.setGlobal("constraint", value: .table(constraintTable))
        }

        try setMethod("Entity:EmitSound", on: entityMetatable) { arguments in
            let entity = try snapshot(
                arguments.first,
                function: "Entity:EmitSound"
            )
            let sound = try requiredSoundName(
                arguments,
                index: 1,
                function: "Entity:EmitSound"
            )
            let level = try optionalNumber(
                arguments,
                index: 2,
                default: 75,
                function: "Entity:EmitSound"
            )
            let pitch = try optionalNumber(
                arguments,
                index: 3,
                default: 100,
                function: "Entity:EmitSound"
            )
            let volume = try optionalNumber(
                arguments,
                index: 4,
                default: 1,
                function: "Entity:EmitSound"
            )
            let channel = try Int32(exactly: optionalNumber(
                arguments,
                index: 5,
                default: 0,
                function: "Entity:EmitSound"
            ))
            let flags = try Int32(exactly: optionalNumber(
                arguments,
                index: 6,
                default: 0,
                function: "Entity:EmitSound"
            ))
            let dsp = try Int32(exactly: optionalNumber(
                arguments,
                index: 7,
                default: 0,
                function: "Entity:EmitSound"
            ))
            guard let channel, let flags, let dsp,
                  volume >= 0 else {
                throw LuaError.runtime(
                    "Entity:EmitSound requires integral channel/flags/dsp and nonnegative volume"
                )
            }
            let event = GMLuaEntitySoundEvent(
                entityIdentity: entity.identity,
                sound: sound,
                origin: entity.transform.origin,
                level: level,
                pitch: pitch,
                volume: volume,
                channel: channel,
                flags: flags,
                dsp: dsp
            )
            if realm == .server {
                try endpoint.broadcastGameplayEvent(.entitySound(event))
            } else {
                guard let soundBridge = runtime.sound else {
                    throw LuaError.runtime(
                        "Entity:EmitSound CLIENT sound bridge is unavailable"
                    )
                }
                try soundBridge.receiveEnginePlayEvent(event.clientPlayEvent)
            }
            return []
        }

        try setMethod("Weapon:SendWeaponAnim", on: weaponMetatable) { arguments in
            let weapon = try snapshot(
                arguments.first,
                function: "Weapon:SendWeaponAnim",
                kind: .weapon
            )
            let activity = try requiredInt32(
                arguments,
                index: 1,
                function: "Weapon:SendWeaponAnim"
            )
            guard realm == .server else {
                throw LuaError.runtime(
                    "Weapon:SendWeaponAnim CLIENT prediction is not connected"
                )
            }
            try endpoint.broadcastGameplayEvent(.weaponAnimation(
                GMLuaWeaponAnimationEvent(
                    weaponIdentity: weapon.identity,
                    activity: activity
                )
            ))
            return [.boolean(true)]
        }

        try setMethod("Player:SetAnimation", on: playerMetatable) { arguments in
            let player = try snapshot(
                arguments.first,
                function: "Player:SetAnimation",
                kind: .player
            )
            let animation = try requiredInt32(
                arguments,
                index: 1,
                function: "Player:SetAnimation"
            )
            guard realm == .server else {
                throw LuaError.runtime(
                    "Player:SetAnimation CLIENT prediction is not connected"
                )
            }
            try endpoint.broadcastGameplayEvent(.playerAnimation(
                GMLuaPlayerAnimationEvent(
                    playerIdentity: player.identity,
                    animation: animation
                )
            ))
            return []
        }

        if realm == .server {
            state.setGlobal(
                "IsFirstTimePredicted",
                value: native("IsFirstTimePredicted") { _ in
                    [.boolean(firstTimePredicted?() ?? true)]
                }
            )
            guard let effects = runtime.effects else {
                throw LuaError.runtime(
                    "SERVER util.Effect bridge is unavailable"
                )
            }
            effects.connectRequestSink { [weak endpoint] request in
                guard let endpoint else {
                    throw LuaError.runtime(
                        "SERVER util.Effect endpoint is unavailable"
                    )
                }
                try endpoint.broadcastGameplayEvent(.effect(request))
            }
        } else {
            guard let clientState else {
                throw LuaError.runtime("CLIENT gameplay event state is unavailable")
            }
            try endpoint.connectGameplayEventHandler {
                [weak runtime, clientState] delivery in
                guard let runtime, !runtime.isClosed else {
                    throw LuaError.runtime(
                        "gameplay event CLIENT runtime is unavailable"
                    )
                }
                switch delivery.payload {
                case let .effect(request):
                    guard let effects = runtime.effects else {
                        throw LuaError.runtime(
                            "gameplay event CLIENT effect bridge is unavailable"
                        )
                    }
                    try effects.receiveReplicatedEffect(request)
                case let .entitySound(event):
                    guard let sound = runtime.sound else {
                        throw LuaError.runtime(
                            "gameplay event CLIENT sound bridge is unavailable"
                        )
                    }
                    try sound.receiveEnginePlayEvent(event.clientPlayEvent)
                case .weaponAnimation, .playerAnimation:
                    break
                }
                clientState.capture(delivery)
            }
        }

        return bridge
    }
}

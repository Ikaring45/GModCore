import Foundation
import GModLua

public struct SourceCanonicalNoCollideConstraintBinding:
    Equatable, Sendable
{
    public let graphRecord: SourceCanonicalConstraintRecord
    public let constraintEntity: SourceCanonicalEntityIdentity
    public let first: SourceCanonicalNoCollideEndpoint
    public let second: SourceCanonicalNoCollideEndpoint
    public let creationCommand:
        SourcePhysicsNoCollideConstraintCreationCommand
    public let creationSequence: UInt64
    public let disableOnRemove: Bool
    public let firstConstraintSlot: Int
    public let secondConstraintSlot: Int

    public init(
        graphRecord: SourceCanonicalConstraintRecord,
        constraintEntity: SourceCanonicalEntityIdentity,
        first: SourceCanonicalNoCollideEndpoint,
        second: SourceCanonicalNoCollideEndpoint,
        creationCommand: SourcePhysicsNoCollideConstraintCreationCommand,
        creationSequence: UInt64,
        disableOnRemove: Bool,
        firstConstraintSlot: Int,
        secondConstraintSlot: Int
    ) {
        self.graphRecord = graphRecord
        self.constraintEntity = constraintEntity
        self.first = first
        self.second = second
        self.creationCommand = creationCommand
        self.creationSequence = creationSequence
        self.disableOnRemove = disableOnRemove
        self.firstConstraintSlot = firstConstraintSlot
        self.secondConstraintSlot = secondConstraintSlot
    }

    public var constraintID: SourcePhysicsConstraintID {
        creationCommand.constraintID
    }
}

/// Engine-owned public `constraint.NoCollide` bindings. Keys always retain a
/// complete constraint EHANDLE; a reused entry index cannot alias old state.
public final class SourceCanonicalNoCollideConstraintStore:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var bindingsByConstraintHandle: [
        UInt32: SourceCanonicalNoCollideConstraintBinding
    ] = [:]

    public init() {}

    public var bindings: [SourceCanonicalNoCollideConstraintBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByConstraintHandle.values.sorted {
            $0.graphRecord.identifier < $1.graphRecord.identifier
        }
    }

    fileprivate func binding(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalNoCollideConstraintBinding? {
        lock.lock()
        defer { lock.unlock() }
        let binding = bindingsByConstraintHandle[identity.handle.rawValue]
        return binding?.constraintEntity == identity ? binding : nil
    }

    fileprivate func bindings(
        involving identity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalNoCollideConstraintBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByConstraintHandle.values.filter {
            $0.first.entity == identity || $0.second.entity == identity
        }.sorted {
            $0.graphRecord.identifier < $1.graphRecord.identifier
        }
    }

    fileprivate func contains(
        firstBodyID: SourcePhysicsBodyID,
        secondBodyID: SourcePhysicsBodyID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByConstraintHandle.values.contains {
            ($0.first.bodyID == firstBodyID &&
                $0.second.bodyID == secondBodyID) ||
            ($0.first.bodyID == secondBodyID &&
                $0.second.bodyID == firstBodyID)
        }
    }

    fileprivate func insert(
        _ binding: SourceCanonicalNoCollideConstraintBinding
    ) {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            bindingsByConstraintHandle[
                binding.constraintEntity.handle.rawValue
            ] == nil,
            "canonical NoCollide constraint EHANDLE must be unique"
        )
        bindingsByConstraintHandle[
            binding.constraintEntity.handle.rawValue
        ] = binding
    }

    @discardableResult
    fileprivate func remove(
        constraintEntity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalNoCollideConstraintBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard let binding = bindingsByConstraintHandle[
            constraintEntity.handle.rawValue
        ], binding.constraintEntity == constraintEntity else { return nil }
        bindingsByConstraintHandle.removeValue(
            forKey: constraintEntity.handle.rawValue
        )
        return binding
    }
}

private final class SourceCanonicalNoCollideWeakEntityHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalNoCollideEntityHost)?

    init(_ value: any SourceCanonicalNoCollideEntityHost) {
        self.value = value
    }
}

private final class SourceCanonicalNoCollideWeakPhysicsHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalNoCollidePhysicsHost)?

    init(_ value: any SourceCanonicalNoCollidePhysicsHost) {
        self.value = value
    }
}

private final class SourceCanonicalNoCollideWeakCommandQueue:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalPhysicsConstraintCommandQueue)?

    init(_ value: any SourceCanonicalPhysicsConstraintCommandQueue) {
        self.value = value
    }
}

/// SERVER implementation of the bundled public `constraint.NoCollide` API.
///
/// The original stool remains the caller, so its trace, `GM:CanTool`,
/// configurable `CheckLimit`, two-click staging, undo and cleanup Lua all stay
/// authoritative. This bridge replaces only the unavailable
/// `logic_collision_pair` backend with a canonical constraint Entity and a
/// generation-safe pair-suppression command in the shared physics FIFO.
public final class SourceCanonicalNoCollideConstraintGLuaBridge:
    @unchecked Sendable
{
    public let store: SourceCanonicalNoCollideConstraintStore

    private let state: LuaState
    private let registry: GMLuaEntityRegistry
    private let entityHost: SourceCanonicalNoCollideWeakEntityHost
    private let physicsHost: SourceCanonicalNoCollideWeakPhysicsHost
    private let commandQueue: SourceCanonicalNoCollideWeakCommandQueue
    private let constraintGraph: SourceCanonicalConstraintGraph
    private let previousEntityRemove: LuaValue
    private let previousRemoveAll: LuaValue
    private let previousRemoveConstraints: LuaValue

    private init(
        state: LuaState,
        registry: GMLuaEntityRegistry,
        entityHost: any SourceCanonicalNoCollideEntityHost,
        physicsHost: any SourceCanonicalNoCollidePhysicsHost,
        commandQueue: any SourceCanonicalPhysicsConstraintCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        previousEntityRemove: LuaValue,
        previousRemoveAll: LuaValue,
        previousRemoveConstraints: LuaValue,
        store: SourceCanonicalNoCollideConstraintStore
    ) {
        self.state = state
        self.registry = registry
        self.entityHost = SourceCanonicalNoCollideWeakEntityHost(entityHost)
        self.physicsHost = SourceCanonicalNoCollideWeakPhysicsHost(physicsHost)
        self.commandQueue = SourceCanonicalNoCollideWeakCommandQueue(
            commandQueue
        )
        self.constraintGraph = constraintGraph
        self.previousEntityRemove = previousEntityRemove
        self.previousRemoveAll = previousRemoveAll
        self.previousRemoveConstraints = previousRemoveConstraints
        self.store = store
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        entityHost: any SourceCanonicalNoCollideEntityHost,
        physicsHost: any SourceCanonicalNoCollidePhysicsHost,
        commandQueue: any SourceCanonicalPhysicsConstraintCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        store: SourceCanonicalNoCollideConstraintStore =
            SourceCanonicalNoCollideConstraintStore()
    ) throws -> SourceCanonicalNoCollideConstraintGLuaBridge {
        guard runtime.realm == .server,
              !runtime.isClosed,
              let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime(
                "canonical constraint.NoCollide requires an open SERVER " +
                "Entity runtime"
            )
        }

        let state = runtime.state
        let constraintTable: LuaTable
        if case let .table(existing) = state.getGlobal("constraint") {
            constraintTable = existing
        } else {
            constraintTable = LuaTable()
        }
        let previousEntityRemove = try state.rawTableValue(
            for: .string("Remove"),
            in: entityMetatable
        )
        let previousRemoveAll = try state.rawTableValue(
            for: .string("RemoveAll"),
            in: constraintTable
        )
        let previousRemoveConstraints = try state.rawTableValue(
            for: .string("RemoveConstraints"),
            in: constraintTable
        )
        let bridge = SourceCanonicalNoCollideConstraintGLuaBridge(
            state: state,
            registry: registry,
            entityHost: entityHost,
            physicsHost: physicsHost,
            commandQueue: commandQueue,
            constraintGraph: constraintGraph,
            previousEntityRemove: previousEntityRemove,
            previousRemoveAll: previousRemoveAll,
            previousRemoveConstraints: previousRemoveConstraints,
            store: store
        )
        try bridge.installFunctions(
            constraintTable: constraintTable,
            entityMetatable: entityMetatable
        )
        return bridge
    }

    private func installFunctions(
        constraintTable: LuaTable,
        entityMetatable: LuaTable
    ) throws {
        // This is a public Source/GMod engine constant, not stool-owned state.
        // The bundled nocollide stool consumes it in its original right-click
        // path after this bridge is installed.
        state.setGlobal(
            "COLLISION_GROUP_WORLD",
            value: .number(Double(
                SourceCanonicalNoCollideCollisionGroup.world
            ))
        )

        try state.setRawTableValue(
            native("constraint.NoCollide", retaining: []) { [self] arguments in
                try createNoCollide(arguments: arguments)
            },
            for: .string("NoCollide"),
            in: constraintTable
        )

        try state.setRawTableValue(
            native(
                "constraint.RemoveConstraints",
                retaining: [previousRemoveConstraints]
            ) { [self] arguments in
                guard arguments.count >= 2,
                      case let .string(type) = arguments[1],
                      type.bytes == Array("NoCollide".utf8),
                      let entity = canonicalSnapshot(arguments.first) else {
                    return try callPrevious(
                        previousRemoveConstraints,
                        arguments: arguments,
                        fallback: [.boolean(false)]
                    )
                }
                let bindings = store.bindings(involving: entity.identity)
                for binding in bindings { try remove(binding: binding) }
                return [
                    .boolean(!bindings.isEmpty),
                    .number(Double(bindings.count)),
                ]
            },
            for: .string("RemoveConstraints"),
            in: constraintTable
        )

        try state.setRawTableValue(
            native(
                "constraint.RemoveAll",
                retaining: [previousRemoveAll]
            ) { [self] arguments in
                guard let entity = canonicalSnapshot(arguments.first) else {
                    return try callPrevious(
                        previousRemoveAll,
                        arguments: arguments,
                        fallback: [.boolean(false), .number(0)]
                    )
                }
                let bindings = store.bindings(involving: entity.identity)
                for binding in bindings { try remove(binding: binding) }
                let previous = try callPrevious(
                    previousRemoveAll,
                    arguments: arguments,
                    fallback: [.boolean(false), .number(0)]
                )
                let previousDidRemove = previous.first?.booleanValue ?? false
                let previousCount = previous.indices.contains(1)
                    ? previous[1].nonNegativeIntegerValue ?? 0
                    : (previousDidRemove ? 1 : 0)
                let count = bindings.count + previousCount
                return [
                    .boolean(count > 0),
                    .number(Double(count)),
                ]
            },
            for: .string("RemoveAll"),
            in: constraintTable
        )
        state.setGlobal("constraint", value: .table(constraintTable))

        try state.setRawTableValue(
            native("Entity:Remove", retaining: [previousEntityRemove]) {
                [self] arguments in
                guard let entity = canonicalSnapshot(arguments.first) else {
                    return try callPrevious(
                        previousEntityRemove,
                        arguments: arguments,
                        fallback: []
                    )
                }
                if let binding = store.binding(for: entity.identity) {
                    try remove(binding: binding)
                    return []
                }
                for binding in store.bindings(involving: entity.identity) {
                    try remove(binding: binding)
                }
                return try callPrevious(
                    previousEntityRemove,
                    arguments: arguments,
                    fallback: try fallbackEntityRemoval(entity.identity)
                )
            },
            for: .string("Remove"),
            in: entityMetatable
        )
    }

    private func createNoCollide(arguments: [LuaValue]) throws -> [LuaValue] {
        guard arguments.count >= 4,
              let firstEntity = canonicalSnapshot(arguments[0]),
              let secondEntity = canonicalSnapshot(arguments[1]),
              firstEntity.kind != .player,
              secondEntity.kind != .player,
              firstEntity.lifecycle == .active,
              secondEntity.lifecycle == .active,
              let firstSolid = exactNonNegativeInteger(arguments[2]),
              let secondSolid = exactNonNegativeInteger(arguments[3]),
              let entityHost = entityHost.value,
              let physicsHost = physicsHost.value,
              let commandQueue = commandQueue.value else {
            return [.boolean(false)]
        }

        let firstBodyID = try SourcePhysicsBodyID(
            entityIdentity: firstEntity.identity,
            solidIndex: firstSolid
        )
        let secondBodyID = try SourcePhysicsBodyID(
            entityIdentity: secondEntity.identity,
            solidIndex: secondSolid
        )
        guard firstBodyID != secondBodyID,
              physicsHost.containsCanonicalNoCollidePhysicsBody(firstBodyID),
              physicsHost.containsCanonicalNoCollidePhysicsBody(secondBodyID),
              !store.contains(
                  firstBodyID: firstBodyID,
                  secondBodyID: secondBodyID
              ) else {
            return [.boolean(false)]
        }

        guard let firstTable = registry.luaTable(for: arguments[0]),
              let secondTable = registry.luaTable(for: arguments[1]) else {
            throw LuaError.runtime(
                "constraint.NoCollide endpoint Entity table is unavailable"
            )
        }
        let firstConstraints = try constraintArray(
            for: firstTable,
            function: "constraint.NoCollide"
        )
        let secondConstraints = firstTable === secondTable
            ? firstConstraints
            : try constraintArray(
                for: secondTable,
                function: "constraint.NoCollide"
            )
        let firstSlot = try firstFreeSlot(in: firstConstraints)
        let secondSlot = firstConstraints === secondConstraints
            ? try firstFreeSlot(in: secondConstraints, startingAfter: firstSlot)
            : try firstFreeSlot(in: secondConstraints)

        let graphRecord: SourceCanonicalConstraintRecord
        do {
            graphRecord = try constraintGraph.insert(entities: [
                firstEntity.identity,
                secondEntity.identity,
            ])
        } catch {
            return [.boolean(false)]
        }
        let creation = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: SourcePhysicsConstraintID(
                rawValue: graphRecord.identifier
            ),
            firstBodyID: firstBodyID,
            secondBodyID: secondBodyID
        )
        let firstEndpoint = SourceCanonicalNoCollideEndpoint(
            entity: firstEntity.identity,
            bodyID: firstBodyID,
            hitPosition: firstEntity.transform.origin,
            hitNormal: .zero
        )
        let secondEndpoint = SourceCanonicalNoCollideEndpoint(
            entity: secondEntity.identity,
            bodyID: secondBodyID,
            hitPosition: secondEntity.transform.origin,
            hitNormal: .zero
        )
        let disableOnRemove = arguments.indices.contains(4)
            ? arguments[4].luaTruth
            : false
        var createdEntity: SourceCanonicalEntitySnapshot?
        var queued: [SourcePhysicsCommand] = []
        var linkedFirst = false
        do {
            let created = try entityHost.createCanonicalEntity(
                kind: .physicsConstraint,
                at: nil,
                state: nil,
                playerUserID: nil
            )
            createdEntity = created
            let constraintValue = registry.entity(
                at: created.identity.entryIndex
            )
            guard registry.canonicalIdentity(for: constraintValue) ==
                    created.identity else {
                throw LuaError.runtime(
                    "constraint.NoCollide failed to publish its exact " +
                    "constraint EHANDLE"
                )
            }

            queued = try commandQueue
                .enqueueCanonicalPhysicsConstraintCommands([
                    .createNoCollide(creation),
                ])
            try validateQueuedCommands(
                queued,
                expected: [.createNoCollide(creation)]
            )
            _ = try entityHost.spawnCanonicalEntity(created.identity)
            let active = try entityHost.activateCanonicalEntity(
                created.identity
            )
            try populateLuaConstraintTable(
                constraintValue: constraintValue,
                firstValue: arguments[0],
                secondValue: arguments[1],
                firstBone: firstSolid,
                secondBone: secondSolid,
                disableOnRemove: disableOnRemove,
                constraintID: creation.constraintID
            )
            try state.setRawTableValue(
                constraintValue,
                for: .number(Double(firstSlot)),
                in: firstConstraints
            )
            linkedFirst = true
            try state.setRawTableValue(
                constraintValue,
                for: .number(Double(secondSlot)),
                in: secondConstraints
            )

            let binding = SourceCanonicalNoCollideConstraintBinding(
                graphRecord: graphRecord,
                constraintEntity: active.identity,
                first: firstEndpoint,
                second: secondEndpoint,
                creationCommand: creation,
                creationSequence: queued[0].sequence,
                disableOnRemove: disableOnRemove,
                firstConstraintSlot: firstSlot,
                secondConstraintSlot: secondSlot
            )
            store.insert(binding)
            return [constraintValue]
        } catch {
            if linkedFirst {
                try? state.setRawTableValue(
                    .nilValue,
                    for: .number(Double(firstSlot)),
                    in: firstConstraints
                )
            }
            if !queued.isEmpty {
                commandQueue.rollbackCanonicalPhysicsConstraintCommands(
                    queued
                )
            }
            if let createdEntity {
                _ = try? entityHost.rollbackUnpublishedCanonicalEntity(
                    createdEntity.identity
                )
            }
            _ = constraintGraph.remove(identifier: graphRecord.identifier)
            throw LuaError.runtime("constraint.NoCollide failed: \(error)")
        }
    }

    private func remove(
        binding: SourceCanonicalNoCollideConstraintBinding
    ) throws {
        guard let entityHost = entityHost.value,
              let commandQueue = commandQueue.value else {
            throw LuaError.runtime(
                "constraint.NoCollide removal SERVER authority is unavailable"
            )
        }
        let commands = try commandQueue
            .enqueueCanonicalPhysicsConstraintCommands([
                .delete(SourcePhysicsConstraintDeletionCommand(
                    constraintID: binding.constraintID
                )),
            ])
        do {
            try validateQueuedCommands(
                commands,
                expected: [
                    .delete(SourcePhysicsConstraintDeletionCommand(
                        constraintID: binding.constraintID
                    )),
                ]
            )
            _ = try entityHost.markCanonicalEntityForRemoval(
                binding.constraintEntity
            )
        } catch {
            commandQueue.rollbackCanonicalPhysicsConstraintCommands(commands)
            throw error
        }
        removeConstraintLink(
            from: binding.first,
            slot: binding.firstConstraintSlot,
            constraint: binding.constraintEntity
        )
        removeConstraintLink(
            from: binding.second,
            slot: binding.secondConstraintSlot,
            constraint: binding.constraintEntity
        )
        _ = store.remove(constraintEntity: binding.constraintEntity)
        _ = constraintGraph.remove(identifier: binding.graphRecord.identifier)
    }

    private func populateLuaConstraintTable(
        constraintValue: LuaValue,
        firstValue: LuaValue,
        secondValue: LuaValue,
        firstBone: Int,
        secondBone: Int,
        disableOnRemove: Bool,
        constraintID: SourcePhysicsConstraintID
    ) throws {
        guard let table = registry.luaTable(for: constraintValue) else {
            throw LuaError.runtime(
                "constraint.NoCollide constraint Entity table is unavailable"
            )
        }
        let fields: [(String, LuaValue)] = [
            ("Type", .string("NoCollide")),
            ("Ent1", firstValue),
            ("Ent2", secondValue),
            ("Bone1", .number(Double(firstBone))),
            ("Bone2", .number(Double(secondBone))),
            ("disableOnRemove", .boolean(disableOnRemove)),
            ("ConstraintID", .number(Double(constraintID.rawValue))),
        ]
        for (name, value) in fields {
            try state.setRawTableValue(
                value,
                for: .string(LuaString(name)),
                in: table
            )
        }
    }

    private func constraintArray(
        for entityTable: LuaTable,
        function: String
    ) throws -> LuaTable {
        switch try state.rawTableValue(
            for: .string("Constraints"),
            in: entityTable
        ) {
        case let .table(existing):
            return existing
        case .nilValue:
            let created = LuaTable()
            try state.setRawTableValue(
                .table(created),
                for: .string("Constraints"),
                in: entityTable
            )
            return created
        default:
            throw LuaError.runtime(
                "\(function) endpoint Constraints field is not a table"
            )
        }
    }

    private func firstFreeSlot(
        in table: LuaTable,
        startingAfter previous: Int? = nil
    ) throws -> Int {
        var index = (previous ?? 0) + 1
        while !(try state.rawTableValue(
            for: .number(Double(index)),
            in: table
        ).isNil) {
            index += 1
        }
        return index
    }

    private func removeConstraintLink(
        from endpoint: SourceCanonicalNoCollideEndpoint,
        slot: Int,
        constraint: SourceCanonicalEntityIdentity
    ) {
        let endpointValue = registry.entity(at: endpoint.entity.entryIndex)
        guard registry.canonicalIdentity(for: endpointValue) == endpoint.entity,
              let endpointTable = registry.luaTable(for: endpointValue),
              case let .table(constraints) = try? state.rawTableValue(
                  for: .string("Constraints"),
                  in: endpointTable
              ),
              let value = try? state.rawTableValue(
                  for: .number(Double(slot)),
                  in: constraints
              ),
              registry.canonicalIdentity(for: value) == constraint else {
            return
        }
        try? state.setRawTableValue(
            .nilValue,
            for: .number(Double(slot)),
            in: constraints
        )
    }

    private func validateQueuedCommands(
        _ queued: [SourcePhysicsCommand],
        expected: [SourceCanonicalQueuedPhysicsConstraintCommand]
    ) throws {
        guard queued.count == expected.count else {
            throw LuaError.runtime(
                "constraint.NoCollide backend returned mismatched FIFO count"
            )
        }
        var previous: UInt64?
        for (command, expectedCommand) in zip(queued, expected) {
            guard command.sequence != 0,
                  previous == nil || command.sequence > previous!,
                  command.payload == expectedCommand.payload else {
                throw LuaError.runtime(
                    "constraint.NoCollide backend returned mismatched FIFO " +
                    "commands"
                )
            }
            previous = command.sequence
        }
    }

    private func canonicalSnapshot(
        _ value: LuaValue?
    ) -> SourceCanonicalEntitySnapshot? {
        guard let value else { return nil }
        return registry.canonicalSnapshot(for: value)
    }

    private func exactNonNegativeInteger(_ value: LuaValue) -> Int? {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              let result = Int(exactly: number),
              result >= 0 else { return nil }
        return result
    }

    private func fallbackEntityRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> [LuaValue] {
        guard !previousEntityRemove.isCallable,
              let entityHost = entityHost.value else { return [] }
        _ = try entityHost.markCanonicalEntityForRemoval(identity)
        return []
    }

    private func callPrevious(
        _ callable: LuaValue,
        arguments: [LuaValue],
        fallback: @autoclosure () throws -> [LuaValue]
    ) throws -> [LuaValue] {
        guard callable.isCallable else { return try fallback() }
        return try state.call(callable, arguments: arguments)
    }

    private func native(
        _ name: String,
        retaining retained: [LuaValue],
        body: @escaping LuaNativeFunction
    ) -> LuaValue {
        .nativeFunction(LuaNativeFunctionBox(
            body,
            debugName: name,
            gcReferences: { [weak self] in
                guard let self else { return retained }
                let entities = self.store.bindings.compactMap { binding in
                    let value = self.registry.entity(
                        at: binding.constraintEntity.entryIndex
                    )
                    return self.registry.canonicalIdentity(for: value) ==
                        binding.constraintEntity ? value : nil
                }
                return retained + entities
            }
        ))
    }
}

private extension LuaValue {
    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }

    var isCallable: Bool {
        switch self {
        case .luaFunction, .nativeFunction: return true
        default: return false
        }
    }

    var luaTruth: Bool {
        switch self {
        case .nilValue, .boolean(false): return false
        default: return true
        }
    }

    var booleanValue: Bool? {
        guard case let .boolean(value) = self else { return nil }
        return value
    }

    var nonNegativeIntegerValue: Int? {
        guard case let .number(value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              let integer = Int(exactly: value),
              integer >= 0 else { return nil }
        return integer
    }
}

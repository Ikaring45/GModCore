import Foundation
import GModLua

/// Compensation seam for a helper entity whose create/spawn/activate journal
/// has not yet been published. The ordinary Entity ABI intentionally exposes
/// only created-state rollback; multi-step native constraints need this
/// narrower all-lifecycle transaction boundary.
public protocol SourceCanonicalUnpublishedEntityRollbackHost: AnyObject {
    @discardableResult
    func rollbackUnpublishedCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot
}

extension GMLuaSourceRuntimeAdapter:
    SourceCanonicalUnpublishedEntityRollbackHost {}

public struct SourceCanonicalWeldConstraintBinding: Equatable, Sendable {
    public let graphIdentifier: UInt64
    public let physicsConstraintID: SourcePhysicsConstraintID
    public let constraintEntity: SourceCanonicalEntityIdentity
    public let firstEntity: SourceCanonicalEntityIdentity
    public let secondEntity: SourceCanonicalEntityIdentity
    public let firstBodyID: SourcePhysicsBodyID
    public let secondBodyID: SourcePhysicsBodyID
}

/// Engine-owned cross-reference between Source's constraint Entity, the
/// canonical topology graph, and the backend constraint identity.
public final class SourceCanonicalWeldConstraintStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bindingsByConstraintHandle: [
        UInt32: SourceCanonicalWeldConstraintBinding
    ] = [:]

    public init() {}

    public var bindings: [SourceCanonicalWeldConstraintBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByConstraintHandle.values.sorted {
            $0.graphIdentifier < $1.graphIdentifier
        }
    }

    func binding(
        for constraintEntity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalWeldConstraintBinding? {
        lock.lock()
        defer { lock.unlock() }
        let binding = bindingsByConstraintHandle[
            constraintEntity.handle.rawValue
        ]
        guard binding?.constraintEntity == constraintEntity else { return nil }
        return binding
    }

    func bindings(
        involving entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalWeldConstraintBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByConstraintHandle.values.filter {
            $0.firstEntity == entity || $0.secondEntity == entity
        }.sorted { $0.graphIdentifier < $1.graphIdentifier }
    }

    func contains(
        firstBodyID: SourcePhysicsBodyID,
        secondBodyID: SourcePhysicsBodyID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByConstraintHandle.values.contains {
            ($0.firstBodyID == firstBodyID && $0.secondBodyID == secondBodyID) ||
            ($0.firstBodyID == secondBodyID && $0.secondBodyID == firstBodyID)
        }
    }

    func insert(_ binding: SourceCanonicalWeldConstraintBinding) {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            bindingsByConstraintHandle[
                binding.constraintEntity.handle.rawValue
            ] == nil,
            "canonical weld constraint EHANDLE must be unique"
        )
        bindingsByConstraintHandle[
            binding.constraintEntity.handle.rawValue
        ] = binding
    }

    @discardableResult
    func remove(
        constraintEntity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalWeldConstraintBinding? {
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

private final class SourceCanonicalWeldWeakEntityHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: any SourceCanonicalEntityLuaHost) {
        self.value = value
    }
}

private final class SourceCanonicalWeldWeakPhysicsHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalPhysicsObjectLuaHost)?

    init(_ value: any SourceCanonicalPhysicsObjectLuaHost) {
        self.value = value
    }
}

private final class SourceCanonicalWeldWeakCommandQueue: @unchecked Sendable {
    weak var value: (
        any SourceCanonicalPhysicsConstraintCommandQueue &
        SourceCanonicalPropPhysicsMutationCommandQueue
    )?

    init(
        _ value: any SourceCanonicalPhysicsConstraintCommandQueue &
            SourceCanonicalPropPhysicsMutationCommandQueue
    ) {
        self.value = value
    }
}

/// SERVER implementation of the public `constraint.Weld` route used by the
/// bundled Sandbox weld tool.
///
/// The bundled implementation first creates `phys_constraintsystem` and sets
/// additional solver iterations through `SetPhysConstraintSystem`. Those
/// backend policies are not yet authenticated here, so this bridge replaces
/// only the public Weld function and accepts the exact fixed-joint subset the
/// current backend implements: two live canonical bodies, zero force limit,
/// collisions enabled, and no delete-on-break behavior.
public final class SourceCanonicalWeldConstraintGLuaBridge:
    @unchecked Sendable
{
    public let store: SourceCanonicalWeldConstraintStore

    private let runtime: GMLuaRuntime
    private let state: LuaState
    private let registry: GMLuaEntityRegistry
    private let entityHost: SourceCanonicalWeldWeakEntityHost
    private let physicsHost: SourceCanonicalWeldWeakPhysicsHost
    private let commandQueue: SourceCanonicalWeldWeakCommandQueue
    private let constraintGraph: SourceCanonicalConstraintGraph

    private init(
        runtime: GMLuaRuntime,
        registry: GMLuaEntityRegistry,
        entityHost: any SourceCanonicalEntityLuaHost,
        physicsHost: any SourceCanonicalPhysicsObjectLuaHost,
        commandQueue: any SourceCanonicalPhysicsConstraintCommandQueue &
            SourceCanonicalPropPhysicsMutationCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        store: SourceCanonicalWeldConstraintStore
    ) {
        self.runtime = runtime
        state = runtime.state
        self.registry = registry
        self.entityHost = SourceCanonicalWeldWeakEntityHost(entityHost)
        self.physicsHost = SourceCanonicalWeldWeakPhysicsHost(physicsHost)
        self.commandQueue = SourceCanonicalWeldWeakCommandQueue(commandQueue)
        self.constraintGraph = constraintGraph
        self.store = store
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        entityHost: any SourceCanonicalEntityLuaHost,
        physicsHost: any SourceCanonicalPhysicsObjectLuaHost,
        commandQueue: any SourceCanonicalPhysicsConstraintCommandQueue &
            SourceCanonicalPropPhysicsMutationCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        store: SourceCanonicalWeldConstraintStore =
            SourceCanonicalWeldConstraintStore()
    ) throws -> SourceCanonicalWeldConstraintGLuaBridge {
        guard runtime.realm == .server,
              !runtime.isClosed,
              let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime(
                "canonical constraint.Weld requires an open SERVER Entity runtime"
            )
        }
        let bridge = SourceCanonicalWeldConstraintGLuaBridge(
            runtime: runtime,
            registry: registry,
            entityHost: entityHost,
            physicsHost: physicsHost,
            commandQueue: commandQueue,
            constraintGraph: constraintGraph,
            store: store
        )
        try bridge.installFunctions(entityMetatable: entityMetatable)
        return bridge
    }

    private func installFunctions(entityMetatable: LuaTable) throws {
        let constraintTable: LuaTable
        if case let .table(existing) = state.getGlobal("constraint") {
            constraintTable = existing
        } else {
            constraintTable = LuaTable()
        }

        try state.setRawTableValue(
            native("constraint.Weld") { [self] arguments in
                try createWeld(arguments: arguments)
            },
            for: .string("Weld"),
            in: constraintTable
        )
        try state.setRawTableValue(
            native("constraint.RemoveAll") { [self] arguments in
                guard let entity = canonicalSnapshot(arguments.first) else {
                    return [.boolean(false), .number(0)]
                }
                let bindings = store.bindings(involving: entity.identity)
                for binding in bindings {
                    try remove(binding: binding)
                }
                return [
                    .boolean(!bindings.isEmpty),
                    .number(Double(bindings.count)),
                ]
            },
            for: .string("RemoveAll"),
            in: constraintTable
        )
        state.setGlobal("constraint", value: .table(constraintTable))

        // lua/includes/extensions/entity.lua replaces the early native method
        // while init.lua loads. Rebind after that load so the stock tool and
        // constraint module read the engine-owned graph without requiring a
        // fabricated NWBool compatibility layer.
        try state.setRawTableValue(
            native("Entity:IsConstrained") { [self] arguments in
                guard let entity = canonicalSnapshot(arguments.first) else {
                    throw LuaError.runtime(
                        "bad self to 'Entity:IsConstrained' " +
                        "(live canonical Entity expected)"
                    )
                }
                return [.boolean(constraintGraph.hasConstraints(
                    involving: entity.identity
                ))]
            },
            for: .string("IsConstrained"),
            in: entityMetatable
        )

        try state.setRawTableValue(
            native("Entity:Remove") { [self] arguments in
                guard let entity = canonicalSnapshot(arguments.first),
                      let host = entityHost.value else {
                    throw LuaError.runtime(
                        "bad self to 'Entity:Remove' (live canonical Entity expected)"
                    )
                }
                if let binding = store.binding(
                    for: entity.identity
                ) {
                    try remove(binding: binding)
                    return []
                }
                for binding in store.bindings(involving: entity.identity) {
                    try remove(binding: binding)
                }
                _ = try host.markCanonicalEntityForRemoval(entity.identity)
                return []
            },
            for: .string("Remove"),
            in: entityMetatable
        )
    }

    private func createWeld(arguments: [LuaValue]) throws -> [LuaValue] {
        guard arguments.count >= 4,
              let firstEntity = canonicalSnapshot(arguments[0]),
              let secondEntity = canonicalSnapshot(arguments[1]),
              firstEntity.kind == .propPhysics,
              secondEntity.kind == .propPhysics,
              firstEntity.identity != secondEntity.identity,
              let firstSolid = exactNonNegativeInteger(arguments[2]),
              let secondSolid = exactNonNegativeInteger(arguments[3]),
              acceptsZeroForceLimit(arguments),
              acceptsDisabledFlag(arguments, index: 5),
              acceptsDisabledFlag(arguments, index: 6),
              let physicsHost = physicsHost.value,
              let entityHost = entityHost.value,
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
              physicsHost.canonicalPhysicsObject(for: firstBodyID)?.bodyID ==
                firstBodyID,
              physicsHost.canonicalPhysicsObject(for: secondBodyID)?.bodyID ==
                secondBodyID,
              !store.contains(
                firstBodyID: firstBodyID,
                secondBodyID: secondBodyID
              ) else {
            return [.boolean(false)]
        }

        let graphRecord: SourceCanonicalConstraintRecord
        do {
            graphRecord = try constraintGraph.insert(entities: [
                firstEntity.identity,
                secondEntity.identity,
            ])
        } catch {
            return [.boolean(false)]
        }
        let physicsConstraintID = try SourcePhysicsConstraintID(
            rawValue: graphRecord.identifier
        )
        var constraintEntity: SourceCanonicalEntitySnapshot?
        var queuedCommands: [SourcePhysicsCommand] = []
        do {
            let created = try entityHost.createCanonicalEntity(
                kind: .physicsConstraint,
                at: nil,
                state: nil,
                playerUserID: nil
            )
            constraintEntity = created
            let luaConstraint = registry.entity(at: created.identity.entryIndex)
            guard registry.canonicalIdentity(for: luaConstraint) == created.identity else {
                throw LuaError.runtime(
                    "constraint.Weld failed to publish its exact constraint EHANDLE"
                )
            }

            queuedCommands = try commandQueue
                .enqueueCanonicalPhysicsConstraintCommands([
                    .createFixed(try SourcePhysicsFixedConstraintCreationCommand(
                        constraintID: physicsConstraintID,
                        referenceBodyID: secondBodyID,
                        attachedBodyID: firstBodyID
                    )),
                ])
            queuedCommands += try commandQueue.enqueueCanonicalPhysicsBodyCommands([
                .mutate(SourcePhysicsBodyMutationCommand(
                    bodyID: firstBodyID,
                    mutation: .wake
                )),
                .mutate(SourcePhysicsBodyMutationCommand(
                    bodyID: secondBodyID,
                    mutation: .wake
                )),
            ])
            _ = try entityHost.spawnCanonicalEntity(created.identity)
            _ = try entityHost.activateCanonicalEntity(created.identity)

            let binding = SourceCanonicalWeldConstraintBinding(
                graphIdentifier: graphRecord.identifier,
                physicsConstraintID: physicsConstraintID,
                constraintEntity: created.identity,
                firstEntity: firstEntity.identity,
                secondEntity: secondEntity.identity,
                firstBodyID: firstBodyID,
                secondBodyID: secondBodyID
            )
            try populateLuaConstraintTables(
                binding: binding,
                constraintValue: luaConstraint,
                firstValue: arguments[0],
                secondValue: arguments[1],
                firstBone: firstSolid,
                secondBone: secondSolid
            )
            store.insert(binding)
            return [luaConstraint]
        } catch {
            if !queuedCommands.isEmpty {
                commandQueue.rollbackCanonicalPhysicsConstraintCommands(
                    queuedCommands
                )
            }
            if let constraintEntity {
                if let rollbackHost = entityHost as?
                    any SourceCanonicalUnpublishedEntityRollbackHost
                {
                    _ = try? rollbackHost.rollbackUnpublishedCanonicalEntity(
                        constraintEntity.identity
                    )
                } else if entityHost.canonicalSnapshot(
                    for: constraintEntity.identity
                )?.lifecycle == .created {
                    _ = try? entityHost.rollbackCanonicalEntityCreation(
                        constraintEntity.identity
                    )
                }
            }
            _ = constraintGraph.remove(identifier: graphRecord.identifier)
            throw LuaError.runtime("constraint.Weld failed: \(error)")
        }
    }

    private func remove(
        binding: SourceCanonicalWeldConstraintBinding
    ) throws {
        guard let host = entityHost.value,
              let queue = commandQueue.value else {
            throw LuaError.runtime(
                "constraint removal SERVER authority is unavailable"
            )
        }
        let commands = try queue.enqueueCanonicalPhysicsConstraintCommands([
            .delete(SourcePhysicsConstraintDeletionCommand(
                constraintID: binding.physicsConstraintID
            )),
        ])
        do {
            _ = try host.markCanonicalEntityForRemoval(
                binding.constraintEntity
            )
        } catch {
            queue.rollbackCanonicalPhysicsConstraintCommands(commands)
            throw error
        }
        _ = store.remove(constraintEntity: binding.constraintEntity)
        _ = constraintGraph.remove(identifier: binding.graphIdentifier)
    }

    private func populateLuaConstraintTables(
        binding: SourceCanonicalWeldConstraintBinding,
        constraintValue: LuaValue,
        firstValue: LuaValue,
        secondValue: LuaValue,
        firstBone: Int,
        secondBone: Int
    ) throws {
        guard let table = registry.luaTable(for: constraintValue) else {
            throw LuaError.runtime(
                "constraint.Weld constraint Entity table is unavailable"
            )
        }
        let fields: [(String, LuaValue)] = [
            ("Type", .string("Weld")),
            ("Ent1", firstValue),
            ("Ent2", secondValue),
            ("Bone1", .number(Double(firstBone))),
            ("Bone2", .number(Double(secondBone))),
            ("forcelimit", .number(0)),
            ("nocollide", .boolean(false)),
            ("deleteonbreak", .boolean(false)),
            ("ConstraintID", .number(Double(binding.physicsConstraintID.rawValue))),
        ]
        for (name, value) in fields {
            try state.setRawTableValue(
                value,
                for: .string(LuaString(name)),
                in: table
            )
        }
        try appendConstraint(constraintValue, to: firstValue)
        try appendConstraint(constraintValue, to: secondValue)
    }

    private func appendConstraint(
        _ constraint: LuaValue,
        to entity: LuaValue
    ) throws {
        guard let entityTable = registry.luaTable(for: entity) else {
            throw LuaError.runtime(
                "constraint.Weld endpoint Entity table is unavailable"
            )
        }
        let constraints: LuaTable
        switch try state.rawTableValue(
            for: .string("Constraints"),
            in: entityTable
        ) {
        case let .table(existing):
            constraints = existing
        case .nilValue:
            constraints = LuaTable()
            try state.setRawTableValue(
                .table(constraints),
                for: .string("Constraints"),
                in: entityTable
            )
        default:
            throw LuaError.runtime(
                "constraint.Weld endpoint Constraints field is not a table"
            )
        }
        var index = 1
        // Existing arrays may contain holes. Preserve their ordering and use
        // the first free numeric slot, matching Lua's table insertion intent.
        while !(try state.rawTableValue(
            for: .number(Double(index)),
            in: constraints
        ).isNil) {
            index += 1
        }
        try state.setRawTableValue(
            constraint,
            for: .number(Double(index)),
            in: constraints
        )
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

    private func acceptsZeroForceLimit(_ arguments: [LuaValue]) -> Bool {
        guard arguments.indices.contains(4) else { return true }
        switch arguments[4] {
        case .nilValue:
            return true
        case let .number(value):
            return value.isFinite && value == 0
        default:
            return false
        }
    }

    private func acceptsDisabledFlag(
        _ arguments: [LuaValue],
        index: Int
    ) -> Bool {
        guard arguments.indices.contains(index) else { return true }
        switch arguments[index] {
        case .nilValue, .boolean(false):
            return true
        default:
            return false
        }
    }

    private func native(
        _ name: String,
        body: @escaping LuaNativeFunction
    ) -> LuaValue {
        .nativeFunction(LuaNativeFunctionBox(
            body,
            debugName: name,
            gcReferences: { [weak self] in
                guard let self else { return [] }
                return self.store.bindings.compactMap {
                    let value = self.registry.entity(
                        at: $0.constraintEntity.entryIndex
                    )
                    return self.registry.canonicalIdentity(for: value) ==
                        $0.constraintEntity ? value : nil
                }
            }
        ))
    }
}

private extension LuaValue {
    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }
}

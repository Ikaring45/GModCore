import Foundation
import GModLua

/// Source distinguishes a dynamic VPhysics solid from worldspawn's immutable
/// static collision scene. Retaining that distinction at the rope boundary
/// prevents a world attachment from being mistaken for a fabricated dynamic
/// body while still preserving the complete EHANDLE and solid index.
public enum SourceCanonicalRopePhysicsEndpointKind:
    Equatable, Sendable
{
    case dynamicBody
    case staticWorld
}

public struct SourceCanonicalRopePhysicsEndpoint:
    Equatable, Sendable
{
    public let entity: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID
    public let kind: SourceCanonicalRopePhysicsEndpointKind
    public let localAnchor: SourceVector3
    public let worldAnchor: SourceVector3

    public init(
        entity: SourceCanonicalEntityIdentity,
        bodyID: SourcePhysicsBodyID,
        kind: SourceCanonicalRopePhysicsEndpointKind,
        localAnchor: SourceVector3,
        worldAnchor: SourceVector3
    ) {
        self.entity = entity
        self.bodyID = bodyID
        self.kind = kind
        self.localAnchor = localAnchor
        self.worldAnchor = worldAnchor
    }
}

public struct SourceCanonicalRopeColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Rendering remains a separate capability from the physical length
/// constraint. A caller can therefore observe that a real physical command
/// was accepted without receiving a fake `keyframe_rope` Entity.
public enum SourceCanonicalRopeRenderingState:
    Equatable, Sendable
{
    case suppressedByNonPositiveWidth
    case unavailableKeyframeRopeEntity
}

/// Exact, backend-neutral request produced by public `constraint.Rope`.
///
/// `additionalLength` is Source's authored value after its documented
/// `[-56756, 56756]` clamp. `maximumLength` is the value submitted to the
/// length-controller backend. The request never substitutes a fixed joint.
public struct SourceCanonicalRopeConstraintCreationRequest:
    Equatable, Sendable
{
    public let constraintID: SourcePhysicsConstraintID
    public let first: SourceCanonicalRopePhysicsEndpoint
    public let second: SourceCanonicalRopePhysicsEndpoint
    public let authoredLength: Float
    public let additionalLength: Float
    public let maximumLength: Float
    public let forceLimit: Float
    public let width: Float
    public let material: LuaString
    public let isRigid: Bool
    public let color: SourceCanonicalRopeColor?

    public init(
        constraintID: SourcePhysicsConstraintID,
        first: SourceCanonicalRopePhysicsEndpoint,
        second: SourceCanonicalRopePhysicsEndpoint,
        authoredLength: Float,
        additionalLength: Float,
        maximumLength: Float,
        forceLimit: Float,
        width: Float,
        material: LuaString,
        isRigid: Bool,
        color: SourceCanonicalRopeColor?
    ) {
        self.constraintID = constraintID
        self.first = first
        self.second = second
        self.authoredLength = authoredLength
        self.additionalLength = additionalLength
        self.maximumLength = maximumLength
        self.forceLimit = forceLimit
        self.width = width
        self.material = material
        self.isRigid = isRigid
        self.color = color
    }
}

public enum SourceCanonicalRopeConstraintCommand:
    Equatable, Sendable
{
    case create(SourceCanonicalRopeConstraintCreationRequest)
    case wake(SourcePhysicsBodyID)
    case delete(SourcePhysicsConstraintID)
}

/// One command accepted by a real rope backend at a sequence allocated from
/// the host's existing net/console/entity/physics FIFO.
public struct SourceCanonicalQueuedRopeConstraintCommand:
    Equatable, Sendable
{
    public let sequence: UInt64
    public let command: SourceCanonicalRopeConstraintCommand

    public init(
        sequence: UInt64,
        command: SourceCanonicalRopeConstraintCommand
    ) {
        self.sequence = sequence
        self.command = command
    }
}

public enum SourceCanonicalRopeConstraintBackendError:
    Error, Equatable, Sendable
{
    /// A backend may reject the length controller itself. This is distinct
    /// from the renderer being unavailable and must never create a live
    /// canonical constraint Entity.
    case lengthConstraintControllerUnavailable
    case rigidLengthConstraintUnavailable
    case flexibleLengthConstraintUnavailable
    case breakableLengthConstraintUnavailable
    case staticWorldEndpointUnavailable(SourcePhysicsBodyID)
}

/// Transactional backend seam. Implementations must allocate sequences from
/// the same global FIFO as net, console, canonical Entity replication, and
/// rigid-body work. Rollback removes only the exact unconsumed suffix and does
/// not reuse its sequence numbers.
public protocol SourceCanonicalRopeConstraintCommandQueue: AnyObject {
    @discardableResult
    func enqueueCanonicalRopeConstraintCommands(
        _ commands: [SourceCanonicalRopeConstraintCommand]
    ) throws -> [SourceCanonicalQueuedRopeConstraintCommand]

    func rollbackCanonicalRopeConstraintCommands(
        _ commands: [SourceCanonicalQueuedRopeConstraintCommand]
    )
}

public struct SourceCanonicalRopeConstraintBinding:
    Equatable, Sendable
{
    public let graphIdentifier: UInt64
    public let constraintEntity: SourceCanonicalEntityIdentity
    public let request: SourceCanonicalRopeConstraintCreationRequest
    public let renderingState: SourceCanonicalRopeRenderingState
    public let creationCommands: [SourceCanonicalQueuedRopeConstraintCommand]
}

public enum SourceCanonicalRopeConstraintFailure:
    Equatable, Sendable
{
    case invalidArguments
    case endpointUnavailable(SourceCanonicalEntityIdentity, solidIndex: Int)
    case identicalPhysicsEndpointsRequireKeyframeRope
    case backend(SourceCanonicalRopeConstraintBackendError)
}

/// Engine-owned mapping between a canonical constraint Entity and the exact
/// length-controller request accepted by the backend.
public final class SourceCanonicalRopeConstraintStore:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var bindingsByHandle: [UInt32: SourceCanonicalRopeConstraintBinding]
        = [:]
    private var lastFailureStorage: SourceCanonicalRopeConstraintFailure?

    public init() {}

    public var bindings: [SourceCanonicalRopeConstraintBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByHandle.values.sorted {
            $0.graphIdentifier < $1.graphIdentifier
        }
    }

    public var lastFailure: SourceCanonicalRopeConstraintFailure? {
        lock.lock()
        defer { lock.unlock() }
        return lastFailureStorage
    }

    fileprivate func recordFailure(
        _ failure: SourceCanonicalRopeConstraintFailure?
    ) {
        lock.lock()
        lastFailureStorage = failure
        lock.unlock()
    }

    fileprivate func insert(_ binding: SourceCanonicalRopeConstraintBinding) {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            bindingsByHandle[binding.constraintEntity.handle.rawValue] == nil,
            "canonical rope constraint EHANDLE must be unique"
        )
        bindingsByHandle[binding.constraintEntity.handle.rawValue] = binding
        lastFailureStorage = nil
    }

    fileprivate func binding(
        for constraintEntity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalRopeConstraintBinding? {
        lock.lock()
        defer { lock.unlock() }
        let binding = bindingsByHandle[constraintEntity.handle.rawValue]
        guard binding?.constraintEntity == constraintEntity else { return nil }
        return binding
    }

    fileprivate func bindings(
        involving entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalRopeConstraintBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindingsByHandle.values.filter {
            $0.request.first.entity == entity ||
                $0.request.second.entity == entity
        }.sorted { $0.graphIdentifier < $1.graphIdentifier }
    }

    @discardableResult
    fileprivate func remove(
        constraintEntity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalRopeConstraintBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard let binding = bindingsByHandle[
            constraintEntity.handle.rawValue
        ], binding.constraintEntity == constraintEntity else { return nil }
        bindingsByHandle.removeValue(
            forKey: constraintEntity.handle.rawValue
        )
        return binding
    }
}

private final class SourceCanonicalRopeWeakEntityHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: any SourceCanonicalEntityLuaHost) {
        self.value = value
    }
}

private final class SourceCanonicalRopeWeakPhysicsHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalPhysicsObjectLuaHost)?

    init(_ value: any SourceCanonicalPhysicsObjectLuaHost) {
        self.value = value
    }
}

private final class SourceCanonicalRopeWeakCommandQueue:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalRopeConstraintCommandQueue)?

    init(_ value: any SourceCanonicalRopeConstraintCommandQueue) {
        self.value = value
    }
}

/// SERVER adapter for the stock Sandbox `constraint.Rope` API.
///
/// This bridge creates a real canonical constraint Entity only after a typed
/// length-controller command has entered the authoritative FIFO. It never
/// maps Rope onto Weld and never fabricates the unimplemented visual
/// `keyframe_rope`; the second public return is therefore nil until that
/// renderer/entity capability exists.
public final class SourceCanonicalRopeConstraintGLuaBridge:
    @unchecked Sendable
{
    public let store: SourceCanonicalRopeConstraintStore

    private let state: LuaState
    private let registry: GMLuaEntityRegistry
    private let entityHost: SourceCanonicalRopeWeakEntityHost
    private let physicsHost: SourceCanonicalRopeWeakPhysicsHost
    private let commandQueue: SourceCanonicalRopeWeakCommandQueue
    private let constraintGraph: SourceCanonicalConstraintGraph
    private let worldPhysicsBodyID: SourcePhysicsBodyID?
    private let previousEntityRemove: LuaValue
    private let previousRemoveAll: LuaValue
    private let previousRemoveConstraints: LuaValue

    private init(
        state: LuaState,
        registry: GMLuaEntityRegistry,
        entityHost: any SourceCanonicalEntityLuaHost,
        physicsHost: any SourceCanonicalPhysicsObjectLuaHost,
        commandQueue: any SourceCanonicalRopeConstraintCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        worldPhysicsBodyID: SourcePhysicsBodyID?,
        previousEntityRemove: LuaValue,
        previousRemoveAll: LuaValue,
        previousRemoveConstraints: LuaValue,
        store: SourceCanonicalRopeConstraintStore
    ) {
        self.state = state
        self.registry = registry
        self.entityHost = SourceCanonicalRopeWeakEntityHost(entityHost)
        self.physicsHost = SourceCanonicalRopeWeakPhysicsHost(physicsHost)
        self.commandQueue = SourceCanonicalRopeWeakCommandQueue(commandQueue)
        self.constraintGraph = constraintGraph
        self.worldPhysicsBodyID = worldPhysicsBodyID
        self.previousEntityRemove = previousEntityRemove
        self.previousRemoveAll = previousRemoveAll
        self.previousRemoveConstraints = previousRemoveConstraints
        self.store = store
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        entityHost: any SourceCanonicalEntityLuaHost,
        physicsHost: any SourceCanonicalPhysicsObjectLuaHost,
        commandQueue: any SourceCanonicalRopeConstraintCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        worldPhysicsBodyID: SourcePhysicsBodyID? = nil,
        store: SourceCanonicalRopeConstraintStore =
            SourceCanonicalRopeConstraintStore()
    ) throws -> SourceCanonicalRopeConstraintGLuaBridge {
        guard runtime.realm == .server,
              !runtime.isClosed,
              let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime(
                "canonical constraint.Rope requires an open SERVER Entity runtime"
            )
        }
        if let worldPhysicsBodyID {
            guard worldPhysicsBodyID.solidIndex == 0,
                  entityHost.canonicalSnapshot(
                    for: worldPhysicsBodyID.entityIdentity
                  )?.kind == .world else {
                throw LuaError.runtime(
                    "canonical constraint.Rope world physics identity is not " +
                    "the live worldspawn solid zero"
                )
            }
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
        let bridge = SourceCanonicalRopeConstraintGLuaBridge(
            state: state,
            registry: registry,
            entityHost: entityHost,
            physicsHost: physicsHost,
            commandQueue: commandQueue,
            constraintGraph: constraintGraph,
            worldPhysicsBodyID: worldPhysicsBodyID,
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
        try state.setRawTableValue(
            native("constraint.Rope", retaining: []) { [self] arguments in
                try createRope(arguments: arguments)
            },
            for: .string("Rope"),
            in: constraintTable
        )

        try state.setRawTableValue(
            native(
                "constraint.RemoveConstraints",
                retaining: [previousRemoveConstraints]
            ) { [self] arguments in
                guard arguments.count >= 2,
                      case let .string(type) = arguments[1],
                      type.bytes == Array("Rope".utf8),
                      let entity = canonicalSnapshot(arguments.first) else {
                    return try callPrevious(
                        previousRemoveConstraints,
                        arguments: arguments,
                        fallback: [.boolean(false)]
                    )
                }
                let bindings = store.bindings(involving: entity.identity)
                for binding in bindings { try remove(binding: binding) }
                return [.boolean(!bindings.isEmpty)]
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
                let total = bindings.count + previousCount
                return [.boolean(total > 0), .number(Double(total))]
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

    private func createRope(arguments: [LuaValue]) throws -> [LuaValue] {
        guard arguments.count >= 12,
              let firstEntity = canonicalSnapshot(arguments[0]),
              let secondEntity = canonicalSnapshot(arguments[1]),
              let firstSolid = exactNonNegativeInteger(arguments[2]),
              let secondSolid = exactNonNegativeInteger(arguments[3]),
              let firstLocal = sourceVector(arguments[4]),
              let secondLocal = sourceVector(arguments[5]),
              let authoredLength = sourceFloat(arguments[6]),
              let authoredAdditionalLength = sourceFloat(arguments[7]),
              let forceLimit = sourceFloat(arguments[8]),
              let width = sourceFloat(arguments[9]),
              case let .string(material) = arguments[10],
              let isRigid = exactBoolean(arguments[11]),
              authoredLength >= 0,
              forceLimit >= 0 else {
            store.recordFailure(.invalidArguments)
            return [.boolean(false), .nilValue]
        }
        let additionalLength = min(max(
            authoredAdditionalLength,
            -56_756
        ), 56_756)
        let maximumLength = authoredLength + additionalLength
        guard maximumLength.isFinite, maximumLength >= 0 else {
            store.recordFailure(.invalidArguments)
            return [.boolean(false), .nilValue]
        }

        guard let first = physicsEndpoint(
            entity: firstEntity,
            solidIndex: firstSolid,
            localAnchor: firstLocal
        ) else {
            store.recordFailure(.endpointUnavailable(
                firstEntity.identity,
                solidIndex: firstSolid
            ))
            return [.boolean(false), .nilValue]
        }
        guard let second = physicsEndpoint(
            entity: secondEntity,
            solidIndex: secondSolid,
            localAnchor: secondLocal
        ) else {
            store.recordFailure(.endpointUnavailable(
                secondEntity.identity,
                solidIndex: secondSolid
            ))
            return [.boolean(false), .nilValue]
        }
        guard first.bodyID != second.bodyID else {
            store.recordFailure(.identicalPhysicsEndpointsRequireKeyframeRope)
            return [.boolean(false), .nilValue]
        }

        let color = try ropeColor(arguments.indices.contains(12)
            ? arguments[12]
            : .nilValue)
        let graphRecord: SourceCanonicalConstraintRecord
        do {
            graphRecord = try constraintGraph.insert(entities: [
                first.entity,
                second.entity,
            ])
        } catch {
            store.recordFailure(.invalidArguments)
            return [.boolean(false), .nilValue]
        }
        let constraintID = try SourcePhysicsConstraintID(
            rawValue: graphRecord.identifier
        )
        let request = SourceCanonicalRopeConstraintCreationRequest(
            constraintID: constraintID,
            first: first,
            second: second,
            authoredLength: authoredLength,
            additionalLength: additionalLength,
            maximumLength: maximumLength,
            forceLimit: forceLimit,
            width: width,
            material: material,
            isRigid: isRigid,
            color: color
        )

        guard let host = entityHost.value,
              let queue = commandQueue.value else {
            _ = constraintGraph.remove(identifier: graphRecord.identifier)
            throw LuaError.runtime(
                "constraint.Rope SERVER authority is unavailable"
            )
        }
        var createdEntity: SourceCanonicalEntitySnapshot?
        var queued: [SourceCanonicalQueuedRopeConstraintCommand] = []
        do {
            let created = try host.createCanonicalEntity(
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
                    "constraint.Rope failed to publish its exact constraint EHANDLE"
                )
            }

            var commands: [SourceCanonicalRopeConstraintCommand] = [
                .create(request),
            ]
            if first.kind == .dynamicBody {
                commands.append(.wake(first.bodyID))
            }
            if second.kind == .dynamicBody {
                commands.append(.wake(second.bodyID))
            }
            queued = try queue.enqueueCanonicalRopeConstraintCommands(commands)
            try validateQueuedCommands(queued, expected: commands)

            _ = try host.spawnCanonicalEntity(created.identity)
            _ = try host.activateCanonicalEntity(created.identity)
            let renderingState: SourceCanonicalRopeRenderingState = width <= 0
                ? .suppressedByNonPositiveWidth
                : .unavailableKeyframeRopeEntity
            let binding = SourceCanonicalRopeConstraintBinding(
                graphIdentifier: graphRecord.identifier,
                constraintEntity: created.identity,
                request: request,
                renderingState: renderingState,
                creationCommands: queued
            )
            try populateLuaConstraintTable(
                binding: binding,
                constraintValue: constraintValue,
                arguments: arguments,
                material: material
            )
            store.insert(binding)
            return [constraintValue, .nilValue]
        } catch let backend as SourceCanonicalRopeConstraintBackendError {
            rollback(
                queued: queued,
                createdEntity: createdEntity,
                graphIdentifier: graphRecord.identifier
            )
            store.recordFailure(.backend(backend))
            return [.boolean(false), .nilValue]
        } catch {
            rollback(
                queued: queued,
                createdEntity: createdEntity,
                graphIdentifier: graphRecord.identifier
            )
            throw LuaError.runtime("constraint.Rope failed: \(error)")
        }
    }

    private func rollback(
        queued: [SourceCanonicalQueuedRopeConstraintCommand],
        createdEntity: SourceCanonicalEntitySnapshot?,
        graphIdentifier: UInt64
    ) {
        if !queued.isEmpty {
            commandQueue.value?.rollbackCanonicalRopeConstraintCommands(queued)
        }
        if let createdEntity, let host = entityHost.value {
            if let rollbackHost = host as?
                any SourceCanonicalUnpublishedEntityRollbackHost
            {
                _ = try? rollbackHost.rollbackUnpublishedCanonicalEntity(
                    createdEntity.identity
                )
            } else if host.canonicalSnapshot(
                for: createdEntity.identity
            )?.lifecycle == .created {
                _ = try? host.rollbackCanonicalEntityCreation(
                    createdEntity.identity
                )
            }
        }
        _ = constraintGraph.remove(identifier: graphIdentifier)
    }

    private func remove(
        binding: SourceCanonicalRopeConstraintBinding
    ) throws {
        guard let host = entityHost.value,
              let queue = commandQueue.value else {
            throw LuaError.runtime(
                "constraint.Rope removal SERVER authority is unavailable"
            )
        }
        let expected: [SourceCanonicalRopeConstraintCommand] = [
            .delete(binding.request.constraintID),
        ]
        let queued = try queue.enqueueCanonicalRopeConstraintCommands(expected)
        do {
            try validateQueuedCommands(queued, expected: expected)
            _ = try host.markCanonicalEntityForRemoval(
                binding.constraintEntity
            )
        } catch {
            queue.rollbackCanonicalRopeConstraintCommands(queued)
            throw error
        }
        _ = store.remove(constraintEntity: binding.constraintEntity)
        _ = constraintGraph.remove(identifier: binding.graphIdentifier)
    }

    private func physicsEndpoint(
        entity: SourceCanonicalEntitySnapshot,
        solidIndex: Int,
        localAnchor: SourceVector3
    ) -> SourceCanonicalRopePhysicsEndpoint? {
        let bodyID: SourcePhysicsBodyID
        do {
            bodyID = try SourcePhysicsBodyID(
                entityIdentity: entity.identity,
                solidIndex: solidIndex
            )
        } catch {
            return nil
        }
        switch entity.kind {
        case .propPhysics:
            guard let body = physicsHost.value?.canonicalPhysicsObject(
                for: bodyID
            ), body.bodyID == bodyID else { return nil }
            return SourceCanonicalRopePhysicsEndpoint(
                entity: entity.identity,
                bodyID: bodyID,
                kind: .dynamicBody,
                localAnchor: localAnchor,
                worldAnchor: body.transform.transformPointFromLocal(localAnchor)
            )
        case .world:
            guard worldPhysicsBodyID == bodyID else { return nil }
            return SourceCanonicalRopePhysicsEndpoint(
                entity: entity.identity,
                bodyID: bodyID,
                kind: .staticWorld,
                localAnchor: localAnchor,
                worldAnchor: entity.transform.transformPointFromLocal(localAnchor)
            )
        case .player, .physicsConstraint, .playerHands, .weapon:
            return nil
        }
    }

    private func populateLuaConstraintTable(
        binding: SourceCanonicalRopeConstraintBinding,
        constraintValue: LuaValue,
        arguments: [LuaValue],
        material: LuaString
    ) throws {
        guard let table = registry.luaTable(for: constraintValue) else {
            throw LuaError.runtime(
                "constraint.Rope constraint Entity table is unavailable"
            )
        }
        let request = binding.request
        let fields: [(String, LuaValue)] = [
            ("Type", .string("Rope")),
            ("Ent1", arguments[0]),
            ("Ent2", arguments[1]),
            ("Bone1", .number(Double(request.first.bodyID.solidIndex))),
            ("Bone2", .number(Double(request.second.bodyID.solidIndex))),
            ("LPos1", arguments[4]),
            ("LPos2", arguments[5]),
            ("length", .number(Double(request.authoredLength))),
            ("addlength", .number(Double(request.additionalLength))),
            ("forcelimit", .number(Double(request.forceLimit))),
            ("width", .number(Double(request.width))),
            ("material", .string(material)),
            ("rigid", .boolean(request.isRigid)),
            ("color", arguments.indices.contains(12)
                ? arguments[12]
                : .nilValue),
            ("ConstraintID", .number(Double(
                request.constraintID.rawValue
            ))),
            ("RopeRenderAvailable", .boolean(false)),
        ]
        for (name, value) in fields {
            try state.setRawTableValue(
                value,
                for: .string(LuaString(name)),
                in: table
            )
        }
        try appendConstraint(constraintValue, to: arguments[0])
        try appendConstraint(constraintValue, to: arguments[1])
    }

    private func appendConstraint(
        _ constraint: LuaValue,
        to entity: LuaValue
    ) throws {
        guard let entityTable = registry.luaTable(for: entity) else {
            throw LuaError.runtime(
                "constraint.Rope endpoint Entity table is unavailable"
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
                "constraint.Rope endpoint Constraints field is not a table"
            )
        }
        var index = 1
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

    private func validateQueuedCommands(
        _ queued: [SourceCanonicalQueuedRopeConstraintCommand],
        expected: [SourceCanonicalRopeConstraintCommand]
    ) throws {
        guard queued.map(\.command) == expected else {
            throw LuaError.runtime(
                "constraint.Rope backend returned mismatched FIFO commands"
            )
        }
        var previous: UInt64?
        for command in queued {
            guard command.sequence != 0,
                  previous == nil || command.sequence > previous! else {
                throw LuaError.runtime(
                    "constraint.Rope backend returned unordered FIFO sequences"
                )
            }
            previous = command.sequence
        }
    }

    private func sourceVector(_ value: LuaValue) -> SourceVector3? {
        guard let components = try? GMLuaVectorAngle.networkVectorComponents(
            from: value,
            function: "constraint.Rope"
        ), let x = sourceFloat(.number(components.0)),
           let y = sourceFloat(.number(components.1)),
           let z = sourceFloat(.number(components.2)) else { return nil }
        return SourceVector3(x, y, z)
    }

    private func sourceFloat(_ value: LuaValue) -> Float? {
        guard case let .number(number) = value,
              number.isFinite,
              abs(number) <= Double(Float.greatestFiniteMagnitude) else {
            return nil
        }
        return Float(number)
    }

    private func exactNonNegativeInteger(_ value: LuaValue) -> Int? {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              let result = Int(exactly: number),
              result >= 0 else { return nil }
        return result
    }

    private func exactBoolean(_ value: LuaValue) -> Bool? {
        switch value {
        case let .boolean(flag): return flag
        case .nilValue: return false
        default: return nil
        }
    }

    private func ropeColor(_ value: LuaValue) throws
        -> SourceCanonicalRopeColor?
    {
        if case .nilValue = value { return nil }
        guard case let .table(table) = value else {
            throw LuaError.runtime(
                "bad argument #13 to 'constraint.Rope' (Color expected)"
            )
        }
        func component(_ name: String, default defaultValue: UInt8? = nil)
            throws -> UInt8
        {
            let raw = try state.rawTableValue(
                for: .string(LuaString(name)),
                in: table
            )
            if case .nilValue = raw, let defaultValue { return defaultValue }
            guard case let .number(number) = raw,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  let integer = UInt8(exactly: number) else {
                throw LuaError.runtime(
                    "bad Color component '\(name)' in constraint.Rope"
                )
            }
            return integer
        }
        return try SourceCanonicalRopeColor(
            red: component("r"),
            green: component("g"),
            blue: component("b"),
            alpha: component("a", default: 255)
        )
    }

    private func canonicalSnapshot(
        _ value: LuaValue?
    ) -> SourceCanonicalEntitySnapshot? {
        guard let value else { return nil }
        return registry.canonicalSnapshot(for: value)
    }

    private func fallbackEntityRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> [LuaValue] {
        guard !previousEntityRemove.isCallable,
              let host = entityHost.value else { return [] }
        _ = try host.markCanonicalEntityForRemoval(identity)
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

    var booleanValue: Bool? {
        guard case let .boolean(value) = self else { return nil }
        return value
    }

    var nonNegativeIntegerValue: Int? {
        guard case let .number(value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              let result = Int(exactly: value),
              result >= 0 else { return nil }
        return result
    }
}

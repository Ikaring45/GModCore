/// Backend-neutral rigid-body boundary for Source-compatible simulation.
///
/// This file deliberately contains no solver and no backend types. A future
/// VPhysics/Jolt bridge must consume these validated values rather than
/// inventing missing shape, mass, inertia, or entity identity data.
public enum SourcePhysicsContract {
    /// Source's fixed `interval_per_tick`. Callers cannot submit an arbitrary
    /// delta through ``SourcePhysicsSimulateCommand``.
    public static let fixedTimeStepSeconds: Float = 0.015

    /// Bounds published by Source SDK `vphysics_interface.h`.
    public static let minimumMassKilograms: Float = 0.1
    public static let maximumMassKilograms: Float = 50_000
}

public enum SourcePhysicsContractError: Error, Equatable, Sendable {
    case negativeSolidIndex(Int)
    case nonFinite(field: String)
    case negative(field: String)
    case nonPositive(field: String)
    case massOutsideVPhysicsRange(Float)
    case negativeMaterialIndex(field: String, value: Int)
    case triangleMaterialIndexOutsideSevenBits(Int)
    case repeatedTriangleVertexIndex
    case emptyMeshPart
    case triangleIndexOutOfBounds(triangle: Int, vertexIndex: Int, vertexCount: Int)
    case degenerateTriangle(Int)
    case emptyShape
    case convexPartHasInsufficientGeometry(part: Int)
    case invalidSweptHullBounds
    case duplicateIgnoredEntity(UInt32)
    case negativeCollisionGroup(Int32)
    case commandSequenceNotIncreasing(previous: UInt64, current: UInt64)
    case simulationTickNotIncreasing(previous: UInt64, current: UInt64)
    case queryFractionOutsideUnitInterval(Float)
    case zeroQueryNormal
    case duplicateBody(SourcePhysicsBodyID)
    case duplicateQueryID(UInt64)
    case invalidConstraintID(UInt64)
    case constraintReferencesSameBody(SourcePhysicsBodyID)
    case duplicateConstraint(SourcePhysicsConstraintID)
    case constraintReferencesUnknownBody(
        constraintID: SourcePhysicsConstraintID,
        bodyID: SourcePhysicsBodyID
    )
}

/// One physics body remains anchored to the complete Source EHANDLE. The
/// solid index is separate because one Source `vcollide_t` may contain more
/// than one solid; neither field is a backend-owned identifier.
public struct SourcePhysicsBodyID: Equatable, Hashable, Sendable {
    public let entityIdentity: SourceCanonicalEntityIdentity
    public let solidIndex: Int

    public init(
        entityIdentity: SourceCanonicalEntityIdentity,
        solidIndex: Int
    ) throws {
        guard solidIndex >= 0 else {
            throw SourcePhysicsContractError.negativeSolidIndex(solidIndex)
        }
        self.entityIdentity = entityIdentity
        self.solidIndex = solidIndex
    }
}

/// A material-bearing triangle recovered from a real collision shape.
/// VPhysics stores a seven-bit material index per collision triangle.
public struct SourcePhysicsIndexedTriangle: Equatable, Hashable, Sendable {
    public let first: Int
    public let second: Int
    public let third: Int
    public let materialIndex: Int

    public init(
        first: Int,
        second: Int,
        third: Int,
        materialIndex: Int
    ) throws {
        guard first != second, second != third, first != third else {
            throw SourcePhysicsContractError.repeatedTriangleVertexIndex
        }
        guard (0 ... 127).contains(materialIndex) else {
            throw SourcePhysicsContractError
                .triangleMaterialIndexOutsideSevenBits(materialIndex)
        }
        self.first = first
        self.second = second
        self.third = third
        self.materialIndex = materialIndex
    }

    fileprivate var indices: [Int] { [first, second, third] }
}

/// One indexed part of a collision shape. The initializer proves only the
/// memory-safe mesh invariants. Convexity must come from the trusted geometry
/// extraction boundary and is not guessed here.
public struct SourcePhysicsMeshPartSnapshot: Equatable, Sendable {
    public let vertices: [SourceVector3]
    public let triangles: [SourcePhysicsIndexedTriangle]

    public init(
        vertices: [SourceVector3],
        triangles: [SourcePhysicsIndexedTriangle]
    ) throws {
        guard vertices.count >= 3, !triangles.isEmpty else {
            throw SourcePhysicsContractError.emptyMeshPart
        }
        for (vertexIndex, vertex) in vertices.enumerated() {
            try sourcePhysicsRequireFinite(
                vertex,
                field: "shape.vertices[\(vertexIndex)]"
            )
        }
        for (triangleIndex, triangle) in triangles.enumerated() {
            for vertexIndex in triangle.indices {
                guard vertices.indices.contains(vertexIndex) else {
                    throw SourcePhysicsContractError.triangleIndexOutOfBounds(
                        triangle: triangleIndex,
                        vertexIndex: vertexIndex,
                        vertexCount: vertices.count
                    )
                }
            }
            let first = vertices[triangle.first]
            let second = vertices[triangle.second]
            let third = vertices[triangle.third]
            let cross = sourcePhysicsCross(second - first, third - first)
            guard cross.lengthSquared.isFinite, cross.lengthSquared > 0 else {
                throw SourcePhysicsContractError.degenerateTriangle(triangleIndex)
            }
        }
        self.vertices = vertices
        self.triangles = triangles
    }
}

public enum SourcePhysicsShapeTopology: Equatable, Hashable, Sendable {
    /// Individually verified convex pieces, as exposed by
    /// `ICollisionQuery::ConvexCount`.
    case convexParts
    /// General triangle geometry, primarily for static world collision.
    case triangleMesh
}

/// Immutable collision geometry. There is intentionally no empty/placeholder
/// case: unavailable PHY geometry must stop body creation.
public struct SourcePhysicsShapeSnapshot: Equatable, Sendable {
    public let topology: SourcePhysicsShapeTopology
    public let parts: [SourcePhysicsMeshPartSnapshot]

    public init(
        topology: SourcePhysicsShapeTopology,
        parts: [SourcePhysicsMeshPartSnapshot]
    ) throws {
        guard !parts.isEmpty else {
            throw SourcePhysicsContractError.emptyShape
        }
        if topology == .convexParts {
            for (partIndex, part) in parts.enumerated()
            where part.vertices.count < 4 || part.triangles.count < 4 {
                throw SourcePhysicsContractError
                    .convexPartHasInsufficientGeometry(part: partIndex)
            }
        }
        self.topology = topology
        self.parts = parts
    }
}

/// Source-compatible mass data. `principalInertia` mirrors the Vector exposed
/// by `IPhysicsObject::GetInertia`/`SetInertia`; it is never synthesized from
/// bounds or a fallback density.
public struct SourcePhysicsMassProperties: Equatable, Sendable {
    public let massKilograms: Float
    public let principalInertia: SourceVector3

    public init(
        massKilograms: Float,
        principalInertia: SourceVector3
    ) throws {
        guard massKilograms.isFinite else {
            throw SourcePhysicsContractError.nonFinite(field: "massKilograms")
        }
        guard
            (SourcePhysicsContract.minimumMassKilograms ...
                SourcePhysicsContract.maximumMassKilograms)
                .contains(massKilograms)
        else {
            throw SourcePhysicsContractError.massOutsideVPhysicsRange(massKilograms)
        }
        try sourcePhysicsRequireFinite(principalInertia, field: "principalInertia")
        guard
            principalInertia.x > 0,
            principalInertia.y > 0,
            principalInertia.z > 0
        else {
            throw SourcePhysicsContractError.nonPositive(field: "principalInertia")
        }
        self.massKilograms = massKilograms
        self.principalInertia = principalInertia
    }
}

/// Backend-neutral linear and angular damping coefficients carried by one
/// VPhysics object.
///
/// Valve's fixed Source SDK initializes both `objectparams_t::damping` and
/// `objectparams_t::rotdamping` to `0.1`. Model solid data may replace those
/// values before body creation, and `IPhysicsObject::SetDamping` may replace
/// them later. Negative or non-finite coefficients never enter a backend.
public struct SourcePhysicsDamping: Equatable, Hashable, Sendable {
    public static let zero = SourcePhysicsDamping(
        validatedLinear: 0,
        validatedAngular: 0
    )
    public static let sourceDefault = SourcePhysicsDamping(
        validatedLinear: 0.1,
        validatedAngular: 0.1
    )

    public let linear: Float
    public let angular: Float

    public init(linear: Float, angular: Float) throws {
        guard linear.isFinite else {
            throw SourcePhysicsContractError.nonFinite(field: "linearDamping")
        }
        guard angular.isFinite else {
            throw SourcePhysicsContractError.nonFinite(field: "angularDamping")
        }
        guard linear >= 0 else {
            throw SourcePhysicsContractError.negative(field: "linearDamping")
        }
        guard angular >= 0 else {
            throw SourcePhysicsContractError.negative(field: "angularDamping")
        }
        self.linear = linear
        self.angular = angular
    }

    private init(validatedLinear: Float, validatedAngular: Float) {
        linear = validatedLinear
        angular = validatedAngular
    }
}

public enum SourcePhysicsMotionType: Equatable, Hashable, Sendable {
    case staticBody
    case dynamicBody
    case kinematicBody
}

/// Full creation input for one body. Every field that changes physical
/// behavior is explicit; there are no guessed mass/inertia/shape defaults.
public struct SourcePhysicsBodyCreationCommand: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let shape: SourcePhysicsShapeSnapshot
    public let massProperties: SourcePhysicsMassProperties
    public let transform: SourceEntityTransform
    public let linearVelocity: SourceVector3
    public let angularVelocity: SourceVector3
    public let damping: SourcePhysicsDamping
    public let motionType: SourcePhysicsMotionType
    public let materialIndex: Int
    public let isGravityEnabled: Bool
    public let isCollisionEnabled: Bool
    public let startsAwake: Bool

    public init(
        bodyID: SourcePhysicsBodyID,
        shape: SourcePhysicsShapeSnapshot,
        massProperties: SourcePhysicsMassProperties,
        transform: SourceEntityTransform,
        linearVelocity: SourceVector3,
        angularVelocity: SourceVector3,
        damping: SourcePhysicsDamping,
        motionType: SourcePhysicsMotionType,
        materialIndex: Int,
        isGravityEnabled: Bool,
        isCollisionEnabled: Bool,
        startsAwake: Bool
    ) throws {
        try sourcePhysicsRequireFinite(transform, field: "transform")
        try sourcePhysicsRequireFinite(linearVelocity, field: "linearVelocity")
        try sourcePhysicsRequireFinite(angularVelocity, field: "angularVelocity")
        guard materialIndex >= 0 else {
            throw SourcePhysicsContractError.negativeMaterialIndex(
                field: "materialIndex",
                value: materialIndex
            )
        }
        self.bodyID = bodyID
        self.shape = shape
        self.massProperties = massProperties
        self.transform = transform
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.damping = damping
        self.motionType = motionType
        self.materialIndex = materialIndex
        self.isGravityEnabled = isGravityEnabled
        self.isCollisionEnabled = isCollisionEnabled
        self.startsAwake = startsAwake
    }
}

public struct SourcePhysicsBodyDeletionCommand: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID

    public init(bodyID: SourcePhysicsBodyID) {
        self.bodyID = bodyID
    }
}

/// One authoritative mutation of an existing rigid body.
///
/// Vector-bearing operations are validated at construction, before they can
/// enter the host's global FIFO. `centerForce` is accumulated until the next
/// fixed 0.015-second simulation command (the established backend-neutral
/// center-force contract). Valve's VPhysics `ApplyForceOffset` input is an
/// impulse in kg*in/s; that offset operation therefore changes linear/angular
/// velocity at its exact FIFO position while retaining the world application
/// point. The explicit
/// `centerImpulse` spelling is kept for backend-neutral callers which already
/// distinguish an impulse from the tick-accumulated center-force operation.
public enum SourcePhysicsBodyMutation: Equatable, Sendable {
    case wake
    case sleep
    case setMotionEnabled(Bool)
    case setGravityEnabled(Bool)
    case setCollisionEnabled(Bool)
    case setLinearVelocity(SourceVector3)
    case addLinearVelocity(SourceVector3)
    case setAngularVelocity(SourceVector3)
    case addAngularVelocity(SourceVector3)
    case applyCenterForce(SourceVector3)
    case applyForceOffset(
        force: SourceVector3,
        worldPosition: SourceVector3
    )
    case applyCenterImpulse(SourceVector3)
    /// Valve `AngularImpulse`: HL/world axes, kilograms-degrees/second.
    case applyTorqueCenter(SourceVector3)
    case setDamping(linear: Float, angular: Float)
    case setMassKilograms(Float)
    /// `teleport` preserves GLua's optional `PhysObj:SetPos` collision mode.
    case setPosition(SourceVector3, teleport: Bool)
    case setAngles(SourceQAngle)
}

public struct SourcePhysicsBodyMutationCommand: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let mutation: SourcePhysicsBodyMutation

    public init(
        bodyID: SourcePhysicsBodyID,
        mutation: SourcePhysicsBodyMutation
    ) throws {
        switch mutation {
        case let .setLinearVelocity(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.linearVelocity"
            )
        case let .addLinearVelocity(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.linearVelocityDelta"
            )
        case let .setAngularVelocity(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.angularVelocity"
            )
        case let .addAngularVelocity(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.angularVelocityDelta"
            )
        case let .applyCenterForce(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.centerForce"
            )
        case let .applyForceOffset(force, worldPosition):
            try sourcePhysicsRequireFinite(
                force,
                field: "bodyMutation.offsetForce"
            )
            try sourcePhysicsRequireFinite(
                worldPosition,
                field: "bodyMutation.offsetWorldPosition"
            )
        case let .applyCenterImpulse(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.centerImpulse"
            )
        case let .applyTorqueCenter(value):
            try sourcePhysicsRequireFinite(
                value,
                field: "bodyMutation.centerTorqueImpulse"
            )
        case let .setDamping(linear, angular):
            guard linear.isFinite else {
                throw SourcePhysicsContractError.nonFinite(
                    field: "bodyMutation.linearDamping"
                )
            }
            guard angular.isFinite else {
                throw SourcePhysicsContractError.nonFinite(
                    field: "bodyMutation.angularDamping"
                )
            }
            guard linear >= 0 else {
                throw SourcePhysicsContractError.negative(
                    field: "bodyMutation.linearDamping"
                )
            }
            guard angular >= 0 else {
                throw SourcePhysicsContractError.negative(
                    field: "bodyMutation.angularDamping"
                )
            }
        case let .setMassKilograms(massKilograms):
            guard massKilograms.isFinite else {
                throw SourcePhysicsContractError.nonFinite(
                    field: "bodyMutation.massKilograms"
                )
            }
            guard
                (SourcePhysicsContract.minimumMassKilograms ...
                    SourcePhysicsContract.maximumMassKilograms)
                    .contains(massKilograms)
            else {
                throw SourcePhysicsContractError
                    .massOutsideVPhysicsRange(massKilograms)
            }
        case let .setPosition(position, _):
            try sourcePhysicsRequireFinite(
                position,
                field: "bodyMutation.position"
            )
        case let .setAngles(angles):
            guard
                angles.pitch.isFinite,
                angles.yaw.isFinite,
                angles.roll.isFinite
            else {
                throw SourcePhysicsContractError.nonFinite(
                    field: "bodyMutation.angles"
                )
            }
        case .wake,
             .sleep,
             .setMotionEnabled,
             .setGravityEnabled,
             .setCollisionEnabled:
            break
        }
        self.bodyID = bodyID
        self.mutation = mutation
    }
}

/// Advances exactly one Source tick. An arbitrary delta is intentionally not
/// representable at this boundary.
public struct SourcePhysicsSimulateCommand: Equatable, Sendable {
    public let simulationTick: UInt64

    public init(simulationTick: UInt64) {
        self.simulationTick = simulationTick
    }
}

public enum SourcePhysicsQueryScope: Equatable, Hashable, Sendable {
    case everything
    case staticOnly
    case movingOnly
    case triggersOnly
    case staticAndMoving
}

public enum SourcePhysicsQueryGeometry: Equatable, Sendable {
    case lineSegment(start: SourceVector3, end: SourceVector3)
    case sweptHull(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3
    )
}

/// One correlated collision query. Filters retain complete EHANDLE values;
/// reducing them to entry indices would make stale generations hittable.
public struct SourcePhysicsQueryCommand: Equatable, Sendable {
    public let queryID: UInt64
    public let geometry: SourcePhysicsQueryGeometry
    public let contentsMask: UInt32
    public let collisionGroup: Int32
    public let scope: SourcePhysicsQueryScope
    public let ignoredEntities: [SourceCanonicalEntityIdentity]

    public init(
        queryID: UInt64,
        geometry: SourcePhysicsQueryGeometry,
        contentsMask: UInt32,
        collisionGroup: Int32,
        scope: SourcePhysicsQueryScope,
        ignoredEntities: [SourceCanonicalEntityIdentity]
    ) throws {
        switch geometry {
        case let .lineSegment(start, end):
            try sourcePhysicsRequireFinite(start, field: "query.start")
            try sourcePhysicsRequireFinite(end, field: "query.end")
        case let .sweptHull(start, end, minimums, maximums):
            try sourcePhysicsRequireFinite(start, field: "query.start")
            try sourcePhysicsRequireFinite(end, field: "query.end")
            try sourcePhysicsRequireFinite(minimums, field: "query.minimums")
            try sourcePhysicsRequireFinite(maximums, field: "query.maximums")
            guard
                minimums.x <= maximums.x,
                minimums.y <= maximums.y,
                minimums.z <= maximums.z
            else {
                throw SourcePhysicsContractError.invalidSweptHullBounds
            }
        }
        guard collisionGroup >= 0 else {
            throw SourcePhysicsContractError.negativeCollisionGroup(collisionGroup)
        }
        var ignoredHandles = Set<UInt32>()
        for identity in ignoredEntities {
            guard ignoredHandles.insert(identity.handle.rawValue).inserted else {
                throw SourcePhysicsContractError
                    .duplicateIgnoredEntity(identity.handle.rawValue)
            }
        }
        self.queryID = queryID
        self.geometry = geometry
        self.contentsMask = contentsMask
        self.collisionGroup = collisionGroup
        self.scope = scope
        self.ignoredEntities = ignoredEntities
    }
}

public enum SourcePhysicsCommandPayload: Equatable, Sendable {
    case createBody(SourcePhysicsBodyCreationCommand)
    case deleteBody(SourcePhysicsBodyDeletionCommand)
    case mutateBody(SourcePhysicsBodyMutationCommand)
    case createFixedConstraint(SourcePhysicsFixedConstraintCreationCommand)
    case deleteConstraint(SourcePhysicsConstraintDeletionCommand)
    case simulate(SourcePhysicsSimulateCommand)
    case query(SourcePhysicsQueryCommand)
}

/// Global FIFO sequence is supplied by the host that already orders console,
/// net, and entity work. Physics does not allocate a second ordering domain.
public struct SourcePhysicsCommand: Equatable, Sendable {
    public let sequence: UInt64
    public let payload: SourcePhysicsCommandPayload

    public init(sequence: UInt64, payload: SourcePhysicsCommandPayload) {
        self.sequence = sequence
        self.payload = payload
    }
}

/// A validated FIFO slice. Sequence gaps are allowed because unrelated host
/// work may occupy them, but reordering and duplicate simulation ticks are not.
public struct SourcePhysicsCommandBatch: Equatable, Sendable {
    public let commands: [SourcePhysicsCommand]

    public init(commands: [SourcePhysicsCommand]) throws {
        var previousSequence: UInt64?
        var previousSimulationTick: UInt64?
        for command in commands {
            if let previousSequence, command.sequence <= previousSequence {
                throw SourcePhysicsContractError.commandSequenceNotIncreasing(
                    previous: previousSequence,
                    current: command.sequence
                )
            }
            previousSequence = command.sequence
            if case let .simulate(simulate) = command.payload {
                if
                    let previousSimulationTick,
                    simulate.simulationTick <= previousSimulationTick
                {
                    throw SourcePhysicsContractError.simulationTickNotIncreasing(
                        previous: previousSimulationTick,
                        current: simulate.simulationTick
                    )
                }
                previousSimulationTick = simulate.simulationTick
            }
        }
        self.commands = commands
    }
}

public struct SourcePhysicsBodySnapshot: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let shape: SourcePhysicsShapeSnapshot
    public let massProperties: SourcePhysicsMassProperties
    public let transform: SourceEntityTransform
    public let linearVelocity: SourceVector3
    public let angularVelocity: SourceVector3
    public let damping: SourcePhysicsDamping
    public let motionType: SourcePhysicsMotionType
    public let materialIndex: Int
    public let isMotionEnabled: Bool
    public let isGravityEnabled: Bool
    public let isCollisionEnabled: Bool
    public let isSleeping: Bool
    public let simulationTick: UInt64

    public init(
        bodyID: SourcePhysicsBodyID,
        shape: SourcePhysicsShapeSnapshot,
        massProperties: SourcePhysicsMassProperties,
        transform: SourceEntityTransform,
        linearVelocity: SourceVector3,
        angularVelocity: SourceVector3,
        damping: SourcePhysicsDamping,
        motionType: SourcePhysicsMotionType,
        materialIndex: Int,
        isMotionEnabled: Bool? = nil,
        isGravityEnabled: Bool,
        isCollisionEnabled: Bool,
        isSleeping: Bool,
        simulationTick: UInt64
    ) throws {
        try sourcePhysicsRequireFinite(transform, field: "transform")
        try sourcePhysicsRequireFinite(linearVelocity, field: "linearVelocity")
        try sourcePhysicsRequireFinite(angularVelocity, field: "angularVelocity")
        guard materialIndex >= 0 else {
            throw SourcePhysicsContractError.negativeMaterialIndex(
                field: "materialIndex",
                value: materialIndex
            )
        }
        self.bodyID = bodyID
        self.shape = shape
        self.massProperties = massProperties
        self.transform = transform
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.damping = damping
        self.motionType = motionType
        self.materialIndex = materialIndex
        self.isMotionEnabled = isMotionEnabled ?? (motionType != .staticBody)
        self.isGravityEnabled = isGravityEnabled
        self.isCollisionEnabled = isCollisionEnabled
        self.isSleeping = isSleeping
        self.simulationTick = simulationTick
    }
}

public struct SourcePhysicsQueryHitSnapshot: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let fraction: Float
    public let position: SourceVector3
    public let normal: SourceVector3
    /// Explicitly nil when a Source trace did not resolve a surface material
    /// (for example, some start-solid results).
    public let materialIndex: Int?
    public let startedSolid: Bool
    public let allSolid: Bool

    public init(
        bodyID: SourcePhysicsBodyID,
        fraction: Float,
        position: SourceVector3,
        normal: SourceVector3,
        materialIndex: Int?,
        startedSolid: Bool,
        allSolid: Bool
    ) throws {
        guard fraction.isFinite else {
            throw SourcePhysicsContractError.nonFinite(field: "queryHit.fraction")
        }
        guard (0 ... 1).contains(fraction) else {
            throw SourcePhysicsContractError.queryFractionOutsideUnitInterval(fraction)
        }
        try sourcePhysicsRequireFinite(position, field: "queryHit.position")
        try sourcePhysicsRequireFinite(normal, field: "queryHit.normal")
        guard normal.lengthSquared > 0 || startedSolid || allSolid else {
            throw SourcePhysicsContractError.zeroQueryNormal
        }
        if let materialIndex, materialIndex < 0 {
            throw SourcePhysicsContractError.negativeMaterialIndex(
                field: "queryHit.materialIndex",
                value: materialIndex
            )
        }
        self.bodyID = bodyID
        self.fraction = fraction
        self.position = position
        self.normal = normal
        self.materialIndex = materialIndex
        self.startedSolid = startedSolid
        self.allSolid = allSolid
    }
}

public struct SourcePhysicsQueryResultSnapshot: Equatable, Sendable {
    public let queryID: UInt64
    public let commandSequence: UInt64
    public let simulationTick: UInt64
    public let hit: SourcePhysicsQueryHitSnapshot?

    public init(
        queryID: UInt64,
        commandSequence: UInt64,
        simulationTick: UInt64,
        hit: SourcePhysicsQueryHitSnapshot?
    ) {
        self.queryID = queryID
        self.commandSequence = commandSequence
        self.simulationTick = simulationTick
        self.hit = hit
    }
}

/// Immutable output of one processed FIFO slice.
public struct SourcePhysicsEnvironmentSnapshot: Equatable, Sendable {
    public let simulationTick: UInt64
    public let lastProcessedCommandSequence: UInt64?
    public let bodies: [SourcePhysicsBodySnapshot]
    public let queryResults: [SourcePhysicsQueryResultSnapshot]
    public let fixedConstraints: [SourcePhysicsFixedConstraintSnapshot]

    public init(
        simulationTick: UInt64,
        lastProcessedCommandSequence: UInt64?,
        bodies: [SourcePhysicsBodySnapshot],
        queryResults: [SourcePhysicsQueryResultSnapshot],
        fixedConstraints: [SourcePhysicsFixedConstraintSnapshot] = []
    ) throws {
        var bodyIDs = Set<SourcePhysicsBodyID>()
        for body in bodies {
            guard bodyIDs.insert(body.bodyID).inserted else {
                throw SourcePhysicsContractError.duplicateBody(body.bodyID)
            }
        }
        var queryIDs = Set<UInt64>()
        for result in queryResults {
            guard queryIDs.insert(result.queryID).inserted else {
                throw SourcePhysicsContractError.duplicateQueryID(result.queryID)
            }
        }
        var constraintIDs = Set<SourcePhysicsConstraintID>()
        for constraint in fixedConstraints {
            guard constraintIDs.insert(constraint.constraintID).inserted else {
                throw SourcePhysicsContractError.duplicateConstraint(
                    constraint.constraintID
                )
            }
            for bodyID in [
                constraint.referenceBodyID,
                constraint.attachedBodyID
            ] where !bodyIDs.contains(bodyID) {
                throw SourcePhysicsContractError.constraintReferencesUnknownBody(
                    constraintID: constraint.constraintID,
                    bodyID: bodyID
                )
            }
        }
        self.simulationTick = simulationTick
        self.lastProcessedCommandSequence = lastProcessedCommandSequence
        self.bodies = bodies
        self.queryResults = queryResults
        self.fixedConstraints = fixedConstraints
    }

    public var fixedTimeStepSeconds: Float {
        SourcePhysicsContract.fixedTimeStepSeconds
    }
}

/// Solver adapter seam. Implementations must execute the validated command
/// order atomically or report failure; partial-success snapshots are not part
/// of this contract.
public protocol SourcePhysicsEnvironment: AnyObject {
    func execute(
        _ batch: SourcePhysicsCommandBatch
    ) throws -> SourcePhysicsEnvironmentSnapshot
}

private func sourcePhysicsRequireFinite(
    _ vector: SourceVector3,
    field: String
) throws {
    guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
        throw SourcePhysicsContractError.nonFinite(field: field)
    }
}

private func sourcePhysicsRequireFinite(
    _ transform: SourceEntityTransform,
    field: String
) throws {
    try sourcePhysicsRequireFinite(transform.origin, field: "\(field).origin")
    guard
        transform.angles.pitch.isFinite,
        transform.angles.yaw.isFinite,
        transform.angles.roll.isFinite
    else {
        throw SourcePhysicsContractError.nonFinite(field: "\(field).angles")
    }
}

private func sourcePhysicsCross(
    _ lhs: SourceVector3,
    _ rhs: SourceVector3
) -> SourceVector3 {
    SourceVector3(
        lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.z * rhs.x - lhs.x * rhs.z,
        lhs.x * rhs.y - lhs.y * rhs.x
    )
}
